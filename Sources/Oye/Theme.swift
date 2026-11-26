import SwiftUI
import AppKit

/// Oye's look: white, near-black ink, soft grey panels, and indigo used sparingly.
enum Theme {
    static let ink = Color(red: 0x17 / 255, green: 0x15 / 255, blue: 0x13 / 255)
    static let muted = Color(red: 0x6B / 255, green: 0x65 / 255, blue: 0x5D / 255)
    static let line = Color(red: 0xE7 / 255, green: 0xE3 / 255, blue: 0xDD / 255)
    static let soft = Color(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEE / 255)
    static let accent = Color(red: 0x4B / 255, green: 0x45 / 255, blue: 0xF0 / 255)
    static let here = Color(red: 0x2F / 255, green: 0xA8 / 255, blue: 0x6A / 255)

    static let accentNS = NSColor(srgbRed: 0x4B / 255, green: 0x45 / 255, blue: 0xF0 / 255, alpha: 1)
    static let hereNS = NSColor(srgbRed: 0x2F / 255, green: 0xA8 / 255, blue: 0x6A / 255, alpha: 1)

    /// Face colours for people with no photo yet.
    static let faces: [NSColor] = [
        NSColor(srgbRed: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255, alpha: 1),
        NSColor(srgbRed: 0xE0 / 255, green: 0x9F / 255, blue: 0x1F / 255, alpha: 1),
        NSColor(srgbRed: 0x3D / 255, green: 0xAE / 255, blue: 0x7A / 255, alpha: 1),
        NSColor(srgbRed: 0xB0 / 255, green: 0x6B / 255, blue: 0xE8 / 255, alpha: 1),
        NSColor(srgbRed: 0xE8 / 255, green: 0x6F / 255, blue: 0x9A / 255, alpha: 1),
        NSColor(srgbRed: 0x2F / 255, green: 0xB3 / 255, blue: 0xC4 / 255, alpha: 1),
        NSColor(srgbRed: 0x8E / 255, green: 0x9A / 255, blue: 0x2E / 255, alpha: 1),
        NSColor(srgbRed: 0x6E / 255, green: 0x6A / 255, blue: 0x64 / 255, alpha: 1)
    ]
}
