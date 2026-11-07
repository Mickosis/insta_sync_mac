#!/usr/bin/env swift
// Draws the Insta Sync app icon and writes Resources/AppIcon.icns and Resources/AppIcon.png.
// Usage: swift scripts/make_icon.swift
// Needs only the Xcode Command Line Tools. All coordinates below are on a 1024-point canvas, y up.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let tileInset: CGFloat = 100  // macOS icon grid: 824-point tile centered on the canvas
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
}

/// Plain rounded rectangle. macOS 26 and later shrink an icon onto a gray tile unless its outline
/// matches the system shape; a superellipse outline triggered that, this radius does not.
func tilePath() -> CGPath {
    let side = canvas - 2 * tileInset
    return CGPath(
        roundedRect: CGRect(x: tileInset, y: tileInset, width: side, height: side),
        cornerWidth: 185, cornerHeight: 185, transform: nil)
}

func pointOnCircle(radius: CGFloat, degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

/// One clockwise sync arrow: a thick arc ending in a head that follows the circle.
func addSyncArrow(to ctx: CGContext, fromDegrees start: CGFloat, toDegrees end: CGFloat) {
    let radius: CGFloat = 290
    let stroke: CGFloat = 62
    let headHalfWidth: CGFloat = 76
    let headLengthDegrees: CGFloat = 22

    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.addArc(
        center: center, radius: radius,
        startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: true)
    ctx.strokePath()

    ctx.move(to: pointOnCircle(radius: radius + headHalfWidth, degrees: end))
    ctx.addLine(to: pointOnCircle(radius: radius, degrees: end - headLengthDegrees))
    ctx.addLine(to: pointOnCircle(radius: radius - headHalfWidth, degrees: end))
    ctx.closePath()
    ctx.setLineWidth(18)  // softens the head's corners
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
}

/// Rounded bust: a dome with a flat base and soft bottom corners.
func addBust(to ctx: CGContext) {
    let left: CGFloat = 384
    let right: CGFloat = 640
    let bottom: CGFloat = 352
    let top: CGFloat = 494
    let corner: CGFloat = 36
    ctx.move(to: CGPoint(x: left, y: bottom + corner))
    ctx.addCurve(
        to: CGPoint(x: center.x, y: top),
        control1: CGPoint(x: left, y: top - 40), control2: CGPoint(x: left + 60, y: top))
    ctx.addCurve(
        to: CGPoint(x: right, y: bottom + corner),
        control1: CGPoint(x: right - 60, y: top), control2: CGPoint(x: right, y: top - 40))
    ctx.addQuadCurve(
        to: CGPoint(x: right - corner, y: bottom), control: CGPoint(x: right, y: bottom))
    ctx.addLine(to: CGPoint(x: left + corner, y: bottom))
    ctx.addQuadCurve(
        to: CGPoint(x: left, y: bottom + corner), control: CGPoint(x: left, y: bottom))
    ctx.closePath()
    ctx.fillPath()
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)

    // Tile with a soft shadow in the grid margin. Shadow values ignore the transform.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
        color: color(0x000000, alpha: 0.32))
    ctx.setFillColor(color(0xE6337F))
    ctx.addPath(tilePath())
    ctx.fillPath()
    ctx.restoreGState()

    // Sunset gradient and a highlight along the top.
    ctx.saveGState()
    ctx.addPath(tilePath())
    ctx.clip()
    let sunset = CGGradient(
        colorsSpace: sRGB,
        colors: [color(0xFFB938), color(0xFF6A4D), color(0xE6327F), color(0x7038E0)] as CFArray,
        locations: [0, 0.36, 0.68, 1])!
    ctx.drawLinearGradient(
        sunset, start: CGPoint(x: 220, y: 940), end: CGPoint(x: 804, y: 84), options: [])
    let highlight = CGGradient(
        colorsSpace: sRGB,
        colors: [color(0xFFFFFF, alpha: 0.26), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        highlight, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // White glyph, lifted slightly off the gradient.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -8 * scale), blur: 18 * scale,
        color: color(0x4A1270, alpha: 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.setStrokeColor(color(0xFFFFFF))

    addSyncArrow(to: ctx, fromDegrees: 164, toDegrees: 30)
    addSyncArrow(to: ctx, fromDegrees: -16, toDegrees: -150)

    ctx.fillEllipse(in: CGRect(x: 512 - 78, y: 594 - 78, width: 156, height: 156))
    addBust(to: ctx)

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func writePNG(pixels: Int, to url: URL) throws {
    guard
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, pixels: pixels)
    guard
        let image = ctx.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let resources = script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources")

let workFolder = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
let iconset = workFolder.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workFolder) }

for points in [16, 32, 128, 256, 512] {
    try writePNG(
        pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(
        pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try writePNG(pixels: 1024, to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed with status \(iconutil.terminationStatus)")
    exit(1)
}
print("Wrote \(resources.path)/AppIcon.icns and AppIcon.png")
