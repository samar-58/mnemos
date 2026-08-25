#!/usr/bin/env swift

// Generates the Mnemos app icon and menu-bar glyph into macos/Mnemos/Assets.xcassets.
// Run with `make icons`. The mark is an open recall loop with a memory core.

import AppKit
import Foundation

let arguments = CommandLine.arguments
let catalogPath = arguments.count > 1
    ? arguments[1]
    : FileManager.default.currentDirectoryPath + "/macos/Mnemos/Assets.xcassets"

let topColor = CGColor(red: 0.353, green: 0.388, blue: 0.847, alpha: 1)
let bottomColor = CGColor(red: 0.239, green: 0.271, blue: 0.659, alpha: 1)

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Unable to create a \(size)pt bitmap context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

/// Rounded rectangle using the macOS icon corner ratio.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.height * 0.2237, transform: nil)
}

/// The Mnemos mark: an open loop that closes back on a solid core.
func drawMark(in context: CGContext, side: CGFloat, origin: CGPoint, color: CGColor) {
    let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
    context.saveGState()
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineCap(.round)
    context.setLineWidth(side * 0.115)
    context.addArc(
        center: center,
        radius: side * 0.3,
        startAngle: -0.96,
        endAngle: 3.86,
        clockwise: false
    )
    context.strokePath()
    context.addArc(
        center: center,
        radius: side * 0.105,
        startAngle: 0,
        endAngle: .pi * 2,
        clockwise: false
    )
    context.fillPath()
    context.restoreGState()
}

func appIcon(size: Int) -> Data {
    let context = makeContext(size: size)
    let dimension = CGFloat(size)
    let inset = dimension * 0.086
    let plate = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)

    context.saveGState()
    context.addPath(squirclePath(in: plate))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.minY),
        options: []
    )
    context.restoreGState()

    let markSide = plate.width * 0.62
    let markOrigin = CGPoint(x: plate.midX - markSide / 2, y: plate.midY - markSide / 2)
    drawMark(in: context, side: markSide, origin: markOrigin, color: CGColor(gray: 1, alpha: 1))

    return png(from: context, size: size)
}

func menuBarIcon(size: Int) -> Data {
    let context = makeContext(size: size)
    let dimension = CGFloat(size)
    let markSide = dimension * 0.88
    let origin = CGPoint(x: (dimension - markSide) / 2, y: (dimension - markSide) / 2)
    drawMark(in: context, side: markSide, origin: origin, color: CGColor(gray: 0, alpha: 1))
    return png(from: context, size: size)
}

func png(from context: CGContext, size: Int) -> Data {
    guard let image = context.makeImage() else { fatalError("Unable to render a \(size)pt image") }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode a \(size)pt PNG")
    }
    return data
}

func write(_ data: Data, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try data.write(to: url)
        print("wrote \(url.lastPathComponent)")
    } catch {
        fatalError("Unable to write \(path): \(error)")
    }
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(appIcon(size: size), to: "\(catalogPath)/AppIcon.appiconset/icon-\(size).png")
}
for (size, suffix) in [(18, ""), (36, "@2x"), (54, "@3x")] {
    write(menuBarIcon(size: size), to: "\(catalogPath)/MenuBarIcon.imageset/menubar\(suffix).png")
}
