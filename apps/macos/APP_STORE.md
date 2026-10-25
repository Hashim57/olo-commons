# Olo for macOS on the Mac App Store

The native app replaces the Electron package from earlier today: it is a real Mac app (menu bar, Quick Ask panel, Services menu, files and folders, offline), which is what App Review's guideline 4.2 asks for. GitHub's Mac runners build, sign and upload it; you only do the Apple account steps once.

## 1. Apple account (once, about 30 minutes, in a browser)

1. Apple Developer Program ($99 a year) at developer.apple.com/programs. Note your **Team ID** (Account > Membership details).
2. Certificates, Identifiers & Profiles > Identifiers > + > App IDs > App: description `Olo`, explicit Bundle ID `io.helius-olo.desktop`. No extra capabilities are needed.
3. **Certificates** > +: make an **Apple Distribution** certificate and a **Mac Installer Distribution** certificate. Each asks for a certificate signing request: on your Mac, Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority > Saved to disk. Download each certificate and double click it so it lands in your keychain.
4. Export each one as a .p12: Keychain Access > My Certificates > right click the certificate > Export, choose one password for both (you will enter it as a secret below; never send it to anyone).
5. **Profiles** > +: Mac App Store Connect > App ID `io.helius-olo.desktop` > your Apple Distribution certificate. Download it.
6. **App Store Connect API key**: appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API > + with the App Manager role. Note the Key ID and Issuer ID and download the .p8 (it can be downloaded only once).
7. App Store Connect > Apps > + > New App: macOS, name **Olo**, English (UK), bundle ID `io.helius-olo.desktop`, SKU `olo-macos`.

## 2. Put them in GitHub (once, Terminal on your Mac)

These commands only read files you downloaded and send them to GitHub's encrypted secrets; nothing runs in the background afterwards. Replace the file names with yours; each command asks nothing else except the last few, which ask for the value.

```
cd ~/Downloads
gh secret set APPLE_TEAM_ID -R Hashim57/olo-commons
base64 -i Distribution.p12 | gh secret set MAC_DIST_CERT_P12 -R Hashim57/olo-commons
base64 -i Installer.p12 | gh secret set MAC_INSTALLER_CERT_P12 -R Hashim57/olo-commons
gh secret set MAC_CERT_PASSWORD -R Hashim57/olo-commons
base64 -i Olo_Mac_App_Store.provisionprofile | gh secret set MAC_PROVISIONING_PROFILE -R Hashim57/olo-commons
gh secret set ASC_KEY_ID -R Hashim57/olo-commons
gh secret set ASC_ISSUER_ID -R Hashim57/olo-commons
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8 -R Hashim57/olo-commons
```

(No `gh`? GitHub > olo-commons > Settings > Secrets and variables > Actions > New repository secret, and paste the output of each `base64 -i file` command.)

## 3. Upload a build

GitHub > olo-commons > Actions > **macOS app** > Run workflow > tick **Archive, sign and upload** > Run. About 15 minutes later the build appears in App Store Connect > Olo > TestFlight. For each later upload, run it again (the build number rises by itself).

## 4. Listing and review

- **Subtitle**: `Answers you can check`
- **Promotional text**: `Ask from any app with Option+Space and see which sentences the sources support. Same account as Olo on the web and iPhone.`
- **Description**:

  Olo answers your questions from sources you can open, and checks every sentence: supported, contradicted or not covered, with the words that decide it.

  On the Mac, Olo is always one shortcut away. Press Option+Space in any app to ask in a floating panel. Select text anywhere and choose Services > Ask Olo to ask about it. Drop in PDFs, Word documents and notes, or let Olo search folders you choose.

  Olo keeps working without a connection: it quotes the copy of Olo Commons saved on your Mac, Olo's open knowledge base where every fact carries its source and licence, and your own files, then asks properly when you are back online.

  The same account and conversations as Olo on the web and iPhone. Answers are made in the cloud, so Olo stays light on your Mac.

- **Keywords**: `research,sources,citations,fact check,AI assistant,verified,offline,PDF,notes,study`
- **Category**: Productivity (secondary: Reference). **Copyright**: `2026 Helius Network`.
- **URLs**: support `https://helius-olo.io/support`, marketing `https://helius-olo.io`, privacy `https://helius-olo.io/privacy`.
- **Screenshots** (16:10, for example 2880 x 1800): the main window with a checked answer, the Quick Ask panel over another app, an offline answer, Settings > Folders.
- **App Privacy**: declare what helius-olo.io collects (email for sign-in, the questions, answers and files you send; linked to the user, not used for tracking). Files and folders you do not send stay on the Mac. Check it against your privacy policy.
- **Encryption**: the app declares `ITSAppUsesNonExemptEncryption = false` (standard HTTPS only).
- **Age rating**: answer the questionnaire truthfully; open-ended AI assistants usually land at 12+ or 17+.

**Notes for the reviewer**:

> Olo is a research assistant that answers from cited sources and checks each sentence against them. Mac features: a menu bar item; a global shortcut (Option+Space) that opens a floating Quick Ask panel over any app; a Services menu item ("Ask Olo") for selected text and for files in Finder; attaching or dropping PDF, Word and text files; optional search of folders the user chooses (security-scoped bookmarks, read only); and offline answers quoted from a knowledge base saved on the device. No account is needed: the first question starts an anonymous session with free messages. To test offline, ask one question online, turn Wi-Fi off and ask again.

## 5. Subscriptions in App Store Connect (once, about 30 minutes)

