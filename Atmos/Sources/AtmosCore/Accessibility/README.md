# Accessibility data and traversal

`AccessibilitySnapshot` contains serializable, snapshot-scoped element IDs, hierarchy links, availability/truncation information, and screen/screenshot bounds. `AccessibilityElement` removes protected content at construction as a second boundary behind the native reader. Native AX handles stay in the application target.

`AccessibilityTraversalQueue` bounds processed plus pending nodes. Its priorities preserve top-level menus while preferring window/content regions over unopened menu descendants. Higher-priority discoveries can replace pending lower-priority work; IDs must never be reused after eviction.

`AccessibilityBounds` clips rectangles to the captured display before mapping them into screenshot pixels. Missing geometry or an unavailable tree must stay explicit, rather than becoming evidence that a target does not exist.

`AccessibilityAction` binds one Press, Show Menu, Increment, or Decrement request to an exact snapshot and element ID. `nativeActionElements` shares eligibility between Decisions and Luna: enabled, visible, non-secure controls with unique IDs and an exposed supported action. Resolving an action checks the captured data; the native controller still revalidates the live target before dispatch. A partial tree can contain usable controls, while an unavailable tree cannot authorize native input.

Regression coverage: [accessibility tests](../../../Tests/AtmosCoreTests/Accessibility/README.md).
