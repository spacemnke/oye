import AppKit
import AVFoundation
import CryptoKit
import OyeCore

/// The live check: two copies of Oye, signed in as two brand-new people (Ana and Ben), do what two
/// friends would do, through the real server. Each copy runs this with OYE_LIVE=ana or ben, a
/// shared OYE_LIVE_DIR to leave notes for the other, and its own OYE_PROFILE.
///
/// It drives the same Store the panels use, so what passes here is what the app does. What it
/// can't do is record: there's no microphone or camera to record from, so the voice note and the
/// videos it sends are made here instead, in the formats the recorder writes.
@MainActor
final class LiveCheck {
    enum Role: String { case ana, ben }

    private let store: Store
    private let role: Role
    private let dir: URL
    private let openChat: (UUID) -> Void
    private var failures = 0

    init(store: Store, role: Role, folder: String, openChat: @escaping (UUID) -> Void) {
        self.store = store
        self.role = role
        self.dir = URL(fileURLWithPath: folder, isDirectory: true)
        self.openChat = openChat
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var other: Role { role == .ana ? .ben : .ana }

    func run() {
        // Whatever happens, it ends.
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000_000)
            fail("Finishes in time", "still going after 400 seconds")
            await finish()
        }
        Task {
            switch role {
            case .ana: await ana()
            case .ben: await ben()
            }
            await finish()
        }
    }

    private func finish() async {
        mark(role.rawValue + "-stopped")
        say("RESULT " + (failures == 0 ? "pass" : "fail (\(failures))"))
        await store.signOff(timeout: 3)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Ana

    private func ana() async {
        store.setName("Ana")
        guard await check("Ana signs in with a new account", within: 40, { store.status == .online }) else { return }
        store.makeInvite()
        guard await check("Ana gets an invite code", within: 20, { store.inviteCode != nil }), let code = store.inviteCode else { return }
        mark("invite", code)

        guard await check("Ben appears on Ana's Mac when he joins", within: 120, fast: 8, since: "ben-joined", { store.people.count == 1 }),
              let ben = store.people.first else { return }
        expect("He's called Ben and shows as here", ben.name == "Ben" && ben.isHere(now: Date()), "name \(ben.name), last seen \(String(describing: ben.lastSeen))")

        // Texting, and the read receipt.
        let hello = "Did the deck go out?"
        mark("ana-text")
        store.send(hello, to: ben.id)
        func mine() -> Message? { thread(ben.id).first { $0.sender != ben.id && $0.body == hello } }
        guard await check("Ana's text is sent", within: 20, { mine() != nil }) else { return }
        await check("Ana sees that Ben read it", within: 60, fast: 8, since: "ben-read", { mine()?.readAt != nil })
        await check("Ben's reply arrives on Ana's Mac", within: 60, fast: 8, since: "ben-text", {
            thread(ben.id).contains { $0.sender == ben.id && $0.kind == .text }
        })
        expect("The reply counts as unread", store.unread(from: ben.id) == 1, "unread is \(store.unread(from: ben.id))")

        // A file.
        let photo = scratch("Team photo.jpg")
        if let source = Resources.folder("Demo")?.appendingPathComponent("ines.jpg"), (try? FileManager.default.copyItem(at: source, to: photo)) != nil {
            mark("file-sha", sha(photo))
            mark("ana-file")
            store.sendFiles([photo], to: ben.id)
            await check("Ana's file uploads", within: 60, { thread(ben.id).contains { $0.sender != ben.id && $0.kind == .file } })
        } else {
            fail("Ana's file uploads", "the check couldn't find a file to send")
        }
        _ = await waitMark("ben-file", 90)

        // A voice note.
        let tone = scratch("voice.m4a")
        if Self.makeTone(at: tone, seconds: 3) {
            mark("voice-sha", sha(tone))
            mark("ana-voice")
            await send(tone, as: .voice, seconds: 3, to: ben.id, step: "Ana's voice note uploads")
        } else {
            skip("Ana's voice note uploads", "couldn't make a sound file on this machine")
        }
        _ = await waitMark("ben-voice", 90)

        // A camera message.
        let clip = scratch("camera.mov")
        if await Self.makeMovie(at: clip, seconds: 2) {
            mark("video-sha", sha(clip))
            mark("ana-video")
            await send(clip, as: .video, seconds: 2, to: ben.id, step: "Ana's camera message uploads")
        } else {
            skip("Ana's camera message uploads", "couldn't make a video file on this machine")
        }
        _ = await waitMark("ben-video", 90)

        // Ben's screen recording comes the other way.
        if await check("Ben's screen recording arrives on Ana's Mac", within: 90, fast: 15, since: "ben-screen", {
            thread(ben.id).contains { $0.sender == ben.id && $0.kind == .screen }
        }), let recording = thread(ben.id).first(where: { $0.sender == ben.id && $0.kind == .screen }) {
            if let file = await fetched(recording, shaMark: "screen-sha", step: "Ana downloads it, identical to what Ben sent") {
                await playable(file, video: true, step: "It plays on Ana's Mac")
            }
        }

        // Hold to talk, without the microphone: the line itself.
        mark("ana-talk")
        do {
            let began = Date()
            try await store.openLine(to: ben.id)
            pass("Ana opens the voice line to Ben", Date().timeIntervalSince(began))
        } catch {
            fail("Ana opens the voice line to Ben", String(describing: error).prefix(300).description)
        }
        await check("Ana's Mac sees Ben on the line", within: 40, { store.line.isConnected && store.line.others == 1 })
        _ = await waitMark("ben-on-line", 45)
        mark("ana-hung-up")
        await store.line.leave()
        _ = await waitMark("ben-line-closed", 40)

        // The thread, open for real, so the screen can be captured.
        openChat(ben.id)
        mark("shot-now")

        if await waitMark("ben-left", 120) != nil {
            await check("Ben shows as away on Ana's Mac once he quits", within: 60, fast: 8, since: "ben-left", {
                store.person(ben.id).map { !$0.isHere(now: Date()) } ?? false
            })
        }
        shots(open: ben.id)

        store.remove(ben.id)
        await check("Removing Ben takes him off Ana's Mac", within: 20, { store.people.isEmpty })
    }

    // MARK: Ben

    private func ben() async {
        store.setName("Ben")
        guard await check("Ben signs in with a new account", within: 40, { store.status == .online }) else { return }
        guard let invite = await waitMark("invite", 90) else {
            fail("Ben gets Ana's invite", "Ana never made one")
            return
        }

        store.join("QQQQ2222")
        await check("A made-up invite code is turned away", within: 20, { store.notice == "Wrong or expired invite" })
        store.notice = nil

        mark("ben-joined")
        store.join(invite.text)
        guard await check("Ben joins with Ana's code", within: 30, { store.people.count == 1 }), let ana = store.people.first else { return }
        expect("She's called Ana and shows as here", ana.name == "Ana" && ana.isHere(now: Date()), "name \(ana.name), last seen \(String(describing: ana.lastSeen))")

        guard await check("Ana's text arrives on Ben's Mac", within: 90, fast: 8, since: "ana-text", {
            thread(ana.id).contains { $0.sender == ana.id && $0.kind == .text }
        }) else { return }
        expect("It reads the same", thread(ana.id).first?.body == "Did the deck go out?", "got \(thread(ana.id).first?.body ?? "nothing")")
        expect("It counts as unread", store.unread(from: ana.id) == 1, "unread is \(store.unread(from: ana.id))")
        mark("ben-read")
        store.markRead(ana.id)
        mark("ben-text")
        store.send("Yes, sending it now", to: ana.id)
        await check("Ben's reply is sent", within: 20, { thread(ana.id).contains { $0.sender != ana.id && $0.kind == .text } })

        // Ana's file.
        if await check("Ana's file arrives on Ben's Mac", within: 120, fast: 15, since: "ana-file", { got(.file, from: ana.id) != nil }),
           let file = got(.file, from: ana.id) {
            expect("It keeps its name and size", file.fileName == "Team photo.jpg" && (file.bytes ?? 0) > 0, "name \(file.fileName ?? "none"), \(file.bytes ?? 0) bytes")
            _ = await fetched(file, shaMark: "file-sha", step: "Ben downloads it, identical to what Ana sent")
        }
        mark("ben-file")

        if await check("Ana's voice note arrives on Ben's Mac", within: 120, fast: 15, since: "ana-voice", { got(.voice, from: ana.id) != nil }),
           let voice = got(.voice, from: ana.id) {
            if let file = await fetched(voice, shaMark: "voice-sha", step: "Ben downloads it, identical to what Ana sent") {
                await playable(file, video: false, step: "It plays on Ben's Mac")
            }
        }
        mark("ben-voice")

        if await check("Ana's camera message arrives on Ben's Mac", within: 120, fast: 15, since: "ana-video", { got(.video, from: ana.id) != nil }),
           let video = got(.video, from: ana.id) {
            if let file = await fetched(video, shaMark: "video-sha", step: "Ben downloads it, identical to what Ana sent") {
                await playable(file, video: true, step: "It plays on Ben's Mac")
            }
        }
        mark("ben-video")

        // A screen recording, the other way.
        let clip = scratch("screen.mov")
        if await Self.makeMovie(at: clip, seconds: 2) {
            mark("screen-sha", sha(clip))
            mark("ben-screen")
            await send(clip, as: .screen, seconds: 2, to: ana.id, step: "Ben's screen recording uploads")
        } else {
            skip("Ben's screen recording uploads", "couldn't make a video file on this machine")
        }

        // Ana starts talking: this Mac should join her line by itself.
        if await check("Ben's Mac joins the line when Ana starts talking", within: 150, fast: 12, since: "ana-talk", {
            store.hearing == ana.id && store.line.isConnected && store.line.others == 1
        }) {
            mark("ben-on-line")
            await check("Ben's Mac leaves the line when Ana hangs up", within: 40, fast: 8, since: "ana-hung-up", {
                store.hearing == nil && !store.line.isOpen
            })
        }
        mark("ben-line-closed")

        // Leave time for the screen to be captured with both of us in the menu bar.
        if await waitMark("shot-now", 30) != nil { try? await Task.sleep(nanoseconds: 8_000_000_000) }
        mark("ben-left")
        await store.signOff(timeout: 4)
        shots(open: ana.id)
    }

    // MARK: Steps

    private func thread(_ id: UUID) -> [Message] { store.conversations.thread(with: id) }

    private func got(_ kind: Message.Kind, from id: UUID) -> Message? {
        thread(id).first { $0.sender == id && $0.kind == kind }
    }

    /// Waits for something to be true. With `since`, measures from the moment the other copy did
    /// its part; with `fast`, taking longer than that is a failure even if it got there, because
    /// it means it only arrived on the 30-second re-read, not live.
    @discardableResult
    private func check(_ step: String, within timeout: Double, fast: Double? = nil, since: String? = nil,
                       _ ready: () -> Bool) async -> Bool {
        let began = Date()
        var happened: Date?
        while Date().timeIntervalSince(began) < timeout {
            if ready() {
                happened = Date()
                break
            }
            if otherStopped(), !ready() { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let happened else {
            var why = otherStopped() ? "the other copy stopped first" : "nothing after \(Int(timeout)) seconds"
            if let notice = store.notice { why += "; Oye says \"\(notice)\"" }
            if case .offline(let reason) = store.status { why += "; status \"\(reason)\"" }
            fail(step, why)
            return false
        }
        var took = happened.timeIntervalSince(began)
        if let since, let from = await waitMark(since, 5) { took = max(0, happened.timeIntervalSince(from.at)) }
        if let fast, took > fast {
            fail(step, String(format: "it got there, but took %.1f seconds: not arriving live", took))
            return true
        }
        pass(step, took)
        return true
    }

    private func expect(_ step: String, _ ok: Bool, _ why: @autoclosure () -> String) {
        if ok { pass(step, nil) } else { fail(step, why()) }
    }

    /// Sends a made file the way a recording is sent.
    private func send(_ file: URL, as kind: Capture.Kind, seconds: Double, to id: UUID, step: String) async {
        let began = Date()
        do {
            try await store.upload(file, kind: kind.messageKind, name: nil, seconds: seconds, contentType: kind.contentType, to: id)
            pass(step, Date().timeIntervalSince(began))
        } catch {
            fail(step, String(describing: error).prefix(300).description)
        }
    }

    /// Downloads what a message points at and compares it, byte for byte, with what was sent.
    private func fetched(_ message: Message, shaMark: String, step: String) async -> URL? {
        let began = Date()
        guard let url = await store.file(for: message), let data = try? Data(contentsOf: url) else {
            fail(step, "couldn't download it" + (store.notice.map { "; Oye says \"\($0)\"" } ?? ""))
            return nil
        }
        let took = Date().timeIntervalSince(began)
        let want = await waitMark(shaMark, 5)?.text
        if Self.sha(data) == want {
            pass(step, took, "\(data.count) bytes")
        } else {
            fail(step, "\(data.count) bytes arrived, but they differ from what was sent")
        }
        return url
    }

    private func playable(_ file: URL, video: Bool, step: String) async {
        if video {
            let asset = AVURLAsset(url: file)
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let length = (try? await asset.load(.duration).seconds) ?? 0
            expect(step, !tracks.isEmpty && length > 1, "\(tracks.count) video tracks, \(length) seconds")
        } else {
            let length = (try? AVAudioPlayer(contentsOf: file))?.duration ?? 0
            expect(step, length > 2, "\(length) seconds of sound")
        }
    }

    private func shots(open id: UUID) {
        Shots.saveStrip(store: store, open: id, to: dir.appendingPathComponent(role.rawValue + "-faces.png"))
        Shots.save(ChatView(store: store, personID: id), to: dir.appendingPathComponent(role.rawValue + "-chat.png"))
    }

    // MARK: Notes

    private func say(_ line: String) {
        let text = role.rawValue + " " + line + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        let url = dir.appendingPathComponent(role.rawValue + ".log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private func pass(_ step: String, _ took: Double?, _ detail: String = "") {
        var line = "PASS " + step
        if let took { line += String(format: " (%.1fs)", took) }
        if !detail.isEmpty { line += " [" + detail + "]" }
        say(line)
    }

    private func fail(_ step: String, _ why: String) {
        failures += 1
        say("FAIL " + step + ": " + why)
    }

    private func skip(_ step: String, _ why: String) { say("SKIP " + step + ": " + why) }

    /// A note for the other copy: when it was left, and maybe a word.
    private func mark(_ name: String, _ text: String = "") {
        let body = String(Date().timeIntervalSince1970) + "\n" + text
        try? Data(body.utf8).write(to: dir.appendingPathComponent(name + ".mark"), options: .atomic)
    }

    private func readMark(_ name: String) -> (at: Date, text: String)? {
        guard let body = try? String(contentsOf: dir.appendingPathComponent(name + ".mark"), encoding: .utf8) else { return nil }
        let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let seconds = Double(first) else { return nil }
        return (Date(timeIntervalSince1970: seconds), parts.count > 1 ? String(parts[1]) : "")
    }

    private func waitMark(_ name: String, _ timeout: Double) async -> (at: Date, text: String)? {
        let began = Date()
        while Date().timeIntervalSince(began) < timeout {
            if let found = readMark(name) { return found }
            if otherStopped() { return readMark(name) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return readMark(name)
    }

    private func otherStopped() -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(other.rawValue + "-stopped.mark").path)
    }

    // MARK: Files to send

    private func scratch(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oye-live-" + UUID().uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private func sha(_ file: URL) -> String { (try? Data(contentsOf: file)).map(Self.sha) ?? "" }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A few seconds of a quiet tone, in the format voice notes are recorded in.
    private static func makeTone(at url: URL, seconds: Double) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * seconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  let samples = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = frames
            for i in 0..<Int(frames) { samples[i] = Float(sin(Double(i) * 2 * Double.pi * 440 / 44_100) * 0.2) }
            try file.write(from: buffer)
        } catch {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A short QuickTime movie of plain frames, the kind of file camera and screen recordings are.
    private static func makeMovie(at url: URL, seconds: Int) async -> Bool {
        let width = 640, height = 400
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let rate: Int32 = 10
        for frame in 0..<(seconds * Int(rate)) {
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 300 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made)
            guard let buffer = made else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(60 + (frame * 6) % 160), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate)) else { return false }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
