# Development tools

`LiveTranscriptCheck.swift` is an opt-in streaming integration harness. It feeds synthetic file audio through production speech helpers, watches Apple transcription events, and writes a timing/result report. It does not open a microphone, call a model API, or execute desktop actions.

Run `./Scripts/check-live-transcript.sh` from the project root. The script compiles the harness with the production speech and core files. Supported options include `--gaps`, `--output`, and `--without-boundary-sync` (an intentionally impaired diagnostic comparison). Real speech assets and supported macOS/Xcode are required.

[Fixtures](Fixtures/README.md) are source inputs and should stay versioned; compiled tools and reports belong in the script's scratch directory. Offline tests live in [Tests](../Tests/README.md).
