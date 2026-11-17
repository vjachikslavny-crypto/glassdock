import Foundation

@main
enum DockBackdropTests {
    static func main() {
        let strip = CGRect(x: 0, y: 680, width: 180, height: 90)
        let frames = [
            CGRect(x: -12, y: 620, width: 112, height: 85),
            CGRect(x: 87.2, y: 660, width: 50.4, height: 68.1),
            CGRect(x: 110, y: 695, width: 24, height: 14),
            CGRect(x: 15, y: 600, width: 100, height: 80)
        ]
        let windows = frames.enumerated().map { DockBackdrop.Window(id: UInt32($0.offset + 1), frame: $0.element) }
        let regions = DockBackdrop.exposedRegions(in: strip, excluding: windows)
        for y in 680..<770 {
            for x in 0..<180 {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let covered = frames.contains { $0.integral.contains(p) }
                precondition(regions.filter { $0.contains(p) }.count == (covered ? 0 : 1))
            }
        }
        precondition(DockBackdrop.exposedRegions(in: strip, excluding: [.init(id: 1, frame: strip)]).isEmpty)
        precondition(DockBackdrop.nearby(frames[3], strip: strip))
        print("Exposed desktop tiles cover the wallpaper exactly and exclude all window interiors.")
    }
}
