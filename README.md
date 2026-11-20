# Atmos workspace

The project is [Atmos](Atmos/README.md), a native Mac voice interface. Its master README covers setup, behavior, architecture, verification, and current limitations.

- Source, tests, resources, and development scripts: [`Atmos/`](Atmos/README.md)
- Runnable app: `Atmos.app`
- Code organization: [source directory guide](Atmos/Sources/README.md)

Build and test scripts keep intermediates in a temporary directory by default. An optional workspace `work/` directory or explicit environment overrides can select another location. Keep generated artifacts out of the source tree.
