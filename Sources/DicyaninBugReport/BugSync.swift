import Foundation
import Network

/// Finds Cadence on the local network and delivers queued reports. Runs on launch, on network
/// change, when Cadence appears, after each new report and every 60 s while the app is active.
final class BugSync: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.dicyaninlabs.bugreport.sync")
    private let outbox: BugOutbox
    private var browser: NWBrowser?
    private var monitor: NWPathMonitor?
    private var endpoints: [NWEndpoint] = []
    private var running = false
    private var timer: DispatchSourceTimer?
    /// Called on the main queue: reachable, changed reports.
    var onChange: (@Sendable (Bool) -> Void)?

    init(outbox: BugOutbox) { self.outbox = outbox }

    func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let b = NWBrowser(for: .bonjour(type: BugWire.serviceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                self.endpoints = results.map(\.endpoint)
                self.notify()
                self.sync()
            }
            b.start(queue: queue)
            browser = b
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] p in if p.status == .satisfied { self?.sync() } }
            m.start(queue: queue)
            monitor = m
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 60, repeating: 60)
            t.setEventHandler { [weak self] in self?.sync() }
            t.resume()
            timer = t
        }
    }

    var reachable: Bool { queue.sync { !endpoints.isEmpty } }

    private func notify() {
        let up = !endpoints.isEmpty
        let cb = onChange
        DispatchQueue.main.async { cb?(up) }
    }

    /// Posts every queued report, then refreshes states of delivered ones that are not fixed.
    func sync() {
        queue.async { [self] in
            guard !running, let ep = endpoints.first else { return }
            running = true
            let all = outbox.all()
            var jobs: [(Data, UUID?)] = all.filter { $0.state == .queued }.compactMap { r in
                (try? BugWire.post(r, png: outbox.png(r.id) ?? Data())).map { ($0, r.id) }
            }
            let open = all.filter { $0.state == .received || $0.state == .working }.map(\.id)
            if !open.isEmpty, let q = try? BugWire.query(open) { jobs.append((q, nil)) }
            run(jobs[...], to: ep)
        }
    }

    private func run(_ jobs: ArraySlice<(Data, UUID?)>, to ep: NWEndpoint) {
        guard let (frame, _) = jobs.first else { running = false; notify(); return }
        send(frame, to: ep) { [weak self] ack in
            guard let self else { return }
            if let ack {
                for (k, s) in ack.states {
                    guard let id = UUID(uuidString: k) else { continue }
                    self.outbox.update(id) { r in
                        if r.receivedAt == nil { r.receivedAt = Date() }
                        r.state = s
                    }
                }
                self.notify()
                self.run(jobs.dropFirst(), to: ep)
            } else {
                self.running = false; self.notify()
            }
        }
    }

    private func send(_ frame: Data, to ep: NWEndpoint, done: @escaping (BugWire.Ack?) -> Void) {
        let c = NWConnection(to: ep, using: .tcp)
        var finished = false
        func finish(_ a: BugWire.Ack?) {
            guard !finished else { return }
            finished = true; c.cancel(); done(a)
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready:
                c.send(content: frame, completion: .contentProcessed { e in if e != nil { finish(nil) } })
                self.receive(c, Data(), finish)
            case .failed, .cancelled: finish(nil)
            case .waiting: finish(nil)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) { finish(nil) }
    }

    private func receive(_ c: NWConnection, _ buf: Data, _ finish: @escaping (BugWire.Ack?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, error in
            var buf = buf
            if let data { buf.append(data) }
            do {
                if let ack = try BugWire.parseReply(buf) { finish(ack); return }
            } catch { finish(nil); return }
            if isDone || error != nil { finish(nil) } else { self.receive(c, buf, finish) }
        }
    }
}
