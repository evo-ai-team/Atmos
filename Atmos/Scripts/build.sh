#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
atmosBuildDir="$(atmos_output_directory "${ATMOS_BUILD_DIR:-}" "atmos-build")"

atmosOutputApp="${1:-$atmosProjectDir/../Atmos.app}"
if [[ $# -gt 1 || "$atmosOutputApp" != *.app ]]; then
    printf 'Usage: %s [path/to/Atmos.app]\n' "$0" >&2
    exit 1
fi
mkdir -p "$(dirname "$atmosOutputApp")"
atmosOutputApp="$(cd "$(dirname "$atmosOutputApp")" && pwd)/$(basename "$atmosOutputApp")"

/usr/bin/xcodebuild -quiet \
    -project "$atmosProjectDir/Atmos.xcodeproj" \
    -scheme Atmos \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -derivedDataPath "$atmosBuildDir" \
    build

atmosBuiltApp="$atmosBuildDir/Build/Products/Release/Atmos.app"
if [[ ! -d "$atmosBuiltApp" ]]; then
    printf 'Build finished without the expected Atmos.app.\n' >&2
    exit 1
fi
if [[ "$atmosBuiltApp" != "$atmosOutputApp" ]]; then
    /usr/bin/ditto "$atmosBuiltApp" "$atmosOutputApp"
fi
/usr/bin/codesign --verify --strict "$atmosOutputApp"
printf 'Built local demo: %s\n' "$atmosOutputApp"
