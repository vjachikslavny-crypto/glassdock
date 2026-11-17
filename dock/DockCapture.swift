import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Explicitly requested one-shot images of the native Dock and its wallpaper backing.
/// With no changes in the desktop or Dock layout there is no image capture at all.
@MainActor
final class DockCapture {
    typealias Update = (CGImage?, CGImage?, NSScreen?, CGRect) -> Void
    private let update: Update
    private let onMagnificationVisibilityChange: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private enum Pause { case system, display, session }
    private var pauses: Set<Pause> = []
    private var started = false
    private var epoch = 0
    private var inFlight = false
    private var deadline: TimeInterval?
    private var nextMetadata: TimeInterval = 0
    private var wallSettlesAfter: TimeInterval = 0
    private(set) var hovering = false
    private var magnification = false
    private var autoHide = false
    private var autoHideSettle: TimeInterval = 1.2
    private var autoHideSettlesAfter: TimeInterval = 0
    private var estimatedShelfHeight: CGFloat = 55
    private var tileSize: CGFloat = 48
    private var largeTileSize: CGFloat = 64
    private var restoreAfter: TimeInterval?
    private(set) var hidesOverlayForMagnification = false
    private var pointerMonitor: Any?
    private var autoHideFrameReady = false
    private var wasAtRevealEdge = false
    private var dragStart: CGPoint?
    private var draggedDockItem = false
    private var wallpaper: CGImage?
    private var lastMetadata: Metadata?
    private var permission = false

    private(set) var status = "idle snapshots"
    private(set) var wallpaperUpdates = 0
    private(set) var dockUpdates = 0
    var shelf = CGRect.zero {
        didSet {
            autoHideFrameReady = !shelf.isEmpty
            if magOnVisibleDock, !hidesOverlayForMagnification, !shelf.isEmpty,
               shelf.insetBy(dx: -9, dy: -5).contains(NSEvent.mouseLocation) {
                hovering = true
                setMagnificationHidden(true)
            }
        }
    }

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

    init(onMagnificationVisibilityChange: @escaping () -> Void = {}, onUpdate: @escaping Update) {
        self.onMagnificationVisibilityChange = onMagnificationVisibilityChange
        update = onUpdate
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var magOnVisibleDock: Bool { magnification && !autoHide }

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
        observe(Notification.Name("com.apple.dock.prefchanged"), in: distributed) { $0.tick() }
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
        removePointerMonitor()
        autoHide = false
        magnification = false
        restoreAfter = nil
        hidesOverlayForMagnification = false
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
        autoHideFrameReady = false
        if wall {
            wallpaper = nil
            shelf = .zero
            hovering = false
            wasAtRevealEdge = false
            dragStart = nil
            draggedDockItem = false
            wallSettlesAfter = max(wallSettlesAfter, now + delay)
        }
        if magOnVisibleDock { shelf = .zero }
        deadline = (magnification && autoHide) ? nil : max(now + delay, wallSettlesAfter, autoHideSettlesAfter)
        nextMetadata = 0
        if hidesOverlayForMagnification { status = "native Dock (magnification)" }
        else { status = pauses.isEmpty ? "waiting for settled Dock" : "paused" }
        update(nil, nil, nil, .zero)
    }

