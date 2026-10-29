#!/bin/bash
set -euo pipefail

# Builds a universal Release of the fork and packs it into build/release/FineTune-Fork.dmg
# for a GitHub release. Usage: ./scripts/package-fork.sh <version>, e.g. 1.9.0-fork.1
#
# Signing: always ad hoc. A personal "Apple Development" certificate names its owner,
# often by email address, and would publish that name with every download. The app is
# not notarized either, so macOS asks the user to allow it once (see README.md).
# Hardened runtime stays off for the same reason as in install-fork.sh.

VERSION="${1:?usage: $0 <version>, e.g. 1.9.0-fork.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DIR="$PROJECT_DIR/build/release-derived"
OUT_DIR="$PROJECT_DIR/build/release"
APP_NAME="FineTune Fork"
DMG="$OUT_DIR/FineTune-Fork.dmg"

# xcode-select may point at the Command Line Tools
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted changes in tracked files; a release must match a commit." >&2
    exit 1
fi

BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

echo "==> Building $APP_NAME $VERSION (build $BUILD_NUMBER, $COMMIT), universal, ad hoc..."
xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
    -scheme FineTune \
    -configuration Release \
    -derivedDataPath "$DERIVED_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$OUT_DIR.log" 2>&1 || {
        grep -E "error:" "$OUT_DIR.log" | head -20
        echo "Build failed, full log: $OUT_DIR.log"
        exit 1
    }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DERIVED_DIR/Build/Products/Release/FineTune.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Checking the signature..."
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"
if codesign -dvv "$STAGE/$APP_NAME.app" 2>&1 | grep -q '^Authority='; then
    echo "The app carries a certificate signature; expected ad hoc." >&2
    exit 1
fi

echo "==> Creating $DMG..."
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null

echo "Done: $DMG"
echo "Architectures: $(lipo -archs "$STAGE/$APP_NAME.app/Contents/MacOS/FineTune")"
shasum -a 256 "$DMG"
