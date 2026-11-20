# Interface

Atmos's presentation layer observes `AppModel` and invokes its user-facing
commands. Views do not decide whether a command is accepted or dispatch computer
input.

- `AtmosMenu.swift` supplies the menu bar label and menu, starts standby on first
  appearance, and forwards stop, microphone, settings, and quit actions.
- `AtmosExpandedMenuController.swift` presents and resizes the half-height or
  full-screen panel, anchors its black top edge to the display, and restores
  foreground focus after submission.
- `AtmosExpandedMenuView.swift` hosts the centered command editor, dictation
  controls, and transitions between Home and Settings.
- `Settings/` contains setup, display-tap calibration, permission controls,
  usage, and local activity diagnostics.
- `Notch/` contains the noninteractive everyday overlay and its animations.

The expanded menu accepts keyboard input. The everyday notch preserves focus
in the application Atmos is controlling.
