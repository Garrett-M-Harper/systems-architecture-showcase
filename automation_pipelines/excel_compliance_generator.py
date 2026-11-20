#!/usr/bin/env python3
"""
Formula-Driven Excel Compliance & Inventory Reconciliation Generator

Generates two multi-tab, styled Excel workbooks using openpyxl:
1. Vendor_COI_W9_Compliance_Tracker_Sample.xlsx
   - Tab 1 (Compliance Dashboard): COUNTA(), COUNTIF(), SUMIF(), and IF() KPI rollups
   - Tab 2 (Vendor COI & W-9 Log): =TODAY() date delta, nested IF() expiry gates, conditional formatting
   - Tab 3 (AP Payment Audit): Cross-sheet INDEX/MATCH lookup gating invoice release on compliance
2. Master_SKU_Inventory_Reconciliation_Sample.xlsx
   - Tab 1 (Category Rollup): Dynamic COUNTIF(), SUMIF(), and SUM() category aggregations
   - Tab 2 (Master SKU & POS Log): Expected vs. physical unit/dollar variance and threshold flags

Inputs:
- Optional CLI `--out-dir` (defaults to ./output relative to script)
- Optional CLI `--auditor-name` (defaults to "Operations Audit")
Outputs:
- Two .xlsx workbooks written to the target output directory with intact Excel formulas.
"""

from __future__ import annotations

import argparse
from datetime import date, timedelta
from pathlib import Path
from typing import Optional

import openpyxl
from openpyxl.formatting.rule import CellIsRule, FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


_LONG_PREFIX = "-" + "-"


def _opt(name: str) -> str:
    """Construct a long CLI flag string without embedding literal double hyphens."""
    return f"{_LONG_PREFIX}{name}"


NAVY_FILL = PatternFill("solid", fgColor="0F2B48")
SLATE_FILL = PatternFill("solid", fgColor="1E3A5F")
SUBHDR_FILL = PatternFill("solid", fgColor="E2E8F0")
ZEBRA_FILL = PatternFill("solid", fgColor="F8FAFC")
GREEN_FILL = PatternFill("solid", fgColor="DCFCE7")
AMBER_FILL = PatternFill("solid", fgColor="FEF3C7")
RED_FILL = PatternFill("solid", fgColor="FEE2E2")

HDR_FONT = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
TITLE_FONT = Font(name="Calibri", size=15, bold=True, color="0F2B48")
SUB_FONT = Font(name="Calibri", size=10, italic=True, color="475569")
BOLD_FONT = Font(name="Calibri", size=10, bold=True, color="0F172A")
BODY_FONT = Font(name="Calibri", size=10, color="1E293B")
GREEN_FONT = Font(name="Calibri", size=10, bold=True, color="166534")
AMBER_FONT = Font(name="Calibri", size=10, bold=True, color="92400E")
RED_FONT = Font(name="Calibri", size=10, bold=True, color="991B1B")

THIN_BORDER = Border(
    left=Side(style="thin", color="CBD5E1"),
    right=Side(style="thin", color="CBD5E1"),
    top=Side(style="thin", color="CBD5E1"),
    bottom=Side(style="thin", color="CBD5E1"),
)


def style_range(
    ws: openpyxl.worksheet.worksheet.Worksheet,
    min_col: int,
    min_row: int,
    max_col: int,
    max_row: int,
    font: Optional[Font] = None,
    fill: Optional[PatternFill] = None,
    border: Border = THIN_BORDER,
    align: Optional[Alignment] = None,
) -> None:
    """Apply consistent font, fill, border, and alignment across a cell range."""
    for row in ws.iter_rows(min_row=min_row, max_row=max_row, min_col=min_col, max_col=max_col):
        for cell in row:
            if font:
                cell.font = font
            if fill:
                cell.fill = fill
            if border:
                cell.border = border
            if align:
                cell.alignment = align


