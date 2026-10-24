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

## Where answers are made

Never on the Mac. In order: helius-olo.io (Anthropic, then OpenAI, then open models on Cloudflare; Zeus checks each sentence), then Olo Commons' own service (open models on Groq and Cloudflare, checked by Zeus) if helius-olo.io cannot be reached, then the offline quotes above. The only work the Mac does is a keyword search (BM25) over saved text, which takes milliseconds.

## Layout

- `OloKit/`: everything that is not interface, Foundation only, with unit tests (`swift test --package-path OloKit`): API client and NDJSON stream parser (mirrors olo-web's `client/src/lib/chatStream.ts`), tRPC with superjson, Commons snapshot and answer service, BM25 search, sentence splitting, quoted answers, message composition, local store.
- `Olo/Sources/`: the SwiftUI app, Quick Ask panel, hot key, Services provider, file reading, folder index.
- `project.yml`: the XcodeGen description of the Xcode project (bundle id `io.helius-olo.desktop`, macOS 14+, App Sandbox with network client, user-selected read-only files and app-scoped bookmarks).

## Building

GitHub builds and tests it on every push (`.github/workflows/macos-app.yml`), and keeps an unsigned universal app as a download for 30 days (Actions > macOS app > the latest run > Artifacts). To work on it in Xcode:

```
brew install xcodegen
cd apps/macos && xcodegen generate && open Olo.xcodeproj
```

For the App Store, see APP_STORE.md: the workflow can sign and upload the build without building anything on your Mac.
