#!/usr/bin/env bash
# Archives Olo for the Mac App Store, signs it with your certificates and uploads
# it to App Store Connect. Run by .github/workflows/macos-app.yml (app_store ticked)
# on a GitHub Mac runner; every secret comes from the environment and lives only in
# a throwaway keychain that is deleted at the end.
set -euo pipefail

need() { for v in "$@"; do if [ -z "${!v:-}" ]; then echo "Missing secret: $v (see apps/macos/APP_STORE.md)"; exit 1; fi; done; }
need APPLE_TEAM_ID MAC_DIST_CERT_P12 MAC_INSTALLER_CERT_P12 MAC_CERT_PASSWORD MAC_PROVISIONING_PROFILE ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
KEYCHAIN="$WORK/olo-signing.keychain-db"
KC_PASS="$(uuidgen)"
cleanup() { security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# 1. A temporary keychain with the two certificates.
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
echo "$MAC_DIST_CERT_P12" | base64 --decode > "$WORK/dist.p12"
echo "$MAC_INSTALLER_CERT_P12" | base64 --decode > "$WORK/installer.p12"
security import "$WORK/dist.p12" -k "$KEYCHAIN" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/security
security import "$WORK/installer.p12" -k "$KEYCHAIN" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# 2. The provisioning profile, installed under its UUID.
echo "$MAC_PROVISIONING_PROFILE" | base64 --decode > "$WORK/profile.provisionprofile"
security cms -D -i "$WORK/profile.provisionprofile" > "$WORK/profile.plist"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$WORK/profile.plist")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print Name' "$WORK/profile.plist")"
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$WORK/profile.provisionprofile" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile"

# 3. The App Store Connect API key, for the upload.
echo "$ASC_KEY_P8" | base64 --decode > "$WORK/AuthKey.p8"

# 4. Archive with manual signing.
cd "$HERE"
xcodegen generate
xcodebuild -project Olo.xcodeproj -scheme Olo -configuration Release -archivePath "$WORK/Olo.xcarchive" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" archive | tail -n 40

# 5. Export for the App Store and upload in one step.
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>Mac Installer Distribution</string>
  <key>provisioningProfiles</key><dict><key>io.helius-olo.desktop</key><string>$PROFILE_NAME</string></dict>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$WORK/Olo.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/export" -authenticationKeyPath "$WORK/AuthKey.p8" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" | tail -n 40

echo "Uploaded build ${BUILD_NUMBER:-1}. It appears in App Store Connect > Olo > TestFlight after Apple processes it (usually 10 to 30 minutes)."
