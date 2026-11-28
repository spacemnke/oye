import Foundation

/// Who gets a face in the menu bar when there are more people than fit.
public enum Lineup {
    /// What decides someone's place.
    public struct Standing: Sendable {
        /// Their panel is open, or you're on a line with them.
        public var pinned: Bool
        public var unread: Bool
        public var here: Bool
        /// When the last message between you was sent.
        public var last: Date?

        public init(pinned: Bool = false, unread: Bool = false, here: Bool = false, last: Date? = nil) {
            self.pinned = pinned
            self.unread = unread
            self.here = here
            self.last = last
        }
    }

    /// Splits people into those shown and those behind "+N". Everyone is shown if they fit.
    /// Otherwise the places go to: anyone pinned, then unread, then here now, then whoever you
    /// spoke with most recently. Both lists keep the order people came in, so faces swap in and
    /// out but never shuffle.
    public static func split(_ people: [Person], most: Int, standing: (Person) -> Standing) -> (shown: [Person], more: [Person]) {
        guard most > 0, people.count > most else { return (people, []) }
        let ranked = people.enumerated().map { (at: $0.offset, standing: standing($0.element)) }.sorted { a, b in
            if a.standing.pinned != b.standing.pinned { return a.standing.pinned }
            if a.standing.unread != b.standing.unread { return a.standing.unread }
            if a.standing.here != b.standing.here { return a.standing.here }
            let first = a.standing.last ?? .distantPast, second = b.standing.last ?? .distantPast
            if first != second { return first > second }
            return a.at < b.at
        }
        let keep = Set(ranked.prefix(most).map(\.at))
        var shown: [Person] = [], more: [Person] = []
        for (at, person) in people.enumerated() {
            if keep.contains(at) { shown.append(person) } else { more.append(person) }
        }
        return (shown, more)
    }
}
