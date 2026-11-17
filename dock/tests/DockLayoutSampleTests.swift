import CoreGraphics
import Foundation

// Compile with DockMask.swift and DockLayoutSample.swift. These fixtures exercise
// real classification without capturing a screen or opening an application.
@main
enum DockLayoutSampleTests {
    struct Appearance {
        var scale = 2
        var opaqueShelf = false
        var thumbnail = true
        var thumbnailOpacity = 1.0
        var thumbnailShift = 0.0
        var artColor = 0.4
        var width = 700
    }

    static func image(_ appearance: Appearance) -> CGImage {
        let scale = appearance.scale
        let canvas = CGContext(data: nil, width: appearance.width * scale, height: 150 * scale,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        canvas.setFillColor(gray: 0.3, alpha: appearance.opaqueShelf ? 1 : 0.65)
        canvas.addPath(CGPath(roundedRect: CGRect(x: 90, y: 6, width: 520, height: 50),
                              cornerWidth: 12, cornerHeight: 12, transform: nil))
        canvas.fillPath()
        canvas.setFillColor(gray: 0.85, alpha: 0.3)
        canvas.fill(CGRect(x: 104, y: 55, width: 492, height: 1))
        for x in stride(from: 102, through: 374, by: 68) {
            canvas.setFillColor(gray: 0.02, alpha: 1)
            canvas.fill(CGRect(x: x, y: 11, width: 44, height: 39))
            canvas.setFillColor(gray: appearance.artColor, alpha: 1)
            canvas.fill(CGRect(x: x + 3, y: 14, width: 38, height: 33))
        }
        // Two opaque badges used to make a fully opaque shelf pass the native
        // alpha-only validity check even when moving tiles had identical alpha.
        canvas.setFillColor(red: 1, green: 0.15, blue: 0.2, alpha: 1)
        for x in [134, 202] {
            canvas.fillEllipse(in: CGRect(x: x, y: 44, width: 16, height: 18))
        }
        if appearance.thumbnail {
            canvas.setFillColor(gray: 0.9, alpha: appearance.thumbnailOpacity)
            canvas.fill(CGRect(x: 450 + appearance.thumbnailShift, y: 16, width: 38, height: 25))
        }
        return canvas.makeImage()!
    }

    static func paper(width: Int, height: Int) -> CGImage {
        let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(gray: 0.85, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return canvas.makeImage()!
    }

    static func assertMatchesRenderedMask(_ image: CGImage, paper: CGImage, scale: CGFloat) {
        var shelf = CGRect.zero
        guard let signature = DockMask.occupancy(of: image, scale: scale),
              let mask = DockMask.compose(dock: image, wallpaper: paper, scale: scale, onShelf: { shelf = $0 }),
              let provider = mask.dataProvider, let bytes = provider.data else {
            fatalError("Expected valid shelf")
        }
        precondition(abs(shelf.minX / scale - 90) <= 2,
                     "Badges interrupting the top edge must not trim the left shelf")
        precondition(abs(shelf.maxX / scale - 610) <= 2,
                     "The same shelf must preserve its right boundary")
        let output = bytes as Data
        let header = 2 * MemoryLayout<UInt32>.size
        precondition(signature.count == header + (image.width * image.height + 7) / 8)
        for pixel in 0..<(image.width * image.height) {
            let occupied = signature[header + pixel / 8] & UInt8(1 << (pixel % 8)) != 0
            precondition(occupied == (output[pixel * 4 + 3] != 0),
                         "Stable signature must describe every actually rendered pixel")
        }
    }

    static func main() async {
        var assertions = 0
        for scale in [1, 2] {
            for opaque in [false, true] {
                for opacity in [0.24, 0.5, 0.7, 1.0] {
                    var appearance = Appearance()
                    appearance.scale = scale
                    appearance.opaqueShelf = opaque
                    appearance.thumbnailOpacity = opacity
                    let present = image(appearance)
                    let wallpaper = paper(width: present.width, height: present.height)
                    let current = await DockLayoutSample.geometry(of: present, wallpaper: wallpaper, scale: CGFloat(scale))
                    precondition(current != nil)
                    assertMatchesRenderedMask(present, paper: wallpaper, scale: CGFloat(scale))
                    appearance.thumbnail = false
                    let absent = await DockLayoutSample.geometry(of: image(appearance), wallpaper: wallpaper, scale: CGFloat(scale))
                    precondition(current != absent, "Fading miniature must change the shape")
                    appearance.thumbnail = true
                    appearance.thumbnailShift = 1.0 / Double(scale)
                    let moved = await DockLayoutSample.geometry(of: image(appearance), wallpaper: wallpaper, scale: CGFloat(scale))
                    precondition(current != moved, "A one-physical-pixel shift must change the shape")
                    appearance.thumbnailShift = 0
                    appearance.artColor = 0.65
                    let recolored = await DockLayoutSample.geometry(of: image(appearance), wallpaper: wallpaper, scale: CGFloat(scale))
                    precondition(current == recolored, "Artwork inside the same silhouette must be stable")
                    assertions += 7
                }
            }
        }
        let empty = paper(width: 1400, height: 300)
        precondition(DockMask.occupancy(of: empty, scale: 2) == nil, "Plain image has no Dock")
        let dock = image(Appearance())
        let wrongSize = paper(width: dock.width - 1, height: dock.height)
        let mismatched = await DockLayoutSample.geometry(of: dock, wallpaper: wrongSize, scale: 2)
        precondition(mismatched == nil)
        print("\(assertions + 2) exact occupancy checks passed")
    }
}
