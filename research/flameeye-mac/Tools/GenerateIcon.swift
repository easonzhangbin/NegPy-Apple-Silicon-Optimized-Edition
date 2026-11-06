import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

func renderIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    let tile = CGRect(x: 91, y: 96, width: 842, height: 842)
    let outline = CGPath(roundedRect: tile, cornerWidth: 193, cornerHeight: 193, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: color(0, 0, 0, alpha: 0.32))
    context.setFillColor(color(0.04, 0.07, 0.13))
    context.addPath(outline)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(outline)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.14, 0.21, 0.33), color(0.055, 0.087, 0.16), color(0.028, 0.044, 0.092)] as CFArray,
        locations: [0, 0.6, 1]
    )!
    context.drawLinearGradient(background, start: point(130, 945), end: point(870, 90), options: [])

    context.setStrokeColor(color(0.69, 0.80, 1, alpha: 0.11))
    context.setLineWidth(5)
    for y: CGFloat in [314, 437, 560, 683] {
        context.move(to: point(233, y))
        context.addLine(to: point(791, y))
    }
    for x: CGFloat in [233, 419, 605, 791] {
        context.move(to: point(x, 314))
        context.addLine(to: point(x, 683))
    }
    context.strokePath()
    context.restoreGState()

    context.setStrokeColor(color(0.70, 0.82, 1, alpha: 0.26))
    context.setLineWidth(5)
    context.addPath(outline)
    context.strokePath()

    let spectrum = CGMutablePath()
    spectrum.move(to: point(231, 375))
    spectrum.addCurve(to: point(375, 662), control1: point(305, 375), control2: point(305, 662))
    spectrum.addCurve(to: point(529, 445), control1: point(445, 662), control2: point(456, 445))
    spectrum.addCurve(to: point(650, 545), control1: point(578, 445), control2: point(601, 545))
    spectrum.addCurve(to: point(791, 364), control1: point(719, 545), control2: point(725, 364))

    context.setLineCap(.round)
    context.setLineWidth(44)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0.25, 0.55, 1, alpha: 0.35))
    context.setStrokeColor(color(0.16, 0.22, 0.37))
    context.addPath(spectrum)
    context.strokePath()
    context.restoreGState()

    context.addPath(spectrum)
    context.replacePathWithStrokedPath()
    context.clip()
    let rainbow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(0.72, 0.47, 1), color(0.37, 0.62, 1), color(0.30, 0.90, 0.97),
            color(0.48, 0.93, 0.63), color(1, 0.81, 0.35), color(1, 0.39, 0.41)
        ] as CFArray,
        locations: [0, 0.18, 0.39, 0.58, 0.76, 1]
    )!
    context.drawLinearGradient(rainbow, start: point(213, 0), end: point(811, 0), options: [])
    return context.makeImage()!
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let output = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, renderIcon(size: size * scale), nil)
        precondition(CGImageDestinationFinalize(destination), "Could not write \(output.lastPathComponent)")
    }
}
