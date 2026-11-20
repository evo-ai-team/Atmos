#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
atmosCheckDir="$(atmos_output_directory "${ATMOS_TRANSCRIPT_CHECK_DIR:-}" "live-transcript-check")"

# SwiftPM/Xcode discover domain directories recursively. The standalone check
# does the same, with a null-delimited array so paths containing spaces are safe.
atmosCheckSources=()
while IFS= read -r -d '' sourceFile; do
    atmosCheckSources+=("$sourceFile")
done < <(/usr/bin/find "$atmosProjectDir/Sources/AtmosCore" "$atmosProjectDir/Sources/Atmos/Speech" -type f -name '*.swift' -print0)

/usr/bin/xcrun swiftc -parse-as-library -O \
    -o "$atmosCheckDir/live-transcript-check" \
    "$atmosProjectDir/Tools/LiveTranscriptCheck.swift" \
    "${atmosCheckSources[@]}"

exec "$atmosCheckDir/live-transcript-check" \
    --fixtures "$atmosProjectDir/Tools/Fixtures" \
    --output "$atmosCheckDir/results.json" \
    "$@"
