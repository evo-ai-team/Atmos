# Native application

This target connects the testable core to macOS. Start with [Application](Application/README.md) for the app lifecycle and accepted-command loop.

| Directory | Responsibility |
|---|---|
| [Application](Application/README.md) | Startup, task coordination, observations, and usage persistence. |
| [Interface](Interface/README.md) | Menu bar, Settings, notch presentation, and animation. |
| [Speech](Speech/README.md) | Microphone capture, Apple transcription, replay, and recovery. |
| [ComputerControl](ComputerControl/README.md) | Screenshots, accessibility reads/actions, and native input. |
| [Security](Security/README.md) | API-key storage and explicit Keychain authorization. |
| [Diagnostics](Diagnostics/README.md) | Opt-in API, microphone, and audio-file checks. |

UI and command coordination use the main actor. Accessibility reads use a separate actor so another application's slow AX server cannot block the interface or microphone. Native adapters validate again at dispatch; a model selection alone never authorizes stale input.
