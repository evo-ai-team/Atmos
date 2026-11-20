# Xcode app project

`project.pbxproj` configures the native Atmos app, its stable bundle identifier, macOS target, entitlements, icon, and signing settings. The synchronized `Sources` group discovers Swift files recursively across domain directories.

The synchronized group's membership exceptions exclude directory READMEs from the app target; otherwise identically named guides can collide when Xcode copies resources. Update those exceptions when adding source directories with guides.

The [shared scheme](xcshareddata/xcschemes/README.md) is used by `Scripts/build.sh`. SwiftPM's separate graph in `Package.swift` builds the same source trees as app/core modules and runs XCTest.
