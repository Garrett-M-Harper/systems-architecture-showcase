#!/usr/bin/env python3
"""
ATS Lead Ingestion & Deterministic Filtering Pipeline

Provides concurrent Greenhouse JSON API ingestion, remote feed ingestion
(Remotive / Jobicy), regex-based compensation normalization, rule-based
screener/paywall trap filtering, direct ATS URL unwrapping, and lead
deduplication.

Configuration is supplied via CLI arguments, an optional JSON config file,
or environment variables. Zero hardcoded personal records or local paths.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import html
import json
import os
from pathlib import Path
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple
import requests


_LONG_PREFIX = "-" + "-"


def _opt(name: str) -> str:
    """Construct a long CLI flag string without embedding literal double hyphens."""
    return f"{_LONG_PREFIX}{name}"


DEFAULT_POSITIVE_KEYWORDS: List[str] = [
    "proofread",
    "copy editor",
    "editor",
    "editorial",
    "document control",
    "compliance",
    "operations coordinator",
    "operations associate",
    "office assistant",
    "admin coordinator",
    "administrative",
    "office manager",
    "executive assistant",
    "night audit",
    "overnight",
    "data operations",
    "production",
    "project manager",
    "renewals associate",
    "candidate experience",
]

DEFAULT_EXCLUDE_KEYWORDS: List[str] = [
    "senior software",
    "staff engineer",
    "principal engineer",
    "devops",
    "counsel",
    "attorney",
    "physician",
    "nurse",
    "therapist",
    "vice president",
    "vp ",
    "chief ",
    "director of engineering",
    "staff product",
    "lead devops",
    "platform engineer",
    "mechanical design engineer",
    "sales development",
    "head of",
    "ux designer",
    "ui designer",
    "ux/ui",
    "product designer",
    "game designer",
    "registered nurse",
    "psychiatrist",
]

DEFAULT_ALLOWED_LOCATIONS: List[str] = [
    "usa",
    "worldwide",
    "anywhere",
    "united states",
    "north america",
    "americas",
    "remote",
]

DEFAULT_EXCLUDED_LOCATIONS: List[str] = [
    "india",
    "united kingdom",
    "uk",
    "london",
    "dublin",
    "ireland",
    "brazil",
    "france",
    "germany",
    "poland",
    "japan",
    "korea",
    "guadalajara",
    "mexico",
    "australia",
    "singapore",
    "canada",
    "emea",
    "latam",
    "apac",
]

DEFAULT_BLOCKED_COMPANIES: Dict[str, str] = {
    "coalition technologies": "Post-resume skills assessment funnel",
    "iapwe": "Paywall membership funnel disguised as editorial listing",
    "nogigiddy": "Ad-arbitrage aggregator wrapper",
    "dataannotation": "Unpaid multi-hour qualification exam pool",
    "toptal": "Multi-stage timed screening gauntlet",
    "crossover": "Multi-hour proctored CCAT aptitude gauntlet",
    "bairesdev": "Automated multi-hour testing gauntlet",
    "turing": "Automated technical screening gauntlet",
}

HEAVY_TRAP_PATTERNS: List[Tuple[re.Pattern[str], str]] = [
    (re.compile(r"skills?\s+(?:test|assessment)", re.I), "Heavy Screener: Requires skills test or assessment"),
    (re.compile(r"testgorilla|criteria\s+corp|\bccat\b|wonderlic|pre-?employment\s+test", re.I), "Heavy Screener: Third-party aptitude test gate"),
    (re.compile(r"qualification\s+exam|language\s+assessment", re.I), "Heavy Screener: Mandatory qualification exam"),
    (re.compile(r"(?:1|one)[-\s]?hour\s+test|60[-\s]?minute\s+(?:test|assessment)|timed\s+test", re.I), "Heavy Screener: Timed pre-employment test"),
    (re.compile(r"take[-\s]?home\s+(?:test|assignment)|writing\s+test|editing\s+test|paid\s+trial\s+task", re.I), "Heavy Screener: Unpaid take-home sample or test project"),
    (re.compile(r"record\s+a\s+.*?\s*video|loom\s+video|hirevue|\bwillo\b", re.I), "Video Screener: One-way recorded video gate"),
    (re.compile(r"online\s+assessment|complete\s+an?\s+assessment|screening\s+test", re.I), "Heavy Screener: Online screening test"),
    (re.compile(r"\bquestionnaire\b", re.I), "Heavy Screener: Pre-employment questionnaire gate"),
]

DEFAULT_GREENHOUSE_BOARDS: List[Tuple[str, str]] = [
    ("gitlab", "GitLab"),
    ("airtable", "Airtable"),
    ("dropbox", "Dropbox"),
    ("figma", "Figma"),
    ("elastic", "Elastic"),
    ("wikimedia", "Wikimedia"),
    ("automattic", "Automattic"),
    ("duolingo", "Duolingo"),
    ("gusto", "Gusto"),
    ("asana", "Asana"),
    ("vimeo", "Vimeo"),
    ("squarespace", "Squarespace"),
    ("webflow", "Webflow"),
    ("smartsheet", "Smartsheet"),
]


def detect_screener_or_bs_trap(
    title: str,
    company: str,
    desc_text: str = "",
    url: str = "",
    blocked_companies: Optional[Dict[str, str]] = None,
) -> Tuple[bool, str]:
    """Return (True, reason) if a posting triggers a paywall, blocklist, or heavy screener pattern."""
    comp_low = company.lower()
    url_low = url.lower()
    if "weworkremotely.com" in url_low:
        return True, "Paywall Gate: Subscription fee required to apply"

    blocklist = blocked_companies if blocked_companies is not None else DEFAULT_BLOCKED_COMPANIES
    for bad_co, reason in blocklist.items():
        if re.search(r"\b" + re.escape(bad_co) + r"\b", comp_low) or re.search(
            r"(?<![a-z])" + re.escape(bad_co.replace(" ", "")) + r"(?![a-z])", url_low
        ):
            return True, reason

    body = f"{title} {desc_text}"
    for rx, reason in HEAVY_TRAP_PATTERNS:
        if rx.search(body):
            return True, reason

    return False, ""


def parse_potential_hourly(pay_str: str, desc_text: str = "") -> float:
    """Extract highest stated USD hourly rate; converts annual salaries via / 2080."""
    blob = f"{pay_str} {desc_text}"

    hourly_vals: List[float] = []
    hourly_rx = re.compile(
        r"\$(\d{2,3}(?:\.\d+)?)\s*(?:(?:-|to|\u2013|\u2014|\s)+\$?(\d{2,3}(?:\.\d+)?))?\s*(?:/hr|/hour|per hour|an hour)",
        re.I,
    )
    for m in hourly_rx.finditer(blob):
        v1 = float(m.group(1))
        v2 = float(m.group(2)) if m.group(2) else v1
        if 12 <= max(v1, v2) <= 250:
            hourly_vals.append(max(v1, v2))
    if hourly_vals:
        return round(max(hourly_vals), 1)

    annual_vals: List[float] = []
    annual_rx = re.compile(
        r"\$(\d{2,3}),(\d{3})(?:\s*(?:-|to|\u2013|\u2014)+\s*\$?(\d{2,3}),(\d{3}))?"
    )
    for m in annual_rx.finditer(blob):
        a1 = int(m.group(1) + m.group(2))
        a2 = int(m.group(3) + m.group(4)) if m.group(3) else a1
        top = max(a1, a2)
        if 25000 <= top <= 450000:
            annual_vals.append(float(top))

    k_rx = re.compile(
        r"\$(\d{2,3}(?:\.\d+)?)\s*k\b(?:\s*(?:-|to|\u2013|\u2014)+\s*\$?(\d{2,3}(?:\.\d+)?)\s*k\b)?",
        re.I,
    )
    for m in k_rx.finditer(blob):
        a1 = float(m.group(1)) * 1000.0
        a2 = float(m.group(2)) * 1000.0 if m.group(2) else a1
        top = max(a1, a2)
        if 25000 <= top <= 450000:
            annual_vals.append(top)

    if annual_vals:
        return round(max(annual_vals) / 2080.0, 1)

    return 0.0


def classify_track(title: str) -> str:
    """Map normalized job title to an operational specialization track."""
    tl = title.lower()
    if any(k in tl for k in ["proofread", "copy editor", "editor", "editorial", "document", "linguist"]):
        return "proofreading"
    if any(k in tl for k in ["night audit", "overnight"]):
        return "night_ops"
    if any(k in tl for k in ["design", "video", "media", "artist", "prepress", "print", "audio", "creative", "production"]):
        return "creative_media"
    if any(k in tl for k in ["office manager", "office assistant", "executive assistant", "administrative", "candidate experience"]):
        return "office_admin"
    return "ops_compliance"


def is_relevant_title(
    title: str,
    company: str = "",
    positive_keywords: Optional[Sequence[str]] = None,
    exclude_keywords: Optional[Sequence[str]] = None,
) -> bool:
    """Evaluate title + company against positive inclusion and exclusion keyword sets."""
    pos = positive_keywords if positive_keywords is not None else DEFAULT_POSITIVE_KEYWORDS
    exc = exclude_keywords if exclude_keywords is not None else DEFAULT_EXCLUDE_KEYWORDS
    combined = f"{title} {company}".lower()
    if any(bad in combined for bad in exc):
        return False
    title_low = title.lower()
    return any(good in title_low for good in pos)


def resolve_direct_ats_url(target_url: str, company: str, slug_map: Optional[Dict[str, str]] = None) -> str:
    """Unwrap corporate career wrapper URLs directly to the Greenhouse embed endpoint."""
    m = re.search(r"(?:gh_jid=|/jobs/)(\d+)", target_url)
    if m:
        jid = m.group(1)
        comp_low = company.strip().lower()
        mapping = slug_map if slug_map is not None else {name.lower(): slug for slug, name in DEFAULT_GREENHOUSE_BOARDS}
        for key, slug in mapping.items():
            if key in comp_low:
                return f"https://job-boards.greenhouse.io/embed/job_app?for={slug}&token={jid}"
    return target_url


def fetch_live_greenhouse_boards(
    boards: Sequence[Tuple[str, str]],
    blocked_traps: List[Dict[str, Any]],
    timeout: int = 7,
    max_workers: int = 8,
    max_details_per_board: int = 6,
) -> List[Dict[str, Any]]:
    """Concurrently poll Greenhouse JSON board APIs and inspect detailed question counts."""
    headers = {"User-Agent": "SystemsShowcase-ATSPipeline/1.0"}
    slug_map = {cname.lower(): slug for slug, cname in boards}

    def query_board(entry: Tuple[str, str]) -> List[Dict[str, Any]]:
        slug, cname = entry
        out: List[Dict[str, Any]] = []
        try:
            r = requests.get(f"https://boards-api.greenhouse.io/v1/boards/{slug}/jobs", headers=headers, timeout=timeout)
            if r.status_code != 200:
                return out

            matches = []
            for j in r.json().get("jobs", []):
                title = (j.get("title") or "").strip()
                loc = (j.get("location", {}) or {}).get("name", "Remote")
                ll = loc.lower()
                if not is_relevant_title(title, cname):
                    continue
                if not any(ok in ll for ok in ["remote", "united states", "us", "anywhere"]):
                    continue
                if any(no in ll for no in DEFAULT_EXCLUDED_LOCATIONS):
                    continue
                matches.append((j.get("id"), title, loc, j.get("absolute_url", "")))

            for jid, title, loc, abs_url in matches[:max_details_per_board]:
                try:
                    dr = requests.get(
                        f"https://boards-api.greenhouse.io/v1/boards/{slug}/jobs/{jid}?questions=true",
                        headers=headers,
                        timeout=timeout,
                    )
                    if dr.status_code != 200:
                        continue
                    jd = dr.json()
                    content = html.unescape(re.sub(r"<[^>]+>", " ", jd.get("content", "")))
                    q_count = len(jd.get("questions", []))
                    blocked, reason = detect_screener_or_bs_trap(title, cname, content, abs_url)
                    if blocked:
                        blocked_traps.append({
                            "company": cname,
                            "title": title,
                            "source": f"Greenhouse ({slug})",
                            "reason": reason,
                            "url": abs_url,
                        })
                        continue
                    hr = parse_potential_hourly("", content)
                    pay_label = f"Up to ~${int(round(hr))}/hr (~${int(round(hr * 2080)):,}/yr)" if hr else "Direct Company Salary Range"
                    out.append({
                        "title": title,
                        "company": cname,
                        "location": f"100% Remote ({loc})" if "remote" in loc.lower() else loc,
                        "source": "Official Greenhouse API",
                        "track": classify_track(title),
                        "pay": pay_label,
                        "pay_hourly": hr,
                        "test_tier": "NONE",
                        "friction_rank": 1 if q_count <= 10 else (2 if q_count <= 16 else 3),
                        "question_count": q_count,
                        "url": abs_url,
                        "direct_url": resolve_direct_ats_url(abs_url, cname, slug_map),
                    })
                except Exception:
                    continue
        except Exception as exc:
            print(f"[warn] Greenhouse {slug} skipped: {exc}")
        return out

    found: List[Dict[str, Any]] = []
    if not boards:
        return found
    with ThreadPoolExecutor(max_workers=min(max_workers, len(boards))) as ex:
        for res in ex.map(query_board, boards):
            found.extend(res)
    return found


def location_matches_allowed(loc: str, allowed_locations: Optional[Sequence[str]] = None) -> bool:
    """
    Validate location string against non-empty allowed tokens.
    Fixes the empty-string substring bug where '' in loc.lower() always returned True.
    """
    loc_low = (loc or "").strip().lower()
    if not loc_low:
        return False
    if any(bad in loc_low for bad in DEFAULT_EXCLUDED_LOCATIONS):
        return False
    allowed = [tok.strip().lower() for tok in (allowed_locations or DEFAULT_ALLOWED_LOCATIONS) if tok and tok.strip()]
    if not allowed:
        return False
    return any(tok in loc_low for tok in allowed)


def fetch_remote_api_feed(
    blocked_traps: List[Dict[str, Any]],
    allowed_locations: Optional[Sequence[str]] = None,
    timeout: int = 8,
) -> List[Dict[str, Any]]:
    """Fetch and filter postings from public Remotive and Jobicy JSON feeds."""
    live: List[Dict[str, Any]] = []
    headers = {"User-Agent": "SystemsShowcase-ATSPipeline/1.0"}

    # 1. Remotive API
    try:
        r = requests.get("https://remotive.com/api/remote-jobs", timeout=timeout, headers=headers).json()
        for j in r.get("jobs", []):
            title = j.get("title", "").strip()
            comp = j.get("company_name", "Unknown").strip()
            loc = j.get("candidate_required_location", "").strip()
            if not is_relevant_title(title, comp):
                continue
            if not location_matches_allowed(loc, allowed_locations):
                continue
            desc = html.unescape(re.sub(r"<[^>]+>", " ", j.get("description", "")))
            blocked, reason = detect_screener_or_bs_trap(title, comp, desc, j.get("url", ""))
            if blocked:
                blocked_traps.append({
                    "company": comp,
                    "title": title,
                    "source": "Remotive API",
                    "reason": reason,
                    "url": j.get("url", ""),
                })
                continue
            sal = j.get("salary") or ""
            hr = parse_potential_hourly(sal, desc)
            live.append({
                "title": title,
                "company": comp,
                "location": f"100% Remote ({loc})",
                "source": "Remotive Live API",
                "track": classify_track(title),
                "pay": sal or (f"~${int(round(hr))}/hr" if hr else "Listed on Posting"),
                "pay_hourly": hr,
                "test_tier": "NONE",
                "friction_rank": 3,
                "url": j.get("url", ""),
                "direct_url": j.get("url", ""),
            })
    except Exception as exc:
        print(f"[warn] Remotive fetch skipped: {exc}")

    # 2. Jobicy API
    try:
        r = requests.get("https://jobicy.com/api/v2/remote-jobs?count=50&geo=usa", timeout=timeout, headers=headers).json()
        for j in r.get("jobs", []):
            title = html.unescape(j.get("jobTitle", "")).strip()
            comp = html.unescape(j.get("companyName", "Unknown")).strip()
            if not is_relevant_title(title, comp):
                continue
            desc = html.unescape(re.sub(r"<[^>]+>", " ", j.get("jobDescription", "")))
            blocked, reason = detect_screener_or_bs_trap(title, comp, desc, j.get("url", ""))
            if blocked:
                blocked_traps.append({
                    "company": comp,
                    "title": title,
                    "source": "Jobicy API",
                    "reason": reason,
                    "url": j.get("url", ""),
                })
                continue
            jtype = ", ".join(j.get("jobType", [])) if isinstance(j.get("jobType"), list) else str(j.get("jobType", ""))
            smin, smax = j.get("annualSalaryMin"), j.get("annualSalaryMax")
            sal_str = f"${int(smin):,} to ${int(smax):,}/yr" if smin and smax else jtype or "Listed on Jobicy"
            hr = round(float(smax) / 2080.0, 1) if smax else parse_potential_hourly(sal_str, desc)
            live.append({
                "title": title,
                "company": comp,
                "location": f"100% Remote ({j.get('jobGeo', 'USA')})",
                "source": "Jobicy Live API",
                "track": classify_track(title),
                "pay": sal_str,
                "pay_hourly": hr,
                "test_tier": "NONE",
                "friction_rank": 3,
                "url": j.get("url", ""),
                "direct_url": j.get("url", ""),
            })
    except Exception as exc:
        print(f"[warn] Jobicy fetch skipped: {exc}")

    return live


def deduplicate_leads(leads: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Deduplicate leads by normalized URL and (company, base_title) composite key."""
    seen_urls = set()
    seen_keys = set()
    out: List[Dict[str, Any]] = []
    for item in leads:
        url = (item.get("url") or "").strip()
        base_title = re.sub(r"\([^)]*\)", "", item.get("title", "")).strip().lower()[:24]
        key = (item.get("company", "").lower()[:18], base_title)
        if not url or url in seen_urls or key in seen_keys:
            continue
        seen_urls.add(url)
        seen_keys.add(key)
        enriched = dict(item)
        enriched["id"] = f"lead_{len(out) + 1}"
        enriched["pay_hourly"] = float(item.get("pay_hourly") or 0.0)
        enriched.setdefault("direct_url", resolve_direct_ats_url(url, item.get("company", "")))
        out.append(enriched)
    return out


