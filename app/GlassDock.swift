import AppKit
import Darwin
import ServiceManagement
import SwiftUI

private func tr(_ russian: String, _ english: String) -> String {
    Bundle.preferredLocalizations(from: ["en", "ru"]).first == "ru" ? russian : english
}

private enum Effect: String, CaseIterable, Identifiable {
    case menu, dock
    var id: Self { self }
    var title: String { self == .menu ? tr("Строка меню", "Menu bar") : "Dock" }
    var helper: String { self == .menu ? "Sheer" : "GlassDock Dock" }
    var bundleID: String { self == .menu ? "io.github.sheer.Sheer" : "local.mac.dockglass" }
    var preference: String { "Restore." + rawValue }
    var supported: Bool { self != .menu || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 }
    var detail: String {
        if !supported { return tr("В этой версии macOS уже есть прозрачная строка меню.", "This version of macOS already has a transparent menu bar.") }
        if self == .menu { return tr("Обои за меню и системными значками.", "Show the wallpaper behind menus and status icons.") }
        return tr("Обои между значками нижнего Dock.", "Show the wallpaper between icons in the bottom Dock.")
    }
    func runningApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }
}

private struct ControlError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private enum Helpers {
    static func matches(_ effect: Effect, at url: URL) -> Bool {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == effect.bundleID,
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    // A previously installed helper retains its identity and permission grants.
    // The managed copy is independent of the enclosing app and of Sheer's updater.
    static func application(for effect: Effect) throws -> URL {
        let files = FileManager.default
        let names = effect == .dock ? ["Прозрачный Dock.app", "GlassDock Dock.app"] : ["Sheer.app"]
        for directory in files.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask]) {
            for name in names {
                let url = directory.appendingPathComponent(name, isDirectory: true)
                if matches(effect, at: url) { return url }
            }
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(effect.helper).app", isDirectory: true)
        guard matches(effect, at: bundled) else {
            throw ControlError(tr("В пакете GlassDock отсутствует \(effect.helper). Установите GlassDock заново.",
                                  "\(effect.helper) is missing from the GlassDock bundle. Reinstall GlassDock."))
        }
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("GlassDock/Helpers", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(effect.helper + ".app", isDirectory: true)
        let lock = Darwin.open(directory.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if matches(effect, at: dest) {
            let oldBuild = Bundle(url: dest)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            let newBuild = Bundle(url: bundled)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            if oldBuild.compare(newBuild, options: .numeric) != .orderedAscending { return dest }
        }

        let staged = directory.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
        defer { try? files.removeItem(at: staged) }
        try files.copyItem(at: bundled, to: staged)
        guard matches(effect, at: staged) else { throw CocoaError(.fileReadCorruptFile) }
        if files.fileExists(atPath: dest.path) {
            _ = try files.replaceItemAt(dest, withItemAt: staged)
        } else {
            try files.moveItem(at: staged, to: dest)
        }
        return dest
    }

    @MainActor static func start(_ effect: Effect) async throws {
        guard effect.supported, effect.runningApps().isEmpty else { return }
        let url = try await Task.detached { try application(for: effect) }.value
        guard effect.runningApps().isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    @MainActor static func stop(_ effect: Effect) async throws {
        let apps = effect.runningApps()
        for app in apps where !app.isTerminated {
            if !app.terminate() && !app.isTerminated {
                throw ControlError(tr("Закройте \(effect.helper) через его меню.", "Quit \(effect.helper) from its own menu."))
            }
        }
        for _ in 0..<30 {
            if effect.runningApps().isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlError(tr("\(effect.helper) ещё завершает работу. Проверьте, нет ли открытого диалога.",
                              "\(effect.helper) is still quitting. Check for an open dialog."))
    }

    @MainActor static func restoreSelected() async {
        for effect in Effect.allCases where UserDefaults.standard.bool(forKey: effect.preference) {
            do { try await start(effect) }
            catch { NSLog("GlassDock %@: %@", effect.helper, error.localizedDescription) }
        }
    }
}

@MainActor
private final class Controls: ObservableObject {
    @Published var running: Set<Effect> = []
    @Published var busy: Set<Effect> = []
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var failure: String?
    private let service = SMAppService.agent(plistName: "app.glassdock.restore.plist")

    func refresh() {
        running = Set(Effect.allCases.filter { !$0.runningApps().isEmpty })
        let status = service.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    func set(_ effect: Effect, to value: Bool) async {
        guard !busy.contains(effect) else { return }
        busy.insert(effect)
        defer { busy.remove(effect); refresh() }
        do {
            if value { try await Helpers.start(effect) } else { try await Helpers.stop(effect) }
            UserDefaults.standard.set(value, forKey: effect.preference)
        } catch {
            failure = error.localizedDescription
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                let active = Set(Effect.allCases.filter { !$0.runningApps().isEmpty })
                for effect in Effect.allCases { UserDefaults.standard.set(active.contains(effect), forKey: effect.preference) }
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

private struct EdgeIcon: View {
    let effect: Effect
    var body: some View {
        ZStack(alignment: effect == .menu ? .top : .bottom) {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.6)
            Capsule().fill(Color.accentColor)
                .frame(width: effect == .menu ? 24 : 15, height: 3)
                .padding(.vertical, 4)
        }
        .frame(width: 32, height: 24)
        .accessibilityHidden(true)
    }
}

private struct ControlView: View {
    @StateObject private var controls = Controls()
    @Environment(\.scenePhase) private var scenePhase
    let activity = NSWorkspace.shared.notificationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GlassDock").font(.system(size: 29, weight: .semibold))
                Text(tr("Выбери, где будут видны обои.", "Choose where to show your wallpaper."))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Effect.allCases) { effect in
                    if effect != .menu { Divider().padding(.leading, 64) }
                    HStack(spacing: 16) {
                        EdgeIcon(effect: effect)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(effect.title).font(.headline)
                            Text(effect.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if controls.busy.contains(effect) { ProgressView().controlSize(.small) }
                        Toggle(effect.title, isOn: Binding(
                            get: { controls.running.contains(effect) },
                            set: { value in Task { await controls.set(effect, to: value) } }
                        ))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(controls.busy.contains(effect) || (!effect.supported && !controls.running.contains(effect)))
                        .accessibilityIdentifier(effect.rawValue + "-toggle")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 15)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 1))
            Toggle(tr("Запускать выбранные эффекты при входе", "Start selected effects at login"),
                   isOn: Binding(get: { controls.loginEnabled }, set: { controls.setLogin($0) }))
                .disabled((controls.running.isEmpty && !controls.loginEnabled) || !controls.busy.isEmpty)
            if controls.loginNeedsApproval {
                Button(tr("Разрешить в настройках объектов входа…", "Allow in Login Items settings…")) {
                    SMAppService.openSystemSettingsLoginItems()
                }.buttonStyle(.link)
            }
            Divider()
            HStack {
                Menu(tr("Разрешения macOS", "macOS permissions")) {
                    Button(tr("Запись экрана…", "Screen Recording…")) { settings("Privacy_ScreenCapture") }
                    Button(tr("Универсальный доступ для Sheer…", "Accessibility for Sheer…")) { settings("Privacy_Accessibility") }
                }.fixedSize()
                Spacer()
                Button(tr("Объекты входа…", "Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { controls.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { controls.refresh() } }
        .onReceive(activity.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in controls.refresh() }
        .onReceive(activity.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in controls.refresh() }
        .alert(tr("GlassDock не смог выполнить действие", "GlassDock couldn’t complete the action"), isPresented: Binding(
            get: { controls.failure != nil }, set: { if !$0 { controls.failure = nil } }
        )) {
            Button("OK") { controls.failure = nil }
        } message: { Text(controls.failure ?? "") }
    }

    private func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("GlassDock", id: "controls") { ControlView() }
            .windowResizability(.contentSize)
            .defaultPosition(.center)
    }
}

@main
private enum GlassDockEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--restore-at-login") {
            await Helpers.restoreSelected()
            return
        }
        ControlApp.main()
    }
}
