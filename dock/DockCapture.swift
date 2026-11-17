import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

private enum DockSurface { case dock, wallpaper }

/// The only content inputs are two windows owned by the system Dock.
/// Each CGImage is a Retina crop of the same lower band, in sRGB, with its native alpha.
@MainActor
final class DockCapture {
    typealias Update = (CGImage?, CGImage?, NSScreen?, CGRect) -> Void
    private let update: Update
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var streams: [SCStream] = []
    private var receivers: [SurfaceReceiver] = []
    private var watch: Timer?
    private var legacyTimer: Timer?
    private var started = false
    private enum PauseReason { case system, display, session }
    private var pauses: Set<PauseReason> = []
    private var sleeping: Bool { !pauses.isEmpty }
    private var generation = 0
    private var configuring = false
    private var screen: NSScreen?
    private var band = CGRect.zero
    private var sourceBand = CGRect.zero
    private var dockID = CGWindowID(0)
    private var wallpaperID = CGWindowID(0)
    private var dock: CGImage?
    private var wallpaper: CGImage?
    private var composite = false
    private var latestLegacyWallpaper = Date.distantPast
    private var latestLegacyChange = Date.distantPast
    private var latestLegacyRead = Date.distantPast
    private var latestLegacyPointer: CGPoint?
    private var latestLegacyHover = Date.distantPast
    private var legacyDockFrames = ImageChanges()
    private var legacyWallpaperFrames = ImageChanges()
    private var awaitingFirstFrame = Date.distantPast
    private var needsPermission = false
    private(set) var status = "stopped"
    private(set) var wallpaperUpdates = 0
    private(set) var dockUpdates = 0
    private let frameQueue = DispatchQueue(label: "local.dockglass.window-crops", qos: .userInitiated)

