#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
mouseTestBuildDir="$(mouse_output_directory "${MOUSE_TEST_BUILD_DIR:-}" "mouse-tests")"

exec /usr/bin/xcrun swift test \
    --package-path "$mouseProjectDir" \
    --scratch-path "$mouseTestBuildDir" \
    "$@"
