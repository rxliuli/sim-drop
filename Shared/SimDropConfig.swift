import FileProvider
import os

enum SimDropConfig {
    static let domainIdentifier = NSFileProviderDomainIdentifier("simdrop")
    static let helperMachService = "com.rxliuli.sim-drop.helper"
    static let helperPlistName = "com.rxliuli.sim-drop.helper.plist"
    /// Team that signs every SimDrop binary; used to authenticate XPC peers.
    static let teamID = "N2X78TUUFG"
    /// userInfo keys on "saved to Downloads" notifications.
    static let notificationItemsKey = "itemIdentifiers"
    static let notificationFolderKey = "folderIdentifier"

    static var domain: NSFileProviderDomain {
        // supportsSyncingTrash stays YES (default): trashing in Finder reparents the
        // item to .trashContainer, which the extension turns into a real Mac Trash move.
        NSFileProviderDomain(identifier: domainIdentifier, displayName: "SimDrop")
    }

    private static let log = Logger(subsystem: "com.rxliuli.sim-drop", category: "config")

    /// Makes sure exactly one SimDrop domain is registered (also cleans up the
    /// per-simulator domains from earlier prototypes).
    static func ensureDomain() async throws {
        let domains = try await NSFileProviderManager.domains()
        var needsAdd = true
        for d in domains {
            // Remove stale domains, and ours if its configuration changed.
            if d.identifier != domainIdentifier || d.supportsSyncingTrash != domain.supportsSyncingTrash {
                try await NSFileProviderManager.remove(d)
            } else {
                needsAdd = false
            }
        }
        if needsAdd {
            try await NSFileProviderManager.add(domain)
        }
    }

    /// Asks the system to re-enumerate the working set (Finder refresh).
    static func signalChanges() {
        guard let manager = NSFileProviderManager(for: domain) else {
            log.error("signalChanges: no manager for domain")
            return
        }
        manager.signalEnumerator(for: .workingSet) { error in
            if let error { log.error("signalEnumerator failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// XPC interface exposed by SimDropHelper (to the extension and the app).
@objc(SimDropHelperProtocol)
protocol HelperProtocol {
    /// Imports a media file into the simulator's Photos library.
    /// Replies with the new file's path relative to `DCIM/`, or an error message.
    func addMedia(udid: String, fileName: String, file: FileHandle, reply: @escaping (String?, String?) -> Void)

    /// Moves a file in the simulator's Downloads to the Mac's Trash ("Put Back" restores it).
    /// Replies with an error message on failure.
    func trashDownload(udid: String, relativePath: String, reply: @escaping (String?) -> Void)

    /// Moves a photo (path relative to DCIM) to the simulator's "Recently Deleted".
    /// Replies with an error message on failure.
    func trashPhoto(udid: String, relativePath: String, reply: @escaping (String?) -> Void)

}
