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
    printf 'Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

if [[ -n "${MOUSE_TRANSCRIPT_CHECK_DIR:-}" ]]; then
    mouseCheckDir="$MOUSE_TRANSCRIPT_CHECK_DIR"
elif [[ -d "$mouseWorkspaceDir/work" ]]; then
    mouseCheckDir="$mouseWorkspaceDir/work/live-transcript-check"
else
    mouseCheckDir="$(mktemp -d "${TMPDIR:-/tmp}/mouse-live-transcript.XXXXXX")"
fi
mkdir -p "$mouseCheckDir"

/usr/bin/xcrun swiftc -parse-as-library -O \
    -o "$mouseCheckDir/live-transcript-check" \
    "$mouseProjectDir/Tools/LiveTranscriptCheck.swift" \
    "$mouseProjectDir/Sources/Mouse/SpeechAudioFeed.swift" \
    "$mouseProjectDir/Sources/Mouse/SpeechRuntimeSetup.swift" \
    "$mouseProjectDir"/Sources/MouseCore/*.swift

exec "$mouseCheckDir/live-transcript-check" \
    --fixtures "$mouseProjectDir/Tools/Fixtures" \
    --output "$mouseCheckDir/results.json" \
    "$@"
