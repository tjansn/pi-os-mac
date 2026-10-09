import Foundation

// Pure model of the attention overlay (DESIGN3 §B): the tether from the bar to the cursor, the drop-target
// highlight, the window hit-test rule and the labels an element pick may carry. Every point and rect here is
// CG global top-left (the wire convention); AppKit conversion happens only through the helpers below.

/// What a tether drop attaches: the window under the cursor, or one accessibility element inside it.
public enum AttentionMode: String, Equatable, Sendable, CaseIterable { case window, element }

/// A cubic Bézier in CG global points.
public struct TetherCurve: Equatable {
    public var start: Point
    public var control1: Point
    public var control2: Point
    public var end: Point
    public init(start: Point, control1: Point, control2: Point, end: Point) {
        self.start = start; self.control1 = control1; self.control2 = control2; self.end = end
    }
    public func point(at t: Double) -> Point {
        let t = min(1, max(0, t)), u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return Point(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                     y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }
    /// The control polygon's box: always contains the curve.
    public var bounds: Rect {
        let xs = [start.x, control1.x, control2.x, end.x], ys = [start.y, control1.y, control2.y, end.y]
        return Rect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    /// Both control points on the chord (Reduce Motion, or a vertical drag).
    public var isStraight: Bool {
        AttentionGeometry.distance(control1, toLineFrom: start, to: end) < 0.01
            && AttentionGeometry.distance(control2, toLineFrom: start, to: end) < 0.01
    }
}

public enum AttentionGeometry {
    /// The sag of a horizontal tether, as a share of its length, and its cap in points.
    public static let sagRatio = 0.14
    public static let maxSag = 96.0
    public static let windowOutset = 1.5
    public static let windowRadius = 14.0
    public static let elementOutset = 3.0
    public static let elementRadius = 6.0
    public static let minimumElementSide = 8.0
    public static let tagGap = 2.0

    // MARK: Coordinates

    /// AppKit global (bottom-left of the primary screen) ↔ CG global (top-left). The map is its own inverse.
    public static func cgPoint(fromAppKit point: Point, primaryHeight: Double) -> Point {
        Point(x: point.x, y: primaryHeight - point.y)
    }
    public static func appKitPoint(fromCG point: Point, primaryHeight: Double) -> Point {
        Point(x: point.x, y: primaryHeight - point.y)
    }
    public static func cgRect(fromAppKit rect: Rect, primaryHeight: Double) -> Rect {
        Placement.appKit(rect, primaryHeight: primaryHeight)
    }
    /// CG global → a flipped view that covers `screen` (CG global).
    public static func local(_ point: Point, in screen: Rect) -> Point { Point(x: point.x - screen.x, y: point.y - screen.y) }
    public static func local(_ rect: Rect, in screen: Rect) -> Rect {
        Rect(x: rect.x - screen.x, y: rect.y - screen.y, width: rect.width, height: rect.height)
    }

    // MARK: Screens

    public static func screenIndex(containing point: Point, in screens: [Rect]) -> Int? {
        screens.firstIndex { $0.contains(point) }
    }
    /// The nearest point that lies on a screen. Displays can leave gaps (different heights, offsets);
    /// a cursor reported on a far edge (x == maxX) is pulled half a point inside.
    public static func clamp(_ point: Point, to screens: [Rect]) -> Point {
        guard point.x.isFinite, point.y.isFinite else { return screens.first.map { Point(x: $0.x, y: $0.y) } ?? Point(x: 0, y: 0) }
        if screens.contains(where: { $0.contains(point) }) { return point }
        let candidates = screens.filter(\.valid).map { screen in
            Point(x: min(max(point.x, screen.x), screen.x + screen.width - 0.5),
                  y: min(max(point.y, screen.y), screen.y + screen.height - 0.5))
        }
        return candidates.min { squaredDistance($0, point) < squaredDistance($1, point) } ?? point
    }

    // MARK: Tether

    /// A rope from the bar to the cursor that sags under gravity (+y): strongest for a horizontal pull, none for
    /// a vertical one. `straight` (Reduce Motion) keeps both control points on the chord.
    public static func tether(from start: Point, to end: Point, straight: Bool) -> TetherCurve {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        func along(_ t: Double) -> Point { Point(x: start.x + dx * t, y: start.y + dy * t) }
        guard !straight, length > 1 else { return TetherCurve(start: start, control1: along(1.0 / 3), control2: along(2.0 / 3), end: end) }
        let sag = min(length * sagRatio, maxSag) * abs(dx) / length
        // Quadratic rope (control at the sagging midpoint) raised to a cubic.
        let middle = Point(x: start.x + dx / 2, y: start.y + dy / 2 + sag)
        return TetherCurve(start: start,
                           control1: Point(x: start.x + 2.0 / 3 * (middle.x - start.x), y: start.y + 2.0 / 3 * (middle.y - start.y)),
                           control2: Point(x: end.x + 2.0 / 3 * (middle.x - end.x), y: end.y + 2.0 / 3 * (middle.y - end.y)),
                           end: end)
    }
    /// Boxes along the tether, one per segment, `margin` around each: a moving line repaints a band, not the
    /// box of the whole curve (a long diagonal over a highlighted window would otherwise repaint most of it).
    public static func tetherDamage(_ curve: TetherCurve, margin: Double, segments: Int = 12) -> [Rect] {
        let count = max(1, segments)
        let points = (0...count).map { curve.point(at: Double($0) / Double(count)) }
        return zip(points, points.dropFirst()).map { a, b in
            outset(Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), by: margin)
        }
    }

    // MARK: Highlights

    public static func outset(_ rect: Rect, by amount: Double) -> Rect {
        Rect(x: rect.x - amount, y: rect.y - amount, width: rect.width + 2 * amount, height: rect.height + 2 * amount)
    }
    /// The purple drop frame sits just outside the window edge.
    public static func windowHighlight(_ bounds: Rect) -> Rect { outset(bounds, by: windowOutset) }
    /// The orange element frame: a little air around the element, never smaller than a fingertip mark.
    public static func elementHighlight(_ bounds: Rect) -> Rect {
        let width = max(bounds.width, minimumElementSide), height = max(bounds.height, minimumElementSide)
        let grown = Rect(x: bounds.x - (width - bounds.width) / 2, y: bounds.y - (height - bounds.height) / 2, width: width, height: height)
        return outset(grown, by: elementOutset)
    }
    /// The part of an element that is visible inside its window (scrolled content can extend past it).
    public static func visible(_ element: Rect, in window: Rect) -> Rect? {
        guard element.valid, window.valid else { return nil }
        let x = max(element.x, window.x), y = max(element.y, window.y)
        let maxX = min(element.x + element.width, window.x + window.width), maxY = min(element.y + element.height, window.y + window.height)
        guard maxX > x, maxY > y else { return nil }
        return Rect(x: x, y: y, width: maxX - x, height: maxY - y)
    }
    /// The role tag rides on the highlight's top-left corner, inside it when the screen edge leaves no room,
    /// and is kept on the screen that holds that corner.
    public static func tagFrame(for highlight: Rect, width: Double, height: Double, screens: [Rect]) -> Rect {
        let corner = Point(x: highlight.x, y: highlight.y)
        let screen = screens.first { $0.contains(clamp(corner, to: screens)) } ?? highlight
        var y = highlight.y - height - tagGap
        if y < screen.y { y = highlight.y + tagGap }
        let x = min(max(highlight.x, screen.x + 4), max(screen.x + 4, screen.x + screen.width - width - 4))
        return Rect(x: x, y: min(y, screen.y + screen.height - height), width: width, height: height)
    }

    // MARK: Helpers

    static func squaredDistance(_ a: Point, _ b: Point) -> Double { (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) }
    static func distance(_ p: Point, toLineFrom a: Point, to b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return squaredDistance(p, a).squareRoot() }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }
}

