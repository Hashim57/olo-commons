# Olo for iPhone (native)

A SwiftUI app that shares `OloKit` with the Mac app (`apps/macos/OloKit`), so both speak to
helius-olo.io through the same code: the same sessions, the same streamed answers, the same Zeus
verdicts. It replaces the earlier React Native app under the same bundle id, `com.helius.olo`.

## What is in it

- **Olo** (chat): the Mac's conversation on a phone. Swift, Standard and Deep; Sources, Olo brain,
  Private and Challenge me; verdict cards; "Answered by Olo, checked by Zeus"; follow-ups; your
  conversations; sign in by emailed code; the terms sheet before the first question.
- **The character**: Olo, light blue, drawn in SwiftUI (`Shared/OloFace.swift`). It floats over every
  screen of the app, can be dragged anywhere, looks where you drag it, and offers a suggestion that
  fits the screen when tapped. Its mood follows the answer: thinking, pleased, or unsure when part
  of an answer could not be verified.
- **Talk to Olo**: the microphone button listens with the phone's own speech recognition; "Read
  aloud" speaks answers with the phone's own voice.
- **Today**: reads the calendar and reminders on the phone (EventKit). What is next, the day's
  agenda, free time, the reminders due, and "What Olo has noticed": habits worked out on the device
  from the last four weeks (`OloKit/DayPlan.swift`, unit tested). "Plan my day with Olo" shows
  exactly what will be shared before anything is sent.
- **Outside the app**: a Live Activity puts Olo in the Dynamic Island and on the Lock Screen with
  what is next; a Home Screen widget shows the next event; a morning brief arrives as a
  notification written on the phone; Siri and Shortcuts get "Ask Olo" and "What is my day like".
- **Library**: Memory (approve, forget), Scheduled (create, run now, pause, email me, delete),
  Watching (stop), Artifacts (the page or the code, exports, share link, delete) and Skills
  (create, delete), from the same account as the Mac.
- **Build with Olo**: say what to build and Olo writes the file as a background build on the
  server, with the same progress card as the Mac. The file opens in Olo's editor: coloured as you
  type by OloKit's scanner, "Ask Olo" rewrites it and shows the change line by line before
  anything is replaced (code.edit), "Review" lists what Olo found with each fix one tap away
  (code.review), and "Preview" shows the page an HTML, SVG or React file makes (JavaScript off
  until you turn it on). Files an answer produces open in the same editor. Files are kept on the
  phone and show in the Files app under On My iPhone, Olo, Build.
- **Exports**: a conversation, one answer, an artifact or a file in the editor as PDF, Word
  (.docx), Markdown, plain text or CSV (tables), through the share sheet, plus a share link.
  The .docx is written on the phone by `OloKit/DocumentText.swift` (unit tested): the Mac uses
  AppKit's exporter, which iOS does not have. Like the Mac, there is no PowerPoint or Excel file.
- **Files and projects**: the paperclip attaches PDF, text, Markdown, CSV, JSON, RTF and source
  files from the Files app to a question (read on the phone, trimmed by the Mac's composer).
  Projects keep instructions and reference files; turn on "Ask inside this project" and both go
  with every question.
- **What Zeus knows**: the Zeus graph, drawn from the same layout as the Mac, with each claim's
  evidence and the source reputations.
- **Mail and calendar (connectors)**: connect Google and Olo reads Gmail and Google Calendar,
  read only, when a question is about them. The consent page opens in the browser and returns
  to the app through `olo://connected`. Tokens stay on the server.
- **Email**: reading is the Google connector above. Writing is a draft: any answer can be
  opened in Mail with the subject, recipients and body filled in (`OloKit/MailDraft.swift`), for
  you to read and send. Olo never sends mail itself.
- **Plans**: Starter and Growth bought through the App Store with StoreKit 2, checked by
  helius-olo.io before the purchase is finished, with Restore Purchases and the renewal terms.
  A plan bought on the web or the Mac works here too, because the plan belongs to the account.

## What iOS does not allow, and what is used instead

- An app cannot draw over other apps. Olo outside the app is the Live Activity, the widget,
  notifications and Siri.
- There is no way to read Apple Mail. Olo reads mail through a connected Google account
  instead, and hands drafts to Mail for you to send. Other mail providers are not connected yet.
- An app cannot read other apps' data. "Learning the schedule" means the calendar and reminders
  the person allows.

## Smaller than the Mac, on purpose or for now

- The editor works on one file at a time in the app's own folder. There is no folder tree, no
  tabs, no suggestions at the cursor as you type, no automatic review while typing and no
  "Fix as I save": the phone asks for a review or a change when you press the button.
- No browser and Run view, no Olo brain orbs, no Quick Ask window and no "Talk to Olo" call
  screen (the microphone button and Read aloud cover voice).
- Word files (.docx, .doc) cannot be attached, because iOS has no reader for them; PDF and
  text can.
- Only Google is offered as a connector, as on the Mac, and only when the server has Google
  set up.

See `apps/macos/PARITY.md` for the Mac's full list.

## Before the plans can be bought

The two subscriptions must exist in App Store Connect under the app `com.helius.olo`, with
exactly these product ids, which helius-olo.io already maps to Starter and Growth
(`server/applePurchases.ts` in olo-web):

- `com.helius.olo.starter.monthly` (Olo Starter, 500 messages a month, 10 analyses)
- `com.helius.olo.growth.monthly` (Olo Growth, 5,000 messages a month, 100 analyses)

Put both in one subscription group, one month each, with your prices. If they already exist
from the earlier iPhone app, nothing needs creating. Until they are approved, or when the App
Store returns nothing, the plans sheet says so and offers Try again; everything else works.
The server must also have its App Store keys set (it reports this through
`billing.applePurchasesAvailable`); the Mac app already depends on the same setting.

## Build it in Xcode

1. On a Mac with Xcode 16 or later: `brew install xcodegen`, then in `apps/ios` run `xcodegen generate` and open `Olo.xcodeproj`.
2. Select the Olo target, Signing and Capabilities, and choose your team. Do the same for the OloWidgets target. Xcode creates the app group `group.com.helius.olo` for both.
3. Choose your iPhone as the destination and press Run. The Dynamic Island and the Lock Screen need a real iPhone; the rest runs in the simulator.
4. To submit: Product, Archive, then Distribute App. The version is 2.0.0 (1); it must be higher than the last build of the earlier app.

Before submitting, update the App Privacy answers in App Store Connect: the app reads calendar and
reminders on the device, and shares calendar titles and times with Helius Network only when the
person presses "Send to Olo" on the Plan my day sheet.
Files attached to a question and code sent for review or rewriting go to Helius Network to be
answered; a connected Google account is read by the server, never by the phone.

## Checks

Every push runs `.github/workflows/ios-app.yml`: OloKit's unit tests, then an unsigned build of the
app and its widget extension for the iPhone simulator. The app cannot be compiled on Linux.
