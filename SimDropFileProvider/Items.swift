import CryptoKit
import os
import FileProvider
import UniformTypeIdentifiers

/// Layout:
///   SimDrop/                         .rootContainer
///   └── <simulator>/                 sim/<udid>
///       ├── Photos and Videos/       photos/<udid>
///       │   └── IMG_0001.JPG         photo/<udid>/<path relative to DCIM>
///       └── Downloads/               downloads/<udid>
///           └── config.json          dl/<udid>/<path relative to Downloads>
enum ItemID: Hashable {
    case root
    /// The domain's trash. Always empty: trashed files are moved to the Mac's Trash and
    /// then reported as deleted.
    case trash
    case device(String)
    case photos(String)
    case photo(String, String)
    case downloads(String)
    case download(String, String)

    init?(_ id: NSFileProviderItemIdentifier) {
        if id == .rootContainer { self = .root; return }
        if id == .trashContainer { self = .trash; return }
        let parts = id.rawValue.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, UUID(uuidString: parts[1]) != nil else { return nil }
        let udid = parts[1]
        switch (parts[0], parts.count) {
        case ("sim", 2): self = .device(udid)
        case ("photos", 2): self = .photos(udid)
        case ("downloads", 2): self = .downloads(udid)
        case ("photo", 3) where Self.isSafe(parts[2]): self = .photo(udid, parts[2])
        case ("dl", 3) where Self.isSafe(parts[2]): self = .download(udid, parts[2])
        default: return nil
        }
    }

    private static func isSafe(_ rel: String) -> Bool {
        !rel.isEmpty && !rel.hasPrefix("/") && !rel.split(separator: "/").contains("..")
    }

    var identifier: NSFileProviderItemIdentifier {
        switch self {
        case .root: return .rootContainer
        case .trash: return .trashContainer
        case .device(let u): return .init("sim/\(u)")
        case .photos(let u): return .init("photos/\(u)")
        case .photo(let u, let rel): return .init("photo/\(u)/\(rel)")
        case .downloads(let u): return .init("downloads/\(u)")
        case .download(let u, let rel): return .init("dl/\(u)/\(rel)")
        }
    }

    var udid: String? {
        switch self {
        case .root, .trash: return nil
        case .device(let u), .photos(let u), .downloads(let u), .photo(let u, _), .download(let u, _): return u
        }
    }
}

final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(id: ItemID, parent: ItemID, filename: String, contentType: UTType,
         capabilities: NSFileProviderItemCapabilities, size: Int? = nil,
         created: Date? = nil, modified: Date? = nil) {
        self.itemIdentifier = id.identifier
        self.parentItemIdentifier = parent.identifier
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = size.map { NSNumber(value: $0) }
        self.creationDate = created
        self.contentModificationDate = modified
        let content = "c\(Item.contentSchema)-\(modified?.timeIntervalSince1970 ?? 0)-\(size ?? 0)"
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(content.utf8),
            metadataVersion: Data("\(Item.metadataSchema)-\(content)-\(filename)".utf8))
    }

    /// Bump when item metadata the system caches (e.g. capabilities) changes shape, so
    /// existing items get refreshed instead of keeping stale capabilities.
    static let metadataSchema = 8

    /// Bump to invalidate what the system caches per content version, e.g. thumbnails
    /// it fetched before the extension could produce them.
    static let contentSchema = 2

    static let virtualFolderCaps: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating]
    static let dropFolderCaps: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]

    static func virtualFolder(_ id: ItemID, parent: ItemID, name: String,
                              caps: NSFileProviderItemCapabilities = virtualFolderCaps) -> Item {
        Item(id: id, parent: parent, filename: name, contentType: .folder, capabilities: caps)
    }

    /// Builds an item from a real file on disk.
    /// Directories are always reported as public.folder (even bundles such as .app): for
    /// anything the system uploads, the type must match the template, or it keeps
    /// retrying the create.
    static func onDisk(_ id: ItemID, parent: ItemID, url: URL,
                       caps: (Bool) -> NSFileProviderItemCapabilities) throws -> Item {
        let v = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey,
        ])
        let isDir = v.isDirectory ?? false
        return Item(
            id: id, parent: parent, filename: url.lastPathComponent,
            contentType: isDir ? .folder : (v.contentType ?? .data),
            capabilities: caps(isDir),
            size: isDir ? nil : v.fileSize,
            created: v.creationDate, modified: v.contentModificationDate)
    }
}

