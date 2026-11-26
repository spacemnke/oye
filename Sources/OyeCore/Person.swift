import Foundation

/// Someone in your menu bar.
public struct Person: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// When their Oye last checked in. Nil once they quit.
    public var lastSeen: Date?

    /// They check in every 30 seconds; this long without one and they've gone.
    public static let awayAfter: TimeInterval = 75

    public init(id: UUID, name: String, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
    }

    public func isHere(now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < Self.awayAfter
    }

    /// One or two letters for a face with no photo: "Ines Marin" is IM, "leo" is L.
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Which of `count` face colours this person gets. The same person always gets the same one.
    public func colourIndex(of count: Int) -> Int {
        guard count > 0 else { return 0 }
        var total = 0
        for byte in id.uuidString.utf8 { total = (total &* 31 &+ Int(byte)) % 1_000_003 }
        return total % count
    }
}
