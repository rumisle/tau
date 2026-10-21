// The app icon: ChatWaitingNode's τ, in white on Telegram's blue, in blue on the night palette, and gray for tinting.
// Usage: xcrun swift ios/scripts/make_icon.swift ios/Tau/Assets.xcassets/AppIcon.appiconset
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// The τ of ChatWaitingNode, in its 24 pt box.
func tau(scale s: CGFloat, center: CGPoint) -> CGPath {
    let box = CGPoint(x: 11.9, y: 13.15)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + (x - box.x) * s, y: center.y + (y - box.y) * s) }
    let path = CGMutablePath()
    path.move(to: p(3.2, 10.0))
    path.addQuadCurve(to: p(7.0, 6.6), control: p(3.9, 6.7))
    path.addLine(to: p(20.6, 6.6))
    path.move(to: p(12.6, 6.6))
    path.addLine(to: p(11.9, 15.2))
    path.addQuadCurve(to: p(16.6, 19.4), control: p(11.5, 19.7))
    return path
}

func render(_ name: String, background: [UInt32]?, glyph: [UInt32], glyphAlpha: CGFloat = 1.0) {
    let size = 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, as UIKit draws the τ.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    if let background {
        let gradient = CGGradient(colorsSpace: space, colors: background.map { rgb($0) } as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])
    }
    let path = tau(scale: 30.0, center: CGPoint(x: 512, y: 506))
    let stroked = path.copy(strokingWithWidth: 2.4 * 30.0, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.addPath(stroked)
    ctx.clip()
    if glyph.count > 1 {
        let gradient = CGGradient(colorsSpace: space, colors: glyph.map { rgb($0, glyphAlpha) } as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 260), end: CGPoint(x: 0, y: 760), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    } else {
        ctx.setFillColor(rgb(glyph[0], glyphAlpha))
        ctx.fill(rect)
    }
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// Telegram's blue, light at the top as its icon, and a white τ.
render("icon.png", background: [0x3DBBF6, 0x1A8AD4], glyph: [0xFFFFFF])
// Dark: the night palette's blue-gray, and the τ in the blue.
render("icon-dark.png", background: [0x1B2836, 0x0E1621], glyph: [0x5CC8FF, 0x2A9EF1])
// Tinted: a gray glyph on nothing, which the system colors.
render("icon-tinted.png", background: nil, glyph: [0xFFFFFF])
