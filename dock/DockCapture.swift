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
    private var watchWindowsUntil: TimeInterval = 0
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
    private var buttonMonitor: Any?
    private var layoutButtonHeld = false
    private var pendingMinimizeWindow: CGWindowID?
    private(set) var titlebarHoverHidden = false
    private(set) var pointerEvents = 0
    private(set) var buttonEvents = 0
    private(set) var titlebarApproaches = 0
    var hidesOverlayForInteraction: Bool { hidesOverlayForMagnification || titlebarHoverHidden }
    private struct HitWindow {
        let id: CGWindowID
        let bounds: CGRect
        let eligible: Bool
    }
    private var titlebarWindows: [HitWindow] = []
    private var dockProcessID: pid_t?
    private struct DockInteraction {
        var originalRegion: CGRect
        var watchUntil: TimeInterval
        var waitForExit = false
    }
    private var dockInteraction: DockInteraction?
    private struct LayoutTransition {
        var quietUntil: TimeInterval
        var previousShape: Data?
        var samples = 0
    }
    private var transition: LayoutTransition?
    private var autoHideFrameReady = false
    private var wasAtRevealEdge = false
    private var dragStart: CGPoint?
    private var draggedDockItem = false
    private var wallpaper: CGImage?
    private var lastMetadata: Metadata?
    private var visibleWindowOwners: Set<pid_t>?
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
        let shadows: [DockBackdrop.Window]
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
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observe(name, in: ws, regularAppsOnly: true) { $0.beginDockTransition() }
        }
        observe(NSWorkspace.didActivateApplicationNotification, in: ws, regularAppsOnly: true) { $0.applicationActivated() }
        buttonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.started, self.pauses.isEmpty, let screen = NSScreen.screens.first else { return }
                self.buttonEvents += 1
                // Use the point of the click even if the pointer has since moved.
                let cgEvent = event.cgEvent
                let point = cgEvent.map {
                    CGPoint(x: $0.location.x, y: screen.frame.maxY - $0.location.y)
                } ?? NSEvent.mouseLocation
                let recipient = cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
                let windowID = CGWindowID(exactly: recipient > 0 ? recipient : Int64(event.windowNumber)) ?? 0
                let pid = pid_t(exactly: cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0) ?? 0
                self.handleLayoutButton(event.type, at: point, on: screen, windowID: windowID,
                                        targetPID: pid, doubleClick: event.clickCount > 1)
            }
        }
        installPointerMonitor()
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
        if let buttonMonitor { NSEvent.removeMonitor(buttonMonitor) }
        buttonMonitor = nil
        layoutButtonHeld = false
        pendingMinimizeWindow = nil
        titlebarWindows.removeAll()
        titlebarHoverHidden = false
        dockProcessID = nil
        dockInteraction = nil
        transition = nil
        watchWindowsUntil = 0
        autoHide = false
        magnification = false
        restoreAfter = nil
        hidesOverlayForMagnification = false
        epoch += 1
        deadline = nil
        wallpaper = nil
        lastMetadata = nil
        visibleWindowOwners = nil
        pauses.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        update(nil, nil, nil, .zero)
    }

    private func pause(_ why: Pause, _ paused: Bool) {
        if paused { pauses.insert(why) } else { pauses.remove(why) }
        layoutButtonHeld = false
        pendingMinimizeWindow = nil
        dockInteraction = nil
        titlebarWindows.removeAll()
        setTitlebarHidden(false)
        layoutChanged(wall: true, delay: 5.5)
    }

    private func beginDockTransition() {
        let quietUntil = now + 0.8
        transition = LayoutTransition(quietUntil: max(transition?.quietUntil ?? 0, quietUntil))
        layoutChanged(wall: false)
    }

    private func handleLayoutButton(_ type: NSEvent.EventType, at point: CGPoint, on screen: NSScreen,
                                    windowID: CGWindowID = 0, targetPID: pid_t = 0,
                                    doubleClick: Bool = false) {
        switch type {
        case .leftMouseDown:
            guard !(magnification && autoHide) else { return }
            let nativeWindow = windowID != 0 && windowID == lastMetadata?.pair?.dock
            let dockTarget = nativeWindow || (targetPID > 0 && targetPID == dockProcessID)
            let region = dockHitRegion(on: screen)
            // A new miniwindow to the right of the divider can already be outside
            // the last measured shelf. The event recipient identifies the native Dock.
            let dockPress = screen.frame.contains(point) && (dockTarget
                ? point.y <= max(region.maxY, screen.frame.minY + estimatedShelfHeight)
                : targetPID == 0 && lastMetadata?.windowIDs.contains(windowID) != true && region.contains(point))
            let minimized = dockPress ? nil : minimizeWindow(at: point, on: screen, doubleClick: doubleClick)
            guard dockPress || minimized != nil else { return }
            if dockPress {
                let pressedTile = CGRect(x: point.x - 12, y: point.y - 10, width: 24, height: 20)
                let wasWaiting = dockInteraction?.waitForExit == true
                dockInteraction = DockInteraction(originalRegion: region.union(pressedTile),
                                                  watchUntil: now + 2.2, waitForExit: wasWaiting)
            } else {
                dockInteraction = nil
            }
            pendingMinimizeWindow = minimized
            layoutButtonHeld = true
        case .leftMouseUp where layoutButtonHeld:
            layoutButtonHeld = false
            dockInteraction?.watchUntil = now + 2.2
        default:
            return
        }
        watchWindowsUntil = max(watchWindowsUntil, now + 2.2)
        beginDockTransition()
    }

    // Input event recipients can be the Dock's full-screen backing or a
    // screen-sharing control. Resolve the ordered window geometry beneath them.
    private func minimizeWindow(at point: CGPoint, on screen: NSScreen, doubleClick: Bool) -> CGWindowID? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
            as? [[String: Any]] else { return nil }
        titlebarWindows = hitWindows(from: rows)
        let quartzPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        return titlebarWindow(at: quartzPoint, doubleClick: doubleClick)?.id
    }

    private func hitWindows(from rows: [[String: Any]]) -> [HitWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID, pid != dockProcessID,
                  let level = row[kCGWindowLayer as String] as? Int, level >= 0, level < dockLevel,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), !bounds.isEmpty else { return nil }
            let eligible = level == 0 && bounds.width >= 96 && bounds.height >= 70 &&
                NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            return HitWindow(id: id, bounds: bounds, eligible: eligible)
        }
    }

    private func titlebarWindow(at point: CGPoint, doubleClick: Bool = false) -> HitWindow? {
        // The list is front to back. An overlying window blocks a button behind
        // it, even if that overlying window has no standard title bar.
        guard let window = titlebarWindows.first(where: { $0.bounds.contains(point) }),
              window.eligible else { return nil }
        let x = point.x - window.bounds.minX
        let y = point.y - window.bounds.minY
        // Include the whole controls cluster, whose position changes with unified
        // toolbars and screen-sharing controls. A double titlebar click can also
        // minimize a window according to the user's macOS settings.
        guard y <= (doubleClick ? 42 : 64), doubleClick || x <= 128 else { return nil }
        return window
    }

    private func setTitlebarHidden(_ hidden: Bool) {
        guard titlebarHoverHidden != hidden else { return }
        titlebarHoverHidden = hidden
        if hidden { titlebarApproaches += 1 }
        // A passive approach changes only presentation. The cached mask is still
        // valid, and is reused immediately when the pointer leaves without a click.
        onMagnificationVisibilityChange()
    }

    private func trackTitlebarPointer(on screen: NSScreen) {
        let point = NSEvent.mouseLocation
        let quartzPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        let candidate = titlebarWindow(at: quartzPoint)
        setTitlebarHidden(candidate != nil)
        if candidate != nil, !layoutButtonHeld, NSEvent.pressedMouseButtons & 1 != 0 {
            handleLayoutButton(.leftMouseDown, at: point, on: screen)
        }
    }

    private func installPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching:
            [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started, self.pauses.isEmpty,
                      let screen = NSScreen.screens.first else { return }
                self.pointerEvents += 1
                self.trackTitlebarPointer(on: screen)
                if self.autoHide != self.magnification { self.trackPointer(on: screen) }
            }
        }
    }

    private func applicationActivated() {
        guard pauses.isEmpty else { return }
        watchWindowsUntil = max(watchWindowsUntil, now + 1.8)
        nextMetadata = 0
        // A running app can be reopened with every window minimized. Activation
        // may arrive before its first restored window appears in WindowServer.
        let activatedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hadNoVisibleWindow = activatedPID.flatMap { visibleWindowOwners?.contains($0) } == false
        if transition != nil || hadNoVisibleWindow { beginDockTransition() }
        tick()
    }

    private func layoutChanged(wall: Bool, delay: TimeInterval = 0.70) {
        epoch += 1
        autoHideFrameReady = false
        if let pending = transition {
            transition = LayoutTransition(quietUntil: max(pending.quietUntil, now + delay))
        }
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
        deadline = (magnification && autoHide) ? nil : max(now + delay, wallSettlesAfter, autoHideSettlesAfter, transition?.quietUntil ?? 0)
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
        readDockGeometry()
        installPointerMonitor()
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

    private func dockHitRegion(on screen: NSScreen) -> CGRect {
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
        return region
    }

    private func trackPointer(on screen: NSScreen, mayRestore: Bool = false) {
        let point = NSEvent.mouseLocation
        let region = dockHitRegion(on: screen)
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
        dockProcessID = owner
        titlebarWindows = hitWindows(from: list)
        let bounds = CGDisplayBounds(display)
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let strip = CGRect(x: bounds.minX, y: max(bounds.minY, bounds.maxY - 150), width: bounds.width, height: min(150, bounds.height))
        let activeOwner = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var shadows: [DockBackdrop.Window] = []
        var native: CGWindowID?, wall: CGWindowID?
        var windows: Set<CGWindowID> = []
        var owners: Set<pid_t> = []
        for row in list {
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let level = row[kCGWindowLayer as String] as? Int,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            if (0..<dockLevel).contains(level), !rect.isEmpty, DockBackdrop.nearby(rect, strip: strip),
               (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
                shadows.append(DockBackdrop.Window(id: id, frame: rect, activeOwner: (row[kCGWindowOwnerPID as String] as? pid_t) == activeOwner))
            }
            if level == 0, rect.width >= 96, rect.height >= 70 {
                windows.insert(id)
                if let pid = row[kCGWindowOwnerPID as String] as? pid_t { owners.insert(pid) }
            }
            guard row[kCGWindowOwnerPID as String] as? pid_t == owner,
                  abs(rect.minX-bounds.minX) <= 1, abs(rect.minY-bounds.minY) <= 1,
                  abs(rect.width-bounds.width) <= 1, abs(rect.height-bounds.height) <= 1 else { continue }
            if level == dockLevel { native = id }
            if level == desktop || level == desktop-1 || (row[kCGWindowName as String] as? String)?.hasPrefix("Wallpaper") == true {
                wall = id
            }
        }
        visibleWindowOwners = owners
        var pair: Pair?
        if let native, let wall { pair = Pair(display: display, dock: native, wallpaper: wall, bounds: bounds) }
        return Metadata(pair: pair, windowIDs: windows, shadows: shadows, dockConfig: modification(dockPrefs), wallpaperConfig: modification(wallPrefs))
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
        if layoutButtonHeld && NSEvent.pressedMouseButtons & 1 == 0 {
            handleLayoutButton(.leftMouseUp, at: NSEvent.mouseLocation, on: screen)
        }
        let verifyingNow = transition != nil && !layoutButtonHeld && dockInteraction?.waitForExit != true &&
            (pendingMinimizeWindow == nil || time >= watchWindowsUntil) && time >= (deadline ?? .infinity)
        if time >= nextMetadata || verifyingNow {
            let allowed = CGPreflightScreenCaptureAccess()
            let current = allowed ? metadata(on: display) : nil
            let old = lastMetadata
            let shadowsChanged = current?.shadows != old?.shadows
            if shadowsChanged { wallpaper = nil }
            lastMetadata = current
            if (autoHide || magnification) && (old == nil || current?.dockConfig != old?.dockConfig) { readDockGeometry() }
            if permission != allowed || current?.pair != old?.pair || current?.wallpaperConfig != old?.wallpaperConfig {
                layoutChanged(wall: true)
            } else if current?.windowIDs != old?.windowIDs {
                if let interaction = dockInteraction, (layoutButtonHeld || time <= interaction.watchUntil),
                   interaction.originalRegion.contains(NSEvent.mouseLocation) {
                    // A miniwindow was inserted or removed while the pointer was
                    // still over the old tiles. Dock can shift them again on exit.
                    dockInteraction?.waitForExit = true
                }
                beginDockTransition()
            } else if shadowsChanged || current?.dockConfig != old?.dockConfig {
                layoutChanged(wall: false)
            }
            permission = allowed
            nextMetadata = time + (time < watchWindowsUntil ? 0.35 : 3)
        }
        trackTitlebarPointer(on: screen)
        trackPointer(on: screen, mayRestore: true)
        if let interaction = dockInteraction {
            if interaction.waitForExit {
                guard !interaction.originalRegion.contains(NSEvent.mouseLocation) else { return }
                dockInteraction = nil
                beginDockTransition()
                return
            } else if !layoutButtonHeld && time >= interaction.watchUntil {
                dockInteraction = nil
            }
        }
        if let pendingMinimizeWindow {
            // NSWindow can remain onscreen as its sheet shrinks. A click can also
            // be cancelled, so snapshot again after a bounded wait in that case.
            if time < watchWindowsUntil && lastMetadata?.windowIDs.contains(pendingMinimizeWindow) == true { return }
            self.pendingMinimizeWindow = nil
        }
        guard permission, !layoutButtonHeld, NSEvent.pressedMouseButtons & 1 == 0, !inFlight, !hidesOverlayForInteraction, !autoHide || hovering, let deadline, time >= deadline,
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
                    guard let desktop = available.displays.first(where: { $0.displayID == display }),
                          let shadows = self.lastMetadata?.shadows,
                          let wall = try await DockBackdrop.capture(display: desktop, wallpaper: wallWindow,
                              windows: shadows, available: available.windows,
                              strip: local.offsetBy(dx: pair.bounds.minX, dy: pair.bounds.minY), scale: scale,
                              isCurrent: { self.canFinishCapture(token, on: screen) }) else { return }
                    guard self.canFinishCapture(token, on: screen) else { return }
                    // A window can move while the cropped desktop images are in flight.
                    guard self.metadata(on: display)?.shadows == shadows else {
                        self.layoutChanged(wall: false)
                        return
                    }
                    self.wallpaper = wall
                    self.wallpaperUpdates += 1
                }
                let dock = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: dockWindow), configuration: config)
                guard self.canFinishCapture(token, on: screen), let wallpaper = self.wallpaper else { return }
                self.dockUpdates += 1
                if self.transition != nil {
                    let shape = await DockLayoutSample.geometry(of: dock, wallpaper: wallpaper, scale: scale)
                    guard self.canFinishCapture(token, on: screen), self.layoutIsStable(shape) else { return }
                }
                self.status = "on-demand snapshots"
                self.update(dock, wallpaper, screen, area)
            } catch {
                // Keep the real Dock visible. The next actual layout change retries.
                if self.epoch == token {
                    if self.transition != nil { _ = self.layoutIsStable(nil) }
                    else { self.status = "snapshot unavailable" }
                }
            }
        }
    }

    // Two successive Dock-only samples must agree before the cached artwork can
    // be placed between tiles again. A continuously changing Dock stays native.
    private func layoutIsStable(_ shape: Data?) -> Bool {
        guard var pending = transition else { return true }
        if let shape, pending.previousShape == shape {
            transition = nil
            return true
        }
        pending.previousShape = shape
        pending.samples += 1
        transition = pending
        if pending.samples < 8 {
            deadline = now + (pending.samples < 4 ? 0.18 : 1.3)
            status = "checking Dock layout"
        } else {
            deadline = nil
            status = "native Dock while layout is changing"
        }
        return false
    }

    private func canFinishCapture(_ token: Int, on screen: NSScreen) -> Bool {
        refreshMode()
        if magOnVisibleDock { trackPointer(on: screen) }
        return started && epoch == token && !layoutButtonHeld && !hidesOverlayForMagnification
    }
}