// MARK: Scene

/// Everything one overlay frame draws. Views translate it into their own screen.
public struct AttentionScene: Equatable {
    public enum Target: Equatable {
        case window(Rect)
        case element(Rect, tag: String)
        public var bounds: Rect {
            switch self {
            case .window(let rect), .element(let rect, _): return rect
            }
        }
    }
    public var anchor: Point
    public var cursor: Point
    public var mode: AttentionMode
    public var target: Target?
    /// Reduce Motion: a static straight line.
    public var straight: Bool
    public init(anchor: Point, cursor: Point, mode: AttentionMode, target: Target? = nil, straight: Bool = false) {
        self.anchor = anchor; self.cursor = cursor; self.mode = mode; self.target = target; self.straight = straight
    }
    public var tether: TetherCurve { AttentionGeometry.tether(from: anchor, to: cursor, straight: straight) }
    /// The drawn highlight frame (outset), in CG global points.
    public var highlight: Rect? {
        switch target {
        case .window(let rect): return AttentionGeometry.windowHighlight(rect)
        case .element(let rect, _): return AttentionGeometry.elementHighlight(rect)
        case nil: return nil
        }
    }
}

// MARK: Window hit-test

/// One CGWindowList row, already parsed. Front-to-back order is the list order.
public struct AttentionWindowInfo: Equatable {
    public var id: UInt32
    public var pid: Int32
    public var layer: Int
    public var bounds: Rect
    public var alpha: Double
    public init(id: UInt32, pid: Int32, layer: Int, bounds: Rect, alpha: Double = 1) {
        self.id = id; self.pid = pid; self.layer = layer; self.bounds = bounds; self.alpha = alpha
    }
}

