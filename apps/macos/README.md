# Olo for macOS

A native SwiftUI app (not a website in a window) on the same account as helius-olo.io and the iPhone app.

## What it does

| Feature | How |
|---|---|
| Quick Ask | Option+Space in any app opens a floating panel; ask, read the checked answer, Esc to close. Uses the Carbon hot key API, so no Accessibility permission. Falls back to Option+Shift+Space if another app holds Option+Space. |
| Ask about selected text | Select text anywhere, then app menu > Services > Ask Olo (or right click > Services). Finder: select files > Services > Ask Olo About These Files. A keyboard shortcut can be given in System Settings > Keyboard > Keyboard Shortcuts > Services. |
| Your files | Attach (Cmd+O) or drop PDFs, Word, RTF, OpenDocument, text, Markdown, CSV, HTML and code files. Text is read with PDFKit and the system importers; a large file is trimmed so the question stays a sensible size. |
| Your folders | Settings > Folders: choose folders Olo may search. They are indexed only when you add them or press Index Again (never watched in the background); with "Use my folders" on, the best matching passages go with your question. |
| Offline | Conversations stay readable. Questions are answered by quoting the copy of Olo Commons saved on the Mac (about 1 MB, refreshed every six hours while online), your folders and attached files, clearly labelled as unchecked. The question is asked properly, with checked sources, when the connection returns. An "Offline only" switch sends nothing at all. |
| Same account | Sign in with your email code; conversations are the same on the web, iPhone and Mac. Without signing in, Olo starts an anonymous workspace with the free messages, which moves into your account when you sign in. |
| Menu bar, login | Lives in the menu bar after the window closes; Open at Login in Settings. olo://ask?q=... and olo://chat/42 links work. |

## 1.1: checked by default, flags, consent

- Only the sentences Zeus could support are shown; contradicted, not covered and unchecked ones wait behind "Show N unverified sentences" (Settings > General to always show them).
- Every claim has a Flag menu (Supported, Contradicted, Not covered, Wrong source, Unclear). A reviewer confirms flags before they teach Zeus (docs/FEEDBACK.md). Never the question, never who asked.
- Under each answer: who wrote it, where it ran, who checked it, and how many independent publishers stand behind it.
- "Use my conversations to improve Olo and train Zeus" is off until ticked (sign-in and Settings > Account). Flags are always used; memory and files never are.
- A message that reads as self-harm shows helplines above the answer (Samaritans 116 123, Shout 85258, 116 123 in the EU, 999 or 112). The answer is never blocked.

## 1.2: terms, subscriptions, the Helius atom

- **Before you start.** A sheet before the first conversation summarises the Olo Terms of Use in plain English (who provides Olo, that it can be wrong, email code accounts, how subscriptions renew and where to cancel, your content stays yours, training only with the consent switch on, flags always used) with links to the Terms, the Privacy Policy and Apple's standard EULA. It closes only through "I agree and continue" or Quit. The version agreed to is kept on the Mac (`OloKit/Legal.swift`); when `Legal.termsVersion` changes the sheet comes back saying "The terms have changed". Settings > Account shows "Terms accepted on <date>" with "Read again".
- **Subscriptions through the App Store.** Olo Starter (500 messages a month, 10 analyses) and Olo Growth (5,000 messages, 100 analyses) are sold with StoreKit 2, as guideline 3.1.1 requires; the app never opens a web checkout. Prices come from StoreKit in the buyer's currency. A verified transaction is sent to helius-olo.io (`billing.redeemApplePurchase`), which checks it with Apple and ties the plan to the account; only then is the transaction finished, so a dropped connection never loses a purchase. Restore Purchases runs `AppStore.sync()` and redeems every current entitlement. Sign-in comes first, because the plan belongs to the account and works on the web and the iPhone too (a plan bought there counts here: `billing.entitlement` is the one source of truth, refreshed at start, after sign-in, after a purchase and whenever the server refuses a question for want of allowance).
- **Where it shows.** When the free messages (5 a day, refilled every 24 hours) are spent, a banner above the composer says so, names the refill time and offers Subscribe. Settings > Account has "Plan: Free" or "Plan: Starter" with Subscribe or Manage (the App Store's subscription page). Olo > Subscribe in the menu. After a purchase: "You're subscribed." and Continue, which returns focus to the composer.
- **The Helius atom** (`docs/HELIUS_ATOM.md`, `Olo/Sources/HeliusAtom.swift`): drawn with Canvas, no image files. The full build up at the top of the terms sheet (a click skips it), the idle loop as the empty state of a new conversation with "Olo. Checked by Zeus. Learning on WEBOCTA." underneath, and a 56 pt loader while an answer is written and checked. With Reduce Motion on, only the nucleus breathes.
- **Local testing.** `Olo/Olo.storekit` holds the two products (placeholder prices) and is set on the Olo scheme, so the purchase flow runs in Xcode without App Store Connect. APP_STORE.md, section "Subscriptions in App Store Connect", has the one-time setup.

## Where answers are made

Never on the Mac. In order: helius-olo.io (Anthropic, then OpenAI, then open models on Cloudflare; Zeus checks each sentence), then Olo Commons' own service (open models on Groq and Cloudflare, checked by Zeus) if helius-olo.io cannot be reached, then the offline quotes above. The only work the Mac does is a keyword search (BM25) over saved text, which takes milliseconds.

## Layout

- `OloKit/`: everything that is not interface, Foundation only, with unit tests (`swift test --package-path OloKit`): API client and NDJSON stream parser (mirrors olo-web's `client/src/lib/chatStream.ts`), tRPC with superjson, Commons snapshot and answer service, BM25 search, sentence splitting, quoted answers, message composition, local store.
- `Olo/Sources/`: the SwiftUI app, Quick Ask panel, hot key, Services provider, file reading, folder index.
- `project.yml`: the XcodeGen description of the Xcode project (bundle id `io.helius-olo.desktop`, macOS 14+, App Sandbox with network client, user-selected read-only files and app-scoped bookmarks; StoreKit needs no entitlement). `Olo/Olo.storekit` is the local StoreKit configuration for the Olo scheme.

## Building

GitHub builds and tests it on every push (`.github/workflows/macos-app.yml`), and keeps an unsigned universal app as a download for 30 days (Actions > macOS app > the latest run > Artifacts). To work on it in Xcode:

```
brew install xcodegen
cd apps/macos && xcodegen generate && open Olo.xcodeproj
```

For the App Store, see APP_STORE.md: the workflow can sign and upload the build without building anything on your Mac.
