import CoreServices
import FileProvider
import Foundation
import os
import SQLite3

let log = Logger(subsystem: "com.rxliuli.sim-drop", category: "helper")

// MARK: - XPC service

final class HelperService: NSObject, HelperProtocol {
    func addMedia(udid: String, fileName: String, file: FileHandle, reply: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rel = try MediaImporter.add(udid: udid, fileName: fileName, file: file)
                log.info("addMedia \(fileName, privacy: .public) -> \(rel, privacy: .public)")
                reply(rel, nil)
            } catch {
                log.error("addMedia failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, error.localizedDescription)
            }
        }
    }

    func trashDownload(udid: String, relativePath: String, reply: @escaping (String?) -> Void) {
        do {
            guard UUID(uuidString: udid) != nil, !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
                  let base = SimulatorStore.downloadsURL(udid: udid)
            else { throw MediaImporter.Failure("Invalid path") }
            let url = base.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            reply(nil)
        } catch {
            log.error("trash failed: \(error.localizedDescription, privacy: .public)")
            reply(error.localizedDescription)
        }
    }

    func trashPhoto(udid: String, relativePath: String, reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PhotoLibrary.trash(udid: udid, relativePath: relativePath)
                log.notice("trashed photo \(relativePath, privacy: .public)")
                // Reply first: relaunching Photos takes seconds, and a slow reply makes
                // the File Provider time out, retry and roll the move back.
                reply(nil)
                PhotoLibrary.refreshPhotosApp(udid: udid)
            } catch {
                log.error("trash photo failed: \(error.localizedDescription, privacy: .public)")
                reply(error.localizedDescription)
            }
        }
    }

}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only accept binaries signed by our team.
        connection.setCodeSigningRequirement(
            "anchor apple generic and certificate leaf[subject.OU] = \"\(SimDropConfig.teamID)\"")
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

// MARK: - Photos import

enum MediaImporter {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func add(udid: String, fileName: String, file: FileHandle) throws -> String {
        guard UUID(uuidString: udid) != nil else { throw Failure("Invalid device id") }
        let name = (fileName as NSString).lastPathComponent
        guard SimulatorStore.isMedia(name) else { throw Failure("\(name) is not an image or video") }

        // simctl needs a path with the right extension, so stream the handle to a temp file.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("simdrop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent(name)
        fm.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.close()
        try? file.close()

        let before = Set(SimulatorStore.dcimFilePaths(udid: udid))
        try run("/usr/bin/xcrun", ["simctl", "addmedia", udid, tmp.path])

        // The file lands in DCIM asynchronously under a new name (IMG_xxxx).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let added = Set(SimulatorStore.dcimFilePaths(udid: udid)).subtracting(before)
            if let rel = added.sorted().last { return rel }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw Failure("Imported, but the new photo did not appear in DCIM")
    }

    /// Runs a tool and returns its stdout.
    static func capture(_ tool: String, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(msg.isEmpty ? "simctl exited with \(process.terminationStatus)" : msg)
        }
    }
}

// MARK: - Photos library edits

/// Moves photos to "Recently Deleted" by editing the simulator's Photos.sqlite, the same
/// columns the Photos app changes (verified by diffing an in-app delete). The tables have
/// Core Data triggers calling a function that only exists inside the Photos daemon, so we
/// register a no-op with that name. The Photos app caches the library and only picks the
/// change up after a relaunch.
enum PhotoLibrary {
    private static let coreDataEpoch: TimeInterval = 978_307_200
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func trash(udid: String, relativePath: String) throws {
        guard UUID(uuidString: udid) != nil else { throw MediaImporter.Failure("Invalid device id") }
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts.contains("..") else { throw MediaImporter.Failure("Invalid photo path") }

        let db = SimulatorStore.devicesURL.appendingPathComponent("\(udid)/data/Media/PhotoData/Photos.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw MediaImporter.Failure("Can't open the Photos library")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_create_function_v2(handle, "NSCoreDataTriggerUpdateAffectedObjectValue", -1, SQLITE_UTF8, nil,
                                   { context, _, _ in sqlite3_result_null(context) }, nil, nil, nil)

        let sql = """
            UPDATE ZASSET SET ZTRASHEDSTATE = 1, ZTRASHEDREASON = 1, ZTRASHEDDATE = ?1,
                ZMODIFICATIONDATE = ?1, Z_OPT = Z_OPT + 1
            WHERE ZDIRECTORY = ?2 AND ZFILENAME = ?3
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MediaImporter.Failure("Photos library schema not supported: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - coreDataEpoch)
        sqlite3_bind_text(stmt, 2, "DCIM/\(parts[0])", -1, transient)
        sqlite3_bind_text(stmt, 3, parts[1], -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MediaImporter.Failure("Photos library update failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        // Idempotent: an asset that is already in "Recently Deleted" still matches.
        guard sqlite3_changes(handle) > 0 else { throw MediaImporter.Failure("Photo not found in the library") }
    }

    /// Relaunches the simulator's Photos app if it is running, so it shows the change.
    static func refreshPhotosApp(udid: String) {
        let bundleID = "com.apple.mobileslideshow"
        guard let list = try? MediaImporter.capture("/usr/bin/xcrun", ["simctl", "spawn", udid, "launchctl", "list"]) else { return }
        let running = String(decoding: list, as: UTF8.self).split(separator: "\n").contains { line in
            line.contains(bundleID) && !line.hasPrefix("-")
        }
        guard running else { return }
        _ = try? MediaImporter.capture("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID])
        _ = try? MediaImporter.capture("/usr/bin/xcrun", ["simctl", "launch", udid, bundleID])
    }
}

// MARK: - Change watcher

/// Watches CoreSimulator's devices folder and signals Finder when a simulator
/// boots/shuts down or files change in Downloads / DCIM.
final class DeviceWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.rxliuli.sim-drop.watcher")
    private var pending: DispatchWorkItem?

    func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(list.prefix(count)))
        }
        stream = FSEventStreamCreate(
            nil, callback, &context,
            [SimulatorStore.devicesURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        guard let stream else {
            log.error("FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func handle(_ paths: [String]) {
        let devices = SimulatorStore.devicesURL.path
        let relevant = paths.contains { path in
            let p = path.hasSuffix("/") ? String(path.dropLast()) : path
            // device.plist changes are reported on the device folder itself
            let isDeviceDir = (p as NSString).deletingLastPathComponent == devices
            return isDeviceDir || p == devices
                || p.contains("/File Provider Storage")
                || p.contains("/data/Media/DCIM")
                || p.contains("/data/Media/PhotoData")   // Photos.sqlite (deletions in the Photos app)
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { SimDropConfig.signalChanges() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

// MARK: - Main

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: SimDropConfig.helperMachService)
listener.delegate = delegate
listener.resume()

let watcher = DeviceWatcher()
watcher.start()

Task {
    do {
        try await SimDropConfig.ensureDomain()
    } catch {
        log.error("ensureDomain failed: \(error.localizedDescription, privacy: .public)")
    }
    SimDropConfig.signalChanges()
}

log.notice("SimDropHelper started")
dispatchMain()
