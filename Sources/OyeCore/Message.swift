import Foundation

/// One thing sent between two people: a text, a voice note or a file.
public struct Message: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case text, voice, file }

    public let id: UUID
    public let sender: UUID
    public let recipient: UUID
    public let kind: Kind
    public var body: String
    public var fileName: String?
    public var bytes: Int?
    public var seconds: Double?
    public var path: String?
    public let createdAt: Date
    public var readAt: Date?

    public init(id: UUID, sender: UUID, recipient: UUID, kind: Kind = .text, body: String = "",
                fileName: String? = nil, bytes: Int? = nil, seconds: Double? = nil, path: String? = nil,
                createdAt: Date, readAt: Date? = nil) {
        self.id = id
        self.sender = sender
        self.recipient = recipient
        self.kind = kind
        self.body = body
        self.fileName = fileName
        self.bytes = bytes
        self.seconds = seconds
        self.path = path
        self.createdAt = createdAt
        self.readAt = readAt
    }

    /// The other person in this message, from `me`'s side.
    public func other(than me: UUID) -> UUID { sender == me ? recipient : sender }
}

/// Every thread you have, by the other person.
public struct Conversations: Equatable, Sendable {
    public private(set) var threads: [UUID: [Message]] = [:]

    public init() {}

    /// Adds a message, or replaces it if it's already here (a read receipt). Threads stay oldest first.
    public mutating func add(_ message: Message, me: UUID) {
        let other = message.other(than: me)
        var thread = threads[other] ?? []
        if let at = thread.firstIndex(where: { $0.id == message.id }) {
            thread[at] = message
        } else {
            thread.append(message)
            thread.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        }
        threads[other] = thread
    }

    public func thread(with other: UUID) -> [Message] { threads[other] ?? [] }

    /// How many messages from this person you haven't opened.
    public func unread(from other: UUID, me: UUID) -> Int {
        thread(with: other).filter { $0.sender == other && $0.recipient == me && $0.readAt == nil }.count
    }

    /// You opened their thread.
    public mutating func markRead(from other: UUID, me: UUID, now: Date) {
        guard var thread = threads[other] else { return }
        for at in thread.indices where thread[at].sender == other && thread[at].recipient == me && thread[at].readAt == nil {
            thread[at].readAt = now
        }
        threads[other] = thread
    }

    /// They were removed: the thread goes with them.
    public mutating func forget(_ other: UUID) { threads[other] = nil }
}
