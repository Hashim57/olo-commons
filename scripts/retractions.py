#!/usr/bin/env python3
"""Weekly retraction check: load the Crossref Retraction Watch data into olo_retractions
and hide the atoms whose paper was retracted (status retracted, never deleted).

  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python3 scripts/retractions.py

The dataset (CC0, about 60 MB CSV) lists every retraction, correction and expression
of concern Retraction Watch has recorded, with the original paper's DOI and PubMed id.
Only rows whose DOI or PubMed id matches an atom are loaded, so the table stays small
and nothing is stored that the Commons does not cite. Without the service key the
script prints what it would do and exits 0 (forks, local runs).
Source: https://www.crossref.org/documentation/retrieve-metadata/retraction-watch/
"""
import csv
import io
import os
import sys
import urllib.request

import requests

CSV_URL = os.environ.get("RETRACTION_WATCH_CSV", "https://api.labs.crossref.org/data/retractionwatch?hello@heliusnetwork.com")


def rest(url, key, path, params=None, method="GET", body=None):
    h = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"}
    r = requests.request(method, f"{url.rstrip('/')}/rest/v1/{path}", headers=h, params=params, json=body, timeout=120)
    r.raise_for_status()
    return r.json() if r.text else []


def matches(reader, dois, pmids):
    """Rows of the dataset whose original paper the Commons cites, as olo_retractions rows."""
    out = []
    for row in reader:
        doi = (row.get("OriginalPaperDOI") or "").strip().lower()
        pmid = (row.get("OriginalPaperPubMedID") or "").strip()
        if (doi and doi in dois) or (pmid and pmid != "0" and pmid in pmids):
            out.append({"doi": doi or f"pmid:{pmid}", "pmid": pmid if pmid and pmid != "0" else None, "retraction_doi": (row.get("RetractionDOI") or "").strip().lower() or None,
                        "nature": (row.get("RetractionNature") or "").strip() or None, "retracted_on": to_date(row.get("RetractionDate")), "reason": (row.get("Reason") or "").strip()[:500] or None})
    return out


def to_date(s):
    """Retraction Watch dates look like 12/31/2024 0:00; keep YYYY-MM-DD or None."""
    s = (s or "").strip().split(" ")[0]
    parts = s.split("/")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        m, d, y = parts
        return f"{y}-{int(m):02d}-{int(d):02d}"
    return None


def main():
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("retractions: no service key; nothing to do")
        return
    atoms = rest(url, key, "olo_atoms", {"select": "doi,pmid", "or": "(doi.not.is.null,pmid.not.is.null)", "limit": "100000"})
    dois = {a["doi"].lower() for a in atoms if a.get("doi")}
    pmids = {a["pmid"] for a in atoms if a.get("pmid")}
    print(f"{len(dois)} DOIs and {len(pmids)} PubMed ids in the Commons")
    if not dois and not pmids:
        return
    with urllib.request.urlopen(urllib.request.Request(CSV_URL, headers={"User-Agent": "OloCommons/1.0 (+https://heliusnetwork.app/olo)"}), timeout=300) as r:
        text = io.TextIOWrapper(r, encoding="utf-8", errors="replace")
        rows = matches(csv.DictReader(text), dois, pmids)
    print(f"{len(rows)} matching retraction records")
    for i in range(0, len(rows), 200):
        rest(url, key, "olo_retractions", {"on_conflict": "doi"}, method="POST", body=rows[i:i + 200])
    n = requests.post(f"{url.rstrip('/')}/rest/v1/rpc/olo_apply_retractions", headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}, json={}, timeout=120)
    n.raise_for_status()
    print(f"atoms newly marked retracted: {n.text}")


if __name__ == "__main__":
    main()
