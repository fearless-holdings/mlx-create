// Renders the MLX Create app icon ("sun in crop marks") at every macOS size.
// Usage: swift draw_icon.swift <output-dir>
// Pure CoreGraphics; no assets. Keep in sync with AppIcon.appiconset.
import AppKit
import CoreGraphics
import Foundation
import ImageIO

let safe = UInt32(0xC8401A)  // safelight
let deep = UInt32(0x8E2A10)  // deeper red
let ink = UInt32(0x141414)  // near-black
let paper = UInt32(0xF3EEE6)  // paper white

func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the icon into `ctx` on a canvas of `px` points. The body is an 824/1024
/// squircle with a drop shadow; the mark is a safelight sun over a horizon inside
/// paper-white crop corners. At small sizes fewer ripples survive.
func drawIcon(_ ctx: CGContext, px: CGFloat) {
    let s = px / 1024  // all geometry is authored on the 1024 grid
    let bodyRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = CGPath(
        roundedRect: bodyRect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Body + shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * s), blur: 26 * s,
        color: cg(0x000000, 0.22))
    ctx.addPath(bodyPath)
    ctx.setFillColor(cg(ink))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Warm glow fading down from the top centre into near-black by ~60% height.
    // (CG y is up: the body's top edge is bodyRect.maxY.)
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [cg(safe, 0.78), cg(deep, 0.52), cg(deep, 0)] as CFArray,
        locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: bodyRect.midX, y: bodyRect.maxY + 40 * s), startRadius: 0,
        endCenter: CGPoint(x: bodyRect.midX, y: bodyRect.maxY), endRadius: 640 * s,
        options: [])

    // Crop corners: paper-white Ls, stroke ~5% of the body, inset ~18%.
    let inset: CGFloat = 0.185 * 824 * s
    let arm: CGFloat = 0.11 * 824 * s
    let thick: CGFloat = (px <= 40 ? 0.062 : 0.05) * 824 * s
    ctx.setStrokeColor(cg(paper))
    ctx.setLineWidth(thick)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.miter)
    let lo = bodyRect.minX + inset
    let hi = bodyRect.maxX - inset
    let bo = bodyRect.minY + inset
    let to = bodyRect.maxY - inset
    for (px2, py2, dx, dy) in [
        (lo, to, 1.0, -1.0), (hi, to, -1.0, -1.0),
        (lo, bo, 1.0, 1.0), (hi, bo, -1.0, 1.0),
    ] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: px2 + dx * arm, y: py2))
        p.addLine(to: CGPoint(x: px2, y: py2))
        p.addLine(to: CGPoint(x: px2, y: py2 + dy * arm))
        ctx.addPath(p)
        ctx.strokePath()
    }

    // Sun on the horizon at the optical centre; ripples thin downward.
    let cx = bodyRect.midX
    let horizonY = bodyRect.minY + 0.44 * 824 * s
    let sunR = 0.152 * 824 * s
    ctx.setFillColor(cg(safe))
    ctx.saveGState()
    ctx.clip(to: CGRect(x: bodyRect.minX, y: horizonY, width: 824 * s, height: bodyRect.maxY - horizonY))
    ctx.fillEllipse(in: CGRect(x: cx - sunR, y: horizonY - sunR, width: 2 * sunR, height: 2 * sunR))
    ctx.restoreGState()

    // Ripple lenses below the horizon, widest and brightest at the top.
    let ripples: [(CGFloat, CGFloat, CGFloat, CGFloat)] =
        px <= 40
        ? [(0.44, 0.018, 8, 1.0), (0.30, 0.013, 48, 0.9), (0.17, 0.010, 82, 0.75)]
        : px <= 140
            ? [(0.46, 0.018, 6, 1.0), (0.34, 0.014, 44, 0.9), (0.23, 0.011, 78, 0.78), (0.13, 0.008, 106, 0.65)]
            : [
                (0.46, 0.018, 6, 1.0), (0.36, 0.014, 48, 0.92), (0.26, 0.011, 86, 0.8),
                (0.17, 0.009, 118, 0.68), (0.09, 0.006, 144, 0.55),
            ]
    for (w, h, drop, a) in ripples {
        ctx.setFillColor(cg(safe, a))
        ctx.fillEllipse(
            in: CGRect(
                x: cx - w * 824 * s / 2, y: horizonY - drop * s - h * 824 * s / 2,
                width: w * 824 * s, height: h * 824 * s))
    }
    ctx.restoreGState()
}

func render(px: Int, to path: String) {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, px: CGFloat(px))
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// macOS iconset: idiom mac, sizes 16/32/128/256/512 at 1x and 2x.
let slots: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in slots { render(px: px, to: "\(out)/\(name)") }
