#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
atmosTestBuildDir="$(atmos_output_directory "${ATMOS_TEST_BUILD_DIR:-}" "atmos-tests")"

exec /usr/bin/xcrun swift test \
    --package-path "$atmosProjectDir" \
    --scratch-path "$atmosTestBuildDir" \
    "$@"
