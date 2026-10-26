# Olo for macOS: feature parity with the web client and the iPhone app

Audited on 2026-10-25 against olo-web v53 (`client/src/components`, `client/src/pages`, `server/routers.ts`, `server/chatStream.ts`) and olo-ios v54 (`apps/mobile/src/components`, `lib/api.ts`). Every user-facing feature of those two clients is listed, with its state on the Mac.

States: **done** (on the Mac, same procedures as the web and iPhone), **partial** (on the Mac with a stated gap), **Mac equivalent** (a different mechanism does the same job, named), **not done** (with the reason), **n/a** (does not apply to a Mac, with the reason).

## Conversations and library

| Feature | Web / iPhone | Mac | Notes |
|---|---|---|---|
| List conversations (title, date, pinned, folder) | `chat.listConversations` | done | Sidebar, `LibraryView.swift`. Pinned section, folder filter, date on each row. |
| Search conversation titles | client side | done | Sidebar search field (local). |
| Full text search across threads | `chat.search` | done | The same field, two or more characters while online: server hits with snippets, click opens the thread. |
| Open a conversation and its messages | `chat.getMessages` | done | Was already there (saved copy shows first). |
| Delete a conversation | `chat.deleteConversation` | done | Context menu "Delete" (server and this Mac). "Delete from This Mac" kept for local only copies. |
| Pin / unpin | `chat.updateConversationOrganization` | done | Context menu. |
| Move to a folder, new folder | `chat.updateConversationOrganization` | done | Context menu "Move to Folder". Folders are the server's grouping of threads. |
| Rename a conversation | no procedure | not done | Neither client renames a thread; the router exposes no title update (`store.updateConversation` can, `routers.ts` does not). Nothing to call. |
| Tags, rename tag, rename folder, batch move | `chat.updateConversationTags`, `renameConversationTag`, `renameConversationFolder`, `batchUpdateConversationFolder` | not done | Secondary organisation the iPhone app does not expose either. Folder filter and move cover the daily use. |
| Fork a thread at a message | `chat.fork` | not done | Not in this round. |
| Summarise and continue | `chat.summariseAndContinue` | not done | Shown as a suggestion by the context gauge on the web; the Mac shows the gauge (below) but not the button yet. |
| Export every thread (JSON) | `chat.exportAll` | Mac equivalent | Export per conversation to Markdown or PDF (below). |
| Clear history | `chat.clearHistory` | Mac equivalent | Settings > Account > Remove Local Data clears this Mac; the server side clear is not offered, by design (one click deleting every thread on every device). |
| Projects: list, create, delete, select | `projects.list`, `projects.create`, `projects.delete` | done | Sidebar "Projects" section. Selecting one scopes new questions (`projectId` on the stream input, as the web does). |
| Project files and instructions | `projects.listFiles`, `addFile`, `deleteFile`, `update`, `context` | partial | OloKit has the calls and models; the Mac shows the project's description and file count in the sidebar footer, but no project editor yet. |
| Nudges (unfinished work on return) | `nudges.list`, `nudges.mark` | done | Banner above the composer, as on the web; "seen" when opened, "dismissed" on close. |
| First run suggestions | `FirstRun.tsx` | done | The four example prompts on the empty state. |

## Answers

