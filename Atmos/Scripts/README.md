# Build and development scripts

Run these scripts from any working directory; each resolves the project relative to its own location.

| Entry point | Purpose | Output override |
|---|---|---|
| `build.sh [path/to/Atmos.app]` | Build an Apple-silicon Release app and verify its ad-hoc signature. Default app: sibling `../Atmos.app`. | `ATMOS_BUILD_DIR` |
| `test.sh [swift test arguments]` | Run the offline XCTest suite. | `ATMOS_TEST_BUILD_DIR` |
| `check-live-transcript.sh [options]` | Compile and run the opt-in Apple streaming transcription check against bundled fixtures. | `ATMOS_TRANSCRIPT_CHECK_DIR` |
| `MakeIcon.swift [iconset directory] [destination .icns]` | Regenerate the icon with AppKit drawing and `iconutil`. Default destination: `Resources/Atmos.icns`. | Positional arguments |

`environment.sh` is a sourced helper shared by the shell entry points. It respects `DEVELOPER_DIR`, otherwise uses selected full Xcode or `/Applications/Xcode.app`, without changing global tool selection. An explicit output override wins; otherwise an existing workspace `work/` is used, or a unique temporary directory when that folder is absent. Icon intermediates default to a temporary directory.

The standalone transcript compiler discovers Swift files recursively, matching the domain layout used by SwiftPM and Xcode. Keep generated binaries/reports outside the source tree. The transcript check uses real local speech assets; the API check documented in the master README is separate and may incur charges.
