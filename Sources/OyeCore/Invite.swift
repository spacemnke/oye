import Foundation

/// Invite codes: eight characters, no 0, O, 1 or I. Shared as a link (oye://join/CODE) or just the code.
public enum Invite {
    public static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let length = 8

    public static func isCode(_ text: String) -> Bool {
        text.count == length && text.allSatisfy { alphabet.contains($0) }
    }

    /// Finds a code in whatever was pasted or opened: the code itself, a link, or a sentence with either.
    public static func code(in text: String) -> String? {
        let upper = text.uppercased()
        // A link says where the code is.
        if let range = upper.range(of: "OYE://JOIN/") {
            let tail = String(upper[range.upperBound...].prefix(length))
            if isCode(tail) { return tail }
        }
        // Otherwise the first eight-character run that reads as a code.
        let runs = upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return runs.map(String.init).first(where: isCode)
    }

    public static func link(for code: String) -> String { "oye://join/\(code)" }

    /// What gets copied to send to someone.
    public static func shareText(code: String) -> String {
        "Join me on Oye. Open \(link(for: code)) or paste this code in Oye: \(code)"
    }
}