| Feature | Web / iPhone | Mac | Notes |
|---|---|---|---|
| Streamed answer, status, sources, verification, follow ups, cut | `/api/chat/stream` | done | Already there. |
| Abstain by default (only supported sentences shown) | client | done | Already there. |
| Flags on a verdict | olo-feedback | done | Already there. |
| Answered by line, publishers count | client | done | Already there. |
| References line ("N references checked, M not found") | `references` stream event, `verification.references` | done | `References.swift` mirrors `client/src/lib/references.ts`; flagged references listed under the line. |
| Source tier pills (tier 4 label), link status | `sources` event with `tier`, `tierLabel`, `urlOk` | done | Label on tier 4 sources, a mark on links that did not answer. Reliability mark when present. |
| Memories that shaped the reply | `memories` stream event | done | "Shaped by N things you've told Olo" under the answer, listing them. |
| Inline charts (```chart blocks) | `chartSpec.ts`, `InlineChart.tsx` | done | `Charts.swift` is the strict parser (same rules); `ChartView.swift` draws with Swift Charts. |
| Edit a passage in place | `chat.editPassage` | done | "Edit a passage" on an answer: pick a sentence (or type the passage), say the change, only that passage is rewritten; the thread is refetched as the web does. The server does not re-verify on edit; the Mac notes that the verdicts are from before the edit and offers "Fix flagged sentences". |
| Fix flagged sentences (research and rewrite, re-checked) | `/api/chat/fix` NDJSON | done | Button in the verification box when anything is flagged; progress lines shown; the new text, sources and verification replace the old. |
| Watch a claim | `monitors.watch` with `claimId` | done | "Watch" in the verification box when any claim carries a `claimId`. |
| Label a verdict for training ("Zeus was right") | `zeus.label` | not done | Flags (above) already send the reader's verdict to a reviewer. |
| Regenerate, redo with Deep, Continue | stream `regenerate`, tier | partial | "Continue" after a cut answer is a follow up button. Regenerate and tier choice are not on the Mac; `AskInput` carries the fields. |
| Crisis helplines | client | done | Already there. |
| Challenge mode ("Challenge me") | stream `challenge: true` | done | Toggle in the composer, saved on this Mac, sent with each question. |
| Context gauge | `contextGauge.ts` | done | `ContextGauge.swift` mirrors the estimate; shown under the composer, amber at 70 percent, red at 90. |
| Compute / analysis jobs | `compute.start`, `get`, `list`, `cancel` | done | "Analyse" in the composer menu runs the draft as a job and polls progress; the result lands in the thread. "Jobs" panel lists and cancels. |
| Background builds | `builds.*`, `truncated` event | partial | The `truncated` notice is shown; polling the build and showing the file is not done. |
| Private chats (ghost mode under the name the clients show) | stream `private: true`, ghost | done | 1.3. "Private chat" switch (lock) in the composer, File > New Private Chat. Never synced to the server list, never the brain, kept only on this Mac, encrypted with AES-GCM under a Keychain key (`OloKit/PrivateStore.swift`). The server keeps no history, so the Mac sends a short summary of earlier turns with each follow-up. Sidebar: lock and "Only on this Mac". |
| Olo brain: ask once, per chat switch, brain note | `auth.me` `brainSharing`, `auth.setBrainSharing`, stream `brain`, `client`, event `brain` | done | 1.3. One-time sheet when the default is null (on this Mac when anonymous), "Add to Olo brain" per chat, a quiet note under the answer, Help > View the Olo brain. On the Commons fallback the Mac calls `olo-brain-ask` directly with `client: "macos"`. |
| Tiers, library file attachments (`fileIds`) | stream fields | not done | Mac attachments are read on the Mac and sent inline (its own feature); the server file library is below. |

## Panels

| Feature | Web / iPhone | Mac | Notes |
|---|---|---|---|
| Memory: list by category, approve proposed, reject, add, edit, delete, clear, on/off, cap | `memory.*` | done | `MemoryView.swift`. Reject is delete, as on the web. Only approved memories are recalled; the view says so. |
| Memory export | `memory.export` (JSON download) | done | Saved as Markdown with NSSavePanel (`MemoryMarkdown`), JSON also offered. |
| Artifacts: list, open, preview, code, delete | `library.artifacts`, `library.deleteArtifact`, stream `artifact` | done | Right hand inspector in a conversation (this thread's artifacts first, then the library). HTML and SVG previewed in WKWebView with JavaScript off by default (a switch turns it on for React or scripted pages). Copy and Save. |
| Share links (/s/token), list, revoke | `library.share`, `shares`, `revokeShare` | done | "Copy Share Link" for a conversation or an artifact; the Workspace panel lists and revokes. |
| Files library (upload, preview text, rename, delete, download) | `files.*` | not done | The Mac attaches files directly (read on the Mac, sent with the question). The server library needs base64 upload and a picker; not in this round. |
| Skills: list, create, delete, report | `skills.*` | done | `SkillsView.swift`. There is no enable/disable on the server: a skill is active, pending review, quarantined or rejected, and the Mac shows which. |
| Connectors: Google connect, disconnect | `connectors.*` | done | Connect opens Google's consent page in the browser (`NSWorkspace`) and polls `connectors.list` until the account appears. |
| Monitors ("Watching"): list, changed, acknowledge, check now, stop | `monitors.*` | done | `MonitorsView.swift`. Create happens from an answer (Watch, above), as on both clients. |
| Monitor hook (URL, rotate, revoke) | `monitors.hook`, `rotateHook`, `revokeHook` | done | Same panel. |
| Evidence file | `monitors.evidenceFile` | done | Saved as HTML with NSSavePanel and opened. |
| Zeus graph | `zeus.graph` | done | `ZeusGraphView.swift`: Canvas, phyllotaxis placement as the iPhone does, colour by verdict, size by corroboration, click for the claim and its evidence; stats and source reputations. |
| Workspaces (shared graphs, invite) | `workspaces.*` | not done | Private graph only (`workspaceId: null`). |
| Build with Olo (editor, review as you type, suggestions, Olo writes code) | `code.review`, `code.edit`, `code.complete`, `code.allowance` | done (Mac first) | 1.3 build 6. A real editor inside Olo: file tree with New File and New Folder, tabs with unsaved dots, Cmd+S and autosave, line numbers, syntax colours, auto-indent, find, issue dots and underlines with hover messages. Review as you type (1.2 s after typing stops, on the open text), Apply and Fix as I type go into the editor with undo, ghost text suggestions (Tab accepts), "Tell Olo what to build or change" with a diff to accept or reject, Explain This in a private chat, the Build allowance in the status line. Still watches the folder, so other editors work too. Always private: code never enters the brain. Degrades to a notice when the server lacks the v61 procedures. The web and iPhone do not have it yet. |
| Coding workspace, code hand off | other `code.*` procedures | not done | The web's coding workspace is a separate surface; Build with Olo is the Mac's own take. |
| Credits / usage meter | `billing.entitlement` | done | Messages used of limit (and analyses) in the sidebar footer and Settings > Account. |
| Paywall / subscribe | `subscription.createCheckout` (web), StoreKit (iPhone) | Mac equivalent | StoreKit 2 (1.2); the Mac never opens a web checkout. |
| Export a conversation (text, PDF) | `exportEngine.ts` (jsPDF), `expo-print` | done | Markdown (same layout as the text export) and PDF through `NSPrintOperation` saving to a file, with NSSavePanel. |
| Change log (/changes) | `Changes.tsx` | done | Help > What's New opens https://helius-olo.io/changes. |
| Support page | `Support.tsx` | done | Help > Olo Support (already there). |
| Terms, privacy | pages | done | Terms sheet (1.2) and links. |
| Sign in with email code, anonymous workspace, consent | `auth.*` | done | Already there. |
| Offline panel and offline answers | `OfflinePanel.tsx`, `commonsOffline.ts` | Mac equivalent | Settings > Offline and the offline answer path (1.0). |
| Dictation | browser SpeechRecognition / expo-speech-recognition | done | `Dictation.swift`: SFSpeechRecognizer, on device when the recogniser supports it; mic button in the composer. Needs the microphone and speech recognition permissions (project.yml). |
| Push notifications | `nudges.registerDevice` (ios/android/web) | n/a | The server accepts only ios, android and web tokens; nudges are fetched and shown in the app instead (above). |
| Quick actions (Services, hot key, menu bar) | iPhone widget, share sheet | Mac equivalent | Quick Ask (Option+Space), Services menu, menu bar item, olo:// links. |
| Install / add to home screen, PWA | web | n/a | A Mac app is installed. |

## Not applicable on a Mac

- Push notifications: no server token type for macOS; the same nudges appear in the app on return.
- Add to home screen, service worker, browser storage usage meter: the Mac app is installed and keeps its data in its own container (Settings > Account shows what).
- The iPhone widget and the iOS share sheet: Quick Ask and the Services menu are the Mac's equivalents.
