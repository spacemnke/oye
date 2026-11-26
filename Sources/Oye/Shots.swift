import AppKit
import SwiftUI
import OyeCore

/// Draws Oye's panels to PNG files, for screenshots without a screen.
@MainActor
enum Shots {
    static func save<Content: View>(_ view: Content, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Twice the points, so it's sharp.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The menu bar faces in a row, as they're drawn in the menu bar.
    static func saveFaces(store: Store, to url: URL) {
        let people = store.people
        let step: CGFloat = 30
        let size = NSSize(width: step * CGFloat(people.count + 1) + 8, height: 30)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (at, person) in people.enumerated() {
                let face = Avatar.menuBarImage(for: person, here: store.isHere(person), unread: store.unread(from: person.id) > 0)
                face.draw(in: NSRect(x: 8 + step * CGFloat(at), y: 4, width: 22, height: 22))
            }
            Avatar.homeImage().draw(in: NSRect(x: 8 + step * CGFloat(people.count), y: 6, width: 20, height: 18))
            return true
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 4), pixelsHigh: Int(size.height * 4),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
