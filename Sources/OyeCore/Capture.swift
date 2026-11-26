import Foundation

/// Recording something to send: a voice note, a camera message or the screen. One at a time.
/// Idle, then recording, then a look at what you made (send it or throw it away).
public struct Capture: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case voice, video, screen

        /// What it becomes in a thread.
        public var messageKind: Message.Kind {
            switch self {
            case .voice: return .voice
            case .video: return .video
            case .screen: return .screen
            }
        }

        public var fileExtension: String { self == .voice ? "m4a" : "mov" }
        public var contentType: String { self == .voice ? "audio/mp4" : "video/quicktime" }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case recording(Kind, since: Date)
        case review(Kind, seconds: Double)
    }

    /// Recordings stop themselves here, so nothing huge gets sent by accident.
    public static let longest: TimeInterval = 120
    /// Shorter than this was a slip of the finger.
    public static let shortest: TimeInterval = 0.5

    public private(set) var phase: Phase = .idle
    /// Who it's for.
    public private(set) var target: UUID?

    public init() {}

    public var isIdle: Bool { phase == .idle }

    public var recording: Kind? {
        if case .recording(let kind, _) = phase { return kind }
        return nil
    }

    public var reviewing: Kind? {
        if case .review(let kind, _) = phase { return kind }
        return nil
    }

    /// Starts recording. Only from idle: a second recording can't start over the first.
    @discardableResult
    public mutating func start(_ kind: Kind, for person: UUID, now: Date) -> Bool {
        guard isIdle else { return false }
        phase = .recording(kind, since: now)
        target = person
        return true
    }

    /// Stops recording and moves to the review. False if it was too short to keep (back to idle).
    @discardableResult
    public mutating func stop(now: Date) -> Bool {
        guard case .recording(let kind, let since) = phase else { return false }
        let seconds = min(now.timeIntervalSince(since), Self.longest)
        if seconds < Self.shortest {
            clear()
            return false
        }
        phase = .review(kind, seconds: seconds)
        return true
    }

    /// Thrown away, sent, or it failed to start.
    public mutating func clear() {
        phase = .idle
        target = nil
    }

    public func elapsed(now: Date) -> TimeInterval {
        switch phase {
        case .idle: return 0
        case .recording(_, let since): return max(0, now.timeIntervalSince(since))
        case .review(_, let seconds): return seconds
        }
    }

    /// The limit has been reached and it should stop itself.
    public func isOver(now: Date) -> Bool {
        if case .recording(_, let since) = phase { return now.timeIntervalSince(since) >= Self.longest }
        return false
    }
}

/// Small bits of wording and naming shared by the app and the server.
public enum Labels {
    /// 7 seconds is "0:07"; 83 is "1:23".
    public static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let tail = total % 60
        return "\(total / 60):\(tail < 10 ? "0" : "")\(tail)"
    }

    /// 4,200,000 bytes is "4.2 MB"; small files are at least "1 KB".
    public static func size(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            let tenths = (Double(bytes) / 100_000).rounded()
            return "\(Int(tenths) / 10).\(Int(tenths) % 10) MB"
        }
        return "\(max(1, bytes / 1000)) KB"
    }

    /// Where a sent file lives in storage: the sender's folder, then the recipient's, then the file.
    /// The folders are what the storage rules check.
    public static func storagePath(sender: UUID, recipient: UUID, id: UUID, fileExtension: String) -> String {
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = id.uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext)
        return "\(sender.uuidString.lowercased())/\(recipient.uuidString.lowercased())/\(name)"
    }

    /// The voice room two people share for hold to talk. The same whoever asks.
    public static func talkRoom(_ a: UUID, _ b: UUID) -> String {
        let pair = [a.uuidString.lowercased(), b.uuidString.lowercased()].sorted()
        return "oye-\(pair[0])_\(pair[1])"
    }
}
