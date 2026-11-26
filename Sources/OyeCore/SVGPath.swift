import Foundation

/// Turns an SVG path string into runs of points, so the app's icons are the very shapes in the
/// designs. Handles M, L, H, V, Z and circular A (both cases); arcs become short straight steps.
public enum SVGPath {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public struct Run: Equatable, Sendable {
        public var points: [Point]
        public var closed: Bool
    }

    public static func runs(_ d: String, arcSteps: Int = 16) -> [Run] {
        var tokens = Tokens(d)
        var runs: [Run] = []
        var current: [Point] = []
        var at = Point(0, 0)
        var start = Point(0, 0)
        var command: Character = " "

        func finish(closed: Bool) {
            if current.count > 1 { runs.append(Run(points: current, closed: closed)) }
            current = []
        }

        while let next = tokens.peek() {
            if case .command(let c) = next {
                tokens.advance()
                command = c
                if c == "Z" || c == "z" {
                    finish(closed: true)
                    at = start
                    continue
                }
            }
            let relative = command.isLowercase
            switch command {
            case "M", "m":
                guard let x = tokens.number(), let y = tokens.number() else { return runs }
                finish(closed: false)
                at = relative ? Point(at.x + x, at.y + y) : Point(x, y)
                start = at
                current = [at]
                // Pairs after the first are lines.
                command = relative ? "l" : "L"
            case "L", "l":
                guard let x = tokens.number(), let y = tokens.number() else { return runs }
                at = relative ? Point(at.x + x, at.y + y) : Point(x, y)
                if current.isEmpty { current = [start] }
                current.append(at)
            case "H", "h":
                guard let x = tokens.number() else { return runs }
                at = Point(relative ? at.x + x : x, at.y)
                if current.isEmpty { current = [start] }
                current.append(at)
            case "V", "v":
                guard let y = tokens.number() else { return runs }
                at = Point(at.x, relative ? at.y + y : y)
                if current.isEmpty { current = [start] }
                current.append(at)
            case "A", "a":
                guard let rx = tokens.number(), tokens.number() != nil, tokens.number() != nil,
                      let large = tokens.number(), let sweep = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return runs }
                let end = relative ? Point(at.x + x, at.y + y) : Point(x, y)
                if current.isEmpty { current = [start] }
                current.append(contentsOf: arc(from: at, to: end, radius: abs(rx), large: large != 0, sweep: sweep != 0, steps: arcSteps))
                at = end
            default:
                return runs
            }
        }
        finish(closed: false)
        return runs
    }

    /// The points along a circular arc after its start, ending exactly on `to`.
    static func arc(from: Point, to: Point, radius: Double, large: Bool, sweep: Bool, steps: Int) -> [Point] {
        guard radius > 0, from != to, steps > 0 else { return [to] }
        let hx = (from.x - to.x) / 2, hy = (from.y - to.y) / 2
        var r = radius
        let stretch = (hx * hx + hy * hy) / (r * r)
        if stretch > 1 { r *= stretch.squareRoot() }
        let under = hx * hx + hy * hy
        let k = (large != sweep ? 1.0 : -1.0) * max(0, (r * r - under) / under).squareRoot()
        let cxp = k * hy, cyp = -k * hx
        let cx = cxp + (from.x + to.x) / 2, cy = cyp + (from.y + to.y) / 2
        let a1 = atan2(hy - cyp, hx - cxp)
        var delta = atan2(-hy - cyp, -hx - cxp) - a1
        if !sweep, delta > 0 { delta -= 2 * Double.pi }
        if sweep, delta < 0 { delta += 2 * Double.pi }
        var points: [Point] = []
        for step in 1..<max(steps, 2) {
            let a = a1 + delta * Double(step) / Double(max(steps, 2))
            points.append(Point(cx + r * cos(a), cy + r * sin(a)))
        }
        points.append(to)
        return points
    }

    private enum Token { case command(Character), number(Double) }

    private struct Tokens {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) { chars = Array(text) }

        private mutating func skipSpace() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" { index += 1 }
        }

        mutating func peek() -> Token? {
            skipSpace()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter { return .command(c) }
            let saved = index
            let value = number()
            index = saved
            return value.map(Token.number)
        }

        mutating func advance() { index += 1 }

        /// The next number: an optional sign, digits, and at most one decimal point.
        mutating func number() -> Double? {
            skipSpace()
            var text = ""
            var seenPoint = false
            if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index])
                index += 1
            }
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    text.append(c)
                } else if c == ".", !seenPoint {
                    seenPoint = true
                    text.append(c)
                } else {
                    break
                }
                index += 1
            }
            return Double(text)
        }
    }
}
