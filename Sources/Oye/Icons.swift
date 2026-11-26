import SwiftUI
import OyeCore

/// The icons from the designs, drawn from the same paths (an 18-point box unless said otherwise).
struct Icon: View {
    enum Kind {
        case mic, clip, wave, file, play

        var path: String {
            switch self {
            case .mic: return "M9 2a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-5 0v-4A2.5 2.5 0 0 1 9 2zM3.5 9a5.5 5.5 0 0 0 11 0M9 14.5V16"
            case .clip: return "M14 8.5l-5.2 5.2a3.2 3.2 0 0 1-4.5-4.5L9.8 3.7a2.1 2.1 0 0 1 3 3L7.6 11.9a1 1 0 0 1-1.5-1.5L10.8 5.8"
            case .wave: return "M3 7v4M6 4.5v9M9 6.5v5M12 3v12M15 7v4"
            case .file: return "M4.5 2h6l3 3v11h-9zM10.5 2v3h3"
            case .play: return "M3 1.5l9 5.5-9 5.5z"
            }
        }

        var box: CGFloat { self == .play ? 14 : 18 }
        var stroke: CGFloat {
            switch self {
            case .wave: return 1.9
            case .file: return 1.6
            default: return 1.7
            }
        }
    }

    let kind: Kind
    var size: CGFloat? = nil

    var body: some View {
        let side = size ?? kind.box
        let shape = IconShape(d: kind.path, box: kind.box)
        Group {
            if kind == .play {
                shape.fill()
            } else {
                shape.stroke(style: StrokeStyle(lineWidth: kind.stroke * side / kind.box, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

private struct IconShape: Shape {
    let d: String
    let box: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / box
        var path = Path()
        for run in SVGPath.runs(d) {
            guard let first = run.points.first else { continue }
            path.move(to: CGPoint(x: rect.minX + first.x * scale, y: rect.minY + first.y * scale))
            for point in run.points.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale))
            }
            if run.closed { path.closeSubpath() }
        }
        return path
    }
}
