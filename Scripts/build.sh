#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
mouseBuildDir="$(mouse_output_directory "${MOUSE_BUILD_DIR:-}" "mouse-build")"

mouseOutputApp="${1:-$mouseProjectDir/../Mouse.app}"
if [[ $# -gt 1 || "$mouseOutputApp" != *.app ]]; then
    printf 'Usage: %s [path/to/Mouse.app]\n' "$0" >&2
    exit 1
fi
mkdir -p "$(dirname "$mouseOutputApp")"
mouseOutputApp="$(cd "$(dirname "$mouseOutputApp")" && pwd)/$(basename "$mouseOutputApp")"

/usr/bin/xcodebuild -quiet \
    -project "$mouseProjectDir/Mouse.xcodeproj" \
    -scheme Mouse \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -derivedDataPath "$mouseBuildDir" \
    build

mouseBuiltApp="$mouseBuildDir/Build/Products/Release/Mouse.app"
if [[ ! -d "$mouseBuiltApp" ]]; then
    printf 'Build finished without the expected Mouse.app.\n' >&2
    exit 1
fi
if [[ "$mouseBuiltApp" != "$mouseOutputApp" ]]; then
    /usr/bin/ditto "$mouseBuiltApp" "$mouseOutputApp"
fi
/usr/bin/codesign --verify --strict "$mouseOutputApp"
printf 'Built local demo: %s\n' "$mouseOutputApp"
