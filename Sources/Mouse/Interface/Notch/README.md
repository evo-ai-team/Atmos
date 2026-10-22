# Notch

The everyday voice interface is a nonactivating AppKit panel anchored at the top
of the primary screen. It passes mouse events through to the app underneath.

- `MouseNotchController.swift` accepts `MouseOverlayState`, owns the panel, and
  sequences state transitions. Transition IDs prevent old animation completions
  from hiding or replacing a newer state.
  The panel answers AppKit's private `_hasActiveAppearance` selector with `true`
  so native clear glass keeps its refractive appearance while another app has
  focus. This changes appearance only: the panel remains nonactivating, cannot
  become key or main, and passes mouse events through. The undocumented hook
  may change with macOS updates; if AppKit stops consulting it, the material
  returns to its normal inactive appearance. Reduce Transparency still uses
  the surface's opaque fallback.
  Edge lighting stays steady through opening and closing; only the body geometry
  animates. Reduce Motion applies the final geometry immediately.
- `MouseNotchLayout.swift` calculates screen/camera geometry, text measurements,
  and each state's target size.
- `MouseNotchSurface.swift` draws the glass body, concave shoulders, and text.
  Its contour follows the panel's actual animated size to avoid competing clocks.
  Only the measured hardware cutout is fully black. A full-width vertical tint
  stays nearly black through the camera's height, then fades down to a 10% dark
  backing at the bottom. It has no sideways falloff; the outer view clips it to
  the silhouette. A brighter bottom reflection fades continuously up the sides
  and reaches zero before the top corners. A one-point, clipped dark stroke
  attenuates the native glass rim in the upper region. It covers only the
  perimeter, keeping the glass itself unmasked
  and at full opacity. Native clear glass runs with tint and text
  inside its `contentView`, allowing AppKit to filter the window behind it and
  apply foreground treatments. Do not lower the material's alpha to tune darkness;
  that lets the untreated background show through. The native top edge extends
  offscreen, so no mask is applied to the material itself.
  Screens without a cutout use the faint backing throughout, including the
  shoulders. Reduce Transparency substitutes opaque charcoal behind the content.
- `MouseThinkingIndicator.swift` draws and animates the compact thinking dots.

Presentation never gates command execution. Reduced-motion and reduced-transparency
preferences are applied by these views. Preserve the panel's non-key,
nonactivating behavior when changing its appearance or transitions.
