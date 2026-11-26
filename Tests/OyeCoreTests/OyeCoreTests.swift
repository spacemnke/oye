import XCTest
@testable import OyeCore

final class OyeCoreTests: XCTestCase {
    private let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let ines = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let leo = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func text(_ body: String, from: UUID, to: UUID, at t: TimeInterval, id: UUID = UUID()) -> Message {
        Message(id: id, sender: from, recipient: to, body: body, createdAt: Date(timeIntervalSince1970: t))
    }

    // MARK: People

    func testInitials() {
        XCTAssertEqual(Person(id: ines, name: "Ines Marin").initials, "IM")
        XCTAssertEqual(Person(id: leo, name: "leo").initials, "L")
        XCTAssertEqual(Person(id: leo, name: "Ana-Maria de la Cruz").initials, "AM")
        XCTAssertEqual(Person(id: leo, name: "  ").initials, "?")
    }

    func testHereUntilTheyGoQuiet() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(Person(id: ines, name: "Ines", lastSeen: now.addingTimeInterval(-30)).isHere(now: now))
        XCTAssertFalse(Person(id: ines, name: "Ines", lastSeen: now.addingTimeInterval(-80)).isHere(now: now))
        XCTAssertFalse(Person(id: ines, name: "Ines").isHere(now: now), "quit, so no check-in at all")
    }

    func testAPersonKeepsTheirColour() {
        let a = Person(id: ines, name: "Ines"), b = Person(id: ines, name: "Renamed")
        XCTAssertEqual(a.colourIndex(of: 8), b.colourIndex(of: 8))
        XCTAssertTrue((0..<8).contains(a.colourIndex(of: 8)))
        XCTAssertEqual(a.colourIndex(of: 0), 0)
    }

    // MARK: Threads

    func testThreadsAreKeptByTheOtherPersonOldestFirst() {
        var c = Conversations()
        c.add(text("second", from: ines, to: me, at: 20), me: me)
        c.add(text("first", from: me, to: ines, at: 10), me: me)
        c.add(text("hi leo", from: me, to: leo, at: 15), me: me)
        XCTAssertEqual(c.thread(with: ines).map(\.body), ["first", "second"])
        XCTAssertEqual(c.thread(with: leo).map(\.body), ["hi leo"])
    }

    func testTheSameMessageTwiceIsOneMessage() {
        var c = Conversations()
        let id = UUID()
        c.add(text("oye", from: ines, to: me, at: 10, id: id), me: me)
        var read = text("oye", from: ines, to: me, at: 10, id: id)
        read.readAt = Date(timeIntervalSince1970: 12)
        c.add(read, me: me)
        XCTAssertEqual(c.thread(with: ines).count, 1)
        XCTAssertNotNil(c.thread(with: ines).first?.readAt, "the later copy carries the read receipt")
    }

    func testUnreadCountsOnlyWhatTheySentYou() {
        var c = Conversations()
        c.add(text("one", from: ines, to: me, at: 1), me: me)
        c.add(text("two", from: ines, to: me, at: 2), me: me)
        c.add(text("mine", from: me, to: ines, at: 3), me: me)
        XCTAssertEqual(c.unread(from: ines, me: me), 2)
        XCTAssertEqual(c.unread(from: leo, me: me), 0)
        c.markRead(from: ines, me: me, now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(c.unread(from: ines, me: me), 0)
        XCTAssertNil(c.thread(with: ines).last?.readAt, "your own message isn't yours to mark read")
    }

    func testForgettingSomeoneDropsTheirThread() {
        var c = Conversations()
        c.add(text("one", from: ines, to: me, at: 1), me: me)
        c.forget(ines)
        XCTAssertTrue(c.thread(with: ines).isEmpty)
    }

    // MARK: Invites

    func testFindsACodeHoweverItArrives() {
        XCTAssertEqual(Invite.code(in: "ABCD2345"), "ABCD2345")
        XCTAssertEqual(Invite.code(in: " abcd2345 \n"), "ABCD2345")
        XCTAssertEqual(Invite.code(in: "oye://join/ABCD2345"), "ABCD2345")
        XCTAssertEqual(Invite.code(in: Invite.shareText(code: "WXYZ6789")), "WXYZ6789")
        XCTAssertNil(Invite.code(in: "hello there"))
        XCTAssertNil(Invite.code(in: "ABCD1234"), "1 isn't in the alphabet")
        XCTAssertNil(Invite.code(in: "ABCD234"), "too short")
    }

    func testLink() {
        XCTAssertEqual(Invite.link(for: "ABCD2345"), "oye://join/ABCD2345")
    }

    // MARK: Timestamps

    func testReadsPostgresTimestamps() {
        let base = Date(timeIntervalSince1970: 1_795_688_749)
        let plain = Stamp.parse("2026-11-26T10:25:49+00:00")
        XCTAssertNotNil(plain)
        XCTAssertEqual(Stamp.parse("2026-11-26T10:25:49Z"), plain)
        XCTAssertEqual(Stamp.parse("2026-11-26 10:25:49+00"), plain)
        XCTAssertEqual(Stamp.parse("2026-11-26T10:25:49"), plain)
        XCTAssertEqual(Stamp.parse("2026-11-26T11:25:49+01:00"), plain)
        let fine = Stamp.parse("2026-11-26T10:25:49.250000+00:00")
        XCTAssertEqual(fine!.timeIntervalSince(plain!), 0.25, accuracy: 0.0001)
        XCTAssertNil(Stamp.parse("yesterday"))
        _ = base
    }
}
