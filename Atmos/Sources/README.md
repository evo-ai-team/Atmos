# Source code

Atmos has two Swift package targets. [Atmos](Atmos/README.md) owns macOS integration and application coordination; [AtmosCore](AtmosCore/README.md) contains plain data, state machines, and model protocols that can be tested without desktop access.

The Xcode app target compiles both source trees together. Imports of `AtmosCore` are conditional on `SWIFT_PACKAGE` to support both builds. Domain directories organize responsibilities within these two modules; they do not add framework boundaries.

Keep platform input and permission work in Atmos. Keep deterministic rules in AtmosCore when they can be expressed without AppKit, AVFoundation, or native handles. Directory README files are excluded from both build systems.
