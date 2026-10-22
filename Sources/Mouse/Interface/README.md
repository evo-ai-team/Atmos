# Interface

Mouse's presentation layer observes `AppModel` and invokes its user-facing
commands. Views do not decide whether a command is accepted or dispatch computer
input.

- `MouseMenu.swift` supplies the menu bar label and menu, starts standby on first
  appearance, and forwards stop, microphone, settings, and quit actions.
- `Settings/` contains setup, permission controls, usage, and optional local
  activity diagnostics.
- `Notch/` contains the noninteractive everyday overlay and its animations.

The settings window can become key; the notch cannot. Overlay state changes must
not steal focus from the application Mouse is controlling.
