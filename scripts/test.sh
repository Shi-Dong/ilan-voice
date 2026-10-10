#!/bin/bash
# Runs the unit tests (well under 15 s):
#   scripts/test.sh
# The Command Line Tools have neither XCTest nor Swift Testing's macro plugin,
# so the app's sources are compiled into a testable library and the tests in
# Tests/IlanVoiceTests are linked into a plain executable that runs them.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=".build/unit-tests"
mkdir -p "$OUT"
TARGET="arm64-apple-macos14.0"
JOBS="$(sysctl -n hw.ncpu)"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/IlanVoice -name '*.swift' | sort)
TESTS=()
while IFS= read -r f; do TESTS+=("$f"); done < <(find Tests/IlanVoiceTests -name '*.swift' | sort)

swiftc -j "$JOBS" -Onone -enable-testing -parse-as-library -target "$TARGET" \
    -module-name IlanVoice -emit-library -emit-module -emit-module-path "$OUT/IlanVoice.swiftmodule" \
    -o "$OUT/libIlanVoice.dylib" "${SOURCES[@]}" 2>"$OUT/build.log" \
    || { grep -E "error" "$OUT/build.log"; exit 1; }

swiftc -j "$JOBS" -Onone -target "$TARGET" -I "$OUT" -L "$OUT" -lIlanVoice \
    -Xlinker -rpath -Xlinker "@executable_path" \
    -o "$OUT/run-tests" "${TESTS[@]}" 2>"$OUT/tests-build.log" \
    || { grep -E "error" "$OUT/tests-build.log"; exit 1; }

# A throwaway home folder: the app's data folder, secrets file and so on are
# created there instead of in the real ~/Library/Application Support.
HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ilan-voice-tests.XXXXXX")"
trap 'rm -rf "$HOME_DIR"' EXIT
CFFIXED_USER_HOME="$HOME_DIR" "$OUT/run-tests"