/// Maps item identifiers to simulator state / files on disk.
struct Resolver {
    let sims: [BootedSimulator]

    init() { sims = SimulatorStore.bootedSimulators() }

    private func sim(_ udid: String) throws -> BootedSimulator {
        guard let s = sims.first(where: { $0.udid == udid }) else { throw NSFileProviderError(.noSuchItem) }
        return s
    }

    static func url(for id: ItemID) -> URL? {
        switch id {
        case .photo(let u, let rel): return SimulatorStore.dcimURL(udid: u).appendingPathComponent(rel)
        case .downloads(let u): return SimulatorStore.downloadsURL(udid: u)
        case .download(let u, let rel): return SimulatorStore.downloadsURL(udid: u)?.appendingPathComponent(rel)
        default: return nil
        }
    }

    private static func downloadCaps(isDir: Bool) -> NSFileProviderItemCapabilities {
        isDir
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsTrashing]
            : [.allowsReading, .allowsWriting, .allowsDeleting, .allowsTrashing]
    }

    /// `requireBooted: false` for items the system is (re-)creating: after the domain
    /// reconnects it re-imports cached files, including ones under a simulator that has
    /// since shut down. Answering "no such item" there leaves the import pending forever,
    /// which blocks deleting that simulator's folder.
    func item(_ id: ItemID, requireBooted: Bool = true) throws -> Item {
        if requireBooted, let udid = id.udid { _ = try sim(udid) }
        switch id {
        case .root:
            return .virtualFolder(.root, parent: .root, name: "SimDrop")
        case .trash:
            return .virtualFolder(.trash, parent: .root, name: "Trash")
        case .device(let u):
            return .virtualFolder(id, parent: .root, name: try sim(u).displayName)
        case .photos(let u):
            return .virtualFolder(id, parent: .device(u), name: "Photos and Videos", caps: Item.dropFolderCaps)
        case .downloads(let u):
            return .virtualFolder(id, parent: .device(u), name: "Downloads", caps: Item.dropFolderCaps)
        case .photo(let u, _):
            guard let url = Self.url(for: id) else { throw NSFileProviderError(.noSuchItem) }
            return try mapMissing {
                try Item.onDisk(id, parent: .photos(u), url: url) { _ in
                    // .allowsWriting only so Finder doesn't treat photos as locked (and copies
                    // dragged out aren't read-only); content changes are rejected in modifyItem.
                    [.allowsReading, .allowsWriting, .allowsDeleting, .allowsTrashing]
                }
            }
        case .download(let u, let rel):
            guard let url = Self.url(for: id) else { throw NSFileProviderError(.noSuchItem) }
            let dir = (rel as NSString).deletingLastPathComponent
            let parent: ItemID = dir.isEmpty ? .downloads(u) : .download(u, dir)
            return try mapMissing { try Item.onDisk(id, parent: parent, url: url, caps: Self.downloadCaps) }
        }
    }

    func children(of id: ItemID) throws -> [Item] {
        if let udid = id.udid { _ = try sim(udid) }
        switch id {
        case .root:
            return sims.map { .virtualFolder(.device($0.udid), parent: .root, name: $0.displayName) }
        case .device(let u):
            return [try item(.photos(u)), try item(.downloads(u))]
        case .photos(let u):
            return SimulatorStore.photoPaths(udid: u).compactMap { try? item(.photo(u, $0)) }
        case .downloads(let u):
            return downloadChildren(udid: u, rel: nil)
        case .download(let u, let rel):
            return downloadChildren(udid: u, rel: rel)
        case .photo, .trash:
            return []
        }
    }

    private func downloadChildren(udid: String, rel: String?) -> [Item] {
        let base = rel.map { ItemID.download(udid, $0) } ?? .downloads(udid)
        guard let dir = Self.url(for: base),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.compactMap { name in
            let childRel = rel.map { "\($0)/\(name)" } ?? name
            return try? item(.download(udid, childRel))
        }
    }

    /// Every item in the domain (used for the working set).
    func allItems() -> [Item] {
        var result: [Item] = []
        var queue: [ItemID] = [.root]
        while let next = queue.popLast() {
            let kids = (try? children(of: next)) ?? []
            result.append(contentsOf: kids)
            queue.append(contentsOf: kids.filter { $0.contentType == .folder }.compactMap { ItemID($0.itemIdentifier) })
        }
        return result
    }

    static func anchor(for items: [Item]) -> NSFileProviderSyncAnchor {
        var hasher = SHA256()
        for item in items.sorted(by: { $0.itemIdentifier.rawValue < $1.itemIdentifier.rawValue }) {
            hasher.update(data: Data(item.itemIdentifier.rawValue.utf8))
            hasher.update(data: item.itemVersion.metadataVersion)
        }
        return NSFileProviderSyncAnchor(Data(hasher.finalize()))
    }

    private func mapMissing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw NSFileProviderError(.noSuchItem)
        }
    }
}