Olo 1.2 sells two auto-renewable subscriptions through StoreKit. The Mac app is its own App Store Connect record, separate from the iPhone app, so the products are created again here with the Mac product ids below. The app reads prices from StoreKit; nothing is typed into the code.

### 5.1 Create the group and the two products

appstoreconnect.apple.com > **Apps** > **Olo** (macOS) > in the left sidebar under **Monetization** choose **Subscriptions** > **Create** (Subscription Groups).

1. **Subscription group**: Reference Name `Olo plans`. Save. Open the group and add a **Localization** (English (UK)): display name `Olo plans`, with a custom app name left blank.
2. Inside the group press **Create** (subscription) for the first product:
   - Reference Name: `Olo Starter Monthly (Mac)`
   - Product ID: `com.helius.olo.desktop.starter.monthly` (exactly this; it cannot be changed later)
   - Subscription Duration: **1 month**
   - **Subscription Prices** > Add: pick the base country (United Kingdom) and the price tier you want; Apple fills the other countries. The app shows whatever you choose.
   - **App Store Localization** (English (UK)): Display Name `Olo Starter`, Description `500 messages a month, 10 analyses`.
   - **Review Information**: a screenshot of the Olo subscription sheet (any size over 640 x 920 is accepted; a Mac screenshot of the sheet works) and a note such as `Sign in with any email, open Olo > Subscribe, choose a plan.`
   - Save.
3. Repeat for the second product:
   - Reference Name `Olo Growth Monthly (Mac)`, Product ID `com.helius.olo.desktop.growth.monthly`, duration **1 month**, your price, Display Name `Olo Growth`, Description `5,000 messages a month, 100 analyses`, the same screenshot.
4. Back in the group, set the **Subscription level** order: Olo Growth above Olo Starter (level 1 is the higher service; it decides how upgrades and downgrades are handled).
5. Each product must show **Ready to Submit** (not "Missing Metadata") before the app version can be submitted.

### 5.2 Tell the server about the Mac app

helius-olo.io verifies App Store transactions with Apple and only accepts purchases made by apps whose bundle id it knows. olo-web v59 reads them from the `APPLE_BUNDLE_IDS` environment variable: add the Mac bundle id `io.helius-olo.desktop` to that list next to the iPhone app's (comma separated), redeploy, and check that `billing.applePurchasesAvailable` answers `{ available: true }`. Without this, a Mac purchase is charged by Apple but `billing.redeemApplePurchase` refuses it; the app keeps the transaction unfinished and offers Restore Purchases, so nothing is lost, but the person waits.

The server also needs the App Store Server API key and the shared secret for this app, which it already has for the iPhone app if both apps are under the same team; the key is per team, not per app.

### 5.3 Submit the subscriptions with the version

- The **first** subscription of an app must be submitted together with a new app version: on the version page (1.2.0) scroll to **In-App Purchases and Subscriptions**, press **+**, tick both products, then submit the version. After that, later changes to a subscription can be submitted on their own.
- App Review tests the purchase in the sandbox. Add to the **Notes for the reviewer**: `Olo > Subscribe opens the plans. Sign-in is required first because the plan is tied to the account (use any email; the code arrives within a minute). Payment goes through StoreKit; the server verifies the transaction with Apple. Restore Purchases is in the same sheet.`
- **EULA**: App Review needs either Apple's standard EULA or a custom one in the listing. The app links Apple's standard EULA (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) in the terms sheet and the subscription sheet; in App Store Connect > the app > **App Information** > **License Agreement**, leave "Apple's Standard License Agreement" selected unless Hashim's lawyer supplies a custom one, in which case paste it there and change `Legal.eulaURL` in `OloKit/Sources/OloKit/Legal.swift` to the page that hosts it.
- **Paid Apps agreement**: Agreements, Tax, and Banking must show the Paid Apps agreement as Active, with bank and tax forms done, or the products stay "Missing Metadata" whatever you do on the product pages.
- The listing's description may mention the plans but must carry the price only as "from" wording or not at all, because Apple shows the price per storefront.

### 5.4 Test before submitting

- In Xcode the Olo scheme uses `Olo/Olo.storekit` (local StoreKit testing: the two products with placeholder prices, no account needed). Run, press Olo > Subscribe, buy; the server will refuse the test transaction (it is not a real Apple transaction), which is expected locally: the sheet shows the plain words error and Restore Purchases.
- For a real end to end test use a **Sandbox tester** (App Store Connect > Users and Access > Sandbox) in a TestFlight build: sign in to the sandbox account in System Settings > App Store (macOS 15 shows a Sandbox Account section once an app has tried a purchase), buy Olo Starter, and check Settings > Account shows "Plan: Starter" and that helius-olo.io's billing dashboard shows the same.

## If something fails

- The workflow says **Missing secret**: add the one it names (step 2).
- **No signing certificate / profile doesn't match**: the profile must be the Mac App Store Connect kind for `io.helius-olo.desktop` and include the Apple Distribution certificate you exported.
- **Build number already used**: run the workflow again with a higher number in "Build number".
- **Guideline 4.2**: reply with the reviewer notes above; the Quick Ask panel, Services and offline answers are native features a website cannot offer.
- **Guideline 3.1.1 / 3.1.2**: the app sells only through StoreKit and never opens a web checkout; the subscription sheet carries the renewal sentence, the price from StoreKit, and links to the Terms, the Privacy Policy and the EULA. If the reviewer cannot buy, check that both products are Ready to Submit and were ticked on the version page (5.3).
