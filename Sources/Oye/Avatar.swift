import AppKit
import SwiftUI
import OyeCore

/// People's faces: their photo in a circle, or a coloured circle with their initials until they have one.
enum Avatar {
    /// One face, drawn into `rect` in the current graphics context.
    static func draw(_ person: Person, photo: NSImage?, in rect: NSRect, alpha: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        if let photo {
            // Fill the circle, cropping the longer side.
            let from = photo.size
            let side = min(from.width, from.height)
            let source = NSRect(x: (from.width - side) / 2, y: (from.height - side) / 2, width: side, height: side)
            photo.draw(in: rect, from: source, operation: .sourceOver, fraction: alpha)
        } else {
            Theme.faces[person.colourIndex(of: Theme.faces.count)].withAlphaComponent(alpha).setFill()
            rect.fill()
            let letters = person.initials as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.nsFont(rect.height * (letters.length > 1 ? 0.4 : 0.48), .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha)
            ]
            let size = letters.size(withAttributes: attributes)
            letters.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Oye's own menu bar icon: a ring with a dot beside it. A template, so macOS tints it.
    static func homeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
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

/// The row of faces in the menu bar, as in the designs: overlapping, with the open one a little
/// larger inside a ring. One image, so the faces can overlap; `frames` says where each one is.
struct FaceStrip {
    static let height: CGFloat = 24
    static let face: CGFloat = 17
    static let openFace: CGFloat = 20.5
    static let overlap: CGFloat = 3.5
    static let pad: CGFloat = 5

    let people: [Person]
    let open: UUID?

    var width: CGFloat {
        guard !people.isEmpty else { return 0 }
        return Self.pad * 2 + CGFloat(people.count) * Self.face - CGFloat(people.count - 1) * Self.overlap
    }

    /// Where each face sits, left to right (the slot, before the open one grows).
    var frames: [(person: Person, rect: NSRect)] {
        people.enumerated().map { at, person in
            let x = Self.pad + CGFloat(at) * (Self.face - Self.overlap)
            return (person, NSRect(x: x, y: (Self.height - Self.face) / 2, width: Self.face, height: Self.face))
        }
    }

    /// Whose face is at this x (in the strip's own points).
    func person(at x: CGFloat) -> Person? {
        // Later faces sit on top, so look from the right.
        frames.reversed().first { x >= $0.rect.minX && x <= $0.rect.maxX }?.person
            ?? frames.min { abs($0.rect.midX - x) < abs($1.rect.midX - x) }?.person
    }

    func image(photo: @escaping (Person) -> NSImage?, here: @escaping (Person) -> Bool, unread: @escaping (Person) -> Bool) -> NSImage {
        let frames = self.frames
        let open = self.open
        let image = NSImage(size: NSSize(width: max(width, 1), height: Self.height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            // The open face is drawn last so it sits on top.
            let order = frames.filter { $0.person.id != open } + frames.filter { $0.person.id == open }
            for (person, slot) in order {
                let isOpen = person.id == open
                let grow = isOpen ? (Self.openFace - Self.face) / 2 : 0
                let rect = slot.insetBy(dx: -grow, dy: -grow)
                // Cut a gap out of whatever is underneath, so faces read as separate.
                context.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: isOpen ? -2.2 : -1.2, dy: isOpen ? -2.2 : -1.2)).fill()
                context.compositingOperation = .sourceOver
                if isOpen {
                    // The ring around the open face, in the menu bar's own text colour.
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5))
                    ring.lineWidth = 1.3
                    ring.stroke()
                }
                Avatar.draw(person, photo: photo(person), in: rect, alpha: here(person) || isOpen ? 1 : 0.45)
                if unread(person), !isOpen {
                    let dot = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 7, height: 7)
                    context.compositingOperation = .destinationOut
                    NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                    context.compositingOperation = .sourceOver
                    Theme.accentNS.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A face in a panel.
struct FaceView: View {
    let person: Person
    var photo: NSImage?
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: Theme.faces[person.colourIndex(of: Theme.faces.count)])
                    Text(person.initials)
                        .font(Theme.font(size * 0.38, .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
