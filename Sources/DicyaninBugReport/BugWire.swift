import Foundation

/// Cadence bug protocol v1 over TCP, advertised with Bonjour as `_cadencebug._tcp`.
///
/// Request frame:
///   4 bytes  magic "DBR1"
///   1 byte   kind: "P" post a report, "Q" query states
///   4 bytes  big-endian JSON length, then JSON (a `BugReport` for P, a `BugQuery` for Q)
///   8 bytes  big-endian payload length, then payload (PNG screenshot for P, empty for Q)
/// Reply frame:
///   4 bytes  big-endian JSON length, then JSON `BugAck`. The server closes after the reply.
public enum BugWire {
    public static let serviceType = "_cadencebug._tcp"
    public static let magic = Data("DBR1".utf8)
    public static let maxJSON = 1 << 20
    public static let maxPayload = 64 << 20

    public enum Kind: UInt8, Sendable { case post = 0x50, query = 0x51 }

    public struct Query: Codable, Sendable, Equatable {
        public var ids: [UUID]
        public init(ids: [UUID]) { self.ids = ids }
    }

    public struct Ack: Codable, Sendable, Equatable {
        public var ok: Bool
        /// Report id (uuidString) to Cadence state.
        public var states: [String: BugState]
        public var host: String
        public init(ok: Bool, states: [String: BugState], host: String) { self.ok = ok; self.states = states; self.host = host }
    }

    public struct Request: Sendable, Equatable {
        public var kind: Kind
        public var json: Data
        public var payload: Data
    }

    public enum WireError: Error, Equatable { case badMagic, badKind, tooLarge, truncated }

    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func request(_ kind: Kind, json: Data, payload: Data = Data()) -> Data {
        var d = magic
        d.append(kind.rawValue)
        d.append(be(UInt32(json.count))); d.append(json)
        d.append(be(UInt64(payload.count))); d.append(payload)
        return d
    }

    public static func post(_ r: BugReport, png: Data) throws -> Data {
        request(.post, json: try encoder.encode(r), payload: png)
    }

    public static func query(_ ids: [UUID]) throws -> Data {
        request(.query, json: try encoder.encode(Query(ids: ids)))
    }

    /// Parses a complete request. Returns nil while more bytes are needed.
    public static func parseRequest(_ d: Data) throws -> Request? {
        let b = [UInt8](d)
        guard b.count >= 4 else { return nil }
        guard Data(b[0..<4]) == magic else { throw WireError.badMagic }
        guard b.count >= 9 else { return nil }
        guard let kind = Kind(rawValue: b[4]) else { throw WireError.badKind }
        let jl = Int(read32(b, 5))
        guard jl <= maxJSON else { throw WireError.tooLarge }
        guard b.count >= 9 + jl + 8 else { return nil }
        let pl = read64(b, 9 + jl)
        guard pl <= UInt64(maxPayload) else { throw WireError.tooLarge }
        let start = 9 + jl + 8
        guard b.count >= start + Int(pl) else { return nil }
        return Request(kind: kind, json: Data(b[9..<(9 + jl)]), payload: Data(b[start..<(start + Int(pl))]))
    }

    public static func reply(_ ack: Ack) throws -> Data {
        let j = try encoder.encode(ack)
        var d = be(UInt32(j.count)); d.append(j)
        return d
    }

    /// Parses a complete reply. Returns nil while more bytes are needed.
    public static func parseReply(_ d: Data) throws -> Ack? {
        let b = [UInt8](d)
        guard b.count >= 4 else { return nil }
        let n = Int(read32(b, 0))
        guard n <= maxJSON else { throw WireError.tooLarge }
        guard b.count >= 4 + n else { return nil }
        return try decoder.decode(Ack.self, from: Data(b[4..<(4 + n)]))
    }

    static func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    static func read32(_ b: [UInt8], _ i: Int) -> UInt32 { b[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
    static func read64(_ b: [UInt8], _ i: Int) -> UInt64 { b[i..<(i + 8)].reduce(0) { $0 << 8 | UInt64($1) } }
}
