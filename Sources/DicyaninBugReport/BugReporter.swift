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
    /// Shake or screenshot first asks "Report a bug?" before opening the sheet.
    public var askFirst = true
    /// The "Report a bug?" prompt is showing.
    public var asking = false
    @ObservationIgnored private var pendingPNG: Data?
    @ObservationIgnored private var pendingScreen: String?
    @ObservationIgnored private var pendingContext: String?
    /// CloudKit container in use, nil when reports go to Cadence only.
    public private(set) var cloudContainer: String?

    public struct Draft: Identifiable, Equatable {
        public let id = UUID()
        public var png: Data?
        public var note = ""
        public var screen: String?
        public var context: String?
    }

    @ObservationIgnored let outbox: BugOutbox
    @ObservationIgnored private var sync: BugSync?
    @ObservationIgnored private var cloud: BugCloud?
    @ObservationIgnored private var server: BugServer?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var project = ""
    @ObservationIgnored private var screenshotObserver: NSObjectProtocol?

    init(outbox: BugOutbox = BugOutbox()) { self.outbox = outbox }

    /// `cloudContainer`: CloudKit container id (e.g. iCloud.org.dicyaninlabs.app). Reports upload to its
    /// public database as `BugReport` records in addition to Cadence on the local network.
    /// `server`: HTTP bug server (Render). Cadence pulls from it, so reports reach Cadence off the local network.
    public func install(project: String, cloudContainer: String? = nil, server: BugServerConfig? = nil) {
        guard sync == nil else { return }
        self.project = project
        self.cloudContainer = cloudContainer
        outbox.prune()
        if let cloudContainer {
            let c = BugCloud(containerID: cloudContainer, outbox: outbox)
            c.onChange = { Task { @MainActor in BugReporter.shared.reload() } }
            cloud = c
            c.sync()
        }
        if let server {
            let h = BugServer(config: server, outbox: outbox)
            h.onChange = { Task { @MainActor in BugReporter.shared.reload() } }
            self.server = h
            h.sync()
        }
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
        ShakeHook.onShake = { BugReporter.shared.trigger() }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BugReporter.shared.trigger() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BugReporter.shared.syncNow() }
        }
        #endif
    }

    func reload() { reports = outbox.all() }

    /// Shake or screenshot. Captures the screen now, then asks "Report a bug?" when `askFirst` is on.
    public func trigger() {
        guard enabled, draft == nil, !asking else { return }
        guard askFirst else { begin(); return }
        pendingPNG = Self.capture(); pendingScreen = screenName?(); pendingContext = context?()
        asking = true
    }

    /// Answer to the "Report a bug?" prompt.
    public func answer(_ report: Bool) {
        asking = false
        let png = pendingPNG, screen = pendingScreen, ctx = pendingContext
        pendingPNG = nil; pendingScreen = nil; pendingContext = nil
        guard report else { return }
        // The alert must finish dismissing before the sheet presents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated { BugReporter.shared.draft = Draft(png: png, screen: screen, context: ctx) }
        }
    }

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
        syncNow()
    }

    public func syncNow() { sync?.sync(); cloud?.sync(); server?.sync() }

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