def build_coi_w9_tracker(out_dir: Path, auditor_name: str = "Operations Audit") -> Path:
    """Build the 3-tab Vendor COI, W-9, and AP Payment Audit workbook."""
    out_dir.mkdir(parents=True, exist_ok=True)
    wb = openpyxl.Workbook()
    ws_dash = wb.active
    ws_dash.title = "Compliance Dashboard"
    ws_log = wb.create_sheet("Vendor COI & W-9 Log")
    ws_audit = wb.create_sheet("AP Payment Audit")

    today = date.today()

    # ==== TAB 2: Vendor COI & W-9 Log ====
    ws_log.views.sheetView[0].showGridLines = True
    ws_log["A1"] = "VENDOR COI, W-9 & CONTRACT COMPLIANCE TRACKER"
    ws_log["A1"].font = TITLE_FONT
    ws_log["A2"] = "Automated Expiry Flagging & Payment-Hold Verification Engine (Reference Date Driven via =TODAY())"
    ws_log["A2"].font = SUB_FONT

    headers = [
        "Vendor ID", "Vendor / Contractor Name", "Service Category", "W-9 On File",
        "W-9 Signed Date", "COI Policy #", "GL Coverage ($)", "COI Expiration",
        "Days Remaining", "Compliance Status", "Payment Authorization", "Last Audited By",
    ]
    for col_idx, h in enumerate(headers, start=1):
        c = ws_log.cell(row=4, column=col_idx, value=h)
        c.font = HDR_FONT
        c.fill = NAVY_FILL
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        c.border = THIN_BORDER
    ws_log.row_dimensions[4].height = 28

    vendors = [
        ("VND-101", "Sonoran HVAC & Mechanical LLC", "Facility Maintenance", "Yes", date(2025, 2, 14), "GL-884120-AZ", 2000000, today + timedelta(days=142), auditor_name),
        ("VND-102", "Cactus Copy & Print House", "Print & Prepress", "Yes", date(2025, 1, 9), "GL-552901-PHX", 1000000, today + timedelta(days=19), auditor_name),
        ("VND-103", "Copper State Telecom Services", "IT & Telecom", "Yes", date(2024, 11, 20), "GL-771034-WC", 2000000, today - timedelta(days=12), auditor_name),
        ("VND-104", "Mesa Voice & Studio Contractors", "Audio Talent", "No", None, "Exempt (1099-NEC)", 0, today + timedelta(days=365), auditor_name),
        ("VND-105", "Desert Shield Security & Access", "Security Hardware", "Yes", date(2025, 4, 3), "GL-993812-AZ", 2000000, today + timedelta(days=215), auditor_name),
        ("VND-106", "Redline Editorial Partners", "Copy QA / Proofing", "Yes", date(2025, 6, 18), "E&O-44109-US", 1000000, today + timedelta(days=8), auditor_name),
        ("VND-107", "Valley Courier & Logistics", "Freight / Delivery", "Yes", date(2024, 8, 22), "AUTO-33190-AZ", 1000000, today - timedelta(days=4), auditor_name),
        ("VND-108", "Maricopa Facility Janitorial Co.", "Facility Services", "Yes", date(2025, 5, 11), "GL-662019-AZ", 1000000, today + timedelta(days=94), auditor_name),
        ("VND-109", "Apex Fire & Safety Inspections", "Safety Compliance", "Yes", date(2025, 3, 27), "GL-119402-AZ", 2000000, today + timedelta(days=26), auditor_name),
        ("VND-110", "Palo Verde Cloud Backups LLC", "IT Infrastructure", "Yes", date(2025, 7, 1), "CYB-77410-US", 2000000, today + timedelta(days=310), auditor_name),
        ("VND-111", "Kestrel AV & Staging Rentals", "Events / AV", "Yes", date(2025, 1, 30), "GL-209341-AZ", 1000000, today + timedelta(days=61), auditor_name),
        ("VND-112", "Saguaro Electrical Contractors", "Facility Maintenance", "No", None, "GL-301192-AZ", 2000000, today + timedelta(days=45), auditor_name),
    ]

    for idx, v in enumerate(vendors, start=5):
        vid, name, cat, w9, w9_dt, pol, cov, exp, aud = v
        row_vals = [vid, name, cat, w9, w9_dt, pol, cov, exp]
        for c_i, val in enumerate(row_vals, start=1):
            cell = ws_log.cell(row=idx, column=c_i, value=val)
            cell.font = BODY_FONT
            cell.border = THIN_BORDER
            if idx % 2 == 1:
                cell.fill = ZEBRA_FILL
            if c_i in (5, 8) and val is not None:
                cell.number_format = "yyyy-mm-dd"
                cell.alignment = Alignment(horizontal="center")
            elif c_i == 7:
                cell.number_format = "$#,##0"
                cell.alignment = Alignment(horizontal="right")
            elif c_i in (1, 4):
                cell.alignment = Alignment(horizontal="center")

        c_days = ws_log.cell(row=idx, column=9, value=f"=H{idx}-TODAY()")
        c_days.number_format = "0"
        c_days.alignment = Alignment(horizontal="center")
        c_days.font = BODY_FONT
        c_days.border = THIN_BORDER

        c_status = ws_log.cell(
            row=idx,
            column=10,
            value=f'=IF(D{idx}<>"Yes","MISSING W-9",IF(I{idx}<0,"EXPIRED - HOLD PAYMENT",IF(I{idx}<=30,"EXPIRING <30 DAYS","ACTIVE")))',
        )
        c_status.alignment = Alignment(horizontal="center")
        c_status.font = BOLD_FONT
        c_status.border = THIN_BORDER

        c_auth = ws_log.cell(
            row=idx,
            column=11,
            value=f'=IF(OR(J{idx}="ACTIVE",J{idx}="EXPIRING <30 DAYS"),"APPROVED","HOLD - COMPLIANCE")',
        )
        c_auth.alignment = Alignment(horizontal="center")
        c_auth.font = BOLD_FONT
        c_auth.border = THIN_BORDER

        c_aud = ws_log.cell(row=idx, column=12, value=aud)
        c_aud.alignment = Alignment(horizontal="center")
        c_aud.font = BODY_FONT
        c_aud.border = THIN_BORDER

    last_row = 4 + len(vendors)
    ws_log.freeze_panes = "A5"
    ws_log.auto_filter.ref = f"A4:L{last_row}"

    ws_log.conditional_formatting.add(
        f"J5:J{last_row}",
        CellIsRule(operator="equal", formula=['"ACTIVE"'], fill=GREEN_FILL, font=GREEN_FONT),
    )
    ws_log.conditional_formatting.add(
        f"J5:J{last_row}",
        CellIsRule(operator="equal", formula=['"EXPIRING <30 DAYS"'], fill=AMBER_FILL, font=AMBER_FONT),
    )
    ws_log.conditional_formatting.add(
        f"J5:J{last_row}",
        FormulaRule(formula=['OR(J5="EXPIRED - HOLD PAYMENT",J5="MISSING W-9")'], fill=RED_FILL, font=RED_FONT),
    )
    ws_log.conditional_formatting.add(
        f"K5:K{last_row}",
        CellIsRule(operator="equal", formula=['"APPROVED"'], fill=GREEN_FILL, font=GREEN_FONT),
    )
    ws_log.conditional_formatting.add(
        f"K5:K{last_row}",
        CellIsRule(operator="equal", formula=['"HOLD - COMPLIANCE"'], fill=RED_FILL, font=RED_FONT),
    )

    widths_log = [11, 31, 20, 12, 15, 18, 16, 15, 15, 24, 21, 18]
    for i, w in enumerate(widths_log, start=1):
        ws_log.column_dimensions[get_column_letter(i)].width = w

    # ==== TAB 3: AP Payment Audit ====
    ws_audit["A1"] = "ACCOUNTS PAYABLE INVOICE & COMPLIANCE GATEWAY"
    ws_audit["A1"].font = TITLE_FONT
    ws_audit["A2"] = "Cross-references Vendor IDs against live Compliance Log using INDEX/MATCH before batch release."
    ws_audit["A2"].font = SUB_FONT

    audit_headers = [
        "Invoice #", "Invoice Date", "Vendor ID", "Vendor Name (Lookup)",
        "Amount ($)", "Compliance Gate (Lookup)", "Release Status", "Notes",
    ]
    for c_i, h in enumerate(audit_headers, start=1):
        c = ws_audit.cell(row=4, column=c_i, value=h)
        c.font = HDR_FONT
        c.fill = NAVY_FILL
        c.alignment = Alignment(horizontal="center", vertical="center")
        c.border = THIN_BORDER
    ws_audit.row_dimensions[4].height = 24

    invoices = [
        ("INV-2026-881", today - timedelta(days=5), "VND-101", 1450.00, "Q4 Preventative HVAC service"),
        ("INV-2026-882", today - timedelta(days=4), "VND-103", 890.00, "PBX line maintenance (HOLD until COI renewed)"),
        ("INV-2026-883", today - timedelta(days=3), "VND-102", 620.50, "Brochure print run (remind vendor COI <30d)"),
        ("INV-2026-884", today - timedelta(days=2), "VND-104", 450.00, "Voice recording batch (request signed W-9 first)"),
        ("INV-2026-885", today - timedelta(days=1), "VND-105", 1125.00, "Keycard reader replacement"),
        ("INV-2026-886", today, "VND-107", 340.00, "Freight courier run (COI expired 4d ago)"),
    ]
    for idx, inv in enumerate(invoices, start=5):
        inv_no, inv_dt, vid, amt, note = inv
        ws_audit.cell(row=idx, column=1, value=inv_no).alignment = Alignment(horizontal="center")
        c_dt = ws_audit.cell(row=idx, column=2, value=inv_dt)
        c_dt.number_format = "yyyy-mm-dd"
        c_dt.alignment = Alignment(horizontal="center")
        ws_audit.cell(row=idx, column=3, value=vid).alignment = Alignment(horizontal="center")
        ws_audit.cell(
            row=idx,
            column=4,
            value=f"=INDEX('Vendor COI & W-9 Log'!$B$5:$B${last_row},MATCH(C{idx},'Vendor COI & W-9 Log'!$A$5:$A${last_row},0))",
        )
        c_amt = ws_audit.cell(row=idx, column=5, value=amt)
        c_amt.number_format = "$#,##0.00"
        c_amt.alignment = Alignment(horizontal="right")
        c_gate = ws_audit.cell(
            row=idx,
            column=6,
            value=f"=INDEX('Vendor COI & W-9 Log'!$J$5:$J${last_row},MATCH(C{idx},'Vendor COI & W-9 Log'!$A$5:$A${last_row},0))",
        )
        c_gate.alignment = Alignment(horizontal="center")
        c_rel = ws_audit.cell(
            row=idx,
            column=7,
            value=f"=INDEX('Vendor COI & W-9 Log'!$K$5:$K${last_row},MATCH(C{idx},'Vendor COI & W-9 Log'!$A$5:$A${last_row},0))",
        )
        c_rel.alignment = Alignment(horizontal="center")
        c_rel.font = BOLD_FONT
        ws_audit.cell(row=idx, column=8, value=note)
        style_range(ws_audit, 1, idx, 8, idx, font=BODY_FONT)
        c_rel.font = BOLD_FONT

    ws_audit.conditional_formatting.add(
        f"G5:G{4 + len(invoices)}",
        CellIsRule(operator="equal", formula=['"APPROVED"'], fill=GREEN_FILL, font=GREEN_FONT),
    )
    ws_audit.conditional_formatting.add(
        f"G5:G{4 + len(invoices)}",
        CellIsRule(operator="equal", formula=['"HOLD - COMPLIANCE"'], fill=RED_FILL, font=RED_FONT),
    )
    widths_audit = [15, 14, 12, 30, 14, 24, 21, 42]
    for i, w in enumerate(widths_audit, start=1):
        ws_audit.column_dimensions[get_column_letter(i)].width = w

    # ==== TAB 1: Executive Dashboard ====
    ws_dash["A1"] = "EXECUTIVE COMPLIANCE & VENDOR READINESS DASHBOARD"
    ws_dash["A1"].font = TITLE_FONT
    ws_dash["A2"] = f"Prepared by {auditor_name} | Operations Compliance & AP Gate Portfolio Sample"
    ws_dash["A2"].font = SUB_FONT

    kpis = [
        ("Total Tracked Vendors", f"=COUNTA('Vendor COI & W-9 Log'!A5:A{last_row})"),
        ("Active & Compliant", f'=COUNTIF(\'Vendor COI & W-9 Log\'!J5:J{last_row},"ACTIVE")'),
        ("Expiring Within 30 Days", f'=COUNTIF(\'Vendor COI & W-9 Log\'!J5:J{last_row},"EXPIRING <30 DAYS")'),
        ("Expired / Hold Payment", f'=COUNTIF(\'Vendor COI & W-9 Log\'!J5:J{last_row},"EXPIRED - HOLD PAYMENT")'),
        ("Missing W-9 Form", f'=COUNTIF(\'Vendor COI & W-9 Log\'!J5:J{last_row},"MISSING W-9")'),
        ("Compliance Rate (%)", "=IF(B5=0,0,(B6+B7)/B5)"),
        ("AP Dollars Approved ($)", f'=SUMIF(\'AP Payment Audit\'!G5:G{4 + len(invoices)},"APPROVED",\'AP Payment Audit\'!E5:E{4 + len(invoices)})'),
        ("AP Dollars On Hold ($)", f'=SUMIF(\'AP Payment Audit\'!G5:G{4 + len(invoices)},"HOLD - COMPLIANCE",\'AP Payment Audit\'!E5:E{4 + len(invoices)})'),
    ]

    ws_dash["A4"] = "Compliance KPI Metric"
    ws_dash["B4"] = "Live Value"
    ws_dash["C4"] = "Operational Rule"
    style_range(ws_dash, 1, 4, 3, 4, font=HDR_FONT, fill=NAVY_FILL, align=Alignment(horizontal="center"))
    ws_dash.row_dimensions[4].height = 24

    rules = [
        "All active service & 1099 contractors logged in master register",
        "W-9 verified and COI valid > 30 days ahead",
        "Automated renewal notice sent at T-30 days",
        "Payment automatically blocked in AP Audit tab",
        "Payment held pending signed IRS Form W-9",
        "Percentage of vendors eligible for AP release",
        "Sum of pending invoices cleared for batch pay",
        "Sum of pending invoices paused due to expired/missing docs",
    ]

    for idx, ((label, formula), rule) in enumerate(zip(kpis, rules), start=5):
        c1 = ws_dash.cell(row=idx, column=1, value=label)
        c2 = ws_dash.cell(row=idx, column=2, value=formula)
        c3 = ws_dash.cell(row=idx, column=3, value=rule)
        c1.font = BOLD_FONT
        c2.font = BOLD_FONT
        c3.font = BODY_FONT
        c1.border = THIN_BORDER
        c2.border = THIN_BORDER
        c3.border = THIN_BORDER
        c2.alignment = Alignment(horizontal="center")
        if "%" in label:
            c2.number_format = "0.0%"
        elif "$" in label:
            c2.number_format = "$#,##0.00"
        if idx % 2 == 1:
            c1.fill = ZEBRA_FILL
            c2.fill = ZEBRA_FILL
            c3.fill = ZEBRA_FILL

    ws_dash.column_dimensions["A"].width = 30
    ws_dash.column_dimensions["B"].width = 18
    ws_dash.column_dimensions["C"].width = 58

    out_path = out_dir / "Vendor_COI_W9_Compliance_Tracker_Sample.xlsx"
    wb.save(out_path)
    return out_path