final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
    }

    func invalidate() {}

    private func items() throws -> [Item] {
        let resolver = Resolver()
        if container == .workingSet { return resolver.allItems() }
        guard let id = ItemID(container) else { throw NSFileProviderError(.noSuchItem) }
        return try resolver.children(of: id)
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        HelperRepair.checkSoon()
        trackerLog.notice("enumerateItems \(self.container.rawValue, privacy: .public)")
        do {
            observer.didEnumerate(try items())
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    /// Reports changes since `anchor`. Items that disappeared (simulator shut down,
    /// photo deleted, file removed) must be reported as deletions explicitly; merely
    /// leaving them out of the working set doesn't remove them from Finder.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard container == .workingSet else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        let items = Resolver().allItems()
        let current = Resolver.anchor(for: items)
        let ids = Set(items.map(\.itemIdentifier.rawValue))

        // Items that vanished since the snapshot behind `anchor`, plus everything we can
        // prove is gone (folders of simulators that aren't booted, photos that are only
        // in "Recently Deleted"). The latter makes Finder converge even when an earlier
        // deletion was dropped, e.g. while a rolled-back move was in flight.
        var deleted = ChangeTracker.knownStaleIdentifiers()
        if let previous = ChangeTracker.load(), previous.anchor == anchor.rawValue {
            deleted.formUnion(Set(previous.ids).subtracting(ids))
        }
        deleted.subtract(ids)

        if current != anchor {
            observer.didUpdate(items)
        }
        trackerLog.debug("deleted: \(deleted.sorted().joined(separator: ", "), privacy: .public)")
        if !deleted.isEmpty {
            observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
        }
        trackerLog.notice("enumerateChanges: \(items.count) items, \(deleted.count) deleted")
        ChangeTracker.save(anchor: current, ids: ids)
        observer.finishEnumeratingChanges(upTo: current, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let items = try? items() else {
            completionHandler(nil)
            return
        }
        let anchor = Resolver.anchor(for: items)
        if container == .workingSet {
            ChangeTracker.save(anchor: anchor, ids: Set(items.map(\.itemIdentifier.rawValue)))
        }
        completionHandler(anchor)
    }
}

private let trackerLog = Logger(subsystem: "com.rxliuli.sim-drop", category: "changes")

/// Remembers the working-set snapshot behind the last anchor handed to the system,
/// so the next change enumeration can compute deletions.
enum ChangeTracker {
    struct Snapshot: Codable {
        var anchor: Data
        var ids: [String]
    }

    private static let lock = NSLock()
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("working-set.json")
    }()

    static func load() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(anchor: NSFileProviderSyncAnchor, ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = Snapshot(anchor: anchor.rawValue, ids: ids.sorted())
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            trackerLog.error("save snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func knownStaleIdentifiers() -> Set<String> {
        let booted = Set(SimulatorStore.bootedSimulators().map(\.udid))
        var stale = Set<String>()
        for udid in SimulatorStore.allDeviceUDIDs() {
            if !booted.contains(udid) {
                stale.insert(ItemID.device(udid).identifier.rawValue)
            } else {
                let inLibrary = Set(SimulatorStore.photoPaths(udid: udid))
                for rel in SimulatorStore.dcimFilePaths(udid: udid) where !inLibrary.contains(rel) {
                    stale.insert(ItemID.photo(udid, rel).identifier.rawValue)
                }
            }
        }
        return stale
    }

}
