import Foundation

/// Invite codes: eight characters, no 0, O, 1 or I. Shared as a web link (which works for someone
/// who doesn't have Oye yet), opened in the app as oye://join/CODE, or typed in as just the code.
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
        if let range = upper.range(of: "/JOIN/") {
            let tail = String(upper[range.upperBound...].prefix(length))
            if isCode(tail) { return tail }
        }
        // Otherwise the first eight-character run that reads as a code.
        let runs = upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return runs.map(String.init).first(where: isCode)
    }

    /// Where Oye's pages live: the page behind an invite, and the page behind a file link.
    public static let site = "https://oye.spacemnke.workers.dev"

    /// The link that opens the app straight to joining.
    public static func link(for code: String) -> String { "oye://join/\(code)" }

    /// The link to send someone: a page that says who invited them and how to get Oye.
    public static func webLink(for code: String, from name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let who = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(site)/join/\(code)" + (who.isEmpty ? "" : "?from=\(who)")
    }

    /// What gets copied to send to someone.
    public static func shareText(code: String, from name: String) -> String {
        "Join me on Oye: \(webLink(for: code, from: name))"
    }
}
