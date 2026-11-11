import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Entry point. Call `BugReporter.shared.install(project:)` once at launch, then attach
/// `.bugReporter()` to the root view. Shake or take a screenshot to report.
@MainActor @Observable
public final class BugReporter {
    public static let shared = BugReporter()

    /// Reports on this device, newest first.
    public private(set) var reports: [BugReport] = []
    /// Cadence is visible on the local network.
    public private(set) var cadenceOnline = false
    /// Draft shown in the sheet after a shake.
    public var draft: Draft?
    /// Shows the report list.
    public var showingList = false
    /// Optional current screen name, included in each report.
    public var screenName: (() -> String?)?
    /// Optional app state dump (selected filters, edits, tweaks), included in each report.
    public var context: (() -> String?)?
    public var enabled = true

    public struct Draft: Identifiable, Equatable {
        public let id = UUID()
        public var png: Data?
        public var note = ""
        public var screen: String?
        public var context: String?
    }

    @ObservationIgnored let outbox: BugOutbox
    @ObservationIgnored private var sync: BugSync?
    @ObservationIgnored private(set) var project = ""
    @ObservationIgnored private var screenshotObserver: NSObjectProtocol?

    init(outbox: BugOutbox = BugOutbox()) { self.outbox = outbox }

    public func install(project: String) {
        guard sync == nil else { return }
        self.project = project
        outbox.prune()
        let s = BugSync(outbox: outbox)
        s.onChange = { up in
            Task { @MainActor in
                BugReporter.shared.cadenceOnline = up
                BugReporter.shared.reload()
            }
        }
        sync = s
        s.start()
        reload()
        #if canImport(UIKit) && !os(visionOS)
        ShakeHook.onShake = { BugReporter.shared.begin() }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BugReporter.shared.begin() }
        }
        #endif
    }

    func reload() { reports = outbox.all() }

    /// Captures the key window and opens the sheet.
    public func begin() {
        guard enabled, draft == nil else { return }
        draft = Draft(png: Self.capture(), screen: screenName?(), context: context?())
    }

    public func submit() {
        guard let d = draft else { return }
        let note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = BugReport(note: note, project: project, bundleID: Bundle.main.bundleIdentifier ?? "",
                          appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                          build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                          device: Self.deviceModel, os: Self.osString, screen: d.screen, context: d.context)
        try? outbox.save(r, png: d.png)
        draft = nil
        reload()
        sync?.sync()
    }

    public func syncNow() { sync?.sync() }

    public func delete(_ id: UUID) { outbox.remove(id); reload() }

    public func screenshot(_ id: UUID) -> Data? { outbox.png(id) }

    static var deviceModel: String {
        var s = utsname(); uname(&s)
        let m = withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return m.isEmpty ? "unknown" : m
    }

    static var osString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let n = "iOS"
        #elseif os(visionOS)
        let n = "visionOS"
        #else
        let n = "macOS"
        #endif
        return "\(n) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func capture() -> Data? {
        #if canImport(UIKit)
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let w else { return nil }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        return r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }.pngData()
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit) && !os(visionOS)
@MainActor enum ShakeHook { static var onShake: (() -> Void)? }

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { MainActor.assumeIsolated { ShakeHook.onShake?() } }
        super.motionEnded(motion, with: event)
    }
}
#endif
