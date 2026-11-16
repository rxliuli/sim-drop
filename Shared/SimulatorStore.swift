import Foundation
import SQLite3
import UniformTypeIdentifiers

struct BootedSimulator: Hashable {
    let udid: String
    let name: String
    let runtime: String      // e.g. "iOS 27.2"
    var displayName: String  // unique folder name shown in Finder

    var rootURL: URL { SimulatorStore.devicesURL.appendingPathComponent(udid, isDirectory: true) }
    var dataURL: URL { rootURL.appendingPathComponent("data", isDirectory: true) }
}

/// Reads simulator state straight from CoreSimulator's on-disk layout, so it
/// works inside the sandboxed extension (no `simctl` needed).
enum SimulatorStore {
    /// The *real* home directory (NSHomeDirectory() points into the container when sandboxed).
    static let devicesURL: URL = {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
    }()

    private static let bootedState = 3

    static func bootedSimulators() -> [BootedSimulator] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: devicesURL, includingPropertiesForKeys: nil) else { return [] }

        var sims: [BootedSimulator] = dirs.compactMap { dir in
            guard
                let data = try? Data(contentsOf: dir.appendingPathComponent("device.plist")),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                plist["state"] as? Int == bootedState,
                plist["isDeleted"] as? Bool != true,
                let udid = plist["UDID"] as? String,
                let name = plist["name"] as? String,
                let runtime = (plist["runtime"] as? String).flatMap(prettyRuntime),
                runtime.hasPrefix("iOS")
            else { return nil }
            return BootedSimulator(udid: udid, name: name, runtime: runtime, displayName: sanitize(name))
        }

        // Disambiguate duplicate names: first by runtime, then by short UDID.
        for pass in 0..<2 {
            let counts = Dictionary(grouping: sims, by: \.displayName).mapValues(\.count)
            for i in sims.indices where counts[sims[i].displayName, default: 0] > 1 {
                let s = sims[i]
                sims[i].displayName = pass == 0
                    ? sanitize("\(s.name) (\(s.runtime))")
                    : sanitize("\(s.name) (\(s.runtime), \(s.udid.prefix(4)))")
            }
        }
        return sims.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4" -> "iOS 27.2"
    static func prettyRuntime(_ id: String) -> String? {
        guard let last = id.components(separatedBy: "SimRuntime.").last else { return nil }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return nil }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? String(os) : "\(os) \(version.joined(separator: "."))"
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - Files app "On My iPhone/Downloads"

    private static let lock = NSLock()
    private static var storageCache: [String: URL] = [:]

    /// `.../AppGroup/<uuid>/File Provider Storage/Downloads` for the device, if the
    /// Files app's local storage container exists.
    static func downloadsURL(udid: String) -> URL? {
        localStorageURL(udid: udid)?.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func localStorageURL(udid: String) -> URL? {
        let fm = FileManager.default
        lock.lock()
        let cached = storageCache[udid]
        lock.unlock()
        if let cached, fm.fileExists(atPath: cached.deletingLastPathComponent().path) { return cached }

        let groups = devicesURL.appendingPathComponent("\(udid)/data/Containers/Shared/AppGroup", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil) else { return nil }
        for group in entries {
            let meta = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard
                let data = try? Data(contentsOf: meta),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                plist["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage"
            else { continue }
            let url = group.appendingPathComponent("File Provider Storage", isDirectory: true)
            lock.lock()
            storageCache[udid] = url
            lock.unlock()
            return url
        }
        return nil
    }

    // MARK: - Photos (DCIM)

    static func dcimURL(udid: String) -> URL {
        devicesURL.appendingPathComponent("\(udid)/data/Media/DCIM", isDirectory: true)
    }

    /// UDIDs of every simulator on disk (booted or not).
    static func allDeviceUDIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devicesURL.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }
    }

    /// Media files physically present in DCIM, relative to DCIM ("100APPLE/IMG_0001.JPG").
    /// Includes photos sitting in "Recently Deleted"; use `photoPaths` for the library view.
    static func dcimFilePaths(udid: String) -> [String] {
        let fm = FileManager.default
        let dcim = dcimURL(udid: udid)
        guard let subdirs = try? fm.contentsOfDirectory(atPath: dcim.path) else { return [] }
        var result: [String] = []
        for sub in subdirs.sorted() where !sub.hasPrefix(".") {
            guard let files = try? fm.contentsOfDirectory(atPath: dcim.appendingPathComponent(sub).path) else { continue }
            for file in files.sorted() where isMedia(file) {
                result.append("\(sub)/\(file)")
            }
        }
        return result
    }

    /// Photos currently in the library (not in "Recently Deleted"), read from
    /// Photos.sqlite. Falls back to the DCIM listing if the database can't be read.
    static func photoPaths(udid: String) -> [String] {
        let db = devicesURL.appendingPathComponent("\(udid)/data/Media/PhotoData/Photos.sqlite")
        guard let rows = queryLibrary(db) else { return dcimFilePaths(udid: udid) }
        let onDisk = Set(dcimFilePaths(udid: udid))
        return rows.filter { onDisk.contains($0) }.sorted()
    }

    private static func queryLibrary(_ url: URL) -> [String]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        var stmt: OpaquePointer?
        let sql = "SELECT ZDIRECTORY, ZFILENAME FROM ZASSET WHERE ZTRASHEDSTATE = 0"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dirC = sqlite3_column_text(stmt, 0), let nameC = sqlite3_column_text(stmt, 1) else { continue }
            var dir = String(cString: dirC)
            if dir.hasPrefix("DCIM/") { dir.removeFirst("DCIM/".count) }
            result.append("\(dir)/\(String(cString: nameC))")
        }
        return result
    }

    static func isMedia(_ fileName: String) -> Bool {
        guard let type = UTType(filenameExtension: (fileName as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }
}
