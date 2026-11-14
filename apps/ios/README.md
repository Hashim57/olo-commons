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
- **Library**: Memory (approve, forget), Scheduled (run now, delete), Watching (stop), Artifacts
  (read, share) and Skills, from the same account as the Mac.

## What iOS does not allow, and what is used instead

- An app cannot draw over other apps. Olo outside the app is the Live Activity, the widget,
  notifications and Siri.
- There is no way to read Apple Mail. Email is a later stage, through each mail provider's own
  sign-in.
- An app cannot read other apps' data. "Learning the schedule" means the calendar and reminders
  the person allows.

## Not in this first build

Build with Olo's editor and file tree, the browser and Run view, exports to Word, PowerPoint and
Excel, files and projects, the Zeus graph, connectors, creating scheduled tasks and skills on the
phone, the Olo brain orbs, and subscriptions bought in the app. Plans bought on the web or the
Mac are honoured, because the plan belongs to the account. See `apps/macos/PARITY.md` for the Mac's
full list.

## Build it in Xcode

1. On a Mac with Xcode 16 or later: `brew install xcodegen`, then in `apps/ios` run `xcodegen generate` and open `Olo.xcodeproj`.
2. Select the Olo target, Signing and Capabilities, and choose your team. Do the same for the OloWidgets target. Xcode creates the app group `group.com.helius.olo` for both.
3. Choose your iPhone as the destination and press Run. The Dynamic Island and the Lock Screen need a real iPhone; the rest runs in the simulator.
4. To submit: Product, Archive, then Distribute App. The version is 2.0.0 (1); it must be higher than the last build of the earlier app.

Before submitting, update the App Privacy answers in App Store Connect: the app reads calendar and
reminders on the device, and shares calendar titles and times with Helius Network only when the
person presses "Send to Olo" on the Plan my day sheet.

## Checks

Every push runs `.github/workflows/ios-app.yml`: OloKit's unit tests, then an unsigned build of the
app and its widget extension for the iPhone simulator. The app cannot be compiled on Linux.
