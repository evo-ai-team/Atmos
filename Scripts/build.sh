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
    printf 'Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

if [[ -n "${CHOSEN_BUILD_DIR:-}" ]]; then
    chosenBuildDir="$CHOSEN_BUILD_DIR"
elif [[ -d "$chosenWorkspaceDir/work" ]]; then
    chosenBuildDir="$chosenWorkspaceDir/work/chosen-build"
else
    chosenBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/chosen-build.XXXXXX")"
fi
mkdir -p "$chosenBuildDir"
chosenBuildDir="$(cd "$chosenBuildDir" && pwd)"

chosenOutputApp="${1:-$chosenProjectDir/../Chosen.app}"
if [[ $# -gt 1 || "$chosenOutputApp" != *.app ]]; then
    printf 'Usage: %s [path/to/Chosen.app]\n' "$0" >&2
    exit 1
fi
mkdir -p "$(dirname "$chosenOutputApp")"
chosenOutputApp="$(cd "$(dirname "$chosenOutputApp")" && pwd)/$(basename "$chosenOutputApp")"

/usr/bin/xcodebuild -quiet \
    -project "$chosenProjectDir/Chosen.xcodeproj" \
    -scheme Chosen \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -derivedDataPath "$chosenBuildDir" \
    build

chosenBuiltApp="$chosenBuildDir/Build/Products/Release/Chosen.app"
if [[ ! -d "$chosenBuiltApp" ]]; then
    printf 'Build finished without the expected Chosen.app.\n' >&2
    exit 1
fi
if [[ "$chosenBuiltApp" != "$chosenOutputApp" ]]; then
    /usr/bin/ditto "$chosenBuiltApp" "$chosenOutputApp"
fi
/usr/bin/codesign --verify --strict "$chosenOutputApp"
printf 'Built local demo: %s\n' "$chosenOutputApp"
