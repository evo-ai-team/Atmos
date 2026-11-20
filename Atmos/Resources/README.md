# Application resources

`Info.plist` supplies bundle metadata and privacy-use descriptions. `Atmos.entitlements` defines the signed app's capabilities. `Atmos.icns` is the shipped icon; regenerate it with `Scripts/MakeIcon.swift`.

The Xcode project refers to these files explicitly. The Atmos bundle identifier is `com.evoai.atmos`.
