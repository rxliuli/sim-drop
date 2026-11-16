import FileProvider
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct SimDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = StatusModel()

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

@MainActor
@Observable
final class StatusModel {
    var helperStatus: SMAppService.Status = .notRegistered
    var extensionEnabled: Bool?
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var simulators: [BootedSimulator] = []
    var error: String?

    private let agent = SMAppService.agent(plistName: SimDropConfig.helperPlistName)

    func setup() async {
        // Dev: `open SimDrop.app --args -reregisterHelper YES` after the launchd plist changes.
        if UserDefaults.standard.bool(forKey: "reregisterHelper") {
            try? await agent.unregister()
        }
        if agent.status != .enabled {
            do {
                try agent.register()
            } catch {
                self.error = "Background service: \(error.localizedDescription)"
            }
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
                    ok: model.helperStatus == .enabled,
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
