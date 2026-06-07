#!/usr/bin/env python3
"""
build_sku_master.py  — Option-3 hybrid generator (v3)

The Google Sheet (1KtJ69B7dsvU0I5SnNMMxgf52iq7H_9-X6-ZKmC34Dzk, tab "SKU Master")
is the working source of truth for Marin. On every run this script:

  1. Reads the current curated sheet as the baseline (preserves Name + any
     manually-filled gaps that aren't in the org masters).
  2. Reads the DTC and Amazon org masters (passed as CLI arg file dumps).
  3. Reads AMZ Product Dimensions (1pDm6W219FtM0mulHD2WaPxh2lrvaC6D7ZTyrnojqD2M,
     tab "AMZ Product Dimensions") to get the actual FBA SKU (col C) and FNSKU (col D).
  4. Merges updates into the sheet rows following these rules:
       - MASTER_AUTH fields: always overwrite from master when master has a value.
         (amazon_sku, fnsku, asin, msrp, unit_cost, upc, variation, source)
       - Gap-fill fields: update from master ONLY when the sheet cell is empty.
         (category, parent, length, shape)
       - Name (col E): NEVER touched — always keeps the clean sheet value.
  5. Appends any brand-new SKUs from the masters that don't yet exist in the sheet.
  6. Writes all changed rows back to the sheet.
  7. Regenerates ~/clicky-plus/data/sku-master.json from the final sheet state.

Usage:
  python3 build_sku_master.py <dtc_json_dump> <amazon_json_dump>

  The two dump files are the raw {"values":[[...]]} JSON written by the weekly
  routine's Sheets MCP read_range calls:
    DTC:   1urJW_9FSaSZEWH6ITmsYZONY3i6aBsu8vjwpX3knDpw  "Final SKU Master List"!B3:O2061
    Amazon:1zva8IzCHQRNUasuBZcI4Cz9tQduvOtxyFSN0p-5bhvE  "MASTER"!A3:V3230

Current sheet column layout (A=0 … N=13):
  A  SKU             B  ASIN               C  FBA SKU
  D  FNSKU           E  Name               F  Category
  G  Parent          H  Length             I  Shape
  J  MSRP            K  Unit Cost          L  UPC
  M  Amazon Variation  N  Source
"""

import json, re, os, sys
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

# ── Config ────────────────────────────────────────────────────────────────────
CURATED_ID    = "1KtJ69B7dsvU0I5SnNMMxgf52iq7H_9-X6-ZKmC34Dzk"
DIMENSIONS_ID = "1pDm6W219FtM0mulHD2WaPxh2lrvaC6D7ZTyrnojqD2M"
TOKEN_PATH    = os.path.expanduser("~/.config/sheets-mcp/token.json")
JSON_OUT      = os.path.expanduser("~/clicky-plus/data/sku-master.json")

# Column indices in curated sheet (0-based, matching current header row)
# v3.1 (2026-06-05): sheet columns B/C/D were reordered to ASIN / FBA SKU /
# FNSKU (was FBA SKU / FNSKU / ASIN) but this map wasn't updated — so the
# generator was loading the FNSKU column into `asin`, the ASIN column into
# `amazon_sku`, and the FBA SKU column into `fnsku`. Fixed to match the live
# header below.
# A=SKU  B=ASIN  C=FBA SKU  D=FNSKU  E=Name  F=Category  G=Parent
# H=Length  I=Shape  J=MSRP  K=Unit Cost  L=UPC  M=Amazon Variation  N=Source
COL = {
    "sku": 0, "asin": 1, "amazon_sku": 2, "fnsku": 3, "name": 4,
    "category": 5, "parent": 6, "length": 7, "shape": 8,
    "msrp": 9, "unit_cost": 10, "upc": 11, "variation": 12, "source": 13,
}
COL_ORDER = sorted(COL, key=COL.get)

# Always overwrite from master when master has a value
MASTER_AUTH = {"sku", "amazon_sku", "fnsku", "asin", "msrp", "unit_cost",
               "upc", "variation", "source"}

# Normalize raw category values from org masters to curated display names.
# Add new entries here as Steph renames categories in the curated sheet.
CATEGORY_MAP = {
    "press on nails":         "Nails",
    "press-on nails":         "Nails",
    "press on nails (toes)":  "Toe Nails",
    "press-on nails (toes)":  "Toe Nails",
    "pre glue lash":          "Pre-Glue Lash",
}

