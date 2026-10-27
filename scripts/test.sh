#!/bin/bash
set -uo pipefail

# Runs the unit tests (FineTuneTests) the way the fork is built: ad-hoc signed,
# hardened runtime off. Uses its own DerivedData so it never touches the Release
# build of install-fork.sh. Extra arguments go to xcodebuild, e.g.
#   ./scripts/test.sh -only-testing:FineTuneTests/SettingsManagerTests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
TEST_DIR="$BUILD_DIR/test"
RESULT="$TEST_DIR/TestResults.xcresult"
LOG="$TEST_DIR/test.log"

# xcode-select may point at the Command Line Tools
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$TEST_DIR"
rm -rf "$RESULT"

# Default to the whole unit test bundle unless the caller picked tests.
SELECTION=(-only-testing:FineTuneTests)
for arg in "$@"; do
    case "$arg" in -only-testing:*) SELECTION=() ;; esac
done

echo "==> Testing (log: $LOG)..."
xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
    -scheme FineTune \
    -destination 'platform=macOS' \
    -derivedDataPath "$TEST_DIR" \
    -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
    -resultBundlePath "$RESULT" \
    ${SELECTION[@]+"${SELECTION[@]}"} \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    "$@" \
    test > "$LOG" 2>&1
STATUS=$?

grep -E ": (warning|error):" "$LOG" | sed "s#$PROJECT_DIR/##" | sort -u

SUMMARY="$TEST_DIR/summary.json"
if xcrun xcresulttool get test-results summary --path "$RESULT" > "$SUMMARY" 2>/dev/null; then
    field() { plutil -extract "$1" raw -o - "$SUMMARY" 2>/dev/null; }
    echo "==> $(field result): $(field passedTests) passed, $(field failedTests) failed, $(field skippedTests) skipped, $(field expectedFailures) known issues of $(field totalTestCount)"
    if [ $STATUS -eq 0 ] && [ "$(field totalTestCount)" = "0" ]; then
        echo "No tests matched the selection."
        STATUS=1
    fi
fi

if [ $STATUS -ne 0 ]; then
    grep -E "failed on|recorded an issue" "$LOG" | head -30
    echo "Tests failed, full log: $LOG"
fi
exit $STATUS
