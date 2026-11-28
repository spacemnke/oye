import Foundation

/// The rules for sent files: how big, how long they're kept, and how they're cut up to be sent.
public enum Files {
    /// 1 GB a file.
    public static let largest = 1024 * 1024 * 1024
    /// Files, voice notes and recordings are deleted from the server this long after they're sent.
    public static let kept: TimeInterval = 3 * 24 * 60 * 60

    /// A file is sent in parts, so a dropped connection costs one part, not the whole file.
    /// Every part is `part` bytes except the last, which is whatever's left.
    public static func parts(size: Int, part: Int) -> [(offset: Int, length: Int)] {
        guard size > 0, part > 0 else { return [] }
        return stride(from: 0, to: size, by: part).map { ($0, min(part, size - $0)) }
    }
}

extension Message {
    /// A file, voice note or recording whose three days on the server are up. Texts never expire.
    public func hasExpired(now: Date) -> Bool {
        kind != .text && now.timeIntervalSince(createdAt) > Files.kept
    }
}
