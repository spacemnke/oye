import SwiftUI
import AppKit
import CoreText

/// Oye's look, straight from the designs: white, near-black ink, soft grey panels, indigo used
/// sparingly, and Inter for type.
enum Theme {
    static let ink = Color(red: 0x17 / 255, green: 0x15 / 255, blue: 0x13 / 255)
    static let muted = Color(red: 0x6B / 255, green: 0x65 / 255, blue: 0x5D / 255)
    static let line = Color(red: 0xE7 / 255, green: 0xE3 / 255, blue: 0xDD / 255)
    static let soft = Color(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEE / 255)
    static let accent = Color(red: 0x4B / 255, green: 0x45 / 255, blue: 0xF0 / 255)
    static let here = Color(red: 0x2F / 255, green: 0xA8 / 255, blue: 0x6A / 255)

    static let accentNS = NSColor(srgbRed: 0x4B / 255, green: 0x45 / 255, blue: 0xF0 / 255, alpha: 1)

    /// Panel measurements from the designs.
    static let panelWidth: CGFloat = 540
    static let panelRadius: CGFloat = 44
    static let panelPadding: CGFloat = 22
    /// Room around a panel for its shadow.
    static let shadowRoom: CGFloat = 60

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

    enum Weight { case regular, medium, semibold, bold }

    /// Inter at this size. Falls back to the system font if Inter didn't load.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(name(weight), size: size)
    }

    static func nsFont(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        NSFont(name: name(weight), size: size) ?? .systemFont(ofSize: size, weight: weight == .bold ? .bold : .regular)
    }

    private static func name(_ weight: Weight) -> String {
        switch weight {
        case .regular: return "Inter-Regular"
        case .medium: return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold: return "Inter-Bold"
        }
    }

    /// Makes Inter available to this app (it isn't installed on the Mac).
    static func registerFonts() {
        guard let folder = Resources.folder("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}
