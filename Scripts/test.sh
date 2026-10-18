#!/bin/bash
set -euo pipefail

chosenProjectDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chosenWorkspaceDir="$(cd "$chosenProjectDir/../.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    chosenSelectedDeveloper="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [[ "$chosenSelectedDeveloper" == *.app/Contents/Developer && -x "$chosenSelectedDeveloper/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$chosenSelectedDeveloper"
    else
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    printf 'Full Xcode is required for XCTest. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

if [[ -n "${CHOSEN_TEST_BUILD_DIR:-}" ]]; then
    chosenTestBuildDir="$CHOSEN_TEST_BUILD_DIR"
elif [[ -d "$chosenWorkspaceDir/work" ]]; then
    chosenTestBuildDir="$chosenWorkspaceDir/work/chosen-tests"
else
    chosenTestBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/chosen-tests.XXXXXX")"
fi

exec /usr/bin/xcrun swift test \
    --package-path "$chosenProjectDir" \
    --scratch-path "$chosenTestBuildDir" \
    "$@"