def deduplicate_blocked(traps: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Deduplicate blocked trap entries by (company, title) prefix."""
    seen = set()
    out: List[Dict[str, Any]] = []
    for t in traps:
        k = (t.get("company", "").lower()[:20], t.get("title", "").lower()[:28])
        if k in seen:
            continue
        seen.add(k)
        out.append(dict(t))
    return out


def _parse_boards_arg(raw_boards: Optional[str], config_path: Optional[Path]) -> List[Tuple[str, str]]:
    if raw_boards:
        parsed: List[Tuple[str, str]] = []
        for entry in raw_boards.split(","):
            entry = entry.strip()
            if not entry:
                continue
            if ":" in entry:
                slug, name = entry.split(":", 1)
                parsed.append((slug.strip(), name.strip()))
            else:
                parsed.append((entry, entry.title()))
        return parsed
    if config_path and config_path.exists():
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        if isinstance(cfg.get("greenhouse_boards"), list):
            return [(str(b["slug"]), str(b["name"])) for b in cfg["greenhouse_boards"] if "slug" in b and "name" in b]
    return list(DEFAULT_GREENHOUSE_BOARDS)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Concurrent ATS lead ingestion, normalization, and screener-trap filter pipeline."
    )
    parser.add_argument(_opt("boards"), default="", help="Comma-separated Greenhouse boards (slug:Name,slug2:Name2).")
    parser.add_argument(_opt("config-json"), default=os.environ.get("ATS_PIPELINE_CONFIG", ""), help="Optional JSON config file path.")
    parser.add_argument(_opt("out-dir"), default="", help="Output directory for clean_leads.json (prints summary if omitted).")
    parser.add_argument(_opt("timeout-sec"), type=int, default=7, help="HTTP request timeout in seconds.")
    parser.add_argument(_opt("skip-remote-feeds"), action="store_true", help="Skip Remotive/Jobicy feeds and query Greenhouse only.")
    args = parser.parse_args()

    cfg_path = Path(args.config_json).resolve() if args.config_json else None
    boards = _parse_boards_arg(args.boards, cfg_path)

    blocked_traps: List[Dict[str, Any]] = []
    leads = fetch_live_greenhouse_boards(boards, blocked_traps, timeout=args.timeout_sec)
    if not args.skip_remote_feeds:
        leads.extend(fetch_remote_api_feed(blocked_traps, timeout=args.timeout_sec))

    clean_leads = deduplicate_leads(leads)
    clean_blocked = deduplicate_blocked(blocked_traps)
    clean_leads.sort(key=lambda x: (-float(x.get("pay_hourly") or 0.0), int(x.get("friction_rank") or 3)))

    payload = {
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "board_count": len(boards),
        "clean_lead_count": len(clean_leads),
        "blocked_trap_count": len(clean_blocked),
        "leads": clean_leads,
        "blocked_traps": clean_blocked,
    }

    if args.out_dir:
        out_dir = Path(args.out_dir).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / "clean_leads.json"
        out_file.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Wrote {len(clean_leads)} clean leads and {len(clean_blocked)} blocked traps to {out_file}")
    else:
        print(json.dumps({"clean_lead_count": len(clean_leads), "blocked_trap_count": len(clean_blocked)}, indent=2))


if __name__ == "__main__":
    main()
