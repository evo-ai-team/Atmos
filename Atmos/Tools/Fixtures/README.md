# Speech fixtures

`atmos-command.wav` contains one synthetic speaker throughout. The macOS Daniel voice reads both segments at 150 words per minute, rendered as 22,050 Hz mono 16-bit PCM. The first segment says “Hey Atmos” and is padded to 1.32 seconds so the harness can insert a controlled pause. The second says “Go to Chrome, open up YouTube, and then search Linus Tech Tips. Go to his channel and click on his store link in his profile.” The file ends with one second of silence.

`live-transcript-events.json` records the Apple SpeechTranscriber output from local playback of this WAV at real-time speed with “Hey Atmos” supplied as recognition context. It includes both provisional and final text with their audio ranges.

The [parent guide](../README.md) describes the streaming integration harness.
