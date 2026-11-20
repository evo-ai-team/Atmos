import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Captures one display without owning task or permission state. The caller pins
/// the display for a command; this adapter verifies its geometry again after the
/// asynchronous capture so returned pixels cannot carry a stale coordinate map.
@MainActor
enum DisplayCapture {
    static func capture(displayID: CGDirectDisplayID, timing: PipelineTiming? = nil) async throws -> ScreenshotFrame {
        var stage = timing?.begin("Capture display discovery and configuration")
        var stageOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(stage, outcome: Task.isCancelled ? .cancelled : stageOutcome) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }), CGDisplayIsActive(displayID) != 0 else {
            throw AtmosError.configuration("The selected display is no longer available. Start a new command on a connected display.")
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw AtmosError.configuration("The selected display has invalid dimensions.")
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        filter.includeMenuBar = true
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(min(bounds.width, 1_600).rounded()))
        configuration.height = max(1, Int((Double(configuration.width) * bounds.height / bounds.width).rounded()))
        configuration.captureResolution = .nominal
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Capture screenshot acquisition")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        // Do not return a stale mapping if a monitor was rearranged during capture.
        guard CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID) == bounds else {
            throw AtmosError.configuration("The display arrangement changed during capture. Retry the command.")
        }
        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Capture JPEG encoding")
        let encoded = try Self.encodeJPEG(image)
        stageOutcome = .succeeded
        return ScreenshotFrame(data: encoded, width: image.width, height: image.height,
                               originX: bounds.minX, originY: bounds.minY,
                               pointWidth: bounds.width, pointHeight: bounds.height, displayID: displayID)
    }

    static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AtmosError.configuration("Could not create the screenshot encoder.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AtmosError.configuration("Could not encode the screenshot.")
        }
        return data as Data
    }

}
