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

# Prints the SHA-1 of the signing identity in our keychain, or nothing.
# (awk reads all its input on purpose: exiting early would SIGPIPE `security`
# and trip pipefail.)
identity_hash() {
    [[ -f "$KEYCHAIN" ]] || return 0
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || return 0
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$IDENTITY\"" 'index($0, name) && h == "" { h = $2 } END { if (h != "") print h }'
}

create_identity() {
    # Start clean: a keychain left over from an interrupted run may be empty.
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
    mkdir -p "$SIGN_DIR"
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<CNF
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
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    # OpenSSL 3 needs -legacy for a .p12 that `security import` accepts;
    # macOS's own LibreSSL writes that format by default.
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/id.p12" -passout pass:ilan 2>/dev/null \
        || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -out "$tmp/id.p12" -passout pass:ilan
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # never auto-lock
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P ilan -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    echo "Created signing certificate \"$IDENTITY\" in $KEYCHAIN"
}

ORIG_KEYCHAINS=()
restore_keychains() {
    security list-keychains -d user -s ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"}
}

# codesign only finds identities in keychains on the user search list
# (--keychain alone is not enough on macOS 26), so ours is added for the
# signing step and the user's original list is put back afterwards.
sign_with_identity() {
    local kc listed=false status=0
    ORIG_KEYCHAINS=()
    while IFS= read -r kc; do
        kc="${kc#"${kc%%[![:space:]]*}"}"; kc="${kc#\"}"; kc="${kc%\"}"
        [[ -n "$kc" ]] || continue
        ORIG_KEYCHAINS+=("$kc")
        [[ "$kc" == "$KEYCHAIN" ]] && listed=true
    done < <(security list-keychains -d user)
    if [[ "$listed" == false ]]; then
        trap restore_keychains EXIT
        security list-keychains -d user -s ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"} "$KEYCHAIN"
    fi
    codesign --force --sign "$HASH" --keychain "$KEYCHAIN" \
        --identifier me.dongshi.ilan-voice "$APP" || status=$?
    if [[ "$listed" == false ]]; then
        restore_keychains
        trap - EXIT
    fi
    return $status
}

HASH="$(identity_hash)"
if [[ -z "$HASH" ]]; then
    create_identity || true
    HASH="$(identity_hash)"
fi

# Never let signing block an update: fall back to an ad hoc signature (the app
# works, but macOS will ask for Accessibility again after this build).
if [[ -n "$HASH" ]] && sign_with_identity; then
    echo "Signed with \"$IDENTITY\" ($HASH)"
else
    echo "warning: could not sign with \"$IDENTITY\"; falling back to an ad hoc signature" >&2
    codesign --force --sign - --identifier me.dongshi.ilan-voice "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Ilan Voice.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Ilan Voice.app"
fi
