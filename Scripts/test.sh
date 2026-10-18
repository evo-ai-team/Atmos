#!/bin/bash
set -euo pipefail

mouseProjectDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mouseWorkspaceDir="$(cd "$mouseProjectDir/../.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    mouseSelectedDeveloper="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [[ "$mouseSelectedDeveloper" == *.app/Contents/Developer && -x "$mouseSelectedDeveloper/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$mouseSelectedDeveloper"
    else
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    printf 'Full Xcode is required for XCTest. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

if [[ -n "${MOUSE_TEST_BUILD_DIR:-}" ]]; then
    mouseTestBuildDir="$MOUSE_TEST_BUILD_DIR"
elif [[ -d "$mouseWorkspaceDir/work" ]]; then
    mouseTestBuildDir="$mouseWorkspaceDir/work/mouse-tests"
else
    mouseTestBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/mouse-tests.XXXXXX")"
fi

exec /usr/bin/xcrun swift test \
    --package-path "$mouseProjectDir" \
    --scratch-path "$mouseTestBuildDir" \
    "$@"
