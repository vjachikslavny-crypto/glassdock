import AppKit
import CoreGraphics
import ServiceManagement

private let appName = "GlassDock Dock"
private let outputLevel = CGWindowLevelForKey(.dockWindow) + 1

private final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(outputLevel))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class DockGlass: NSObject, NSApplicationDelegate {
    private let panel = GlassPanel()
    private let worker = DispatchQueue(label: "local.dockglass.mask", qos: .userInitiated)
    private typealias Frame = (dock: CGImage, wallpaper: CGImage, area: CGRect)
    private var latest: Frame?
    private var rendering = false
    private var generation = 0
    private var capture: DockCapture?
    private var permissionPoll: Timer?
    private var presentationPoll: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var lastWindowCheck: TimeInterval = 0
    private var covered = false
    private var clippedRegions: [CGRect] = []
    private var appliedRegions: [CGRect]?
    private var lastGood: (image: CGImage, area: CGRect, scale: CGFloat, shelf: CGRect)?
    private var triedQuartz = false
    private var triedComposite = false
    private var compositions: UInt64 = 0
    private var previousCounters = ""
    private let counterFile: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--measure-to"), args.indices.contains(i+1) else { return nil }
        return URL(fileURLWithPath: args[i+1])
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CGPreflightScreenCaptureAccess() {
            start()
        } else {
            // Ask exactly on the first interactive launch. macOS owns the grant prompt.
            if !UserDefaults.standard.bool(forKey: "didRequestCapture") {
                UserDefaults.standard.set(true, forKey: "didRequestCapture")
                _ = CGRequestScreenCaptureAccess()
            }
            waitForPermission()
        }
    }

    private func waitForPermission() {
        guard permissionPoll == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard CGPreflightScreenCaptureAccess() else { return }
                self?.permissionPoll?.invalidate()
                self?.permissionPoll = nil
                self?.start()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    private func start() {
        guard capture == nil else { return }
        let component = DockCapture { [weak self] dock, wallpaper, screen, area in
            guard let self else { return }
            guard let dock, let wallpaper, screen != nil, !area.isEmpty,
                  dock.width == wallpaper.width, dock.height == wallpaper.height else {
                self.flush()
                return
            }
            self.latest = (dock, wallpaper, area)
            self.consume()
        }
        capture = component
        component.start()
        let workspace = NSWorkspace.shared.notificationCenter
        let windowChanges = [NSWorkspace.didActivateApplicationNotification,
                             NSWorkspace.activeSpaceDidChangeNotification,
                             NSWorkspace.didHideApplicationNotification,
                             NSWorkspace.didUnhideApplicationNotification,
                             NSWorkspace.didTerminateApplicationNotification]
        windowObservers = windowChanges.map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePresentation(forceWindowCheck: true) }
            }
        }
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePresentation() }
        }
        timer.tolerance = 0.10
        RunLoop.main.add(timer, forMode: .common)
        presentationPoll = timer
    }

    private func flush() {
        generation += 1
        latest = nil
        lastGood = nil
        appliedRegions = nil
        panel.orderOut(nil)
    }

    private func consume() {
        guard !rendering, let frame = latest else { return }
        rendering = true
        latest = nil
        let token = generation
        let scale = CGFloat(frame.dock.width)/frame.area.width
        let state = capture?.status ?? ""
        let kind = state.contains("composite") ? "composite" : (state.contains("Quartz") ? "quartz" : "stream")
        let area = frame.area
        let dock = frame.dock
        let wallpaper = frame.wallpaper
        worker.async { [weak self] in
            var measured = CGRect.zero
            let result = autoreleasepool { DockMask.compose(dock: dock, wallpaper: wallpaper, scale: scale, onShelf: { measured = $0 }) }
            let shelf = CGRect(x: area.minX+measured.minX/scale, y: area.maxY-measured.maxY/scale,
                               width: measured.width/scale, height: measured.height/scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                if token == self.generation {
                    self.compositions &+= 1
                    let geometryChanged = self.lastGood?.shelf != shelf
                    self.lastGood = result.map { ($0, area, scale, shelf) }
                    if geometryChanged && result != nil { self.checkWindows(in: area, shelf: shelf) }
                    if result == nil && !self.triedQuartz && kind == "stream" {
                        self.triedQuartz = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+1.0) { [weak self] in
                            guard let self, self.lastGood == nil else { return }
                            self.capture?.retryUsingQuartzCrops()
                        }
                    }
                    if result == nil && !self.triedComposite && kind == "quartz" {
                        self.triedComposite = true
                        DispatchQueue.main.asyncAfter(deadline: .now()+0.8) { [weak self] in
                            guard let self, self.lastGood == nil else { return }
                            self.capture?.retryUsingWallpaperComposite()
                        }
                    }
                    self.present()
                }
                self.consume()
            }
        }
    }

    private func updatePresentation(forceWindowCheck: Bool = false) {
        if let counterFile, let capture {
            let counters = "wall=\(capture.wallpaperUpdates) dock=\(capture.dockUpdates) rendered=\(compositions) visible=\(panel.isVisible) mode=\(capture.status)\n"
            if counters != previousCounters,
               (try? counters.write(to: counterFile, atomically: true, encoding: .utf8)) != nil {
                previousCounters = counters
            }
        }
        guard let sample = lastGood else { return }
        // Recheck quickly during a window drag and just after release. Typing or
        // simply moving the pointer need not enumerate every window on the desktop.
        if !forceWindowCheck && ProcessInfo.processInfo.systemUptime - lastWindowCheck < 3 &&
            NSEvent.pressedMouseButtons == 0 &&
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) > 0.8 {
            return
        }
        let wasCovered = covered
        checkWindows(in: sample.area, shelf: sample.shelf)
        if wasCovered != covered || appliedRegions != clippedRegions { present() }
    }

    private func checkWindows(in area: CGRect, shelf: CGRect) {
        lastWindowCheck = ProcessInfo.processInfo.systemUptime
        covered = true
        guard let main = NSScreen.screens.first, !NSApp.currentSystemPresentationOptions.contains(.fullScreen),
              NSEvent.pressedMouseButtons == 0 || !shelf.insetBy(dx: -4, dy: -12).contains(NSEvent.mouseLocation),
              let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
                as? [[String: Any]] else { return }
        var regions: [CGRect] = []
        for row in wins {
            guard let level = row[kCGWindowLayer as String] as? Int, level >= 0, level < Int(outputLevel)-1,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let frame = CGRect(x: rect.minX, y: main.frame.maxY-rect.maxY, width: rect.width, height: rect.height)
            if frame.intersects(shelf.insetBy(dx: 3, dy: 3)) { return }
            let overlap = area.intersection(frame)
            if !overlap.isEmpty { regions.append(overlap.offsetBy(dx: -area.minX, dy: -area.minY)) }
        }
        covered = false
        clippedRegions = regions
    }

    private func present() {
        guard !covered, let info = lastGood, let layer = panel.contentView?.layer else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != info.area {
            panel.setFrame(info.area, display: false)
            appliedRegions = nil
        }
        if appliedRegions != clippedRegions {
            if clippedRegions.isEmpty { layer.mask = nil }
            else {
                let full = CGRect(origin: .zero, size: info.area.size)
                let windows = CGMutablePath()
                for rect in clippedRegions { windows.addRect(rect) }
                let cutout = CAShapeLayer()
                cutout.frame = full
                cutout.path = CGPath(rect: full, transform: nil).subtracting(windows)
                layer.mask = cutout
            }
            appliedRegions = clippedRegions
        }
        layer.contentsScale = info.scale
        layer.contents = info.image
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        let alert = NSAlert()
        alert.messageText = appName
        let russian = Bundle.preferredLocalizations(from: ["en", "ru"]).first == "ru"
        alert.informativeText = russian
            ? "Обои видны между значками, пока за Dock находится рабочий стол. Управление автозапуском доступно в GlassDock."
            : "Your wallpaper appears between the icons when the desktop is behind the Dock. Manage launch at login in GlassDock."
        alert.addButton(withTitle: russian ? "Готово" : "Done")
        alert.addButton(withTitle: russian ? "Завершить" : "Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        presentationPoll?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in windowObservers { workspace.removeObserver(token) }
        windowObservers.removeAll()
        capture?.stop()
        flush()
    }
}

if CommandLine.arguments.contains("--login-status") {
    print(SMAppService.mainApp.status.rawValue)
    exit(0)
}
if CommandLine.arguments.contains("--login") {
    do {
        if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
        print(SMAppService.mainApp.status.rawValue)
        exit(0)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}
let application = NSApplication.shared
private let owner = MainActor.assumeIsolated { DockGlass() }
application.setActivationPolicy(.accessory)
application.delegate = owner
application.run()