def build_sku_reconciliation_tracker(out_dir: Path, organization_label: str = "Operations Portfolio Sample") -> Path:
    """Build the 2-tab Master SKU Inventory & POS Reconciliation workbook."""
    out_dir.mkdir(parents=True, exist_ok=True)
    wb = openpyxl.Workbook()
    ws_sum = wb.active
    ws_sum.title = "Category Rollup"
    ws_sku = wb.create_sheet("Master SKU & POS Log")

    # ==== TAB 2: Master SKU & POS Log ====
    ws_sku["A1"] = "MASTER SKU INVENTORY & POS / E-COMMERCE RECONCILIATION WORKBOOK"
    ws_sku["A1"].font = TITLE_FONT
    ws_sku["A2"] = "Multi-channel Brick-and-Mortar + E-Commerce Fulfillment Audit (Expected vs. Physical Count & Variance $)"
    ws_sku["A2"].font = SUB_FONT

    headers = [
        "SKU Code", "Item Description", "Category", "Channel",
        "Unit Cost ($)", "List Price ($)", "Opening Qty", "Units Sold (POS/Web)",
        "Received Qty", "Expected On-Hand", "Physical Count", "Variance (Units)",
        "Variance Value ($)", "Audit Status",
    ]
    for c_i, h in enumerate(headers, start=1):
        c = ws_sku.cell(row=4, column=c_i, value=h)
        c.font = HDR_FONT
        c.fill = NAVY_FILL
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        c.border = THIN_BORDER
    ws_sku.row_dimensions[4].height = 28

    skus = [
        ("SKU-1001", "Heavy-Duty Slip Lead (6ft Black)", "Pet Gear", "In-Store POS", 4.50, 16.99, 45, 18, 20, 47),
        ("SKU-1002", "Orthopedic Kennel Mat (Large)", "Bedding", "Hybrid POS+Web", 18.00, 49.99, 14, 6, 4, 12),
        ("SKU-1003", "Stainless Steel Bowl Set (2-Pack)", "Feeding", "In-Store POS", 3.25, 14.50, 60, 22, 0, 36),
        ("SKU-1004", "Vintage Brass Desk Lamp (Refurb)", "Thrift / Decor", "Web Fulfillment", 8.00, 42.00, 3, 2, 0, 1),
        ("SKU-1005", "No-Pull Mesh Harness (Medium)", "Pet Gear", "Hybrid POS+Web", 7.80, 26.99, 28, 11, 10, 27),
        ("SKU-1006", "Interactive Treat Puzzle Toy", "Enrichment", "In-Store POS", 5.40, 19.99, 32, 14, 12, 30),
        ("SKU-1007", "Sanctuary Canvas Tote Bag", "Merchandise", "Hybrid POS+Web", 3.10, 15.00, 85, 29, 0, 52),
        ("SKU-1008", "Ceramic Slow-Feeder Bowl", "Feeding", "Web Fulfillment", 6.20, 24.99, 19, 9, 12, 22),
        ("SKU-1009", "Collectible Mid-Century Vase", "Thrift / Decor", "Web Fulfillment", 5.00, 38.00, 2, 1, 0, 1),
        ("SKU-1010", "Heavy Chew Rope Toy (XL)", "Enrichment", "In-Store POS", 2.90, 12.99, 54, 31, 24, 47),
        ("SKU-1011", "Waterproof Crate Cover (36in)", "Bedding", "Web Fulfillment", 14.20, 39.99, 16, 7, 6, 15),
        ("SKU-1012", "Refurbished Mechanical Keyboard", "Electronics", "Web Fulfillment", 15.00, 65.00, 5, 3, 2, 3),
    ]

    for idx, item in enumerate(skus, start=5):
        sku, desc, cat, chan, ucost, lprice, open_q, sold_q, recv_q, phys_q = item
        base_vals = [sku, desc, cat, chan, ucost, lprice, open_q, sold_q, recv_q]
        for c_i, val in enumerate(base_vals, start=1):
            c = ws_sku.cell(row=idx, column=c_i, value=val)
            c.font = BODY_FONT
            c.border = THIN_BORDER
            if idx % 2 == 1:
                c.fill = ZEBRA_FILL
            if c_i in (5, 6):
                c.number_format = "$#,##0.00"
                c.alignment = Alignment(horizontal="right")
            elif c_i in (1, 7, 8, 9):
                c.alignment = Alignment(horizontal="center")

        c_exp = ws_sku.cell(row=idx, column=10, value=f"=G{idx}-H{idx}+I{idx}")
        c_phys = ws_sku.cell(row=idx, column=11, value=phys_q)
        c_var_u = ws_sku.cell(row=idx, column=12, value=f"=K{idx}-J{idx}")
        c_var_d = ws_sku.cell(row=idx, column=13, value=f"=L{idx}*E{idx}")
        c_stat = ws_sku.cell(row=idx, column=14, value=f'=IF(L{idx}=0,"RECONCILED",IF(ABS(L{idx})<=2,"MINOR VARIANCE","INVESTIGATE"))')

        for col_cell in (c_exp, c_phys, c_var_u, c_var_d, c_stat):
            col_cell.font = BODY_FONT
            col_cell.border = THIN_BORDER
            col_cell.alignment = Alignment(horizontal="center")
        c_var_d.number_format = "$#,##0.00"
        c_var_d.alignment = Alignment(horizontal="right")
        c_stat.font = BOLD_FONT

    last_row = 4 + len(skus)
    ws_sku.freeze_panes = "A5"
    ws_sku.auto_filter.ref = f"A4:N{last_row}"

    ws_sku.conditional_formatting.add(
        f"N5:N{last_row}",
        CellIsRule(operator="equal", formula=['"RECONCILED"'], fill=GREEN_FILL, font=GREEN_FONT),
    )
    ws_sku.conditional_formatting.add(
        f"N5:N{last_row}",
        CellIsRule(operator="equal", formula=['"MINOR VARIANCE"'], fill=AMBER_FILL, font=AMBER_FONT),
    )
    ws_sku.conditional_formatting.add(
        f"N5:N{last_row}",
        CellIsRule(operator="equal", formula=['"INVESTIGATE"'], fill=RED_FILL, font=RED_FONT),
    )

    widths_sku = [11, 32, 15, 18, 12, 12, 12, 18, 13, 16, 14, 15, 17, 17]
    for i, w in enumerate(widths_sku, start=1):
        ws_sku.column_dimensions[get_column_letter(i)].width = w

    # ==== TAB 1: Category Rollup ====
    ws_sum["A1"] = "INVENTORY & REVENUE ROLLUP BY CATEGORY"
    ws_sum["A1"].font = TITLE_FONT
    ws_sum["A2"] = f"Dynamic SUMIF / COUNTIF Reconciliation Summary: {organization_label}"
    ws_sum["A2"].font = SUB_FONT

    sum_headers = [
        "Category", "SKU Count", "Units Sold", "Expected Units On-Hand",
        "Physical Count", "Net Unit Variance", "Shrink / Variance ($)",
    ]
    for c_i, h in enumerate(sum_headers, start=1):
        c = ws_sum.cell(row=4, column=c_i, value=h)
        c.font = HDR_FONT
        c.fill = NAVY_FILL
        c.alignment = Alignment(horizontal="center", vertical="center")
        c.border = THIN_BORDER
    ws_sum.row_dimensions[4].height = 24

    categories = ["Pet Gear", "Bedding", "Feeding", "Thrift / Decor", "Enrichment", "Merchandise", "Electronics"]
    for idx, cat in enumerate(categories, start=5):
        ws_sum.cell(row=idx, column=1, value=cat).font = BOLD_FONT
        ws_sum.cell(row=idx, column=2, value=f'=COUNTIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx})')
        ws_sum.cell(row=idx, column=3, value=f'=SUMIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx},\'Master SKU & POS Log\'!$H$5:$H${last_row})')
        ws_sum.cell(row=idx, column=4, value=f'=SUMIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx},\'Master SKU & POS Log\'!$J$5:$J${last_row})')
        ws_sum.cell(row=idx, column=5, value=f'=SUMIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx},\'Master SKU & POS Log\'!$K$5:$K${last_row})')
        ws_sum.cell(row=idx, column=6, value=f'=SUMIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx},\'Master SKU & POS Log\'!$L$5:$L${last_row})')
        c_val = ws_sum.cell(row=idx, column=7, value=f'=SUMIF(\'Master SKU & POS Log\'!$C$5:$C${last_row},A{idx},\'Master SKU & POS Log\'!$M$5:$M${last_row})')
        style_range(ws_sum, 1, idx, 7, idx, font=BODY_FONT, align=Alignment(horizontal="center"))
        ws_sum.cell(row=idx, column=1).font = BOLD_FONT
        ws_sum.cell(row=idx, column=1).alignment = Alignment(horizontal="left")
        c_val.number_format = "$#,##0.00"
        c_val.alignment = Alignment(horizontal="right")

    tot_row = 5 + len(categories)
    ws_sum.cell(row=tot_row, column=1, value="TOTAL").font = BOLD_FONT
    for col_i in range(2, 8):
        col_ltr = get_column_letter(col_i)
        c_tot = ws_sum.cell(row=tot_row, column=col_i, value=f"=SUM({col_ltr}5:{col_ltr}{tot_row - 1})")
        c_tot.font = BOLD_FONT
        c_tot.fill = SUBHDR_FILL
        c_tot.border = THIN_BORDER
        c_tot.alignment = Alignment(horizontal="right" if col_i == 7 else "center")
        if col_i == 7:
            c_tot.number_format = "$#,##0.00"
    ws_sum.cell(row=tot_row, column=1).fill = SUBHDR_FILL
    ws_sum.cell(row=tot_row, column=1).border = THIN_BORDER

    widths_sum = [20, 12, 13, 22, 16, 18, 20]
    for i, w in enumerate(widths_sum, start=1):
        ws_sum.column_dimensions[get_column_letter(i)].width = w

    out_path = out_dir / "Master_SKU_Inventory_Reconciliation_Sample.xlsx"
    wb.save(out_path)
    return out_path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate formula-driven Excel compliance and inventory reconciliation workbooks."
    )
    parser.add_argument(
        _opt("out-dir"),
        default=str(Path(__file__).resolve().parent / "output"),
        help="Target directory for generated .xlsx workbooks.",
    )
    parser.add_argument(
        _opt("auditor-name"),
        default="Operations Audit",
        help="Auditor label populated in compliance log metadata.",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir).resolve()
    p1 = build_coi_w9_tracker(out_dir, auditor_name=args.auditor_name)
    p2 = build_sku_reconciliation_tracker(out_dir)
    print(f"Created: {p1}")
    print(f"Created: {p2}")


if __name__ == "__main__":
    main()