    init(onUpdate: @escaping Update) { update = onUpdate }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, in: .default) { $0.configure() }
        observe(NSWorkspace.activeSpaceDidChangeNotification, in: workspace) { $0.configure() }
        observe(NSWorkspace.willSleepNotification, in: workspace) { $0.setPaused(true, for: .system) }
        observe(NSWorkspace.didWakeNotification, in: workspace) { $0.setPaused(false, for: .system) }
        observe(NSWorkspace.screensDidSleepNotification, in: workspace) { $0.setPaused(true, for: .display) }
        observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.setPaused(false, for: .display) }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { $0.setPaused(true, for: .session) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.setPaused(false, for: .session) }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
        configure()
    }

    func stop() {
        started = false
        watch?.invalidate()
        watch = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        reset()
        pauses.removeAll()
        status = "stopped"
    }

    private func setPaused(_ paused: Bool, for reason: PauseReason) {
        let wasSleeping = sleeping
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        if !wasSleeping && sleeping { reset() }
        if wasSleeping && !sleeping { configure() }
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter,
                         perform: @escaping @MainActor (DockCapture) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { perform(self) } }
        }
        observers.append((center, observer))
    }

    private func reset() {
        generation += 1
        configuring = false
        legacyTimer?.invalidate()
        legacyTimer = nil
        composite = false
        let previous = streams
        streams.removeAll()
        receivers.removeAll()
        for stream in previous { Task { try? await stream.stopCapture() } }
        dockID = 0
        wallpaperID = 0
        dock = nil
        wallpaper = nil
        legacyDockFrames = ImageChanges()
        legacyWallpaperFrames = ImageChanges()
        screen = nil
        band = .zero
        update(nil, nil, nil, .zero)
    }

    private struct WindowPair {
        let dock: CGWindowID
        let wallpaper: CGWindowID
    }

    private static func identify(on display: CGDirectDisplayID, reason: inout String) -> WindowPair? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] else { return nil }
        let displayRect = CGDisplayBounds(display)
        var dock: CGWindowID?
        var wallpaper: CGWindowID?
        var metadata: [String] = []
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        for row in all {
            guard row[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let level = row[kCGWindowLayer as String] as? Int,
                  let data = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: data) else { continue }
            let name = row[kCGWindowName as String] as? String ?? ""
            let desktopLike = name.hasPrefix("Wallpaper") || level == desktop || level == desktop - 1
            let dockLevel = level == Int(CGWindowLevelForKey(.dockWindow))
            guard desktopLike || dockLevel else { continue }
            metadata.append("\(id)@\(level)=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
            guard abs(rect.minX-displayRect.minX) <= 1, abs(rect.minY-displayRect.minY) <= 1,
                  abs(rect.width-displayRect.width) <= 1, abs(rect.height-displayRect.height) <= 1 else { continue }
            if dockLevel { dock = id }
            if desktopLike { wallpaper = id }
        }
        reason = "display=\(display) size=\(Int(displayRect.width))x\(Int(displayRect.height)) Dock surfaces=" + metadata.joined(separator: ",")
        guard let dock, let wallpaper else { return nil }
        return WindowPair(dock: dock, wallpaper: wallpaper)
    }

    private func checkHealth() {
        guard started, !sleeping, !configuring else { return }
        if !CGPreflightScreenCaptureAccess() {
            if !needsPermission { configure() }
            return
        }
        guard let screen, let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            configure()
            return
        }
        var reason = "no Dock owner"
        guard let pair = Self.identify(on: display, reason: &reason), pair.dock == dockID, pair.wallpaper == wallpaperID else {
            configure()
            return
        }
        if legacyTimer == nil && (dock == nil || wallpaper == nil) && Date().timeIntervalSince(awaitingFirstFrame) > 4 {
            startLegacy()
        }
    }

    private func configure() {
        reset()
        guard started, !sleeping else { return }
        guard CGPreflightScreenCaptureAccess() else {
            needsPermission = true
            status = "screen recording permission required"
            return
        }
        needsPermission = false
        var reason = "no screen or Dock owner"
        guard let screen = NSScreen.screens.first,
              let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let pair = Self.identify(on: display, reason: &reason) else { status = "native Dock surfaces unavailable: " + reason; return }
        self.screen = screen
        let height = min(screen.frame.height, 150)
        band = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
        let bounds = CGDisplayBounds(display)
        sourceBand = CGRect(x: bounds.minX, y: bounds.maxY-height, width: bounds.width, height: height)
        dockID = pair.dock
        wallpaperID = pair.wallpaper
        configuring = true
        let token = generation
        let localBand = CGRect(x: 0, y: bounds.height-height, width: bounds.width, height: height)
        let scale = screen.backingScaleFactor
        let pixelWidth = Int((bounds.width*scale).rounded()), pixelHeight = Int((height*scale).rounded())
        awaitingFirstFrame = Date()
        DispatchQueue.main.asyncAfter(deadline: .now()+4.5) { [weak self] in
            guard let self, self.generation == token, self.legacyTimer == nil,
                  self.dock == nil || self.wallpaper == nil else { return }
            self.startLegacy()
        }
        status = "starting isolated window streams"
        Task { [weak self] in
            guard let self else { return }
            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == token else { return }
                guard let dock = shareable.windows.first(where: { $0.windowID == pair.dock }),
                      let wall = shareable.windows.first(where: { $0.windowID == pair.wallpaper }) else {
                    self.startLegacy()
                    return
                }
                for (role, window) in [(DockSurface.dock, dock), (.wallpaper, wall)] {
                    guard self.generation == token else { return }
                    let receiver = SurfaceReceiver { [weak self] image in
                        Task { @MainActor in self?.receive(image, from: role, generation: token) }
                    } onError: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.startLegacy()
                        }
                    }
                    let config = SCStreamConfiguration()
                    config.sourceRect = localBand
                    config.width = pixelWidth
                    config.height = pixelHeight
                    config.showsCursor = false
                    config.capturesAudio = false
                    config.shouldBeOpaque = false
                    config.backgroundColor = CGColor.clear
                    config.ignoreShadowsSingleWindow = true
                    config.includeChildWindows = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.colorSpaceName = CGColorSpace.sRGB
                    config.queueDepth = 3
                    config.minimumFrameInterval = CMTime(value: 1, timescale: role == .dock ? 20 : 12)
                    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                          configuration: config, delegate: receiver)
                    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: self.frameQueue)
                    self.receivers.append(receiver)
                    self.streams.append(stream)
                    try await stream.startCapture()
                }
                if self.generation == token { self.configuring = false; self.status = "isolated window streams" }
            } catch {
                if self.generation == token { self.startLegacy() }
            }
        }
    }

    private func receive(_ frame: CGImage?, from role: DockSurface, generation token: Int) {
        guard token == generation, started, !sleeping, let screen else { return }
        if role == .dock {
            guard frame != nil || dock != nil else { return }
            dock = frame
            if frame != nil { dockUpdates += 1 }
        } else {
            guard frame != nil || wallpaper != nil else { return }
            wallpaper = frame
            if frame != nil { wallpaperUpdates += 1 }
        }
        update(dock, wallpaper, screen, band)
    }

    // A few Sequoia configurations omit system windows from SCShareableContent even when their
    // window IDs exist. Use the same permission and the same two explicit IDs with Quartz there.
    /// If compositing detects a complete but opaque/incorrect SC frame, retry with Quartz.
    /// Repeated requests are idempotent. A failing renderer keeps its panel hidden.
    func retryUsingQuartzCrops() { startLegacy() }

    private func startLegacy() {
        guard started, !sleeping, legacyTimer == nil, let screen, dockID != 0, wallpaperID != 0 else { return }
        generation += 1
        configuring = false
        let prior = streams
        streams.removeAll()
        receivers.removeAll()
        for stream in prior { Task { try? await stream.stopCapture() } }
        dock = nil
        wallpaper = nil
        latestLegacyWallpaper = .distantPast
        latestLegacyRead = .distantPast
        latestLegacyChange = Date()
        legacyDockFrames = ImageChanges()
        legacyWallpaperFrames = ImageChanges()
        update(nil, nil, screen, band)
        guard croppedWindowImage != nil else {
            status = "window captures unavailable"
            return
        }
        status = "isolated Quartz crops"
        scheduleLegacyTimer(fast: true)
        readLegacy()
    }

    private func scheduleLegacyTimer(fast: Bool) {
        let interval = fast ? 1.0 / 12 : 0.25
        guard legacyTimer?.timeInterval != interval else { return }
        legacyTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let pointer = NSEvent.mouseLocation
                if pointer != self.latestLegacyPointer,
                   self.band.contains(pointer) || self.latestLegacyPointer.map(self.band.contains) == true {
                    self.latestLegacyHover = now
                }
                self.latestLegacyPointer = pointer
                let active = now.timeIntervalSince(self.latestLegacyHover) < 0.75 || now.timeIntervalSince(self.latestLegacyChange) < 1.5
                self.scheduleLegacyTimer(fast: active)
                if active || now.timeIntervalSince(self.latestLegacyRead) >= 1.0 { self.readLegacy() }
            }
        }
        timer.tolerance = fast ? 0.008 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        legacyTimer = timer
    }

    private typealias CropFunction = @convention(c) (CGRect, CGWindowListOption.RawValue, CGWindowID, CGWindowImageOption.RawValue) -> Unmanaged<CGImage>?
    private let croppedWindowImage: CropFunction? = {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(address, to: CropFunction.self)
    }()
    private typealias CompositeFunction = @convention(c) (CGRect, CFArray, CGWindowImageOption.RawValue) -> Unmanaged<CGImage>?
    private let croppedComposite: CompositeFunction? = {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(address, to: CompositeFunction.self)
    }()

    /// Native backdrop materials can omit their floor entirely on isolated window captures.
    /// In that case the two-window composite lets the material sample its actual wallpaper.
    func retryUsingWallpaperComposite() {
        guard !composite, legacyTimer != nil, croppedComposite != nil else { return }
        generation += 1
        composite = true
        dock = nil
        wallpaper = nil
        latestLegacyWallpaper = .distantPast
        latestLegacyChange = Date()
        legacyDockFrames = ImageChanges()
        legacyWallpaperFrames = ImageChanges()
        status = "Quartz wallpaper composite"
        update(nil, nil, screen, band)
        readLegacy()
    }

    private var legacyReadInFlight = false
    private func readLegacy() {
        guard let capture = croppedWindowImage, !legacyReadInFlight, screen != nil else { return }
        let token = generation, dockID = self.dockID, wallID = wallpaperID, rect = sourceBand
        let dockFrames = legacyDockFrames, wallFrames = legacyWallpaperFrames
        let now = Date()
        let updateWall = wallpaper == nil || now.timeIntervalSince(latestLegacyWallpaper) >= 1
        if updateWall { latestLegacyWallpaper = now }
        latestLegacyRead = now
        let compositeCapture = composite ? croppedComposite : nil
        legacyReadInFlight = true
        frameQueue.async { [weak self] in
            let options = CGWindowImageOption.bestResolution.rawValue
            let dock: CGImage?
            if let compositeCapture {
                // Quartz expects the numerical IDs cast to pointers, not CFNumbers. Nil array
                // callbacks keep these opaque integers from ever being retained as pointers.
                var ids = [UnsafeRawPointer(bitPattern: Int(dockID)), UnsafeRawPointer(bitPattern: Int(wallID))]
                let pair = CFArrayCreate(nil, &ids, ids.count, nil)!
                dock = compositeCapture(rect, pair, options)?.takeRetainedValue()
            } else {
                dock = capture(rect, CGWindowListOption.optionIncludingWindow.rawValue, dockID, options)?.takeRetainedValue()
            }
            let wall = updateWall ? capture(rect, CGWindowListOption.optionIncludingWindow.rawValue, wallID, options)?.takeRetainedValue() : nil
            let dockChanged = dockFrames.accept(dock)
            let wallChanged = updateWall && wallFrames.accept(wall)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.legacyReadInFlight = false
                guard self.generation == token, self.started, !self.sleeping else { return }
                guard dockChanged || wallChanged else { return }
                self.latestLegacyChange = Date()
                if dockChanged {
                    self.dock = dock
                    if dock != nil { self.dockUpdates += 1 }
                }
                if wallChanged {
                    self.wallpaper = wall
                    if wall != nil { self.wallpaperUpdates += 1 }
                }
                self.update(self.dock, self.wallpaper, self.screen, self.band)
            }
        }
    }
}

