import Foundation

/// On-device store. Each report lives in `<root>/<id>/report.json` plus `shot.png`, so reports
/// survive relaunch and sync whenever Cadence is reachable.
public final class BugOutbox: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DicyaninBugReport", isDirectory: true)
    }

    public init(root: URL = BugOutbox.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func shotURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("shot.png") }
    private func jsonURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("report.json") }

    public func save(_ r: BugReport, png: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: dir(r.id), withIntermediateDirectories: true)
        if let png { try png.write(to: shotURL(r.id), options: .atomic) }
        try BugWire.encoder.encode(r).write(to: jsonURL(r.id), options: .atomic)
    }

    public func update(_ id: UUID, _ change: (inout BugReport) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: jsonURL(id)), var r = try? BugWire.decoder.decode(BugReport.self, from: d) else { return }
        change(&r)
        try? BugWire.encoder.encode(r).write(to: jsonURL(id), options: .atomic)
    }

    /// Newest first.
    public func all() -> [BugReport] {
        lock.lock(); defer { lock.unlock() }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { u in
            (try? Data(contentsOf: u.appendingPathComponent("report.json"))).flatMap { try? BugWire.decoder.decode(BugReport.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    public func png(_ id: UUID) -> Data? { try? Data(contentsOf: shotURL(id)) }

    public func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir(id))
    }

    /// Drops fixed reports older than `age` seconds.
    public func prune(olderThan age: TimeInterval = 14 * 86400, now: Date = Date()) {
        for r in all() where r.state == .fixed && now.timeIntervalSince(r.created) > age { remove(r.id) }
    }
}
