# Check any text

The same checking Olo applies to its own answers, for any text: a draft, a report, the output of another AI system. Send the text, and optionally the sources it is meant to rest on; get every sentence back with a verdict (supported, contradicted, not covered), the exact words of the source that decide it, and a verification receipt anyone can check later (docs/RECEIPTS.md).

## Call

`POST https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-answer`

Against the Commons (each sentence is checked against the Commons passages found for it):

```json
{ "mode": "check", "text": "Comair Flight 5191 crashed on takeoff from Lexington. It was headed from Atlanta to Lexington." }
```

Against your own sources (your retrieved context, a contract, a paper; up to 8 passages of up to 20,000 characters each):

```json
{ "mode": "check",
  "text": "The flight was headed from Atlanta to Lexington. Dell is recalling 4.1 million batteries.",
  "passages": [ { "text": "...", "title": "Comair crash", "url": "https://..." }, "a passage can also be a plain string" ] }
```

`tests/fixtures/check_request.json` is a complete request. The same headers as the other calls (`apikey`, and `x-olo-key` for a partner key).

## Response

```json
{ "mode": "check", "against": "supplied",
  "sentences": [
    { "text": "The flight was headed from Atlanta to Lexington.", "verdict": "contradicted",
      "evidence": [ { "passage": "s1", "quote": "was headed from Lexington's Blue Grass Airport to Atlanta's Hartsfield-Jackson International Airport" } ],
      "rationale": "...", "checked_by": "zeus:default_model", "figures_missing": [], "passages": ["s1"] } ],
  "summary": { "supported": 1, "contradicted": 1, "not_covered": 0, "unchecked": 0 },
  "passages": [ { "id": "s1", "supplied": 1, "title": "Comair crash", "url": "https://...", "chars": 342 } ],
  "receipt": { "format": "olo-receipt/1", "...": "...", "supplied": [ { "supplied": 1, "sha256": "...", "title": "Comair crash", "url": "https://..." } ] },
  "verifier": "zeus:default_model" }
```

Against the Commons, `passages` lists the atoms used (`p1`, `p2`, ...) with source, licence and citation, as in an answer.

## How a sentence is checked

1. The text is split into sentences the way Olo splits its own answers (initials and abbreviations such as "George A." and "U.S." do not end a sentence; citation marks an AI left behind, like `[p1]`, are taken off).
2. Each sentence gets its passages: with your passages, the three chunks that share most of its words (a long passage is cut into verbatim chunks of about 900 characters at sentence ends, the length Zeus is trained on); against the Commons, the four passages retrieved for that sentence.
3. Zeus checks the sentence against them (sentences not in English go to the fallback verifier, which the response names). A verdict whose quote is not found word for word in its passage becomes not covered, and so does a supported sentence with a number, date or percentage its passages do not contain.

## Limits

- Up to 4,000 characters of text a call. Anonymous calls check the first 6 sentences, calls with a partner key the first 20; the rest are counted in `summary.unchecked` and named in `notice`, never dropped silently.
- A check counts as one request against the same hourly limit as questions (120 an hour anonymous, 3,000 with a key).

## Privacy

Nothing you send is stored: not the text, not the passages, not the verdicts. The request log keeps only what it keeps for questions (the length of the text and a daily-salted address hash). Check-mode sentences are never tallied or queued for review. The receipt carries the SHA-256 of each passage you supplied, never its text, so you can prove later which text was checked without anyone else holding it.

## Checking the receipt

```
python3 scripts/verify_receipt.py response.json --supplied request.json
```

matches each passage you sent to its fingerprint and looks for every quote in it; without `--supplied` those lines are reported as SKIP. For a check against the Commons it works exactly as for an answer.
