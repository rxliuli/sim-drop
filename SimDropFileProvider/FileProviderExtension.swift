import FileProvider
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.rxliuli.sim-drop", category: "extension")

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.manager = NSFileProviderManager(for: domain)
        super.init()
    }

    func invalidate() {}

    // MARK: Read

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            guard let id = ItemID(identifier) else { throw NSFileProviderError(.noSuchItem) }
            completionHandler(try Resolver().item(id), nil)
        } catch {
            completionHandler(nil, error)
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            guard let id = ItemID(itemIdentifier), let source = Resolver.url(for: id) else {
                throw NSFileProviderError(.noSuchItem)
            }
            let item = try Resolver().item(id)
            let tmpDir = (try? manager?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
            let dest = tmpDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: dest)
            completionHandler(dest, item, nil)
        } catch {
            log.error("fetchContents \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier == .workingSet || ItemID(containerItemIdentifier) != nil else {
            throw NSFileProviderError(.noSuchItem)
        }
        return Enumerator(container: containerItemIdentifier)
    }

    // MARK: Write

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) ?? false
        let fail = { (error: Error) in
            log.error("createItem \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        }

        log.debug("createItem \(name, privacy: .public) parent=\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public) type=\(itemTemplate.contentType?.identifier ?? "-", privacy: .public) hasContents=\(url != nil) options=\(options.rawValue)")
        guard let parent = ItemID(itemTemplate.parentItemIdentifier) else {
            fail(NSFileProviderError(.noSuchItem))
            return Progress()
        }

        switch parent {
        case .downloads(let udid), .download(let udid, _):
            var parentRel: String?
            if case .download(_, let rel) = parent { parentRel = rel }
            do {
                let item = try createInDownloads(
                    udid: udid, parentRel: parentRel, name: name, isFolder: isFolder,
                    contents: url, mayAlreadyExist: options.contains(.mayAlreadyExist))
                completionHandler(item, [], false, nil)
            } catch {
                fail(error)
            }

        case .photos(let udid):
            // Finder can't filter drops by type, so anything that isn't a photo or
            // video is routed to Downloads; returning an item with a different
            // parent makes the system move it there on the Mac side too.
            guard !isFolder, SimulatorStore.isMedia(name), let url else {
                do {
                    let item = try createInDownloads(
                        udid: udid, parentRel: nil, name: name, isFolder: isFolder,
                        contents: url, mayAlreadyExist: options.contains(.mayAlreadyExist))
                    completionHandler(item, [], false, nil)
                    if !options.contains(.mayAlreadyExist) {
                        let simName = Resolver().sims.first { $0.udid == udid }?.displayName ?? "Simulator"
                        RedirectNotifier.fileRedirected(
                            udid: udid, simName: simName, fileName: item.filename, identifier: item.itemIdentifier)
                    }
                } catch {
                    fail(error)
                }
                return Progress()
            }
            let progress = Progress(totalUnitCount: 1)
            HelperClient.addMedia(udid: udid, fileName: name, from: url) { result in
                switch result {
                case .success(let rel):
                    do {
                        completionHandler(try Resolver().item(.photo(udid, rel)), [], false, nil)
                    } catch {
                        fail(error)
                    }
                case .failure(let error):
                    fail(error)
                }
                progress.completedUnitCount = 1
            }
            return progress

        default:
            fail(CocoaError(.featureUnsupported))
        }
        return Progress()
    }

    private func createInDownloads(
        udid: String, parentRel: String?, name: String, isFolder: Bool,
        contents: URL?, mayAlreadyExist: Bool
    ) throws -> Item {
        let fm = FileManager.default
        guard let base = SimulatorStore.downloadsURL(udid: udid) else { throw NSFileProviderError(.noSuchItem) }
        let dir = parentRel.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var dest = dir.appendingPathComponent(name)
        let rel = { (url: URL) in parentRel.map { "\($0)/\(url.lastPathComponent)" } ?? url.lastPathComponent }

        if fm.fileExists(atPath: dest.path) {
            // Re-imports (e.g. after the domain is re-added) upload files that are
            // already there; reuse identical files instead of creating "name 2".
            let identical = !isFolder && contents.map { fm.contentsEqual(atPath: $0.path, andPath: dest.path) } == true
            if mayAlreadyExist || identical { return try Resolver().item(.download(udid, rel(dest))) }
            dest = uniqueURL(for: dest)
        }

        if isFolder {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } else if let contents {
            try fm.copyItem(at: contents, to: dest)
        } else {
            fm.createFile(atPath: dest.path, contents: Data())
        }
        return try Resolver().item(.download(udid, rel(dest)))
    }

    private func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            guard let id = ItemID(item.itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
            // Photos moved to Trash go to the simulator's "Recently Deleted" instead.
            if case .photo(let udid, let rel) = id {
                if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                    HelperClient.trashPhoto(udid: udid, relativePath: rel) { error in
                        if let error {
                            log.error("trash photo \(rel, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            completionHandler(nil, [], false, error)
                        } else {
                            completionHandler(item, [], false, nil)
                            SimDropConfig.signalChanges()
                        }
                    }
                    return Progress()
                }
                // Photos are only edited in the simulator.
                if changedFields.contains(.contents) || changedFields.contains(.filename)
                    || changedFields.contains(.parentItemIdentifier) {
                    throw CocoaError(.featureUnsupported)
                }
            }
            if case .download(let udid, let rel) = id {
                // Move to Trash: Finder reparents the item to .trashContainer. Move the real
                // file into the Mac's Trash (recoverable; "Put Back" restores it into the
                // simulator) and accept the reparent; the next change enumeration reports
                // the item as deleted since it's no longer in the simulator.
                if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                    HelperClient.trashDownload(udid: udid, relativePath: rel) { error in
                        if let error {
                            log.error("trash \(rel, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            completionHandler(nil, [], false, error)
                        } else {
                            completionHandler(item, [], false, nil)
                            SimDropConfig.signalChanges()
                        }
                    }
                    return Progress()
                }
                // Identifiers are path-based, so rename/move is not supported (yet).
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    throw CocoaError(.featureUnsupported)
                }
                if changedFields.contains(.contents), let newContents, let dest = Resolver.url(for: id) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: newContents, to: dest)
                }
            }
            // Other metadata changes (dates, tags, ...) are accepted and ignored.
            completionHandler(try Resolver().item(id), [], false, nil)
        } catch {
            log.error("modifyItem \(item.itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        if let id = ItemID(identifier), case .photo(let udid, let rel) = id {
            HelperClient.trashPhoto(udid: udid, relativePath: rel) { error in
                // Already gone from the library counts as deleted.
                completionHandler(error.flatMap { $0.localizedDescription.contains("not found") ? nil : $0 })
            }
            return Progress()
        }
        guard let id = ItemID(identifier), case .download(let udid, let rel) = id else {
            completionHandler(CocoaError(.featureUnsupported))
            return Progress()
        }
        // Deleting from Finder moves the file to the Mac's Trash (via the helper, which
        // isn't sandboxed), so it's recoverable and "Put Back" restores it to the simulator.
        HelperClient.trashDownload(udid: udid, relativePath: rel) { error in
            if let error {
                log.error("trash \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            completionHandler(error)
        }
        return Progress()
    }
}
