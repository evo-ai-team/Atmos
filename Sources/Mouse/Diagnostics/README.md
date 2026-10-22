# Opt-in diagnostics

`MouseApp` routes explicit command-line check flags to these entry points before starting the normal UI.

- `APICheck` checks model request/response handling with generated images. It uses the saved API key and can incur API charges; it does not operate the desktop.
- `MicrophoneCheck` runs a finite production-input check and reports signal/preview counts without saving recognized text or audio.
- `VoiceFileCheck` runs local Apple transcription on a supplied audio file.

These checks are not part of normal startup or the offline test suite. See the master [README](../../../README.md#verification) for invocation and permission requirements. The separate streaming integration harness lives in [Tools](../../../Tools/README.md).

The removable [Benchmark](Benchmark/README.md) directory supports the regular app's Settings toggle for bounded live trials and local exports. It uses normal commands and model routes; `TESTING` markers and its README explain removal.