# ── Helpers ───────────────────────────────────────────────────────────────────
def load(path):
    return json.load(open(path)).get("values", [])

def g(row, i):
    return str(row[i]).strip() if i < len(row) and row[i] is not None else ""

def upcnorm(u):
    d = re.sub(r"\D", "", u or "")
    return d.zfill(12) if 0 < len(d) <= 12 else d

def normalize_category(raw):
    """Map raw master category strings to curated display names."""
    return CATEGORY_MAP.get((raw or "").strip().lower(), (raw or "").strip())

def row_to_rec(row):
    """Pad a sheet row to 14 cols and return a dict keyed by COL field names."""
    pad = list(row) + [""] * (14 - len(row))
    return {k: pad[v] for k, v in COL.items()}

def rec_to_row(rec):
    """Return a 14-element list in column order."""
    return [rec.get(k, "") for k in COL_ORDER]

# ── AMZ Product Dimensions lookup ─────────────────────────────────────────────
def build_dimensions_lookup(api):
    """
    Read AMZ Product Dimensions (US rows) and return:
        { asin: {"amazon_sku": fba_sku, "fnsku": fnsku} }

    Dimensions sheet columns (0-based):
      0 Asin | 1 Gm Sku | 2 Sku (FBA SKU, sheet col C) | 3 Fnsku (sheet col D) | 8 Country

    Prefers rows whose FNSKU starts with "X" (proper FBA FNSKU).
    """
    result = api.values().get(
        spreadsheetId=DIMENSIONS_ID,
        range="'AMZ Product Dimensions'!A2:I20000",
    ).execute()
    rows = result.get("values", [])

    lookup = {}  # asin -> {"amazon_sku": ..., "fnsku": ..., "is_fba": bool}
    for row in rows:
        if len(row) < 4:
            continue
        asin    = g(row, 0)
        sku     = g(row, 2)   # col C of Dimensions — actual FBA SKU
        fnsku   = g(row, 3)   # col D of Dimensions — FNSKU
        country = g(row, 8) if len(row) > 8 else ""

        if not asin or country.upper() != "US":
            continue

        is_fba = fnsku.upper().startswith("X")

        if asin not in lookup:
            lookup[asin] = {"amazon_sku": sku, "fnsku": fnsku, "is_fba": is_fba}
        else:
            # Upgrade to a real FBA entry if we find one
            if is_fba and not lookup[asin]["is_fba"]:
                lookup[asin] = {"amazon_sku": sku, "fnsku": fnsku, "is_fba": True}

    return lookup

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    dtc_file, amz_file = sys.argv[1], sys.argv[2]

    dtc_rows = load(dtc_file)
    amz_rows = load(amz_file)

    creds = Credentials.from_authorized_user_file(TOKEN_PATH)
    svc   = build("sheets", "v4", credentials=creds)
    api   = svc.spreadsheets()

    # ── Step 1: read current curated sheet ──
    result = api.values().get(
        spreadsheetId=CURATED_ID,
        range="'SKU Master'!A2:N",
    ).execute()
    sheet_rows = result.get("values", [])

    # ── Step 2: build Dimensions lookup (ASIN → FBA SKU + FNSKU) ──
    dims = build_dimensions_lookup(api)

    # ── Step 3: index curated sheet by SKU and UPC ──
    by_sku = {}
    by_upc = {}
    for i, row in enumerate(sheet_rows):
        rec = row_to_rec(row)
        by_sku[rec["sku"]] = (i, rec)
        if rec["upc"]:
            by_upc[upcnorm(rec["upc"])] = i

    # ── Step 4: process Amazon master, enriched with Dimensions data ──
    amz_active = []
    for r in amz_rows:
        asin, gmsku = g(r, 2), g(r, 4)
        if not (asin or gmsku):
            continue
        if g(r, 1).upper() == "TRUE" and g(r, 0).upper() != "TRUE":
            d = dims.get(asin, {})
            amz_active.append(dict(
                asin       = asin,
                amazon_sku = d.get("amazon_sku", gmsku),  # FBA SKU; fallback to GM internal
                fnsku      = d.get("fnsku", ""),
                category   = normalize_category(g(r, 5)),
                parent     = g(r, 6),
                description= g(r, 7),
                gs1_upc    = g(r, 13),
                variation  = g(r, 21),
            ))

    amz_by_upc = {}
    for rec in amz_active:
        k = upcnorm(rec["gs1_upc"])
        if k:
            amz_by_upc.setdefault(k, []).append(rec)

    # ── Step 5: merge DTC + Amazon into curated rows ──
    final_rows        = [row_to_rec(row) for row in sheet_rows]
    matched_upcs      = set()
    variations_updated = 0
    variation_updates  = []  # (sheet_row_index, new_variation) for batchUpdate

    for r in dtc_rows:
        if g(r, 0).upper() != "YES":
            continue
        sku = g(r, 1)
        if not sku:
            continue

        upc_raw  = g(r, 13)
        upc_norm = upcnorm(upc_raw)
        a = (amz_by_upc.get(upc_norm) or [None])[0]
        if upc_norm:
            matched_upcs.add(upc_norm)

        master_rec = dict(
            sku        = sku,
            amazon_sku = a["amazon_sku"] if a else "",
            fnsku      = a["fnsku"]      if a else "",
            asin       = a["asin"]       if a else "",
            name       = g(r, 3) or g(r, 2),  # only used for brand-new rows
            category   = normalize_category(g(r, 4)),
            parent     = g(r, 5),
            length     = g(r, 6),
            shape      = g(r, 7),
            msrp       = g(r, 10),
            unit_cost  = g(r, 9),
            upc        = upc_raw,
            variation  = a["variation"] if a else "",
            source     = "dtc+amazon"   if a else "dtc-only",
        )

        if sku not in by_sku:
            # New SKU — append only
            final_rows.append(master_rec)
            by_sku[sku] = (len(final_rows) - 1, master_rec)
        else:
            # Existing SKU — only update variation, since Amazon changes these
            idx, existing = by_sku[sku]
            new_variation = master_rec["variation"]
            if new_variation and existing["variation"] != new_variation:
                final_rows[idx]["variation"] = new_variation
                variation_updates.append((idx, new_variation))
                variations_updated += 1

    # ── Step 6: handle Amazon-only rows ──
    seen_amz = set()
    for rec in amz_active:
        k = upcnorm(rec["gs1_upc"])
        if k in matched_upcs:
            continue
        key = rec["asin"] or rec["amazon_sku"]
        if key in seen_amz:
            continue
        seen_amz.add(key)
        amz_sku = rec["amazon_sku"] or rec["asin"]
        if amz_sku in by_sku:
            continue
        final_rows.append(dict(
            sku=amz_sku, amazon_sku=rec["amazon_sku"], fnsku=rec["fnsku"],
            asin=rec["asin"], name=rec["description"], category=normalize_category(rec["category"]),
            parent=rec["parent"], length="", shape="", msrp="", unit_cost="",
            upc=rec["gs1_upc"], variation=rec["variation"], source="amazon-only",
        ))

    # ── Step 7: write variation updates + append new rows ──
    n_added = len(final_rows) - len(sheet_rows)
    variation_col = COL["variation"]  # column index for the variation field

    if variation_updates:
        var_col_letter = chr(ord("A") + variation_col)
        api.values().batchUpdate(
            spreadsheetId=CURATED_ID,
            body={
                "valueInputOption": "RAW",
                "data": [
                    {
                        "range": f"'SKU Master'!{var_col_letter}{idx + 2}",
                        "values": [[new_var]],
                    }
                    for idx, new_var in variation_updates
                ],
            },
        ).execute()

    if n_added > 0:
        api.values().append(
            spreadsheetId=CURATED_ID,
            range="'SKU Master'!A:A",
            valueInputOption="RAW",
            insertDataOption="INSERT_ROWS",
            body={"values": [rec_to_row(r) for r in final_rows[len(sheet_rows):]]},
        ).execute()

    # ── Step 8: regenerate sku-master.json ──
    os.makedirs(os.path.dirname(JSON_OUT), exist_ok=True)
    # Exclude retired rows from JSON — they stay in the sheet for reference
    # but Marin's lookup_sku should only see canonical, active SKUs.
    json_records = [
        {k: rec.get(k, "") for k in COL_ORDER}
        for rec in final_rows
        if rec.get("sku") and not (rec.get("source","") or "").lower().startswith("retired")
    ]
    json.dump(json_records, open(JSON_OUT, "w"), indent=2)
    print(f"Wrote {len(json_records)} records → {JSON_OUT}")
    print(f"Sheet updates: {n_added} rows appended, {variations_updated} variation(s) updated")


if __name__ == "__main__":
    main()
