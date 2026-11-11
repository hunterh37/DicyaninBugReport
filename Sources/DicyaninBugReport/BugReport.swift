import Foundation

/// One bug report. Stored in the outbox until Cadence acknowledges it.
public struct BugReport: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var note: String
    public var project: String
    public var bundleID: String
    public var appVersion: String
    public var build: String
    public var device: String
    public var os: String
    /// Name of the front view or route when the report was taken, if the app supplies one.
    public var screen: String?
    /// App state at report time (filters, edits, tweaks), supplied by `BugReporter.context`. For LLM diagnosis.
    public var context: String?
    public var created: Date
    /// Set when Cadence acknowledged receipt.
    public var receivedAt: Date?
    /// Cadence state: received, working, fixed.
    public var state: BugState

    public init(id: UUID = UUID(), note: String, project: String, bundleID: String, appVersion: String, build: String,
                device: String, os: String, screen: String? = nil, context: String? = nil, created: Date = Date(),
                receivedAt: Date? = nil, state: BugState = .queued) {
        self.id = id; self.note = note; self.project = project; self.bundleID = bundleID
        self.appVersion = appVersion; self.build = build; self.device = device; self.os = os
        self.screen = screen; self.context = context; self.created = created; self.receivedAt = receivedAt; self.state = state
    }

    public var delivered: Bool { state != .queued }
}

public enum BugState: String, Codable, Sendable, CaseIterable {
    /// Saved on device, Cadence has not acknowledged it.
    case queued
    /// Cadence stored it.
    case received
    /// A Claude session was started for it.
    case working
    /// Marked fixed in Cadence.
    case fixed
}
