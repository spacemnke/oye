import Foundation

/// Reads the timestamps Postgres sends: "2026-11-26T10:25:49.209152+00:00", with or without the
/// fraction, with a space for the T, or with a short "+00" offset.
public enum Stamp {
    public static func parse(_ text: String) -> Date? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        guard s.count >= 19 else { return nil }
        // Split off the fraction, if there is one.
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + String(s[dot..<end])) ?? 0
            s.removeSubrange(dot..<end)
        }
        // The zone: none means UTC, and "+00" is short for "+00:00".
        let zone = s.dropFirst(19)
        if zone.isEmpty {
            s += "Z"
        } else if zone.count == 3, zone.first == "+" || zone.first == "-" {
            s += ":00"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: s) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
