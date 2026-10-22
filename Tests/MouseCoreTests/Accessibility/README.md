# Accessibility tests

`AccessibilitySnapshotTests` covers serializable snapshots, secure-field redaction, and mapping/clipping screen bounds. `AccessibilityTraversalQueueTests` covers bounded traversal priorities, menu starvation, replacement of pending nodes, and deeply nested content.

Use synthetic topology rather than a live app's AX tree so these contracts remain deterministic. Native-handle revalidation still needs separate platform verification.
