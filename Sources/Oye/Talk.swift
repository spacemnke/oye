import Foundation
import AVFoundation
import LiveKit
import Supabase
import OyeCore

/// The voice line two people share for hold to talk: a LiveKit room named after the pair.
/// Your microphone is only ever on while you're holding.
@MainActor
final class TalkLine {
    /// What the token function hands back.
    struct Pass: Decodable, Sendable {
        let url: String
        let token: String
        let room: String
    }

    /// The other person left, or the connection dropped.
    var onAlone: (() -> Void)?
    private(set) var roomName: String?
    private var room: Room?
    private var delegate: TalkDelegate?
    /// Bumped on every join and leave, so events from an old room are ignored.
    private var generation = 0

    var isOpen: Bool { room != nil }

    /// Into the pair's room. Already in it, nothing changes.
    func join(_ pass: Pass) async throws {
        if room != nil, roomName == pass.room { return }
        await leave()
        generation += 1
        let gen = generation
        let delegate = TalkDelegate { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.onAlone?()
            }
        }
        let room = Room(delegate: delegate)
        self.room = room
        self.delegate = delegate
        roomName = pass.room
        do {
            try await room.connect(url: pass.url, token: pass.token)
        } catch {
            if generation == gen {
                self.room = nil
                self.delegate = nil
                roomName = nil
            }
            await room.disconnect()
            throw error
        }
    }

    /// Hold to talk: the microphone goes live only while this is on.
    func setTalking(_ on: Bool) {
        guard let room else { return }
        Task { _ = try? await room.localParticipant.setMicrophone(enabled: on) }
    }

    func leave() async {
        guard let room else { return }
        generation += 1
        self.room = nil
        delegate = nil
        roomName = nil
        await room.disconnect()
    }
}

/// Hears from LiveKit on its own threads and passes on the one thing Oye needs to know.
private final class TalkDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private let alone: @Sendable () -> Void

    init(_ alone: @escaping @Sendable () -> Void) {
        self.alone = alone
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        alone()
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        alone()
    }
}

extension Store {
    private struct Ask: Encodable {
        let to: String
        let answer: Bool
    }

    /// How long the line stays open after the last word, so a reply doesn't have to reconnect.
    private static let lingers: UInt64 = 30_000_000_000

    /// You pressed hold to talk on someone.
    func startTalking(to id: UUID) {
        guard talkingTo == nil else { return }
        talkingTo = id
        notice = nil
        if Self.isDemo { return }
        talkIdle?.cancel()
        Task {
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Recorder.Problem.microphoneOff }
                let ask = Ask(to: id.uuidString.lowercased(), answer: false)
                let pass: TalkLine.Pass = try await client.functions.invoke("oye-talk", options: FunctionInvokeOptions(body: ask))
                try await line.join(pass)
                // You may have let go while it connected.
                if talkingTo == id {
                    line.setTalking(true)
                } else {
                    hangUpSoon()
                }
            } catch {
                if talkingTo == id { talkingTo = nil }
                notice = (error as? LocalizedError)?.errorDescription ?? "Couldn't open the line. " + Self.describe(error)
            }
        }
    }

    /// You let go.
    func stopTalking() {
        guard talkingTo != nil else { return }
        talkingTo = nil
        if Self.isDemo { return }
        line.setTalking(false)
        hangUpSoon()
    }

    /// Someone started talking to you: join their line to listen. Not on do not disturb.
    func heard(from caller: UUID) {
        guard !doNotDisturb, people.contains(where: { $0.id == caller }) else { return }
        hearing = caller
        Task {
            do {
                let ask = Ask(to: caller.uuidString.lowercased(), answer: true)
                let pass: TalkLine.Pass = try await client.functions.invoke("oye-talk", options: FunctionInvokeOptions(body: ask))
                try await line.join(pass)
                hangUpSoon()
            } catch {
                if hearing == caller { hearing = nil }
            }
        }
    }

    /// The other person left the line.
    func lineWentQuiet() {
        guard talkingTo == nil else { return }
        talkIdle?.cancel()
        hearing = nil
        Task { await line.leave() }
    }

    private func hangUpSoon() {
        talkIdle?.cancel()
        talkIdle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.lingers)
            guard let self, !Task.isCancelled, self.talkingTo == nil else { return }
            self.hearing = nil
            await self.line.leave()
        }
    }
}
