# Automation and Data Pipelines (`automation_pipelines/`)

Standalone Python 3.11+ utilities for concurrent API ingestion, rule-based filtering, resilient Playwright DOM automation, and formula-driven Excel compliance workbook generation.

## 1. `ats_lead_pipeline.py`

### System Purpose and Engineering Lens
Concurrent ATS job ingestion, compensation normalization, and deterministic trap-filtering pipeline. Converts heterogeneous external job feeds into a deduplicated, schema-consistent JSON dataset while blocking paywalls, aggregator wrappers, and unpaid multi-hour screening gauntlets.

### Inputs and Outputs
- **Inputs**:
  - `--boards`: Optional comma-separated `slug:Company Name` pairs (defaults to `DEFAULT_GREENHOUSE_BOARDS`).
  - `--config-json` or `ATS_PIPELINE_CONFIG`: Optional JSON configuration file specifying `greenhouse_boards`.
  - `--timeout-sec`: HTTP timeout budget per request (default `7` seconds).
  - `--skip-remote-feeds`: Flag to query Greenhouse JSON APIs only.
- **Outputs**:
  - Writes `clean_leads.json` inside `--out-dir` (or prints summary counts to stdout) containing `leads` (enriched with `id`, `pay_hourly`, `track`, `friction_rank`, `direct_url`) and `blocked_traps` (audit log of rejected listings and matching rules).

### State Transitions and Execution Flow
1. **Concurrent Index Polling**: Queries Greenhouse `/jobs` endpoints via `ThreadPoolExecutor` (`max_workers <= 8`), pre-filtering by title keywords and geography before issuing detail requests.
2. **Detail Inspection and Trap Gate**: Fetches `?questions=true` for matched roles, strips HTML tags, evaluates `detect_screener_or_bs_trap()` across company blocklists, paywall domains, and compiled `HEAVY_TRAP_PATTERNS` regexes, and records rejections in `blocked_traps`.
3. **Feed Ingestion and Location Guard**: Queries Remotive and Jobicy APIs, enforcing `location_matches_allowed()` with non-empty token validation to prevent empty location strings from bypassing regional filters.
4. **Normalization and Deduplication**: Extracts hourly USD equivalents (`parse_potential_hourly()`, converting annual salaries via `/ 2080`), unwraps corporate wrapper URLs to direct Greenhouse embed endpoints (`resolve_direct_ats_url()`), and deduplicates by URL and `(company, base_title)` key.

### Design Trade-Offs
- **Two-Stage Board Querying**: Fetching lightweight board indexes first and limiting `?questions=true` detail requests per board avoids saturating large company boards while still capturing form field counts and compensation text.
- **Config-Driven Parameters**: Externalizing board lists and output paths removes personal search lists and workstation paths from source control.

## 2. `ats_dom_autofill.py`

### System Purpose and Engineering Lens
Multi-frame Playwright DOM automation engine engineered to maintain state persistence across single-page React/Greenhouse forms where asynchronous resume parsing overwrites form fields.

### Inputs and Outputs
- **Inputs**:
  - `--ats-url`: Target job application URL (required).
  - `--company-name`: Employer name used for Greenhouse embed URL resolution.
  - `--profile-json` or `ATS_PROFILE_JSON`: Path to external applicant profile JSON (defaults to non-PII `DEFAULT_EXAMPLE_PROFILE`).
  - `--resume-pdf` and `--cover-letter-pdf`: Optional attachment file paths.
  - `--dry-run` / `--headless-browser`: Verification and browser execution controls.
- **Outputs**:
  - JSON execution summary reporting `ats_type`, `resolved_url`, `contexts_scanned`, `filled_fields`, `dropdowns_selected`, `attached_files`, and `persisted_fixes`.

### State Transitions and Execution Flow
1. **Direct URL Unwrapping and Frame Discovery**: Rewrites wrapped career links to embed URLs (`resolve_direct_ats_url()`) and polls main document plus child iframes up to 15 seconds until input or file elements mount.
2. **Multi-Frame File and Input Population**: Attaches PDFs by inspecting `id`/`name` attributes with positional fallback (`_attach_pdfs_across_contexts()`), fills core contact inputs, resolves `<label for>`, `aria-label`, and `aria-labelledby` questions (`_fill_labeled_questions()`), and selects React-Select / ARIA combobox options (`_fill_dropdowns_and_comboboxes()`).
3. **DOM State-Persistence Retry Loop (`_ensure_contact_fields()`)**: Waits for async resume-parsing re-renders to settle, reads live `input_value()` across frames (normalizing phone digits to last 10 digits), and sequentially re-types (`press_sequentially(..., delay=15)` + `blur()`) up to `rounds=4` until every contact field converges.

### Design Trade-Offs
- **Read-Back Convergence vs. Single-Pass `fill()`**: Naive `locator.fill()` calls execute faster on static HTML, but React-controlled ATS forms frequently clear contact inputs 1 to 2 seconds after resume upload triggers background parsing. The bounded 4-round read-back loop guarantees persistence without blind fixed long sleeps.
- **Externalized Profile Configuration**: Loading applicant metadata solely from `--profile-json` or `ATS_PROFILE_JSON` guarantees zero PII in the repository.

## 3. `excel_compliance_generator.py`

### System Purpose and Engineering Lens
Deterministic `openpyxl` generator producing audit-ready Excel workbooks where compliance statuses, payment authorization holds, and inventory shrink flags are computed live inside Excel formulas rather than pre-baked static strings.

### Inputs and Outputs
- **Inputs**:
  - `--out-dir`: Target directory for generated workbooks (defaults to `./output` relative to script).
  - `--auditor-name`: Metadata label recorded in log rows and dashboard subtitle (defaults to `"Operations Audit"`).
- **Outputs**:
  - `Vendor_COI_W9_Compliance_Tracker_Sample.xlsx` (3 worksheets: `Compliance Dashboard`, `Vendor COI & W-9 Log`, `AP Payment Audit`).
  - `Master_SKU_Inventory_Reconciliation_Sample.xlsx` (2 worksheets: `Category Rollup`, `Master SKU & POS Log`).

### State Transitions and Execution Flow
1. **Vendor Compliance Graph**: Writes raw W-9 and COI expiration dates, injects `=H{row}-TODAY()` for live remaining-day calculation, chains nested `=IF()` gates into `Compliance Status` (`MISSING W-9`, `EXPIRED - HOLD PAYMENT`, `EXPIRING <30 DAYS`, `ACTIVE`) and `Payment Authorization` (`APPROVED` vs. `HOLD - COMPLIANCE`), and applies `CellIsRule` / `FormulaRule` conditional formatting.
2. **Cross-Sheet AP Gate**: `AP Payment Audit` uses `=INDEX(..., MATCH(...))` lookups keyed by `Vendor ID` so any expiration or missing W-9 automatically blocks invoice release, while `Compliance Dashboard` aggregates counts and dollar totals via `COUNTA()`, `COUNTIF()`, and `SUMIF()`.
3. **SKU Reconciliation Graph**: Computes expected stock (`=G{row}-H{row}+I{row}`), unit variance (`=K{row}-J{row}`), dollar variance (`=L{row}*E{row}`), and threshold classification (`RECONCILED`, `MINOR VARIANCE`, `INVESTIGATE`), rolled up dynamically by category on Tab 1.

### Design Trade-Offs
- **Formula-Driven Gates vs. Python Pre-Computation**: Emitting live Excel formulas instead of static evaluated strings preserves full auditability and recalculation when operations staff update dates or counts inside Excel or LibreOffice.
