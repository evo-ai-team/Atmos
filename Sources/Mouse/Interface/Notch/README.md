# Notch

The everyday voice interface is a nonactivating AppKit panel anchored at the top
of the primary screen. It passes mouse events through to the app underneath.

- `MouseNotchController.swift` accepts `MouseOverlayState`, owns the panel, and
  sequences state transitions. Transition IDs prevent old animation completions
  from hiding or replacing a newer state.
- `MouseNotchLayout.swift` calculates screen/camera geometry, text measurements,
  and each state's target size.
- `MouseNotchSurface.swift` draws the glass body, concave shoulders, and text.
  Its contour follows the panel's actual animated size to avoid competing clocks.
- `MouseThinkingIndicator.swift` draws and animates the compact thinking dots.

Presentation never gates command execution. Reduced-motion and reduced-transparency
preferences are applied by these views. Preserve the panel's non-key,
nonactivating behavior when changing its appearance or transitions.
