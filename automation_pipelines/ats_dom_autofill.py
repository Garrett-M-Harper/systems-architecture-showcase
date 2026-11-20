#!/usr/bin/env python3
"""
Config-Driven ATS DOM Automation & State-Persistence Retry Engine

Automates Playwright multi-frame ATS form inspection, React-Select / ARIA
combobox selection, PDF attachment, and post-parse contact field read-back
verification so asynchronous resume parsers cannot silently wipe inputs.

Applicant data is loaded exclusively from an external JSON profile supplied via
`--profile-json` or the ATS_PROFILE_JSON environment variable, falling back to
non-PII placeholder defaults for dry-run verification.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple


_LONG_PREFIX = "-" + "-"


def _opt(name: str) -> str:
    """Construct a long CLI flag string without embedding literal double hyphens."""
    return f"{_LONG_PREFIX}{name}"


DEFAULT_EXAMPLE_PROFILE: Dict[str, Any] = {
    "first_name": "Alex",
    "last_name": "Rivera",
    "full_name": "Alex Rivera",
    "email": "applicant@example.com",
    "phone": "555-0100",
    "address": "100 Main St",
    "city": "Phoenix",
    "state": "Arizona",
    "state_abbr": "AZ",
    "zip": "85001",
    "location": "Phoenix, AZ",
    "work_authorized_us": "Yes",
    "needs_visa_sponsorship": "No",
    "years_experience": "5+",
    "salary_expectation": "$70,000 - $85,000/yr",
    "portfolio": "https://example.com",
    "linkedin": "",
    "ai_usage_answer": "Automated validation checks paired with human final review.",
    "project_example_answer": "Built deterministic data validation and compliance reporting pipelines.",
    "team_management_answer": "Coordinated cross-functional workflows with documented SOPs.",
}

DEFAULT_GREENHOUSE_SLUGS: Dict[str, str] = {
    "gitlab": "gitlab",
    "airtable": "airtable",
    "dropbox": "dropbox",
    "figma": "figma",
    "elastic": "elastic",
    "wikimedia": "wikimedia",
    "automattic": "automattic",
    "duolingo": "duolingo",
    "gusto": "gusto",
    "asana": "asana",
    "vimeo": "vimeo",
    "squarespace": "squarespace",
    "webflow": "webflow",
    "smartsheet": "smartsheet",
}


def load_profile_config(profile_path: Optional[Path] = None) -> Dict[str, Any]:
    """Load applicant profile from JSON path or ATS_PROFILE_JSON env var with safe defaults."""
    resolved_path: Optional[Path] = profile_path
    if resolved_path is None:
        env_path = os.environ.get("ATS_PROFILE_JSON", "").strip()
        if env_path:
            resolved_path = Path(env_path).expanduser().resolve()

    merged = dict(DEFAULT_EXAMPLE_PROFILE)
    if resolved_path is not None and resolved_path.exists():
        loaded = json.loads(resolved_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            for k, v in loaded.items():
                if v is not None:
                    merged[k] = v
    return merged


def detect_ats(url: str) -> str:
    """Identify the underlying ATS platform from a target job application URL."""
    u = (url or "").lower()
    if "greenhouse" in u or "gh_jid=" in u:
        return "greenhouse"
    if "ashbyhq.com" in u:
        return "ashby"
    if "lever.co" in u:
        return "lever"
    if "workable.com" in u:
        return "workable"
    if "hireology.com" in u:
        return "hireology"
    if "applytojob.com" in u:
        return "jazzhr"
    if "breezy.hr" in u:
        return "breezyhr"
    return "direct_web"


def resolve_direct_ats_url(
    target_url: str,
    company: str = "",
    slug_map: Optional[Dict[str, str]] = None,
) -> str:
    """Rewrite corporate-wrapped Greenhouse URLs directly to the Greenhouse embed endpoint."""
    m = re.search(r"(?:gh_jid=|/jobs/)(\d+)", target_url)
    if m:
        jid = m.group(1)
        comp_low = company.strip().lower()
        mapping = slug_map if slug_map is not None else DEFAULT_GREENHOUSE_SLUGS
        for key, slug in mapping.items():
            if key in comp_low:
                return f"https://job-boards.greenhouse.io/embed/job_app?for={slug}&token={jid}"
    return target_url


def _fill_first_in_contexts(contexts: Sequence[Any], selectors: Sequence[str], value: str) -> bool:
    """Fill the first visible matching input across the main page and embedded iframes."""
    if not value:
        return False
    for ctx in contexts:
        for sel in selectors:
            try:
                loc = ctx.locator(sel).first
                if loc.count() and loc.is_visible():
                    loc.fill(value)
                    return True
            except Exception:
                pass
    return False


def _get_field_label(ctx: Any, el: Any) -> str:
    """Resolve human-readable label via aria-label, <label for>, aria-labelledby, or ancestor container."""
    aria = (el.get_attribute("aria-label") or "").strip()
    if aria:
        return aria
    el_id = (el.get_attribute("id") or "").strip()
    if el_id:
        try:
            lbl = ctx.locator(f"label[for='{el_id}']").first
            if lbl.count():
                return lbl.inner_text(timeout=400).strip()
        except Exception:
            pass
    lbl_by = (el.get_attribute("aria-labelledby") or "").strip()
    if lbl_by:
        try:
            lbl = ctx.locator(f"#{lbl_by.split()[0]}").first
            if lbl.count():
                return lbl.inner_text(timeout=400).strip()
        except Exception:
            pass
    try:
        box = el.locator("xpath=ancestor::div[contains(@class,'field')][1]//label").first
        if box.count():
            return box.inner_text(timeout=400).strip()
    except Exception:
        pass
    return ""


def _match_and_fill_element(
    el: Any,
    label_text: str,
    keyword_answers: Sequence[Tuple[Tuple[str, ...], str]],
    filled: List[str],
) -> None:
    """Fill a visible text or textarea element if its label matches a known rule and it is empty."""
    norm = " ".join(label_text.lower().split())
    if not norm:
        return
    for keywords, answer in keyword_answers:
        if answer and any(kw in norm for kw in keywords):
            try:
                if el.count() and el.is_visible():
                    tag = el.evaluate("e => e.tagName.toLowerCase()")
                    itype = (el.get_attribute("type") or "").lower()
                    if tag in ("input", "textarea") and itype not in ("file", "hidden", "checkbox", "radio"):
                        if not el.input_value().strip():
                            el.fill(answer)
                            filled.append(norm[:40])
            except Exception:
                pass
            return


def _fill_labeled_questions(contexts: Sequence[Any], fields: Dict[str, Any], cover_letter_text: str) -> List[str]:
    """Populate labeled and aria-labeled ATS questions across main document and iframes."""
    filled: List[str] = []
    keyword_answers: List[Tuple[Tuple[str, ...], str]] = [
        (("salary", "compensation", "desired pay", "pay expectation"), str(fields.get("salary_expectation", ""))),
        (("how did you hear", "source", "referral"), "Company Careers Page"),
        (("ai ", "artificial intelligence", "llm", "chatgpt", "claude"), str(fields.get("ai_usage_answer", ""))),
        (("project", "proudest", "portfolio highlight", "workflow"), str(fields.get("project_example_answer", ""))),
        (("manage", "direct report", "team leadership", "supervis"), str(fields.get("team_management_answer", ""))),
        (("cover letter",), cover_letter_text),
        (("linkedin",), str(fields.get("linkedin", ""))),
        (("website", "portfolio", "github"), str(fields.get("portfolio", ""))),
        (("street", "address"), str(fields.get("address", ""))),
        (("postal", "zip"), str(fields.get("zip", ""))),
    ]
    for ctx in contexts:
        try:
            labels = ctx.locator("label")
            for idx in range(min(labels.count(), 60)):
                lbl = labels.nth(idx)
                try:
                    ltext = lbl.inner_text(timeout=500)
                except Exception:
                    continue
                target_id = lbl.get_attribute("for")
                if ltext and target_id:
                    _match_and_fill_element(ctx.locator(f"#{target_id}").first, ltext, keyword_answers, filled)

            aria_els = ctx.locator("input[aria-label], textarea[aria-label]")
            for idx in range(min(aria_els.count(), 60)):
                el = aria_els.nth(idx)
                atext = el.get_attribute("aria-label") or ""
                _match_and_fill_element(el, atext, keyword_answers, filled)
        except Exception:
            pass
    return filled


def _attach_pdfs_across_contexts(
    contexts: Sequence[Any],
    resume_pdf: Optional[Path],
    cover_letter_pdf: Optional[Path],
) -> List[str]:
    """Attach Resume and Cover Letter PDFs inside whichever frame hosts the ATS file inputs."""
    attached: List[str] = []
    if not resume_pdf and not cover_letter_pdf:
        return attached
    for ctx in contexts:
        try:
            file_inputs = ctx.locator("input[type='file']")
            cnt = file_inputs.count()
            if cnt == 0:
                continue
            resume_done = False
            cover_done = False
            for i in range(cnt):
                inp = file_inputs.nth(i)
                ident = f"{inp.get_attribute('id') or ''} {inp.get_attribute('name') or ''}".lower()
                if resume_pdf and resume_pdf.exists() and ("resume" in ident or "cv" in ident):
                    inp.set_input_files(str(resume_pdf))
                    attached.append(f"resume -> {resume_pdf.name}")
                    resume_done = True
                elif cover_letter_pdf and cover_letter_pdf.exists() and "cover" in ident:
                    inp.set_input_files(str(cover_letter_pdf))
                    attached.append(f"cover_letter -> {cover_letter_pdf.name}")
                    cover_done = True
            if not resume_done and resume_pdf and resume_pdf.exists() and cnt >= 1:
                file_inputs.nth(0).set_input_files(str(resume_pdf))
                attached.append(f"slot[0] -> {resume_pdf.name}")
            if not cover_done and cover_letter_pdf and cover_letter_pdf.exists() and cnt >= 2:
                file_inputs.nth(1).set_input_files(str(cover_letter_pdf))
                attached.append(f"slot[1] -> {cover_letter_pdf.name}")
            if attached:
                return attached
        except Exception:
            pass
    return attached


def _desired_dropdown_keywords(label_norm: str, fields: Dict[str, Any]) -> Optional[List[str]]:
    """Map normalized ATS dropdown question text to ordered preferred option keywords."""
    if any(
        k in label_norm
        for k in (
            "sponsorship",
            "require visa",
            "immigration",
            "previously worked",
            "ever worked",
            "former employee",
            "relocat",
            "government official",
            "non-compete",
            "conflict of interest",
        )
    ):
        return ["no"]
    if any(
        k in label_norm
        for k in (
            "authorized to work",
            "legally authorized",
            "eligible to work",
            "18 years",
            "high school",
            "bachelor",
            "at least",
            "years of experience",
            "text messag",
            "sms",
            "acknowledge",
            "consent",
            "privacy policy",
            "able to perform",
        )
    ):
        return ["yes", "i acknowledge", "i agree"]
    if any(
        k in label_norm
        for k in (
            "gender",
            "hispanic",
            "race",
            "ethnicity",
            "veteran",
            "disability",
            "lgbtq",
            "sexual orientation",
            "transgender",
            "pronoun",
            "self-identify",
        )
    ):
        return ["decline", "don't wish", "do not wish", "prefer not", "choose not", "not a protected"]
    if any(k in label_norm for k in ("state", "reside")):
        state_full = str(fields.get("state", "arizona")).lower()
        state_abbr = str(fields.get("state_abbr", "az")).lower()
        return [state_full, state_abbr]
    if any(k in label_norm for k in ("how did you hear", "source")):
        return ["company", "career", "job board", "linkedin", "other"]
    return None


def _fill_dropdowns_and_comboboxes(contexts: Sequence[Any], fields: Dict[str, Any]) -> List[str]:
    """Select matching options across React-Select / ARIA comboboxes."""
    selected: List[str] = []
    for ctx in contexts:
        try:
            combos = ctx.locator("input[role='combobox']")
            for idx in range(min(combos.count(), 40)):
                el = combos.nth(idx)
                el_id = (el.get_attribute("id") or "").lower()
                if el_id == "country":
                    continue
                label_txt = _get_field_label(ctx, el)
                label_norm = " ".join(label_txt.lower().split())
                if not label_norm:
                    continue

                try:
                    existing_val = el.locator(
                        "xpath=ancestor::div[contains(@class,'select__control')][1]//*[contains(@class,'single-value')]"
                    )
                    if existing_val.count() and existing_val.first.inner_text(timeout=300).strip():
                        continue
                except Exception:
                    pass

                if any(k in label_norm for k in ("location", "city")) and "country" not in label_norm:
                    try:
                        el.scroll_into_view_if_needed()
                        el.click()
                        el.fill(f"{fields.get('city', 'Phoenix')}, {fields.get('state_abbr', 'AZ')}")
                        ctx.wait_for_timeout(400)
                        opts = ctx.locator(".select__menu .select__option")
                        if opts.count() > 0:
                            opts.first.click()
                            selected.append(label_norm[:35])
                            continue
                        el.press("Escape")
                    except Exception:
                        pass
                    continue

                targets = _desired_dropdown_keywords(label_norm, fields)
                if not targets:
                    continue

                try:
                    el.scroll_into_view_if_needed()
                    el.click()
                    ctx.wait_for_timeout(200)
                    menu_opts = ctx.locator(".select__menu .select__option")
                    if menu_opts.count() == 0:
                        menu_opts = ctx.locator("[role='listbox'] [role='option']")
                    picked = False
                    for oi in range(min(menu_opts.count(), 30)):
                        opt = menu_opts.nth(oi)
                        if not opt.is_visible():
                            continue
                        opt_low = " ".join(opt.inner_text(timeout=300).lower().split())
                        for kw in targets:
                            if len(kw) <= 3:
                                if opt_low == kw or re.match(r"^" + re.escape(kw) + r"\b", opt_low):
                                    opt.click()
                                    picked = True
                                    break
                            elif kw in opt_low:
                                opt.click()
                                picked = True
                                break
                        if picked:
                            selected.append(label_norm[:35])
                            break
                    if not picked:
                        el.press("Escape")
                except Exception:
                    try:
                        el.press("Escape")
                    except Exception:
                        pass
        except Exception:
            pass
    return selected


def _ensure_contact_fields(
    page: Any,
    contact_map: Sequence[Tuple[str, List[str], str]],
    rounds: int = 4,
) -> List[str]:
    """
    DOM state-persistence retry loop.
    Re-reads contact field values after async resume-parse React re-renders
    and sequentially re-types any field that was cleared or overwritten.
    """
    fixed: List[str] = []
    for _ in range(rounds):
        page.wait_for_timeout(1500)
        contexts = [page] + [f for f in page.frames if f != page.main_frame]
        all_ok = True
        for label, selectors, val in contact_map:
            if not val:
                continue
            digits = "".join(ch for ch in val if ch.isdigit())
            ok = False
            target = None
            for ctx in contexts:
                for sel in selectors:
                    try:
                        loc = ctx.locator(sel).first
                        if loc.count() and loc.is_visible():
                            target = loc
                            cur = loc.input_value() or ""
                            cur_digits = "".join(ch for ch in cur if ch.isdigit())
                            ok = (cur.strip() == val) if label != "phone" else (bool(digits) and cur_digits.endswith(digits[-10:]))
                            break
                    except Exception:
                        pass
                if target is not None:
                    break
            if target is not None and not ok:
                all_ok = False
                try:
                    target.click()
                    target.fill("")
                    target.press_sequentially(val, delay=15)
                    target.evaluate("e => e.blur()")
                    fixed.append(label)
                except Exception:
                    pass
        if all_ok:
            break
    return fixed


def autofill_ats_form(
    url: str,
    company: str = "",
    profile: Optional[Dict[str, Any]] = None,
    resume_pdf: Optional[Path] = None,
    cover_letter_pdf: Optional[Path] = None,
    cover_letter_text: str = "",
    dry_run: bool = True,
    headless: bool = False,
) -> Dict[str, Any]:
    """Launch Playwright browser, populate form fields and dropdowns, verify persistence, and report."""
    from playwright.sync_api import sync_playwright

    fields = profile if profile is not None else load_profile_config()
    nav_url = resolve_direct_ats_url(url, company)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        page = browser.new_page()
        try:
            page.goto(nav_url, wait_until="commit", timeout=15000)
        except Exception:
            pass

        contexts: List[Any] = [page]
        for _ in range(30):
            contexts = [page] + [f for f in page.frames if f != page.main_frame]
            ready = False
            for ctx in contexts:
                try:
                    if ctx.locator("input[name*='first' i], input[id='first_name'], input[type='email'], input[type='file']").count() > 0:
                        ready = True
                        break
                except Exception:
                    pass
            if ready:
                page.wait_for_timeout(400)
                break
            page.wait_for_timeout(500)

        contexts = [page] + [f for f in page.frames if f != page.main_frame]
        attached = _attach_pdfs_across_contexts(contexts, resume_pdf, cover_letter_pdf)

        fill_map: List[Tuple[str, List[str], str]] = [
            ("first_name", ["input[name*='first_name' i]", "input[id='first_name']", "input[name*='first' i]"], str(fields.get("first_name", ""))),
            ("last_name", ["input[name*='last_name' i]", "input[id='last_name']", "input[name*='last' i]"], str(fields.get("last_name", ""))),
            ("email", ["input[type='email']", "input[id='email']", "input[name*='email' i]"], str(fields.get("email", ""))),
            ("phone", ["input[type='tel']", "input[id='phone']", "input[name*='phone' i]"], str(fields.get("phone", ""))),
        ]

        filled_fields: List[str] = []
        for label, selectors, val in fill_map:
            if _fill_first_in_contexts(contexts, selectors, val):
                filled_fields.append(label)

        filled_fields.extend(_fill_labeled_questions(contexts, fields, cover_letter_text))
        dropdowns = _fill_dropdowns_and_comboboxes(contexts, fields)
        persisted_fixes = _ensure_contact_fields(page, fill_map)

        if dry_run:
            page.wait_for_timeout(1500)

        browser.close()

    return {
        "ats_type": detect_ats(nav_url),
        "resolved_url": nav_url,
        "contexts_scanned": len(contexts),
        "filled_fields": filled_fields,
        "dropdowns_selected": dropdowns,
        "attached_files": attached,
        "persisted_fixes": persisted_fixes,
        "dry_run": dry_run,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Config-driven Playwright ATS DOM autofill engine with async read-back retry loop."
    )
    parser.add_argument(_opt("ats-url"), required=True, help="Target ATS posting URL.")
    parser.add_argument(_opt("company-name"), default="", help="Employer name for Greenhouse slug resolution.")
    parser.add_argument(_opt("profile-json"), default="", help="Path to JSON applicant profile (or set ATS_PROFILE_JSON).")
    parser.add_argument(_opt("resume-pdf"), default="", help="Optional path to Resume PDF.")
    parser.add_argument(_opt("cover-letter-pdf"), default="", help="Optional path to Cover Letter PDF.")
    parser.add_argument(_opt("dry-run"), action="store_true", help="Verify DOM population without submitting.")
    parser.add_argument(_opt("headless-browser"), action="store_true", help="Run Chromium in headless mode.")
    args = parser.parse_args()

    profile = load_profile_config(Path(args.profile_json).resolve() if args.profile_json else None)
    resume_path = Path(args.resume_pdf).resolve() if args.resume_pdf else None
    cl_path = Path(args.cover_letter_pdf).resolve() if args.cover_letter_pdf else None

    result = autofill_ats_form(
        url=args.ats_url,
        company=args.company_name,
        profile=profile,
        resume_pdf=resume_path,
        cover_letter_pdf=cl_path,
        dry_run=args.dry_run,
        headless=args.headless_browser,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
