# Application resources

`Info.plist` supplies bundle metadata and privacy-use descriptions. `Mouse.entitlements` defines the signed app's capabilities. `Mouse.icns` is the shipped icon; regenerate it with `Scripts/MakeIcon.swift`.

The Xcode project refers to these files explicitly. The stable `com.chosen.mac` identity is intentional after the rename to Mouse, preserving saved credentials and permission identity. Do not change identifiers or add permissions as part of visual/source cleanup.
