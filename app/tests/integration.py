"""Run macOS integration checks with disposable, UI-less helper applications."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def app(directory, name, executable, identifier, binary, background=True):
    import shutil
    result = directory / (name + ".app")
    target = result / "Contents" / "MacOS"
    target.mkdir(parents=True)
    shutil.copy2(binary, target / executable)
    info = {"CFBundleName": name, "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier, "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL", "LSUIElement": background}
    with (result / "Contents/Info.plist").open("wb") as f:
        plistlib.dump(info, f)
    return result


helper_code = """
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
"""

test_entry = """
@main
private enum Checks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controls = Controls()

        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ControlError(message) }
        }
        func checkState(_ expected: Set<Effect>, _ message: String) async throws {
            for _ in 0..<40 {
                controls.refresh()
                if controls.running == expected && controls.failure == nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ControlError("\\(message): \\(controls.running), error=\\(String(describing: controls.failure))")
        }
        do {
            try await checkState([], "Clean launch")
            await controls.set(.menu, to: true)
            try await checkState([.menu], "Menu only")
            await controls.set(.dock, to: true)
            try await checkState([.menu, .dock], "Both together")
            let reopened = Controls()
            reopened.refresh()
            try require(reopened.running == [.menu, .dock], "Reopen must reflect both active helpers")
            try await Helpers.start(.menu)
            try require(Effect.menu.runningApps().count == 1, "Duplicate helper")
            await controls.set(.menu, to: false)
            try await checkState([.dock], "Dock only")
            try await Helpers.stop(.dock)
            try await checkState([], "Simulated logout")
            await Helpers.restoreSelected()
            try await checkState([.dock], "Restore only the previously selected helper")
            await controls.set(.dock, to: false)
            try await checkState([], "Both off")
            await Helpers.restoreSelected()
            try await checkState([], "Do not restore disabled effects")
            print("PASS: menu only, both, Dock only, stop, reopen, duplicate prevention, selective login restore")
        } catch {
            for effect in Effect.allCases { try? await Helpers.stop(effect) }
            throw error
        }
    }
}
"""

source_file = Path(__file__).resolve().parents[1] / "GlassDock.swift"
with tempfile.TemporaryDirectory(prefix="glassdock-integration-") as scratch:
    root = Path(scratch)
    namespace = "app.glassdock.integration.x" + uuid.uuid4().hex
    source = source_file.read_text()
    # Keep the controller and helper logic unchanged. Isolate every editable external
    # identity, its bundle defaults domain, and its managed cache before compiling.
    replacements = {
        "io.github.sheer.Sheer": namespace + ".menu",
        "local.mac.dockglass": namespace + ".dock",
        'support.appendingPathComponent("GlassDock/Helpers", isDirectory: true)':
            'URL(fileURLWithPath: "' + str(root / "managed") + '", isDirectory: true)',
        'SMAppService.agent(plistName: "app.glassdock.restore.plist")':
            'SMAppService.agent(plistName: "' + namespace + '.plist")',
    }
    for old, new in replacements.items():
        if source.count(old) != 1:
            raise RuntimeError("Cannot isolate the test environment safely: " + old)
        source = source.replace(old, new)
    entry = "@main\nprivate enum GlassDockEntry"
    if source.count(entry) != 1:
        raise RuntimeError("Unexpected app entry point")
    (root / "TestController.swift").write_text(source.split(entry)[0] + test_entry)
    (root / "helper.swift").write_text(helper_code)
    run("swiftc", str(root / "helper.swift"), "-o", str(root / "IdleHelper"))
    run("swiftc", "-parse-as-library", str(root / "TestController.swift"), "-o", str(root / "Controller"))
    controller = app(root, "Test Controller", "Controller", namespace + ".controller", root / "Controller")
    bundled = controller / "Contents/Helpers"
    for name, effect in (("Sheer", "menu"), ("GlassDock Dock", "dock")):
        demo = app(bundled, name, "Dummy", namespace + "." + effect, root / "IdleHelper")
        run("codesign", "--force", "--sign", "-", str(demo))
    run("codesign", "--force", "--sign", "-", str(controller))
    try:
        run(str(controller / "Contents/MacOS/Controller"), timeout=55)
    finally:
        # Only the two binaries underneath this run's random temp directory may
        # be terminated during cleanup, even when the test timed out or crashed.
        processes = subprocess.check_output(["ps", "-Ao", "pid=,command="], text=True)
        for line in processes.splitlines():
            if len(line.split(None, 1)) != 2:
                continue
            pid, executable = line.split(None, 1)
            for helper in ("Sheer", "GlassDock Dock"):
                expected = root / "managed" / (helper + ".app") / "Contents/MacOS/Dummy"
                if executable == str(expected):
                    try:
                        os.kill(int(pid), 15)
                    except ProcessLookupError:
                        pass
        subprocess.run(["defaults", "delete", namespace + ".controller"], capture_output=True)
