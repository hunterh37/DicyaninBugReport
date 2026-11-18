import Foundation

/// HTTP backend for reports (RealityStudio web server on Render, `web/server/bugs.js`).
/// `POST /api/bugs` with the report JSON plus a base64 `shot`; `GET /api/bugs/<id>/state` reads the Cadence state back.
public struct BugServerConfig: Sendable, Equatable {
    public var url: URL
    /// Write key, sent as `X-Bug-Key`.
    public var key: String
    public init(url: URL, key: String) { self.url = url; self.key = key }
}

final class BugServer: @unchecked Sendable {
    private let config: BugServerConfig
    private let outbox: BugOutbox
    private let session: URLSession
    private let lock = NSLock()
    private var running = false
    var onChange: (@Sendable () -> Void)?

    init(config: BugServerConfig, outbox: BugOutbox, session: URLSession = .shared) {
        self.config = config; self.outbox = outbox; self.session = session
    }

    /// Uploads every report without `serverAt`, then refreshes the state of sent, unfixed reports.
    func sync() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            await run()
            finish()
        }
    }

    private func finish() {
        lock.withLock { running = false }
        onChange?()
    }

    func run() async {
        for r in outbox.all() where r.serverAt == nil {
            guard await upload(r) else { break }
        }
        for r in outbox.all() where r.serverAt != nil && r.state != .fixed {
            guard let s = await state(r.id) else { break }
            if s != r.state { outbox.update(r.id) { $0.state = s } }
        }
    }

    static func body(_ r: BugReport, png: Data?) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: BugWire.encoder.encode(r)) as? [String: Any] ?? [:]
        if let png { obj["shot"] = png.base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var q = URLRequest(url: config.url.appendingPathComponent(path))
        q.httpMethod = method
        q.timeoutInterval = 60
        q.setValue(config.key, forHTTPHeaderField: "X-Bug-Key")
        q.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return q
    }

    private func upload(_ r: BugReport) async -> Bool {
        var q = request("api/bugs", method: "POST")
        guard let body = try? Self.body(r, png: outbox.png(r.id)) else { return true }
        q.httpBody = body
        guard let (_, resp) = try? await session.data(for: q), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        outbox.update(r.id) { $0.serverAt = Date(); if $0.state == .queued { $0.state = .received } }
        return true
    }

    private func state(_ id: UUID) async -> BugState? {
        guard let (d, resp) = try? await session.data(for: request("api/bugs/\(id.uuidString.lowercased())/state")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
        return o["state"].flatMap(BugState.init(rawValue:))
    }
}
