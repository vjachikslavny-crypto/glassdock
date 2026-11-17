import CoreGraphics
import Foundation

enum DockLayoutSample {
    static func geometry(of dock: CGImage, wallpaper: CGImage, scale: CGFloat) async -> Data? {
        guard dock.width == wallpaper.width, dock.height == wallpaper.height else { return nil }
        return await Task.detached(priority: .userInitiated) {
            DockMask.occupancy(of: dock, scale: scale)
        }.value
    }
}
