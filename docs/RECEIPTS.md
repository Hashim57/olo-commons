# Verification receipts

Every answer from `olo-answer` carries a `receipt`: a record of what Olo said, what checked it, and exactly which words of which open source each sentence rests on. Anyone holding a receipt can check it later, against the public Commons, without trusting Helius Network or the model that wrote the answer.

## Why it exists

An answer engine usually asks to be believed: it shows links, and the reader cannot tell whether the linked page says what the sentence says, or still says it next month. Olo is built the other way round. Every sentence is checked by Zeus, quotes are kept only when they are found word for word in their passage, and every passage is an atom of the Commons, whose text, licence and SHA-256 fingerprint are public. The receipt puts those three things in one portable record, so an answer can be audited by someone who was not there when it was written: an editor checking a journalist's draft, a reviewer checking a literature summary, a compliance team keeping a record of what an AI told a customer and why.

## What is in a receipt

```json
{
  "format": "olo-receipt/1",
  "issued_at": "2026-11-26T22:00:00.000Z",
  "question": "What happened to Comair Flight 5191?",
  "answer_shown": "Comair Flight 5191 crashed on takeoff from Lexington, Kentucky, killing 49 people on board [p1].",
  "answered_by": { "writer": "openai/gpt-oss-120b", "verifier": "zeus:default_model", "mode": "written" },
  "sentences": [
    { "n": 1, "text": "...", "verdict": "supported", "checked_by": "zeus:default_model", "shown": true,
      "evidence": [ { "atom": "43ab91a6-50bc-4f4d-8807-7363377e1087", "quote": "A Comair commuter jet crashed on takeoff from Lexington, Kentucky yesterday, killing 49 people on board" } ] }
  ],
  "atoms": [
    { "atom": "43ab91a6-50bc-4f4d-8807-7363377e1087", "content_hash": "503eda91...", "title": "49 dead after Comair regional jet crashes in Kentucky",
      "source": "wikinews", "licence": "CC BY 2.5", "url": "https://en.wikinews.org/wiki/...", "retrieved_at": "2026-11-24T12:18:12Z", "published_at": "2006-08-28" }
  ],
  "check": "https://github.com/Hashim57/olo-commons/blob/main/docs/RECEIPTS.md",
  "receipt_sha256": "572ff0bf..."
}
```

`tests/fixtures/receipt.json` is a complete one over two real Wikinews atoms. Every sentence the writer produced is listed, shown or not, so a reader sees what Olo held back and why (`verdict`). Evidence is keyed to atom ids, which outlive the response; a quote that named a passage the answer did not have is dropped, never attached to a guessed atom. An atom whose fingerprint could not be read is listed with `content_hash: null`, and the check says so.

## Checking one

```
export OLO_ANON_KEY=<the public read key from docs/API.md>
python3 scripts/verify_receipt.py receipt.json        # a receipt, or a whole olo-answer response
```

Standard library only. Four checks, each printed as PASS or FAIL:

1. **intact**: `receipt_sha256` is the SHA-256 of the receipt's canonical JSON (keys sorted at every level, no whitespace, UTF-8; integers, never floats), so nothing in it was changed after it was issued.
2. **unchanged**: each atom still has the fingerprint the receipt recorded, read through the public `olo_atom` RPC. An atom whose text has changed since (a source revised it) or that has been removed (a cleanup rule refused it) is named, not hidden.
3. **quoted**: every quoted piece of evidence is in its atom's own title, summary or content, read the way `olo-answer` reads quotes (case, curly quotes, dashes and spacing do not make a quote inexact; the words must be the source's own, in its order). This is checked against the Commons, not against the receipt, so resealing an edited receipt does not get a false quote past it.
4. **licensed**: every atom names its source and licence, so the answer can be cited and reused under the source's terms.

Exit status 0 when every check holds, 1 when one fails, 2 when the receipt cannot be read. `--offline` runs checks 1 and 4 only.

## What a receipt does and does not prove

- It proves that the quoted words are in the named open sources, that those sources have not changed since (or says that they have), and that the receipt itself has not been edited, once you hold a copy or its fingerprint was published somewhere you trust.
- It records what the verifier said. A supported verdict means Zeus (or the named fallback) judged that the quoted words support the sentence; Zeus's measured accuracy is in `docs/ZEUS_SCORECARD.md`, and it can be wrong. The receipt makes that judgement inspectable; it does not make it infallible.
- The fingerprint is not a signature: it does not by itself prove that Helius Network issued a receipt. A signed receipt (an Ed25519 signature with a published public key) is the next step, tracked in the roadmap issue.
- The question is in the receipt because the receipt goes back to the person who asked. Olo never stores question text (SECURITY.md); neither does the receipt path.
