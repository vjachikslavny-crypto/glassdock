import CoreGraphics
import Foundation

@main
enum DockShadowTests {
    static func main() {
        for scale in [1, 2] {
            let width = 700 * scale, height = 150 * scale
            let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            canvas.setFillColor(gray: 0.9, alpha: 1)
            canvas.fill(CGRect(x: 0, y: 0, width: 700, height: 150))
            let wallpaper = canvas.makeImage()!
            canvas.clear(CGRect(x: 0, y: 0, width: 700, height: 150))

            canvas.setFillColor(gray: 0, alpha: 0.012)
            canvas.fill(CGRect(x: 60, y: 2, width: 580, height: 96))
            canvas.setFillColor(gray: 0.3, alpha: 0.65)
            canvas.addPath(CGPath(roundedRect: CGRect(x: 90, y: 6, width: 520, height: 50),
                                  cornerWidth: 12, cornerHeight: 12, transform: nil))
            canvas.fillPath()
            canvas.setFillColor(gray: 0.85, alpha: 0.08)
            canvas.fill(CGRect(x: 104, y: 55, width: 492, height: 1))
            canvas.setFillColor(gray: 0.4, alpha: 1)
            for x in stride(from: 102, through: 510, by: 68) {
                canvas.fill(CGRect(x: x, y: 11, width: 44, height: 39))
            }
            canvas.setFillColor(red: 1, green: 0.15, blue: 0.2, alpha: 1)
            canvas.fillEllipse(in: CGRect(x: 270, y: 44, width: 16, height: 18))
            var shelf = CGRect.zero
            guard let mask = DockMask.compose(dock: canvas.makeImage()!, wallpaper: wallpaper,
                                              scale: CGFloat(scale), onShelf: { shelf = $0 }) else {
                fatalError("Expected a shelf at scale \(scale)")
            }
            let bytes = mask.dataProvider!.data! as Data
            func alpha(_ x: Int, _ y: Int) -> UInt8 {
                bytes[((height - 1 - y * scale) * width + x * scale) * 4 + 3]
            }
            precondition(alpha(226, 30) == 255, "The gap between icons needs wallpaper")
            precondition(alpha(226, 55) == 255, "The shelf hairline needs wallpaper")
            precondition(alpha(244, 30) == 0, "The patch must leave native icons visible")
            precondition(alpha(278, 54) == 0, "The badge crossing the hairline must remain visible")
            precondition(alpha(226, 80) == 0 && alpha(74, 30) == 0, "Native shadows must remain clear")
            let allowed = shelf.insetBy(dx: CGFloat(-2 * scale), dy: CGFloat(-2 * scale))
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] != 0 {
                    precondition(allowed.contains(CGPoint(x: x, y: y)), "Wallpaper escaped the shelf rim")
                }
            }
        }
        print("Shelf, hairline, badge, icon and shadow bounds passed at 1× and 2×.")
    }
}