/// The serial capture queue owns these snapshots. Compare visible bytes only:
/// Core Video can vary padding or recycle an IOSurface for a different image.
private struct FrameBytes {
    let data: CFData
    let width: Int
    let height: Int
    let stride: Int
    let rowBytes: Int

    func matches(_ pixels: UnsafeRawPointer, width: Int, height: Int, stride: Int, rowBytes: Int) -> Bool {
        guard width == self.width, height == self.height, rowBytes == self.rowBytes,
              let previous = CFDataGetBytePtr(data) else { return false }
        if stride == rowBytes && self.stride == rowBytes {
            return memcmp(previous, pixels, height * rowBytes) == 0
        }
        for y in 0..<height {
            if memcmp(previous.advanced(by: y * self.stride), pixels.advanced(by: y * stride), rowBytes) != 0 {
                return false
            }
        }
        return true
    }
}

/// Quartz supplies snapshots without damage metadata. Keep the last accepted
/// bytes so static snapshots never reach the renderer, including on the fallback.
/// Only the serial frameQueue calls accept(). Each capture generation has its own pair.
private final class ImageChanges: @unchecked Sendable {
    private var previous: CGImage?
    private var bytes: FrameBytes?

    func accept(_ image: CGImage?) -> Bool {
        guard let image else {
            let changed = previous != nil
            previous = nil
            bytes = nil
            return changed
        }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        let rowBytes = (width * image.bitsPerPixel + 7) / 8
        guard height > 0, width > 0, rowBytes > 0, stride >= rowBytes,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= (height - 1) * stride + rowBytes,
              let pixels = CFDataGetBytePtr(data) else {
            previous = image
            bytes = nil
            return true
        }
        if let previous, let bytes, image.bitsPerComponent == previous.bitsPerComponent,
           image.bitsPerPixel == previous.bitsPerPixel, image.bitmapInfo == previous.bitmapInfo,
           image.colorSpace == previous.colorSpace,
           bytes.matches(pixels, width: width, height: height, stride: stride, rowBytes: rowBytes) {
            return false
        }
        previous = image
        bytes = FrameBytes(data: data, width: width, height: height, stride: stride, rowBytes: rowBytes)
        return true
    }
}

private final class SurfaceReceiver: NSObject, SCStreamDelegate, SCStreamOutput {
    let frame: (CGImage?) -> Void
    let onError: () -> Void
    private var last: FrameBytes?
    init(frame: @escaping (CGImage?) -> Void, onError: @escaping () -> Void) {
        self.frame = frame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError() }

    private func invalidateFrame() {
        last = nil
        frame(nil)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let code = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: code) else { return }
        switch status {
        case .idle, .started: return
        case .complete: break
        default: invalidateFrame(); return
        }
        guard let pixel = sample.imageBuffer,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { invalidateFrame(); return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
        let rowBytes = width * 4
        guard width > 0, height > 0, stride >= rowBytes,
              let base = CVPixelBufferGetBaseAddress(pixel) else { invalidateFrame(); return }
        if last?.matches(base, width: width, height: height, stride: stride, rowBytes: rowBytes) == true { return }
        let data = Data(bytes: base, count: stride * height) as CFData
        guard let provider = CGDataProvider(data: data),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { invalidateFrame(); return }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                      space: sRGB, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent) else { invalidateFrame(); return }
        last = FrameBytes(data: data, width: width, height: height, stride: stride, rowBytes: rowBytes)
        frame(image)
    }
}
