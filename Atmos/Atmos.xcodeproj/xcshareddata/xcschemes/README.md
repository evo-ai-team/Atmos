# Shared scheme

`Atmos.xcscheme` identifies the Atmos app target for build, run, profile, analyze, and archive actions. `Scripts/build.sh` selects this scheme explicitly.

Offline XCTest runs through `Scripts/test.sh` and the Swift package test target. Keep the scheme's target identifiers aligned with `project.pbxproj` when changing build configuration.
