#!/bin/bash
# Shared by the build, test, and transcript-check entry points. Source this file;
# it only selects tools and paths, and never changes the global xcode-select setting.

atmosProjectDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
atmosWorkspaceDir="$(cd "$atmosProjectDir/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    atmosSelectedDeveloper="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [[ "$atmosSelectedDeveloper" == *.app/Contents/Developer && -x "$atmosSelectedDeveloper/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$atmosSelectedDeveloper"
    else
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    printf 'Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
    exit 1
fi

# An explicit destination wins. A workspace work/ directory is optional; otherwise
# keep generated files in a unique temporary directory, outside the source tree.
atmos_output_directory() {
    local requested="$1"
    local name="$2"
    local directory
    if [[ -n "$requested" ]]; then
        directory="$requested"
    elif [[ -d "$atmosWorkspaceDir/work" ]]; then
        directory="$atmosWorkspaceDir/work/$name"
    else
        directory="$(mktemp -d "${TMPDIR:-/tmp}/$name.XXXXXX")"
    fi
    mkdir -p "$directory"
    (cd "$directory" && pwd)
}
