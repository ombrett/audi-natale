#!/bin/bash
# Firma opzionale dell'archivio con certificato e profilo forniti come secret GitHub.
# Secret richiesti: BUILD_CERTIFICATE_BASE64 (.p12 in base64), P12_PASSWORD,
# BUILD_PROVISION_PROFILE_BASE64 (.mobileprovision in base64), KEYCHAIN_PASSWORD, TEAM_ID.
# Facoltativo: EXPORT_METHOD (default "development"; per Xcode 15.4+ anche "debugging").
set -euo pipefail

: "${BUILD_CERTIFICATE_BASE64:?}" "${BUILD_PROVISION_PROFILE_BASE64:?}" "${TEAM_ID:?}"
P12_PASSWORD="${P12_PASSWORD:-}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-ci-temp-keychain}"
EXPORT_METHOD="${EXPORT_METHOD:-development}"

WORK="$RUNNER_TEMP/signing"
mkdir -p "$WORK"
CERT="$WORK/cert.p12"
PROFILE="$WORK/profile.mobileprovision"
KEYCHAIN="$WORK/build.keychain-db"

echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$CERT"
echo -n "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$PROFILE"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychain -d user -s "$KEYCHAIN"

PROFILE_PLIST="$WORK/profile.plist"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" "$PROFILE_PLIST")
NAME=$(/usr/libexec/PlistBuddy -c "Print Name" "$PROFILE_PLIST")
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/$UUID.mobileprovision"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:application-identifier" "$PROFILE_PLIST" | sed "s/^$TEAM_ID\.//")
echo "Profilo: $NAME ($UUID) per $BUNDLE_ID"

xcodebuild -project AudiLightStudio.xcodeproj -scheme AudiLightStudio -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/build/Signed.xcarchive" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER="$UUID" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  archive | tee ci-out/signed-build.log

cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>$UUID</string></dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$PWD/build/Signed.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$PWD/build/export" | tee ci-out/export.log
cp build/export/*.ipa AudiLightStudio-signed.ipa
security delete-keychain "$KEYCHAIN" || true
echo "IPA firmato: AudiLightStudio-signed.ipa"
