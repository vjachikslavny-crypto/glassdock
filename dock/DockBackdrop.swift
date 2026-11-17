import AppKit
import ScreenCaptureKit

/// Read the exposed desktop in the bottom strip, including shadows cast onto it.
/// Window interiors are removed from the capture regions before taking any image.
enum DockBackdrop {
    struct Window: Equatable {
        let id: CGWindowID
        let frame: CGRect
        var activeOwner = false
    }

    static func nearby(_ frame: CGRect, strip: CGRect) -> Bool {
        frame.insetBy(dx: -128, dy: -128).intersects(strip)
    }

    static func exposedRegions(in strip: CGRect, excluding windows: [Window]) -> [CGRect] {
        var regions = [strip]
        // Tall windows reaching furthest down normally hide all the shorter
        // ones. Subtract them first to avoid fragmenting visible wallpaper.
        for bounds in Set(windows.map { $0.frame.integral }).sorted(by: { $0.maxY > $1.maxY }) {
            regions = regions.flatMap { region -> [CGRect] in
                let hit = region.intersection(bounds)
                guard !hit.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: hit.minY - region.minY),
                    CGRect(x: region.minX, y: hit.maxY, width: region.width, height: region.maxY - hit.maxY),
                    CGRect(x: region.minX, y: hit.minY, width: hit.minX - region.minX, height: hit.height),
                    CGRect(x: hit.maxX, y: hit.minY, width: region.maxX - hit.maxX, height: hit.height)
                ].filter { !$0.isEmpty }
            }
        }
        return regions
    }

    @MainActor static func capture(display: SCDisplay, wallpaper: SCWindow, windows: [Window],
                                   available: [SCWindow], strip: CGRect, scale: CGFloat,
                                   isCurrent: () -> Bool) async throws -> CGImage? {
        let width = Int((strip.width * scale).rounded()), height = Int((strip.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setBlendMode(.copy)
        let ids = Set(windows.map(\.id))
        let contributors = available.filter { ids.contains($0.windowID) }
        // Reconcile the latest window geometry reported by ScreenCaptureKit as well.
        let rectangles = windows + contributors.map { Window(id: $0.windowID, frame: $0.frame) }
        for region in exposedRegions(in: strip, excluding: rectangles) {
            guard isCurrent() else { return nil }
            let adjacent = contributors.filter { nearby($0.frame, strip: region) }
            let filter = SCContentFilter(display: display, including: [wallpaper] + adjacent)
            let config = SCStreamConfiguration()
            config.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int((region.width * scale).rounded())
            config.height = Int((region.height * scale).rounded())
            config.colorSpaceName = CGColorSpace.sRGB
            config.ignoreShadowsDisplay = false
            config.includeChildWindows = false
            config.capturesAudio = false
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            canvas.draw(image, in: CGRect(x: (region.minX - strip.minX) * scale,
                                          y: (strip.maxY - region.maxY) * scale,
                                          width: CGFloat(config.width), height: CGFloat(config.height)))
        }
        return canvas.makeImage()
    }
}
