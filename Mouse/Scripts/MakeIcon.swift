#!/usr/bin/env swift
import AppKit
import Foundation

// Rebuild the app icon using only AppKit vector drawing and macOS iconutil.
// Optional arguments: iconset directory, destination .icns file.
// No app launches, screenshot capture, network requests, or external assets.

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : FileManager.default.temporaryDirectory
        .appendingPathComponent("mouse-icon-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Mouse.iconset", isDirectory: true)
let destination = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : project.appendingPathComponent("Resources/Mouse.icns")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func withGraphicsState(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    draw()
}

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MouseIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create icon drawing context."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Standard inset macOS silhouette; transparent corners keep the icon native
    // in the Dock, Finder, and app switcher at every supported size.
    let bodyRect = NSRect(x: 82, y: 86, width: 860, height: 860)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: 192, yRadius: 192)
    withGraphicsState {
        let shadow = NSShadow()
        shadow.shadowColor = color(0.025, 0.10, 0.22, 0.38)
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        shadow.set()
        color(0.08, 0.29, 0.55).setFill()
        body.fill()
    }

    NSGradient(colorsAndLocations:
        (color(0.075, 0.19, 0.43), 0),
        (color(0.055, 0.39, 0.66), 0.48),
        (color(0.18, 0.72, 0.86), 1)
    )!.draw(in: body, angle: 78)

    withGraphicsState {
        body.addClip()
        // Broad reflected light supplies depth without adding visual noise.
        NSGradient(starting: color(0.55, 0.97, 1, 0.56), ending: color(0.30, 0.85, 0.96, 0))!
            .draw(fromCenter: NSPoint(x: 270, y: 886), radius: 0,
                  toCenter: NSPoint(x: 270, y: 886), radius: 670, options: [])
        NSGradient(starting: color(0.02, 0.72, 0.93, 0.39), ending: color(0.02, 0.55, 0.83, 0))!
            .draw(fromCenter: NSPoint(x: 860, y: 200), radius: 0,
                  toCenter: NSPoint(x: 860, y: 200), radius: 550, options: [])
        let reflection = NSBezierPath()
        reflection.move(to: NSPoint(x: 50, y: 890))
        reflection.curve(to: NSPoint(x: 990, y: 760), controlPoint1: NSPoint(x: 280, y: 1_070), controlPoint2: NSPoint(x: 680, y: 590))
        reflection.line(to: NSPoint(x: 990, y: 1_040))
        reflection.line(to: NSPoint(x: 50, y: 1_040))
        reflection.close()
        NSGradient(starting: color(1, 1, 1, 0.025), ending: color(1, 1, 1, 0.20))!.draw(in: reflection, angle: 90)
    }

    // A restrained glass lens echoes the waveform orb in the app's main view.
    let lens = NSBezierPath(ovalIn: NSRect(x: 210, y: 214, width: 604, height: 604))
    withGraphicsState {
        let shadow = NSShadow()
        shadow.shadowColor = color(0.02, 0.17, 0.36, 0.20)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.set()
        color(0.38, 0.82, 0.96, 0.10).setFill()
        lens.fill()
    }
    NSGradient(starting: color(0.22, 0.69, 0.90, 0.04), ending: color(0.85, 0.98, 1, 0.18))!
        .draw(in: lens, angle: 90)
    withGraphicsState {
        lens.addClip()
        NSGradient(starting: color(0.77, 0.98, 1, 0.18), ending: color(0.65, 0.93, 1, 0))!
            .draw(fromCenter: NSPoint(x: 360, y: 755), radius: 0,
                  toCenter: NSPoint(x: 360, y: 755), radius: 490, options: [])
    }
    color(0.81, 0.97, 1, 0.22).setStroke()
    lens.lineWidth = 2.5
    lens.stroke()
    let lensHighlight = NSBezierPath()
    lensHighlight.appendArc(withCenter: NSPoint(x: 512, y: 516), radius: 301,
                            startAngle: 38, endAngle: 148, clockwise: false)
    lensHighlight.lineWidth = 3
    lensHighlight.lineCapStyle = .round
    color(0.89, 1, 1, 0.39).setStroke()
    lensHighlight.stroke()

    // Seven capsules are the app's signature, with a gentle asymmetric rhythm.
    let heights: [CGFloat] = [100, 202, 324, 430, 348, 232, 116]
    let barWidth: CGFloat = 42
    let spacing: CGFloat = 22
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    let firstX = (1024 - totalWidth) / 2
    let waveform = NSBezierPath()
    for (index, height) in heights.enumerated() {
        let rect = NSRect(x: firstX + CGFloat(index) * (barWidth + spacing),
                          y: 516 - height / 2, width: barWidth, height: height)
        waveform.append(NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2))
    }
    withGraphicsState {
        let shadow = NSShadow()
        shadow.shadowColor = color(0.03, 0.22, 0.40, 0.34)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -9)
        shadow.set()
        color(0.70, 0.97, 1).setFill()
        waveform.fill()
    }
    NSGradient(colorsAndLocations:
        (color(0.47, 0.92, 1), 0),
        (color(0.84, 0.99, 1), 0.48),
        (color(1, 1, 1), 1)
    )!.draw(in: waveform, angle: 90)

    // Fine edge highlights remain subdued at Dock size.
    let rim = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 2.5, dy: 2.5), xRadius: 190, yRadius: 190)
    rim.lineWidth = 3
    color(0.80, 0.97, 1, 0.29).setStroke()
    rim.stroke()
    let upperRim = NSBezierPath()
    upperRim.move(to: NSPoint(x: 276, y: 942))
    upperRim.line(to: NSPoint(x: 748, y: 942))
    upperRim.lineWidth = 2.5
    upperRim.lineCapStyle = .round
    color(1, 1, 1, 0.33).setStroke()
    upperRim.stroke()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MouseIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode icon PNG."])
    }
    return png
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
for logicalSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(logicalSize)x\(logicalSize)\(scale == 2 ? "@2x" : "").png"
        try render(size: logicalSize * scale).write(to: iconset.appendingPathComponent(filename), options: .atomic)
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "MouseIcon", code: Int(iconutil.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the iconset."])
}
print("Created \(destination.path)")
