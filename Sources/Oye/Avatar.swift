import AppKit
import SwiftUI
import OyeCore

/// A person's face: a coloured circle with their initials until photos arrive.
enum Avatar {
    /// The face as it sits in the menu bar, with a green dot when they're around and an indigo
    /// dot when they've sent something you haven't opened.
    static func menuBarImage(for person: Person, here: Bool, unread: Bool) -> NSImage {
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let face = rect.insetBy(dx: 1, dy: 1)
            Theme.faces[person.colourIndex(of: Theme.faces.count)].withAlphaComponent(here ? 1 : 0.45).setFill()
            NSBezierPath(ovalIn: face).fill()
            let letters = person.initials as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: letters.length > 1 ? 9 : 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = letters.size(withAttributes: attributes)
            letters.draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2), withAttributes: attributes)
            if unread {
                let dot = NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot).fill()
                Theme.accentNS.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Oye's own menu bar icon: a ring with a dot beside it. A template, so macOS tints it.
    static func homeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 11, height: 11))
            ring.lineWidth = 2.4
            ring.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13.5, y: 11, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The same face, in a panel.
struct FaceView: View {
    let person: Person
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: Theme.faces[person.colourIndex(of: Theme.faces.count)]))
            Text(person.initials)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
