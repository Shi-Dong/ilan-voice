#!/usr/bin/env bash
# Builds "Ilan Voice.app" into dist/ (Apple Silicon only).
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Ilan Voice.app"
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
# The in-app updater compares this against the newest commit on GitHub.
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date +%Y-%m-%d)"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/IlanVoice"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/IlanVoice"

# App icon from the shared Ilan artwork.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/icon-512.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/icon-512.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ilan Voice</string>
    <key>CFBundleDisplayName</key><string>Ilan Voice</string>
    <key>CFBundleIdentifier</key><string>me.dongshi.ilan-voice</string>
    <key>CFBundleExecutable</key><string>IlanVoice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>IlanVoiceCommit</key><string>${COMMIT}</string>
    <key>IlanVoiceBuildDate</key><string>${BUILD_DATE}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Ilan Voice records your voice while you hold the talk key.</string>
</dict>
</plist>
PLIST

# Sign with a per-Mac self-signed certificate rather than ad hoc. macOS ties
# the Accessibility and Microphone permissions to the signing identity; an ad
# hoc signature changes on every build, so each update silently lost them.
# The certificate lives in its own keychain (created on first build, no
# password prompts) and never leaves this Mac.
SIGN_DIR="$HOME/Library/Application Support/Ilan Voice/signing"
KEYCHAIN="$SIGN_DIR/ilan-voice-signing.keychain-db"
KEYCHAIN_PASS="ilan-voice-local"
IDENTITY="Ilan Voice Local Signing"
if [[ ! -f "$KEYCHAIN" ]]; then
    mkdir -p "$SIGN_DIR"
    TMP="$(mktemp -d)"
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:ilan 2>/dev/null \
        || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout pass:ilan
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # never auto-lock
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P ilan -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
    rm -rf "$TMP"
    echo "Created signing certificate \"$IDENTITY\" in $KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier me.dongshi.ilan-voice "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Ilan Voice.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Ilan Voice.app"
fi
