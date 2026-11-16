import FileProvider
import os
import UserNotifications

/// Tells the user when a non-media file dropped into "Photos and Videos" was saved
/// to Downloads instead. Drops arriving within a short window are merged per
/// simulator. Notifications are attributed to the SimDrop app.
enum RedirectNotifier {
    private struct Batch {
        var simName: String
        var fileNames: [String] = []
        var identifiers: [String] = []
    }

    private static let lock = NSLock()
    private static var batches: [String: Batch] = [:]
    private static let delay: TimeInterval = 1.0

    static func fileRedirected(udid: String, simName: String, fileName: String, identifier: NSFileProviderItemIdentifier) {
        lock.lock()
        let isNew = batches[udid] == nil
        var batch = batches[udid] ?? Batch(simName: simName)
        batch.fileNames.append(fileName)
        batch.identifiers.append(identifier.rawValue)
        batches[udid] = batch
        lock.unlock()

        if isNew {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { flush(udid: udid) }
        }
    }

    private static func flush(udid: String) {
        lock.lock()
        let batch = batches.removeValue(forKey: udid)
        lock.unlock()
        guard let batch, !batch.fileNames.isEmpty else { return }
        let content = UNMutableNotificationContent()
        let location = "\(batch.simName) › Downloads"
        if batch.fileNames.count == 1 {
            content.title = "Saved to Downloads"
            content.body = "“\(batch.fileNames[0])” isn’t a photo or video, so it was saved to \(location)."
        } else {
            content.title = "Saved \(batch.fileNames.count) files to Downloads"
            content.body = "They aren’t photos or videos, so they were saved to \(location)."
        }
        content.userInfo = [
            SimDropConfig.notificationItemsKey: batch.identifiers,
            SimDropConfig.notificationFolderKey: ItemID.downloads(udid).identifier.rawValue,
        ]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger(subsystem: "com.rxliuli.sim-drop", category: "notify")
                    .error("post notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
