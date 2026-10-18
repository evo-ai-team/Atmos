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

if [[ -n "${MOUSE_BUILD_DIR:-}" ]]; then
    mouseBuildDir="$MOUSE_BUILD_DIR"
elif [[ -d "$mouseWorkspaceDir/work" ]]; then
    mouseBuildDir="$mouseWorkspaceDir/work/mouse-build"
else
    mouseBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/mouse-build.XXXXXX")"
fi
mkdir -p "$mouseBuildDir"
mouseBuildDir="$(cd "$mouseBuildDir" && pwd)"

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
