#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
mouseCheckDir="$(mouse_output_directory "${MOUSE_TRANSCRIPT_CHECK_DIR:-}" "live-transcript-check")"

# SwiftPM/Xcode discover domain directories recursively. The standalone check
# does the same, with a null-delimited array so paths containing spaces are safe.
mouseCheckSources=()
while IFS= read -r -d '' sourceFile; do
    mouseCheckSources+=("$sourceFile")
done < <(/usr/bin/find "$mouseProjectDir/Sources/MouseCore" "$mouseProjectDir/Sources/Mouse/Speech" -type f -name '*.swift' -print0)

/usr/bin/xcrun swiftc -parse-as-library -O \
    -o "$mouseCheckDir/live-transcript-check" \
    "$mouseProjectDir/Tools/LiveTranscriptCheck.swift" \
    "${mouseCheckSources[@]}"

exec "$mouseCheckDir/live-transcript-check" \
    --fixtures "$mouseProjectDir/Tools/Fixtures" \
    --output "$mouseCheckDir/results.json" \
    "$@"