    private func modification(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func readDockGeometry() {
        let settings = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        let delay = settings["autohide-delay"] as? Double ?? 0.5
        let duration = settings["autohide-time-modifier"] as? Double ?? 0.5
        autoHideSettle = max(0.25, max(0, delay) + max(0, duration) + 0.2)
        tileSize = CGFloat(settings["tilesize"] as? Double ?? 48)
        largeTileSize = max(tileSize, CGFloat(settings["largesize"] as? Double ?? 64))
        estimatedShelfHeight = max(55, tileSize + 20)
    }

    private func removePointerMonitor() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    // Read just the two effective preferences. Plist writes can lag the actual
    // settings, especially while System Settings is still open.
    private func refreshMode() {
        guard started else { return }
        let domain = "com.apple.dock" as CFString
        let magnifies = CFPreferencesGetAppBooleanValue("magnification" as CFString, domain, nil)
        let hides = CFPreferencesGetAppBooleanValue("autohide" as CFString, domain, nil)
        guard magnification != magnifies || autoHide != hides else { return }
        magnification = magnifies
        autoHide = hides
        autoHideSettlesAfter = 0
        removePointerMonitor()
        if autoHide != magnification {
            readDockGeometry()
            // The native animation begins between presentation ticks. Hide on
            // the pointer event itself; this path never requests a screenshot.
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.started, self.pauses.isEmpty,
                          let screen = NSScreen.screens.first else { return }
                    self.trackPointer(on: screen)
                }
            }
        }
        layoutChanged(wall: true)
        restoreAfter = nil
        if let screen = NSScreen.screens.first { trackPointer(on: screen) }
    }

    private func setMagnificationHidden(_ hidden: Bool) {
        guard hidesOverlayForMagnification != hidden else { return }
        hidesOverlayForMagnification = hidden
        if hidden {
            epoch += 1
            // A capture invalidated halfway through must be retried at rest.
            if inFlight && deadline == nil && !autoHide { deadline = now }
            status = "native Dock (magnification)"
        } else {
            status = deadline == nil ? "on-demand snapshots" : "waiting for settled Dock"
        }
        onMagnificationVisibilityChange()
    }

    private func trackPointer(on screen: NSScreen, mayRestore: Bool = false) {
        let point = NSEvent.mouseLocation
        var region = shelf.isEmpty
            ? CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                     height: magOnVisibleDock ? max(estimatedShelfHeight, largeTileSize + 16) : estimatedShelfHeight)
            : (autoHide ? shelf : shelf.insetBy(dx: -9, dy: -5))
        if magOnVisibleDock && (hovering || hidesOverlayForMagnification) && !shelf.isEmpty {
            // Keep the patch hidden as the cursor rides a growing outer tile
            // beyond the resting shelf horizontally or vertically.
            region = region.insetBy(dx: -max(0, largeTileSize - tileSize), dy: 0)
            region.size.height = max(region.height, screen.frame.minY + largeTileSize + 16 - region.minY)
        }
        let atRevealEdge = autoHide && screen.frame.contains(point) && point.y - screen.frame.minY < 3 &&
            point.x >= region.minX && point.x <= region.maxX
        let overDock = (screen.frame.contains(point) && region.contains(point)) || atRevealEdge
        let enteredOrLeft = hovering != overDock
        let reachedEdge = atRevealEdge && !wasAtRevealEdge
        hovering = overDock
        wasAtRevealEdge = atRevealEdge

        if magnification && (overDock || autoHide) {
            if restoreAfter != nil { status = "native Dock (magnification)" }
            restoreAfter = nil
            setMagnificationHidden(true)
        } else if magOnVisibleDock && hidesOverlayForMagnification {
            if let restoreAfter {
                if mayRestore && now >= restoreAfter {
                    self.restoreAfter = nil
                    setMagnificationHidden(false)
                }
            } else {
                // Keep the cached mask off until native tiles are back at rest.
                restoreAfter = now + 0.45
                nextMetadata = 0
                status = "waiting for icons to settle"
            }
        } else {
            setMagnificationHidden(false)
        }

        if NSEvent.pressedMouseButtons & 1 != 0 {
            if let start = dragStart {
                if hypot(point.x - start.x, point.y - start.y) > 4 { draggedDockItem = true }
            } else if overDock {
                dragStart = point
            }
        } else if dragStart != nil {
            dragStart = nil
            if draggedDockItem {
                draggedDockItem = false
                layoutChanged(wall: false, delay: 0.25)
            }
        }

        if autoHide && !magnification && (enteredOrLeft || (reachedEdge && !autoHideFrameReady)) {
            autoHideSettlesAfter = now + autoHideSettle
            layoutChanged(wall: false, delay: autoHideSettle)
        }
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
        guard started, pauses.isEmpty else { return }
        refreshMode()
        guard !(magnification && autoHide),
              let screen = NSScreen.screens.first,
              let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        let time = now
        if time >= nextMetadata {
            let allowed = CGPreflightScreenCaptureAccess()
            let current = allowed ? metadata(on: display) : nil
            let old = lastMetadata
            lastMetadata = current
            if (autoHide || magnification) && (old == nil || current?.dockConfig != old?.dockConfig) { readDockGeometry() }
            if permission != allowed || current?.pair != old?.pair || current?.wallpaperConfig != old?.wallpaperConfig {
                layoutChanged(wall: true)
            } else if current?.windowIDs != old?.windowIDs || current?.dockConfig != old?.dockConfig {
                layoutChanged(wall: false)
            }
            permission = allowed
            nextMetadata = time + 3
        }
        trackPointer(on: screen, mayRestore: true)
        guard permission, !inFlight, !hidesOverlayForMagnification, !autoHide || hovering, let deadline, time >= deadline,
              let pair = lastMetadata?.pair, pair.display == display else { return }
        self.deadline = nil
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
                guard self.canFinishCapture(token, on: screen) else { return }
                let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.canFinishCapture(token, on: screen) else { return }
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
                    guard self.canFinishCapture(token, on: screen) else { return }
                    self.wallpaper = wall
                    self.wallpaperUpdates += 1
                }
                let dock = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: dockWindow), configuration: config)
                guard self.canFinishCapture(token, on: screen), let wallpaper = self.wallpaper else { return }
                self.dockUpdates += 1
                self.status = "on-demand snapshots"
                self.update(dock, wallpaper, screen, area)
            } catch {
                // Keep the real Dock visible. The next actual layout change retries.
                if self.epoch == token { self.status = "snapshot unavailable" }
            }
        }
    }

    private func canFinishCapture(_ token: Int, on screen: NSScreen) -> Bool {
        refreshMode()
        if magOnVisibleDock { trackPointer(on: screen) }
        return started && epoch == token && !hidesOverlayForMagnification
    }
}
