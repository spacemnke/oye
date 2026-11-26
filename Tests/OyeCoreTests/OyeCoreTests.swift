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

final class SVGPathTests: XCTestCase {
    private func close(_ a: SVGPath.Point, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.y, y, accuracy: 0.001, file: file, line: line)
    }

    func testLinesRelativeAndAbsolute() {
        let runs = SVGPath.runs("M4.5 2h6l3 3v11h-9z")
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].closed)
        XCTAssertEqual(runs[0].points.count, 5)
        close(runs[0].points[1], 10.5, 2)
        close(runs[0].points[2], 13.5, 5)
        close(runs[0].points[3], 13.5, 16)
        close(runs[0].points[4], 4.5, 16)
    }

    func testSeveralStrokesInOnePath() {
        let runs = SVGPath.runs("M3 7v4M6 4.5v9M9 6.5v5M12 3v12M15 7v4")
        XCTAssertEqual(runs.count, 5)
        XCTAssertFalse(runs[0].closed)
        close(runs[3].points[1], 12, 15)
    }

    func testTheMicsCupHangsBelow() {
        // From (3.5, 9) round to (14.5, 9): the lowest point is straight under the middle.
        let runs = SVGPath.runs("M3.5 9a5.5 5.5 0 0 0 11 0M9 14.5V16", arcSteps: 16)
        XCTAssertEqual(runs.count, 2)
        let cup = runs[0].points
        close(cup.first!, 3.5, 9)
        close(cup.last!, 14.5, 9)
        close(cup[8], 9, 14.5)
        close(runs[1].points[1], 9, 16)
    }

    func testSweepPicksTheOtherSide() {
        let up = SVGPath.arc(from: .init(0, 0), to: .init(10, 0), radius: 5, large: false, sweep: true, steps: 2)
        close(up[0], 5, -5)
        let down = SVGPath.arc(from: .init(0, 0), to: .init(10, 0), radius: 5, large: false, sweep: false, steps: 2)
        close(down[0], 5, 5)
    }

    func testNumbersRunTogetherWithoutSpaces() {
        let runs = SVGPath.runs("M14 8.5l-5.2 5.2a3.2 3.2 0 0 1-4.5-4.5L9.8 3.7")
        XCTAssertEqual(runs.count, 1)
        close(runs[0].points[1], 8.8, 13.7)
        close(runs[0].points.last!, 9.8, 3.7)
        XCTAssertTrue(runs[0].points.contains { abs($0.x - 4.3) < 0.001 && abs($0.y - 9.2) < 0.001 })
    }
}

final class CaptureTests: XCTestCase {
    private let ines = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let leo = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

    func testRecordThenReviewThenClear() {
        var c = Capture()
        XCTAssertTrue(c.isIdle)
        XCTAssertTrue(c.start(.voice, for: ines, now: t(0)))
        XCTAssertEqual(c.recording, .voice)
        XCTAssertEqual(c.target, ines)
        XCTAssertEqual(c.elapsed(now: t(7)), 7, accuracy: 0.001)
        XCTAssertTrue(c.stop(now: t(8)))
        XCTAssertEqual(c.reviewing, .voice)
        XCTAssertEqual(c.phase, .review(.voice, seconds: 8))
        XCTAssertEqual(c.elapsed(now: t(99)), 8, accuracy: 0.001, "the review keeps the length it had")
        c.clear()
        XCTAssertTrue(c.isIdle)
        XCTAssertNil(c.target)
    }

    func testOnlyOneRecordingAtATime() {
        var c = Capture()
        c.start(.screen, for: ines, now: t(0))
        XCTAssertFalse(c.start(.video, for: leo, now: t(1)))
        XCTAssertEqual(c.recording, .screen)
        XCTAssertEqual(c.target, ines)
        c.stop(now: t(5))
        XCTAssertFalse(c.start(.voice, for: leo, now: t(6)), "not while one is waiting to be sent")
    }

    func testASlipOfTheFingerIsThrownAway() {
        var c = Capture()
        c.start(.voice, for: ines, now: t(0))
        XCTAssertFalse(c.stop(now: t(0.2)))
        XCTAssertTrue(c.isIdle)
    }

    func testStopsItselfAtTheLimit() {
        var c = Capture()
        c.start(.video, for: ines, now: t(0))
        XCTAssertFalse(c.isOver(now: t(119)))
        XCTAssertTrue(c.isOver(now: t(120)))
        c.stop(now: t(500))
        XCTAssertEqual(c.phase, .review(.video, seconds: Capture.longest), "never longer than the limit")
    }

    func testStoppingWhenNotRecordingDoesNothing() {
        var c = Capture()
        XCTAssertFalse(c.stop(now: t(1)))
        XCTAssertTrue(c.isIdle)
    }

    func testWhatEachKindBecomes() {
        XCTAssertEqual(Capture.Kind.voice.messageKind, .voice)
        XCTAssertEqual(Capture.Kind.video.messageKind, .video)
        XCTAssertEqual(Capture.Kind.screen.messageKind, .screen)
        XCTAssertEqual(Capture.Kind.voice.fileExtension, "m4a")
        XCTAssertEqual(Capture.Kind.screen.fileExtension, "mov")
    }

    func testLabels() {
        XCTAssertEqual(Labels.time(7), "0:07")
        XCTAssertEqual(Labels.time(83), "1:23")
        XCTAssertEqual(Labels.time(0), "0:00")
        XCTAssertEqual(Labels.time(-4), "0:00")
        XCTAssertEqual(Labels.size(4_200_000), "4.2 MB")
        XCTAssertEqual(Labels.size(12_000_000), "12.0 MB")
        XCTAssertEqual(Labels.size(300), "1 KB")
        XCTAssertEqual(Labels.size(48_000), "48 KB")
    }

    func testStoragePathPutsBothPeopleInTheFolders() {
        let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000009")!
        XCTAssertEqual(Labels.storagePath(sender: ines, recipient: leo, id: id, fileExtension: "MOV"),
                       "00000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000003/aaaaaaaa-0000-0000-0000-000000000009.mov")
        XCTAssertTrue(Labels.storagePath(sender: ines, recipient: leo, id: id, fileExtension: "../x").hasSuffix("000000000009.x"),
                      "nothing in the extension can climb out of the folder")
        XCTAssertTrue(Labels.storagePath(sender: ines, recipient: leo, id: id, fileExtension: "").hasSuffix("000000000009"))
    }

    func testBothPeopleGetTheSameTalkRoom() {
        XCTAssertEqual(Labels.talkRoom(ines, leo), Labels.talkRoom(leo, ines))
        XCTAssertTrue(Labels.talkRoom(ines, leo).hasPrefix("oye-00000000-0000-0000-0000-000000000002_"))
    }
}
