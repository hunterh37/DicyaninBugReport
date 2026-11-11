import XCTest
@testable import DicyaninBugReport

final class BugWireTests: XCTestCase {
    func report() -> BugReport {
        BugReport(note: "Button clipped", project: "Demo", bundleID: "org.dicyaninlabs.demo", appVersion: "1.0",
                  build: "7", device: "iPhone17,1", os: "iOS 26.1.0", screen: "home")
    }

    func testPostRoundTrip() throws {
        let r = report(), png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let frame = try BugWire.post(r, png: png)
        let req = try XCTUnwrap(try BugWire.parseRequest(frame))
        XCTAssertEqual(req.kind, .post)
        XCTAssertEqual(req.payload, png)
        let back = try BugWire.decoder.decode(BugReport.self, from: req.json)
        XCTAssertEqual(back.id, r.id)
        XCTAssertEqual(back.note, r.note)
    }

    func testPartialFrameNeedsMore() throws {
        let frame = try BugWire.post(report(), png: Data(repeating: 7, count: 100))
        for n in [0, 3, 8, 20, frame.count - 1] { XCTAssertNil(try BugWire.parseRequest(frame.prefix(n))) }
        XCTAssertNotNil(try BugWire.parseRequest(frame))
    }

    func testBadMagic() {
        XCTAssertThrowsError(try BugWire.parseRequest(Data("XXXX0".utf8)))
    }

    func testQueryAndReply() throws {
        let id = UUID()
        let req = try XCTUnwrap(try BugWire.parseRequest(try BugWire.query([id])))
        XCTAssertEqual(req.kind, .query)
        XCTAssertEqual(try BugWire.decoder.decode(BugWire.Query.self, from: req.json).ids, [id])
        let ack = BugWire.Ack(ok: true, states: [id.uuidString: .working], host: "Mac")
        let reply = try BugWire.reply(ack)
        XCTAssertNil(try BugWire.parseReply(reply.prefix(5)))
        XCTAssertEqual(try BugWire.parseReply(reply), ack)
    }

    func testOutboxPersistsOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let box = BugOutbox(root: root)
        var r = report()
        try box.save(r, png: Data([1, 2]))
        XCTAssertEqual(BugOutbox(root: root).all().first?.state, .queued)
        box.update(r.id) { $0.state = .received }
        r = try XCTUnwrap(box.all().first)
        XCTAssertTrue(r.delivered)
        XCTAssertEqual(box.png(r.id), Data([1, 2]))
        box.remove(r.id)
        XCTAssertTrue(box.all().isEmpty)
    }
}
