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

## If something fails

- The workflow says **Missing secret**: add the one it names (step 2).
- **No signing certificate / profile doesn't match**: the profile must be the Mac App Store Connect kind for `io.helius-olo.desktop` and include the Apple Distribution certificate you exported.
- **Build number already used**: run the workflow again with a higher number in "Build number".
- **Guideline 4.2**: reply with the reviewer notes above; the Quick Ask panel, Services and offline answers are native features a website cannot offer.
