#!/bin/bash
set -euo pipefail

# Builds the fork with an ad-hoc signature and installs it as
# "/Applications/FineTune Fork.app", replacing a previous fork install.
#
# Hardened runtime is off: an ad-hoc signature has no Team ID, so library
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

echo "==> Building $APP_NAME (build $BUILD_NUMBER, $COMMIT)..."
xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
    -scheme FineTune \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
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
