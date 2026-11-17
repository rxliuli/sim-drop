import AppKit
import os

private let log = Logger(subsystem: "com.rxliuli.sim-drop", category: "repair")

/// Brings the helper back when it's gone (e.g. an upgrade removed its launchd job) without
/// the user having to open SimDrop: whenever the system starts the extension (Finder
/// showing SimDrop is enough), check that the helper answers, and if not, launch the
/// containing app headless (`-setupOnly`), which re-registers it. Rate-limited so a helper
/// that can't start (e.g. not approved in Login Items) doesn't cause a launch loop.
enum HelperRepair {
    private static let lastAttemptKey = "lastHelperRepairAttempt"
    private static let minInterval: TimeInterval = 10 * 60

    static func checkSoon() {
        Task.detached(priority: .utility) {
            guard await HelperClient.version() == nil else { return }

            let defaults = UserDefaults.standard
            let now = Date().timeIntervalSince1970
            guard now - defaults.double(forKey: lastAttemptKey) > minInterval else { return }
            defaults.set(now, forKey: lastAttemptKey)

            guard let app = containingApp() else {
                log.error("helper unreachable, and the containing app couldn't be located")
                return
            }
            log.notice("helper unreachable; launching \(app.path, privacy: .public) -setupOnly")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            config.addsToRecentItems = false
            config.arguments = ["-setupOnly", "YES"]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if let error {
                    log.error("launching the app failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// .../SimDrop.app/Contents/PlugIns/SimDropFileProvider.appex → .../SimDrop.app
    private static func containingApp() -> URL? {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()  // PlugIns
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // SimDrop.app
        return app.pathExtension == "app" ? app : nil
    }
}
