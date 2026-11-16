import Foundation
import CloudKit

/// Uploads reports to the CloudKit public database as `BugReport` records (record name = report id,
/// screenshot in the `shot` asset). Schema: cloudkit/schema.ckdb in the app repo. Free tier, no server.
final class BugCloud: @unchecked Sendable {
    static let recordType = "BugReport"
    private let containerID: String
    private let outbox: BugOutbox
    private let lock = NSLock()
    private var running = false
    var onChange: (@Sendable () -> Void)?

    init(containerID: String, outbox: BugOutbox) {
        self.containerID = containerID
        self.outbox = outbox
    }

    /// Uploads every report without `cloudAt`. Reports stay in the outbox on failure and retry next call.
    func sync() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            await upload()
            finish()
        }
    }

    private func finish() {
        lock.lock(); running = false; lock.unlock()
        onChange?()
    }

    private func upload() async {
        let pending = outbox.all().filter { $0.cloudAt == nil }
        guard !pending.isEmpty else { return }
        let container = CKContainer(identifier: containerID)
        guard (try? await container.accountStatus()) == .available else { return }
        let db = container.publicCloudDatabase
        for r in pending {
            let rec = Self.record(r, shot: FileManager.default.fileExists(atPath: outbox.shotURL(r.id).path) ? outbox.shotURL(r.id) : nil)
            do {
                let (saved, _) = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys)
                if case .failure(let e) = saved[rec.recordID] { throw e }
                mark(r.id)
            } catch let e as CKError where e.code == .serverRecordChanged {
                mark(r.id)
            } catch {
                return
            }
        }
    }

    private func mark(_ id: UUID) { outbox.update(id) { $0.cloudAt = Date() } }

    static func record(_ r: BugReport, shot: URL?) -> CKRecord {
        let rec = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: r.id.uuidString))
        rec["note"] = r.note
        rec["project"] = r.project
        rec["bundleID"] = r.bundleID
        rec["appVersion"] = r.appVersion
        rec["build"] = r.build
        rec["device"] = r.device
        rec["os"] = r.os
        rec["screen"] = r.screen
        rec["context"] = r.context
        rec["created"] = r.created
        rec["state"] = r.state.rawValue
        if let shot { rec["shot"] = CKAsset(fileURL: shot) }
        return rec
    }
}

/// Build channel checks for gating the reporter.
public enum BugEnvironment {
    /// True in TestFlight installs. False in the simulator, Xcode installs and App Store installs.
    public static var isTestFlight: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}
