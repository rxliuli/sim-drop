import AppKit
import os

private let log = Logger(subsystem: "com.rxliuli.sim-drop", category: "repair")

/// Brings the helper back when it's gone (e.g. an upgrade removed its launchd job) without
/// the user having to open SimDrop: when the extension starts and while Finder browses
/// SimDrop, check that the helper answers, and if not, launch the containing app headless
/// (`-setupOnly`), which re-registers it. Checks run at most once a minute per process;
/// launches at most every 2 minutes per app copy, so a helper that can't start (e.g. not
/// approved in Login Items) doesn't cause a launch loop.
enum HelperRepair {
    private static let lastAttemptKey = "lastHelperRepairAttempt"
    private static let lastAttemptAppKey = "lastHelperRepairApp"
    private static let launchInterval: TimeInterval = 2 * 60
    private static let checkInterval: TimeInterval = 60

    private static let lock = NSLock()
    private static var lastCheck: Date = .distantPast

    static func checkSoon() {
        lock.lock()
        let due = Date().timeIntervalSince(lastCheck) >= checkInterval
        if due { lastCheck = Date() }
        lock.unlock()
        guard due else { return }

        Task.detached(priority: .utility) {
            guard await HelperClient.version() == nil else { return }
            guard let app = containingApp() else {
                log.error("helper unreachable, and the containing app couldn't be located")
                return
            }

            let defaults = UserDefaults.standard
            let now = Date().timeIntervalSince1970
            let sameApp = defaults.string(forKey: lastAttemptAppKey) == app.path
            guard !sameApp || now - defaults.double(forKey: lastAttemptKey) > launchInterval else { return }
            defaults.set(now, forKey: lastAttemptKey)
            defaults.set(app.path, forKey: lastAttemptAppKey)

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
