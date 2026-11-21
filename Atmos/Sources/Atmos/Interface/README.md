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
  controls, and transitions between Home, Settings, calibration, and the answer reader.
- `Settings/` contains setup, display-tap calibration, permission controls,
  usage, and local activity diagnostics.
- `AtmosAnswerReader.swift` displays a selected question and its complete, selectable answer.
- `Notch/` contains the compact overlay, loading animation, and answer-ready checkmark.

The expanded menu accepts keyboard input. The everyday notch preserves focus
in the application Atmos is controlling.
