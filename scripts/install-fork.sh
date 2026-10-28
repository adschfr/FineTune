#!/bin/bash
set -euo pipefail

# Builds the fork and installs it as "/Applications/FineTune Fork.app", replacing a
# previous fork install.
#
# Signing: with a valid "Apple Development" identity in the keychain (a free Personal
# Team in Xcode is enough) the app is signed with it. Its designated requirement then
# names the certificate instead of the build's hash, so macOS keeps the audio-capture
# and Accessibility permissions across builds. Without one it falls back to an ad-hoc
# signature, and those permissions have to be granted again after every build.
#
# Hardened runtime stays off: an ad-hoc signature has no Team ID, so library
# validation would reject the embedded Sparkle.framework at launch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="FineTune Fork"
DEST="/Applications/$APP_NAME.app"

# xcode-select may point at the Command Line Tools
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

# The Team ID is read from the certificate, so it never has to be stored in the repository
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    TEAM_ID="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
    if [ -n "$TEAM_ID" ]; then
        SIGNING=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID")
        echo "==> Signing with the Apple Development certificate (team $TEAM_ID)"
    fi
fi
if [ "${SIGNING[0]}" = "CODE_SIGN_IDENTITY=-" ]; then
    echo "==> No valid Apple Development certificate, signing ad hoc (permissions must be granted again)"
fi

echo "==> Building $APP_NAME (build $BUILD_NUMBER, $COMMIT)..."
xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
    -scheme FineTune \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    "${SIGNING[@]}" \
    ENABLE_HARDENED_RUNTIME=NO \
    MARKETING_VERSION="1.9.0-fork" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$BUILD_DIR/install-fork.log" 2>&1 || {
        grep -E "error:" "$BUILD_DIR/install-fork.log" | head -20
        echo "Build failed, full log: $BUILD_DIR/install-fork.log"
        exit 1
    }

echo "==> Quitting running fork..."
osascript -e 'tell application id "com.adschfr.FineTuneFork" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do
    pgrep -f "$DEST/Contents/MacOS/FineTune" >/dev/null || break
    sleep 0.25
done

echo "==> Installing to $DEST..."
rm -rf "$DEST"
ditto "$BUILD_DIR/Build/Products/Release/FineTune.app" "$DEST"

echo "==> Launching..."
open "$DEST"
echo "Done: $APP_NAME 1.9.0-fork ($BUILD_NUMBER, $COMMIT)"
