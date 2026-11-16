import Foundation

/// Talks to SimDropHelper over its launchd Mach service (launchd starts it on demand).
enum HelperClient {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Opens a connection, hands the proxy to `body`, and invalidates the connection
    /// after `body` calls `done` (or on error, after `onError`).
    private static func withProxy(
        onError: @escaping (Error) -> Void,
        _ body: (HelperProtocol, _ done: @escaping () -> Void) -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: SimDropConfig.helperMachService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            onError(Failure(errorDescription: "SimDrop helper is not running (\(error.localizedDescription))"))
            connection.invalidate()
        } as! HelperProtocol
        body(proxy) { connection.invalidate() }
    }

    static func addMedia(udid: String, fileName: String, from url: URL,
                         completion: @escaping (Result<String, Error>) -> Void) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            completion(.failure(error))
            return
        }
        let once = Once(completion)
        withProxy(onError: { once(.failure($0)) }) { proxy, done in
            proxy.addMedia(udid: udid, fileName: fileName, file: handle) { rel, message in
                once(rel.map { .success($0) } ?? .failure(Failure(errorDescription: message ?? "Import failed")))
                done()
            }
        }
    }

    static func trashPhoto(udid: String, relativePath: String, completion: @escaping (Error?) -> Void) {
        let once = Once<Error?>(completion)
        withProxy(onError: { once($0) }) { proxy, done in
            proxy.trashPhoto(udid: udid, relativePath: relativePath) { message in
                once(message.map { Failure(errorDescription: $0) })
                done()
            }
        }
    }

    static func trashDownload(udid: String, relativePath: String, completion: @escaping (Error?) -> Void) {
        let once = Once<Error?>(completion)
        withProxy(onError: { once($0) }) { proxy, done in
            proxy.trashDownload(udid: udid, relativePath: relativePath) { message in
                once(message.map { Failure(errorDescription: $0) })
                done()
            }
        }
    }

}

/// Calls the wrapped closure at most once (XPC may report both a reply and an error).
final class Once<T> {
    private let lock = NSLock()
    private var fn: ((T) -> Void)?

    init(_ fn: @escaping (T) -> Void) { self.fn = fn }

    func callAsFunction(_ value: T) {
        lock.lock()
        let f = fn
        fn = nil
        lock.unlock()
        f?(value)
    }
}
