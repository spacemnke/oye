import AppKit
import SwiftUI
import OyeCore

/// Draws Oye's panels to PNG files, for screenshots without a screen.
@MainActor
enum Shots {
    /// The view at its own size, on white, at twice the points so it's sharp.
    static func save<Content: View>(_ view: Content, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color.white).environment(\.colorScheme, .light))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = bitmap(size, scale: 2) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The menu bar faces, enlarged, on a menu-bar grey.
    static func saveStrip(store: Store, open: UUID?, to url: URL) {
        saveStrip(FaceStrip(people: store.people, open: open), store: store, to: url)
    }

    static func saveStrip(_ strip: FaceStrip, store: Store, to url: URL) {
        let image = strip.image(photo: { store.photo(for: $0) }, here: { store.isHere($0) }, unread: { store.unread(from: $0.id) > 0 })
        let size = NSSize(width: strip.width + 16, height: FaceStrip.height + 8)
        guard let rep = bitmap(size, scale: 6) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 8, y: 4, width: strip.width, height: FaceStrip.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func bitmap(_ size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