public enum AttentionHitTest {
    /// Visible chrome that covers what is beneath it: floating/utility/modal panels up to the Dock (1–20), the menu
    /// bar and status items (24, 25) and open pop-up menus (101). Pointing at these attaches nothing.
    public static func blocks(layer: Int) -> Bool { (1...20).contains(layer) || layer == 24 || layer == 25 || layer == 101 }
    /// Smaller windows are tooltips, drag images and helpers, not something to attach.
    public static let minimumSide = 24.0

    /// The window a drop at `point` would attach: the front-most normal (layer 0) window that contains it.
    /// - pi-os's own overlay (`ownPID` at `overlayLayer`) and windows in `skipping` (phantoms) are transparent.
    /// - Any other pi-os window, the menu bar, the Dock and floating panels block: the user points at them.
    /// - Invisible full-screen shields at other layers (Notification Center keeps one at 21) are transparent,
    ///   as is a non-normal window that covers a whole display, the system cursor and anything with alpha ≈ 0.
    public static func window(at point: Point, in windows: [AttentionWindowInfo], ownPID: Int32, overlayLayer: Int,
                              cursorLayer: Int, screens: [Rect], skipping: Set<UInt32> = []) -> AttentionWindowInfo? {
        for info in windows {
            guard info.bounds.valid, info.bounds.contains(point), info.alpha > 0.01, info.layer != cursorLayer,
                  !skipping.contains(info.id) else { continue }
            if info.pid == ownPID && info.layer == overlayLayer { continue }
            if info.layer == 0 {
                if info.pid == ownPID { return nil }
                if info.bounds.width < minimumSide || info.bounds.height < minimumSide { continue }
                return info
            }
            if coversDisplay(info.bounds, screens: screens) { continue }
            if blocks(layer: info.layer) || info.pid == ownPID { return nil }
        }
        return nil
    }
    static func coversDisplay(_ bounds: Rect, screens: [Rect]) -> Bool {
        screens.contains { screen in
            guard let shared = AttentionGeometry.visible(screen, in: bounds) else { return false }
            return shared.width * shared.height >= 0.95 * screen.width * screen.height
        }
    }
}

// MARK: Labels

/// Text an element or window pick may carry, made to pass `AttachmentValidation` (no controls, UTF-16 caps).
public enum AttentionLabel {
    public static let maxTagCharacters = 40

    /// Controls become spaces, runs of whitespace collapse, and the result is cut on a grapheme boundary so
    /// it fits `maxUTF16` (with an ellipsis when cut). Nil when nothing printable remains.
    public static func sanitize(_ value: String?, maxUTF16: Int = AttachmentLimits.maxLabelChars) -> String? {
        guard let value, maxUTF16 > 1 else { return nil }
        var scalars = String.UnicodeScalarView()
        var space = false
        for scalar in value.unicodeScalars {
            if AttachmentValidation.hasControl(String(scalar)) || scalar.properties.isWhitespace {
                space = !scalars.isEmpty
                continue
            }
            if space { scalars.append(" "); space = false }
            scalars.append(scalar)
        }
        let clean = String(scalars)
        guard !clean.isEmpty else { return nil }
        return truncate(clean, maxUTF16: maxUTF16).text
    }

    /// Cuts on a grapheme boundary to at most `maxUTF16` UTF-16 units (JavaScript length), ending with "…" when cut.
    public static func truncate(_ value: String, maxUTF16: Int, ellipsis: Bool = true) -> (text: String, truncated: Bool) {
        guard value.utf16.count > maxUTF16 else { return (value, false) }
        let budget = maxUTF16 - (ellipsis ? 1 : 0)
        var used = 0, end = value.startIndex
        for character in value {
            let units = character.utf16.count
            guard used + units <= budget else { break }
            used += units; end = value.index(after: end)
        }
        var cut = String(value[..<end])
        while cut.last?.isWhitespace == true { cut.removeLast() }
        return (ellipsis ? cut + "…" : cut, true)
    }

    /// An AX role the wire accepts (`AX[A-Za-z]{1,48}`), else nil.
    public static func role(_ value: String?) -> String? {
        guard let value, AttachmentValidation.isRole(value) else { return nil }
        return value
    }

    /// The small tag on the element highlight: the app's own role description ("group" → "Group"), else the role
    /// without its prefix ("AXGroup" → "Group").
    public static func tag(role: String, roleDescription: String?) -> String {
        let described = sanitize(roleDescription, maxUTF16: maxTagCharacters)
        var fallback = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        if fallback.isEmpty { fallback = "Element" }
        let text = described ?? sanitize(fallback, maxUTF16: maxTagCharacters) ?? "Element"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// What the reader and the chip say the user pointed at: "Group", or "Button “Send”" when it has a label.
    public static func pointing(tag: String, label: String?) -> String {
        guard let label = sanitize(label, maxUTF16: 60), label.caseInsensitiveCompare(tag) != .orderedSame else { return tag }
        return "\(tag) “\(label)”"
    }
}
