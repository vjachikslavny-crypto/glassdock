// Usage: swift art/MakeIcon.swift /path/to/GlassDock.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let channels = [16, 8, 0].map { CGFloat((hex >> $0) & 255) / 255 }
    return CGColor(colorSpace: rgb, components: channels + [alpha])!
}

private func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                     _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func gradient(_ ctx: CGContext, _ shape: CGPath, from: CGPoint, to: CGPoint,
                      colors: [CGColor], stops: [CGFloat]? = nil) {
    let ramp = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: stops)!
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(ramp, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

private func fill(_ ctx: CGContext, _ path: CGPath, with tint: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(tint)
    ctx.fillPath()
}

private func outline(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat, _ tint: CGColor) {
    ctx.addPath(path)
    ctx.setStrokeColor(tint)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

// The crest is drawn once as an open path for the light edge, and closed for its water.
private func swell(y: CGFloat) -> CGMutablePath {
    let crest = CGMutablePath()
    crest.move(to: CGPoint(x: 30, y: y - 94))
    crest.addCurve(to: CGPoint(x: 505, y: y + 9), control1: CGPoint(x: 246, y: y - 165),
                   control2: CGPoint(x: 371, y: y + 34))
    crest.addCurve(to: CGPoint(x: 995, y: y + 108), control1: CGPoint(x: 686, y: y - 30),
                   control2: CGPoint(x: 799, y: y - 33))
    return crest
}

private func image(at pixels: Int) throws -> CGImage {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: rgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError("Could not allocate the \(pixels)-pixel icon.")
    }
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = rounded(92, 100, 840, 840, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -9), blur: 18, color: color(0x031628, 0.31))
    fill(ctx, tile, with: color(0x123448))
    ctx.restoreGState()

    gradient(ctx, tile, from: CGPoint(x: 200, y: 902), to: CGPoint(x: 807, y: 149),
             colors: [color(0x101C34), color(0x143950), color(0x0B6671)], stops: [0, 0.55, 1])
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let crest = swell(y: 508)
    let water = crest.mutableCopy()!
    water.addLine(to: CGPoint(x: 995, y: 50))
    water.addLine(to: CGPoint(x: 30, y: 50))
    water.closeSubpath()
    gradient(ctx, water, from: CGPoint(x: 690, y: 596), to: CGPoint(x: 393, y: 120),
             colors: [color(0x66DED0), color(0x198B94), color(0x10516F)], stops: [0, 0.23, 1])
    outline(ctx, crest, 3, color(0xA5F8DF, 0.49))
    let near = swell(y: 446)
    near.addLine(to: CGPoint(x: 995, y: 50))
    near.addLine(to: CGPoint(x: 30, y: 50))
    near.closeSubpath()
    gradient(ctx, near, from: CGPoint(x: 612, y: 510), to: CGPoint(x: 455, y: 107),
             colors: [color(0x05616C, 0.58), color(0x0A526C, 0.96)])
    ctx.restoreGState()
    outline(ctx, tile, 3, color(0xCCFFFF, 0.21))

    let bar = rounded(219, 655, 586, 90, 32)
    gradient(ctx, bar, from: CGPoint(x: 300, y: 746), to: CGPoint(x: 322, y: 655),
             colors: [color(0xCFF7F6, 0.95), color(0x82BCCC, 0.89)])
    outline(ctx, bar, 4, color(0xF2FFFC, 0.77))
    fill(ctx, rounded(254, 688, 74, 24, 12), with: color(0x163B56, 0.86))
    fill(ctx, rounded(698, 690, 72, 20, 10), with: color(0x174359, 0.70))

    let dock = rounded(237, 270, 550, 147, 52)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 13, color: color(0x07334B, 0.33))
    fill(ctx, dock, with: color(0x367F8E))
    ctx.restoreGState()
    gradient(ctx, dock, from: CGPoint(x: 412, y: 417), to: CGPoint(x: 449, y: 271),
             colors: [color(0xB9EFEB, 0.82), color(0x76ABB8, 0.94)])
    outline(ctx, dock, 4, color(0xDFFDFA, 0.83))
    let tiles: [(UInt32, UInt32)] = [
        (0xFBFFED, 0xC7E7D3), (0x7CF0E0, 0x34BEBD),
        (0x7DCFFF, 0x4593DA), (0xF7CE9F, 0xE39B84)
    ]
    for (index, pair) in tiles.enumerated() {
        let x = CGFloat(278 + index * 122)
        let shape = rounded(x, 301, 101, 87, 21)
        gradient(ctx, shape, from: CGPoint(x: x, y: 390), to: CGPoint(x: x + 75, y: 297),
                 colors: [color(pair.0), color(pair.1)])
        if pixels >= 64 { outline(ctx, shape, 2.5, color(0xEFFFFD, 0.37)) }
    }
    guard let rendered = ctx.makeImage() else { throw IconError("Could not render icon.") }
    return rendered
}

private struct IconError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func build(_ output: URL) throws {
    let files = FileManager.default
    let temp = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let iconset = temp.appendingPathComponent("GlassDock.iconset")
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temp) }
    var images: [Int: CGImage] = [:]
    for size in [16, 32, 128, 256, 512] {
        for scale in 1...2 {
            let pixels = size * scale
            let rendered: CGImage
            if let existing = images[pixels] { rendered = existing }
            else {
                rendered = try image(at: pixels)
                images[pixels] = rendered
            }
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(size)x\(size)\(suffix).png"
            let url = iconset.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                             1, nil) else { throw IconError("Cannot create \(name).") }
            CGImageDestinationAddImage(dest, rendered, nil)
            guard CGImageDestinationFinalize(dest) else { throw IconError("Cannot write \(name).") }
        }
    }
    let staged = temp.appendingPathComponent("GlassDock.icns")
    let pack = Process()
    pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    pack.arguments = ["-c", "icns", "-o", staged.path, iconset.path]
    try pack.run()
    pack.waitUntilExit()
    guard pack.terminationStatus == 0 else { throw IconError("iconutil failed.") }
    try Data(contentsOf: staged).write(to: output, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw IconError("Usage: swift MakeIcon.swift /path/to/output.icns")
    }
    try build(URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
