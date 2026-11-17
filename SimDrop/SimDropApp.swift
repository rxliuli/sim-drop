import FileProvider
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct SimDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = StatusModel()

    init() {
        // `open SimDrop.app --args -setupOnly YES` (run by the Homebrew cask after install
        // and upgrade): make sure the helper and the Finder location are set up, then quit
        // without showing any UI.
        if UserDefaults.standard.bool(forKey: "setupOnly") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await Setup.ensureHelper()
                try? await SimDropConfig.ensureDomain()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 30)
            exit(0)
        }
    }

    var body: some Scene {
        Window("SimDrop", id: "settings") {
            SettingsView()
                .environment(model)
                .task { await model.setup() }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // The app is only a settings window; the helper keeps working after it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a "Saved to Downloads" notification reveals the files in Finder.
    /// (Known issue: clicks on notifications posted by the extension don't arrive yet.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let ids = info[SimDropConfig.notificationItemsKey] as? [String] ?? []
        let folder = info[SimDropConfig.notificationFolderKey] as? String
        Task { @MainActor in
            guard let manager = NSFileProviderManager(for: SimDropConfig.domain) else { return completionHandler() }
            var urls: [URL] = []
            for id in ids {
                if let url = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(id)),
                   FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } else if let folder,
                      let url = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(folder)) {
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }
}

/// Registration logic shared by the settings window and the headless `-setupOnly` mode.
enum Setup {
    static let agent = SMAppService.agent(plistName: SimDropConfig.helperPlistName)

    /// Makes sure the helper is registered *and actually running this build*. The
    /// registration can say "enabled" while launchd has no such job (e.g. a package
    /// manager removed it during an upgrade), while an older helper is still running, or
    /// while launchd refuses to spawn it because its recorded launch constraint is stale
    /// (`needs LWCR update`, exit 78). So trust a live version check over `agent.status`,
    /// and if a fresh registration still doesn't answer, remove the launchd job entirely
    /// and register once more (what fixes a stale constraint).
    static func ensureHelper(forceReregister: Bool = false) async -> Error? {
        if !forceReregister, agent.status == .enabled, await helperIsCurrent(wait: 0) {
            return nil
        }
        if forceReregister || agent.status == .enabled {
            try? await agent.unregister()
        }
        if let error = register() { return error }
        if await helperIsCurrent(wait: 5) { return nil }

        // Registered but not answering (or still the old version): start over.
        bootoutHelperJob()
        try? await agent.unregister()
        if let error = register() { return error }
        _ = await helperIsCurrent(wait: 5)
        return nil
    }

    /// Always calls register(): right after unregister() the reported status can lag, so a
    /// "skip if enabled" check would skip the re-registration. "Already registered" is fine.
    private static func register() -> Error? {
        do {
            try agent.register()
            return nil
        } catch {
            return agent.status == .enabled ? nil : error
        }
    }

    /// Polls the helper's version for up to `wait` seconds.
    private static func helperIsCurrent(wait: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if await HelperClient.version(timeout: 1) == SimDropConfig.buildVersion { return true }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(500))
        } while true
        return false
    }

    private static func bootoutHelperJob() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(SimDropConfig.helperLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
@Observable
final class StatusModel {
    var helperStatus: SMAppService.Status = .notRegistered
    /// Version reported by the running helper; nil when it can't be reached.
    var helperVersion: String?
    var extensionEnabled: Bool?
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var simulators: [BootedSimulator] = []
    var error: String?

    private var agent: SMAppService { Setup.agent }

    func setup() async {
        // Dev: `open SimDrop.app --args -reregisterHelper YES` forces a fresh registration.
        if let error = await Setup.ensureHelper(
            forceReregister: UserDefaults.standard.bool(forKey: "reregisterHelper")) {
            self.error = "Background service: \(error.localizedDescription)"
        }
        // Dev: `open SimDrop.app --args -resetDomain YES` wipes the domain's local state
        // (e.g. a stale .Trash left over from an earlier domain instance) and re-adds it.
        if UserDefaults.standard.bool(forKey: "resetDomain") {
            do {
                _ = try await NSFileProviderManager.remove(SimDropConfig.domain, mode: .removeAll)
            } catch {
                self.error = "Reset: \(error.localizedDescription)"
            }
        }
        do {
            try await SimDropConfig.ensureDomain()
        } catch {
            self.error = "Finder extension: \(error.localizedDescription)"
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        helperStatus = agent.status
        helperVersion = await HelperClient.version(timeout: 1)
        let domains = try? await NSFileProviderManager.domains()
        extensionEnabled = domains?.first { $0.identifier == SimDropConfig.domainIdentifier }?.userEnabled
        simulators = SimulatorStore.bootedSimulators()
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.rxliuli.sim-drop")!
        NSWorkspace.shared.open(url)
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Opens the SimDrop location in Finder (where the "Enable" banner shows up).
    func revealInFinder(subpath: String? = nil) {
        Task {
            guard let manager = NSFileProviderManager(for: SimDropConfig.domain),
                  var url = try? await manager.getUserVisibleURL(for: .rootContainer)
            else { return }
            if let subpath { url.appendPathComponent(subpath) }
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    @Environment(StatusModel.self) private var model

    var body: some View {
        Form {
            Section {
                StatusRow(
                    ok: model.helperStatus == .enabled && model.helperVersion != nil,
                    title: helperTitle,
                    detail: "Runs in the background to detect simulators and import photos."
                ) {
                    Button("Open Login Items") { model.openLoginItems() }
                }
            } header: {
                Text("Background Service")
            }

            Section {
                StatusRow(
                    ok: model.extensionEnabled == true,
                    title: model.extensionEnabled == true ? "Extension enabled" : "Extension not enabled",
                    detail: "Click “Enable” in the Finder banner, or turn on SimDrop under File Providers in System Settings."
                ) {
                    HStack {
                        Button("Open in Finder") { model.revealInFinder() }
                        Button("Open Login Items") { model.openLoginItems() }
                    }
                }
            } header: {
                Text("Finder Extension")
            }

            Section {
                StatusRow(
                    ok: model.notificationStatus == .authorized || model.notificationStatus == .provisional,
                    title: model.notificationStatus == .authorized ? "Notifications allowed" : "Notifications off",
                    detail: "Used to tell you when a file that isn’t a photo or video was saved to Downloads instead. Optional."
                ) {
                    Button("Open Notification Settings") { model.openNotificationSettings() }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                if model.simulators.isEmpty {
                    Text("No iOS simulator is running.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.simulators, id: \.udid) { sim in
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(sim.displayName)
                                Text(sim.runtime).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show in Finder") { model.revealInFinder(subpath: sim.displayName) }
                        }
                    }
                }
            } header: {
                Text("Active Simulators")
            } footer: {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var helperTitle: String {
        if model.helperStatus == .enabled && model.helperVersion == nil {
            return "Not running (reopen SimDrop to restart it)"
        }
        switch model.helperStatus {
        case .enabled: return "Running"
        case .requiresApproval: return "Needs approval in Login Items"
        case .notFound: return "Not found (reinstall the app)"
        default: return "Not registered"
        }
    }
}

struct StatusRow<Actions: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ok ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(title).font(.headline)
            }
            if !ok {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                actions()
            }
        }
        .padding(.vertical, 2)
    }
}
