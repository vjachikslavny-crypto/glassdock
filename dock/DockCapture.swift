import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Explicitly requested one-shot images of the native Dock and its wallpaper backing.
/// With no changes in the desktop or Dock layout there is no image capture at all.
@MainActor
final class DockCapture {
    typealias Update = (CGImage?, CGImage?, NSScreen?, CGRect) -> Void
    private let update: Update
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private enum Pause { case system, display, session }
    private var pauses: Set<Pause> = []
    private var started = false
    private var epoch = 0
    private var inFlight = false
    private var deadline: TimeInterval?
    private var nextMetadata: TimeInterval = 0
    private var wallSettlesAfter: TimeInterval = 0
    private var hovering = false
    private var wallpaper: CGImage?
    private var lastMetadata: Metadata?
    private var permission = false

    private(set) var status = "idle snapshots"
    private(set) var wallpaperUpdates = 0
    private(set) var dockUpdates = 0
    var shelf = CGRect.zero

    private struct Pair: Equatable {
        let display: CGDirectDisplayID
        let dock: CGWindowID
        let wallpaper: CGWindowID
        let bounds: CGRect
    }
    private struct Metadata {
        let pair: Pair?
        let windowIDs: Set<CGWindowID>
        let dockConfig: Date?
        let wallpaperConfig: Date?
    }
    private let dockPrefs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    private let wallPrefs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    init(onUpdate: @escaping Update) { update = onUpdate }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, in: ws) { $0.pause(.system, true) }
        observe(NSWorkspace.didWakeNotification, in: ws) { $0.pause(.system, false) }
        observe(NSWorkspace.screensDidSleepNotification, in: ws) { $0.pause(.display, true) }
        observe(NSWorkspace.screensDidWakeNotification, in: ws) { $0.pause(.display, false) }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: ws) { $0.pause(.session, true) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: ws) { $0.pause(.session, false) }
        observe(NSWorkspace.activeSpaceDidChangeNotification, in: ws) { $0.layoutChanged(wall: true) }
        observe(NSApplication.didChangeScreenParametersNotification, in: .default) { $0.layoutChanged(wall: true) }
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsUnlocked"), in: distributed) { $0.layoutChanged(wall: true, delay: 5.5) }
        observe(Notification.Name("com.apple.screensaver.didstop"), in: distributed) { $0.layoutChanged(wall: true, delay: 5.5) }
        observe(NSWorkspace.didLaunchApplicationNotification, in: ws, regularAppsOnly: true) { $0.layoutChanged(wall: false) }
        observe(NSWorkspace.didTerminateApplicationNotification, in: ws, regularAppsOnly: true) { $0.layoutChanged(wall: false) }
        layoutChanged(wall: true)
        tick()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter,
                         regularAppsOnly: Bool = false, _ fn: @escaping @MainActor (DockCapture) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if regularAppsOnly {
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.activationPolicy == .regular else { return }
                }
                if let self { fn(self) }
            }
        }
        observers.append((center, token))
    }

    func stop() {
        started = false
        epoch += 1
        deadline = nil
        wallpaper = nil
        lastMetadata = nil
        pauses.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        update(nil, nil, nil, .zero)
    }

    private func pause(_ why: Pause, _ paused: Bool) {
        if paused { pauses.insert(why) } else { pauses.remove(why) }
        layoutChanged(wall: true, delay: 5.5)
    }

    private func layoutChanged(wall: Bool, delay: TimeInterval = 0.70) {
        epoch += 1
        if wall {
            wallpaper = nil
            wallSettlesAfter = max(wallSettlesAfter, now + delay)
        }
        deadline = max(now + delay, wallSettlesAfter)
        nextMetadata = 0
        status = pauses.isEmpty ? "waiting for settled Dock" : "paused"
        update(nil, nil, nil, .zero)
    }

    private func modification(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // The WindowServer poll reads only identifiers, levels, shapes and owners. It
    // doesn't access pixels or start a capture. Regular window insertion/removal
    // covers changes to the minimized-window section without Accessibility access.
    private func metadata(on display: CGDirectDisplayID) -> Metadata? {
        guard let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] else { return nil }
        let bounds = CGDisplayBounds(display)
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var native: CGWindowID?, wall: CGWindowID?
        var windows: Set<CGWindowID> = []
        for row in list {
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let level = row[kCGWindowLayer as String] as? Int,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            if level == 0, rect.width >= 96, rect.height >= 70 { windows.insert(id) }
            guard row[kCGWindowOwnerPID as String] as? pid_t == owner,
                  abs(rect.minX-bounds.minX) <= 1, abs(rect.minY-bounds.minY) <= 1,
                  abs(rect.width-bounds.width) <= 1, abs(rect.height-bounds.height) <= 1 else { continue }
            if level == dockLevel { native = id }
            if level == desktop || level == desktop-1 || (row[kCGWindowName as String] as? String)?.hasPrefix("Wallpaper") == true {
                wall = id
            }
        }
        var pair: Pair?
        if let native, let wall { pair = Pair(display: display, dock: native, wallpaper: wall, bounds: bounds) }
        return Metadata(pair: pair, windowIDs: windows, dockConfig: modification(dockPrefs), wallpaperConfig: modification(wallPrefs))
    }

    // Called by the application's existing presentation timer. Only layout events
    // can arm a screenshot; simply polling never arms one for an unchanged scene.
    func tick() {
        guard started, pauses.isEmpty,
              let screen = NSScreen.screens.first,
              let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        let time = now
        let hoverRect = shelf.isEmpty
            ? CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 55)
            : shelf.insetBy(dx: -9, dy: -5)
        let overDock = hoverRect.contains(NSEvent.mouseLocation)
        if overDock != hovering {
            hovering = overDock
            layoutChanged(wall: false)
        }
        if time >= nextMetadata {
            let allowed = CGPreflightScreenCaptureAccess()
            let current = allowed ? metadata(on: display) : nil
            let old = lastMetadata
            lastMetadata = current
            if permission != allowed || current?.pair != old?.pair || current?.wallpaperConfig != old?.wallpaperConfig {
                layoutChanged(wall: true)
            } else if current?.windowIDs != old?.windowIDs || current?.dockConfig != old?.dockConfig {
                layoutChanged(wall: false)
            }
            permission = allowed
            nextMetadata = time + 3
        }
        guard permission, !hovering, !inFlight, let due = deadline, time >= due,
              let pair = lastMetadata?.pair, pair.display == display else { return }
        deadline = nil
        inFlight = true
        let token = epoch
        let height = min(150.0, screen.frame.height)
        let area = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
        let local = CGRect(x: 0, y: pair.bounds.height-height, width: pair.bounds.width, height: height)
        let scale = screen.backingScaleFactor
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.epoch == token, !self.hovering else { return }
                guard let dockWindow = available.windows.first(where: { $0.windowID == pair.dock }),
                      let wallWindow = available.windows.first(where: { $0.windowID == pair.wallpaper }) else {
                    self.status = "native Dock or wallpaper unavailable"
                    return
                }
                let config = SCStreamConfiguration()
                config.sourceRect = local
                config.width = Int((local.width * scale).rounded())
                config.height = Int((local.height * scale).rounded())
                config.showsCursor = false
                config.capturesAudio = false
                config.shouldBeOpaque = false
                config.backgroundColor = .clear
                config.ignoreShadowsSingleWindow = true
                config.includeChildWindows = false
                config.colorSpaceName = CGColorSpace.sRGB
                if self.wallpaper == nil {
                    let wall = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: wallWindow), configuration: config)
                    guard self.epoch == token else { return }
                    self.wallpaper = wall
                    self.wallpaperUpdates += 1
                }
                let dock = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: dockWindow), configuration: config)
                guard self.epoch == token, let wallpaper = self.wallpaper else { return }
                self.dockUpdates += 1
                self.status = "on-demand snapshots"
                self.update(dock, wallpaper, screen, area)
            } catch {
                // Keep the real Dock visible. The next actual layout change retries.
                if self.epoch == token { self.status = "snapshot unavailable" }
            }
        }
    }
}
