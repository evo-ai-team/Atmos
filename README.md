# Chosen

A native Mac demo that turns spoken or typed commands into clicks, typing, and scrolling. The interface embeds SwiftUI content in macOS 26's native `NSGlassEffectView`, with a transparent window backing and system glass controls. Computer control uses OpenAI Responses with GPT-6 Luna, Fast service, and low reasoning.

Requires an Apple silicon Mac running macOS 26 or later, full Xcode 27 to build, and an OpenAI API key with access to the model and computer tool. The local build environment uses Xcode 27.1. Voice mode requires on-device English (US) speech recognition.

## Build and open

From this folder:

```sh
./Scripts/build.sh
open ../Chosen.app
```

The default destination is `../Chosen.app`—the `Chosen.app` alongside this source folder. To choose another destination, pass its path:

```sh
./Scripts/build.sh /path/to/Chosen.app
```

The scripts respect `DEVELOPER_DIR`, otherwise use the selected full Xcode or fall back to `/Applications/Xcode.app`. They do not change global `xcode-select` settings. Build products go into the workspace’s `work/` folder when available, otherwise a temporary directory. Set `CHOSEN_BUILD_DIR` to choose a derived-data directory.

## First use

1. Open **Settings** using the sliders button. Enter your API key in the secure field and select **Save key**. The key is stored in macOS Keychain, not a configuration file.
2. Select **Allow** for **See your screen** and **Click and type**. Enable Chosen under **System Settings → Privacy & Security → Screen Recording** (or **Screen & System Audio Recording**) and **Accessibility**. Quit and reopen Chosen if macOS asks.
3. For voice control, select **Enable Hey Chosen** and grant **Microphone** and **Speech Recognition** access. If local recognition is unavailable, enable English dictation in System Settings or use typed commands.

Type a command such as “Open Chrome” and press Return. Chosen restores the previously active app, hides its control window while acting, then brings the window back with the result. Its screenshot capture excludes Chosen’s own windows. On multiple displays, start with the pointer on the display you want to control; a command remains on that display.

Say **“Hey Chosen, open Chrome”** to start a voice command. Follow-up commands work without the wake phrase during a 20-second session; the follow-up window starts again after an action finishes. **Listen Now** starts a session directly. Say **“stop”** or **“cancel”** while voice is enabled, or use **Stop Current Action** in the menu bar. Stopping cancels queued actions; it does not undo earlier clicks or typing. **Pause listening** turns the microphone off. Launch at login is optional in Settings.

Voice uses Apple’s on-device `SFSpeechRecognizer` with local recognition required. It continuously recognizes speech while listening is enabled; it is not a dedicated low-power wake-word engine. No model requests run while idle. Commands and screenshots are sent to OpenAI only while a command is running; microphone audio is not sent to OpenAI. A screenshot can include other visible apps on the selected display.

## Usage counter and checks

Chosen has **no cumulative request limit**. Its test counter persists request totals and input and output token totals across launches in `~/Library/Application Support/Chosen/usage.json`, and displays an estimated cost. Requests are counted before networking, including failed and cancelled attempts. Token totals reflect usage returned by the API; the cost estimate uses those recorded tokens. Your OpenAI project controls actual billing and provider limits.

Accounting read or write failures do not block requests. If history cannot be loaded, counting starts from zero; if it cannot be saved, totals continue in memory for the current run.

Each command retains an **8-model-turn execution guard** to prevent endless action loops. This guard applies separately to each command and does not limit cumulative API usage. Model requests time out after 30 seconds and are not automatically retried. Pending model safety checks pause execution before the requested actions.

Run the offline tests with full Xcode’s toolchain:

```sh
./Scripts/test.sh
./Scripts/test.sh --filter OpenAIClientTests
```

Tests cover request formatting, action parsing, incomplete/refused responses, cancellation, persistent usage counting beyond 100 requests, coordinate mapping, and wake-session behavior. They use no API credentials or live requests. `CHOSEN_TEST_BUILD_DIR` can override the test build directory. A successful build or offline suite does not verify microphone quality, macOS permissions, model access, or end-to-end computer control; check those in the app on your Mac.

For a key import without putting the secret in shell history, Settings is preferred. The executable also accepts a key on standard input. In macOS’s default zsh:

```zsh
read -r -s 'chosenApiKey?OpenAI API key: '
printf '\n'
printf '%s' "$chosenApiKey" | ../Chosen.app/Contents/MacOS/Chosen --import-key
unset chosenApiKey
```

`../Chosen.app/Contents/MacOS/Chosen --diagnostics` reports whether a key and desktop permissions are configured without printing the key.

For an opt-in live API check, run `../Chosen.app/Contents/MacOS/Chosen --api-check`. This uses the Keychain key, makes up to three billable requests added to the usage counter, and checks the model’s returned click against a generated test image. Screenshot-only turns receive the same fixture. It does not capture your desktop or execute desktop events. It verifies the API connection and action response, not end-to-end Mac control.

The check also accepts `--key-stdin` to read the key from standard input instead of Keychain. Never put a key in command arguments. Quit the GUI before running a CLI API check so the two processes do not update the usage counter simultaneously.

For a local speech diagnostic, create an audio file saying “Hey Chosen, open Chrome.” and pass it to `Chosen --voice-check /path/to/audio.aiff`. The check requires existing Speech authorization, uses on-device recognition, and validates that the wake phrase produces one `open Chrome` command. It does not execute that command. CLI permission attribution can differ from a normal app launch; the app’s Enable Hey Chosen control is the authoritative microphone check.

This build is ad-hoc signed for local demonstration. Rebuilding changes its signature and can require granting macOS permissions again. It is not Developer ID signed or notarized for customer distribution. A release for other users needs its own signing, notarization, and testing.
