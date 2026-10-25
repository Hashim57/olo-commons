# Olo for macOS: build and submit from Xcode

You need Xcode 16 or newer and your Apple Developer account. About 20 minutes the first time.

## 1. Open the project

Double click `Olo.xcodeproj`. Xcode opens it and fetches nothing from the internet (the app has no outside libraries).

## 2. Signing (once)

1. In the left sidebar click the blue **Olo** project, then the **Olo** target, then the **Signing & Capabilities** tab.
2. Tick **Automatically manage signing** and choose your team under **Team**.
3. The Bundle Identifier is `io.helius-olo.desktop`. If Xcode says it is taken, change it to one of yours (for example `com.yourname.olo`) and use the same one in App Store Connect.
4. App Sandbox should show **Outgoing Connections (Client)** and **User Selected File: Read Only**. Leave them as they are.

## 3. Try it on your Mac

Choose **My Mac** at the top, press **Cmd+R**. Olo opens with an icon in the menu bar. Press Option+Space in any app to try Quick Ask. Quit it with Cmd+Q when done.

## 4. Create the app in App Store Connect (once)

appstoreconnect.apple.com > **Apps** > **+** > **New App**: platform **macOS**, name **Olo**, language English (UK), bundle ID `io.helius-olo.desktop` (pick it from the list; if it is not there, Xcode creates it the first time you archive, or add it at developer.apple.com > Identifiers), SKU `olo-macos`.

## 5. Archive and upload

Version 1.1.0, build 2 are already set in the project. For each later upload raise the Build number by one.

### Archive

1. At the top choose **Any Mac (Apple Silicon, Intel)**.
2. Menu **Product** > **Archive**. When it finishes, the Organizer window opens.
3. Select the archive > **Distribute App** > **App Store Connect** > **Upload**, then Next through the screens (automatic signing) and **Upload**.
4. After 10 to 30 minutes the build appears in App Store Connect > Olo > the macOS version > **Build**. Select it.

For each later upload, raise the **Build** number (Olo target > General > Identity) by one.

## 6. Fill in the listing and submit

Copy the subtitle, description, keywords, privacy answers and reviewer notes from `APP_STORE.md` (section 4), add at least one screenshot (Cmd+Shift+4, then Space, then click the Olo window), and press **Add for Review** / **Submit**.

## If something goes wrong

- **"No account for team"**: Xcode > Settings > Accounts > + > Apple ID, sign in, then pick the team again in step 2.
- **"Version or build already used"**: raise the Build number and archive again.
- **Missing icon warning**: make sure you archived the Olo scheme, not OloTests.
- **Changing the code later**: the project file here is generated from `project.yml`. Small edits in Xcode are fine; for big changes ask me and I will update both.
