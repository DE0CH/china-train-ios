import CoreText
import UIKit

// The site's tokens (china-train src/index.css), light and dark, and its two type faces: system PingFang SC for
// text and the bundled Archivo (OFL) for figures, both with tabular figures as `font-variant-numeric` asks.

extension UIColor {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> UIColor {
        func c(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        return UIColor { $0.userInterfaceStyle == .dark ? c(dark) : c(light) }
    }
    static let ground = pair(0xeef0f2, 0x111315)
    static let panel = pair(0xffffff, 0x1a1d20)
    static let ink = pair(0x14171a, 0xe8eaec)
    static let muted = pair(0x59626b, 0x9ea6ae)
    static let rule = pair(0xd3d8dd, 0x33393f)
    static let onLine = pair(0xffffff, 0x111315)
    static let focus = pair(0x005eb8, 0x5aa9ff)
    static func line(_ cls: String) -> UIColor {
        switch cls {
        case "G": return pair(0xc8102e, 0xff6b78)
        case "D": return pair(0x005eb8, 0x5aa9ff)
        case "C": return pair(0x00774a, 0x3cc48a)
        case "W": return .muted
        default: return pair(0x8a5800, 0xe0a54a)
        }
    }
}

enum Face { case text, num }

enum Fonts {
    private static let tabular: [[String: Any]] = [[kCTFontFeatureTypeIdentifierKey as String: kNumberSpacingType,
                                                     kCTFontFeatureSelectorIdentifierKey as String: kMonospacedNumbersSelector]]
    private static var cache: [String: CTFont] = [:]
    private static let archivo: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "Archivo", withExtension: "ttf", subdirectory: "Fonts"),
              let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        return list.first
    }()

    /// PingFang SC at the face WebKit picks for a CSS weight: it has nothing above Semibold, so 600–900 are Semibold.
    private static func pingFang(_ size: CGFloat, _ weight: Int) -> CTFont {
        let name = weight >= 600 ? "PingFangSC-Semibold" : weight >= 500 ? "PingFangSC-Medium" : "PingFangSC-Regular"
        let d = CTFontDescriptorCreateWithAttributes(([kCTFontNameAttribute: name, kCTFontFeatureSettingsAttribute: tabular] as [CFString: Any]) as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    static func font(_ face: Face, _ size: CGFloat, _ weight: Int) -> CTFont {
        let key = "\(face)-\(size)-\(weight)"
        if let f = cache[key] { return f }
        var font = pingFang(size, weight)
        if face == .num, let archivo {
            // Archivo is variable (wght 100–900, wdth 62–125); Chinese in a figure run falls back to PingFang SC.
            let cascade = CTFontCopyFontDescriptor(pingFang(size, weight))
            let attrs: [CFString: Any] = [
                kCTFontVariationAttribute: [0x7767_6874: weight, 0x7764_7468: 100] as [Int: Int],
                kCTFontFeatureSettingsAttribute: tabular,
                kCTFontCascadeListAttribute: [cascade],
            ]
            let d = CTFontDescriptorCreateCopyWithAttributes(archivo, attrs as CFDictionary)
            font = CTFontCreateWithFontDescriptor(d, size, nil)
        }
        cache[key] = font
        return font
    }

    /// Ascent and descent as WebKit uses them for line boxes: whole points.
    static func metrics(_ f: CTFont) -> (ascent: CGFloat, descent: CGFloat) {
        (CTFontGetAscent(f).rounded(), CTFontGetDescent(f).rounded())
    }
}

/// A run of text in one face, size, weight and colour, with the CSS line height it sits in.
struct Run {
    var text: String
    var face: Face = .text
    var size: CGFloat = 16
    var weight = 400
    var color: UIColor = .ink
    var lineHeight: CGFloat? = nil   // nil: 1.5 × size, the body's
    var marginRight: CGFloat = 0
    var font: CTFont { Fonts.font(face, size, weight) }
    var lh: CGFloat { lineHeight ?? size * 1.5 }
}

/// One line of inline runs laid out the way CSS lays out an inline formatting context: each run's box is its line
/// height with the font's ascent+descent centred in it (half-leading), boxes share a baseline, and the line is the max
/// above plus the max below.
struct InlineLine {
    let runs: [Run]
    let widths: [CGFloat]
    let width, above, below: CGFloat
    var height: CGFloat { above + below }

    init(_ runs: [Run]) {
        self.runs = runs
        var w: [CGFloat] = [], total: CGFloat = 0, above: CGFloat = 0, below: CGFloat = 0
        for r in runs {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: r.text, attributes: [.init(kCTFontAttributeName as String): r.font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            w.append(width)
            total += width + r.marginRight
            let (a, d) = Fonts.metrics(r.font)
            let half = (r.lh - (a + d)) / 2
            above = max(above, half + a)
            below = max(below, r.lh - half - a)
        }
        widths = w
        width = total
        self.above = above
        self.below = below
    }
}

/// Draws an InlineLine (or several wrapped lines of one run) at exact baselines with Core Text. It is also the
/// accessibility element for its text, so the replica finds the same static texts natively and in the HTML.
final class TextView: UIView {
    private(set) var lines: [InlineLine] = []
    private var lineHeight: CGFloat = 0
    var align: NSTextAlignment = .left { didSet { setNeedsDisplay() } }

    init(_ runs: [Run]) {
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .topLeft   // a rotation moves the text; it never stretches it
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        set(runs)
    }

    convenience init(_ text: String, _ face: Face = .text, size: CGFloat = 16, weight: Int = 400, color: UIColor = .ink, lineHeight: CGFloat? = nil) {
        self.init([Run(text: text, face: face, size: size, weight: weight, color: color, lineHeight: lineHeight)])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var runs: [Run] = []
    func set(_ runs: [Run]) {
        self.runs = runs
        lines = [InlineLine(runs)]
        accessibilityLabel = runs.map(\.text).joined()
        setNeedsDisplay()
    }

    var one: InlineLine { lines[0] }
    var naturalWidth: CGFloat { lines.map(\.width).max() ?? 0 }
    var firstBaseline: CGFloat { lines.first?.above ?? 0 }
    var height: CGFloat { lines.reduce(0) { $0 + $1.height } }

    /// Back to one unbroken line.
    func unwrap() {
        lines = [InlineLine(runs)]
        setNeedsDisplay()
    }

    /// Breaks a single-run text into lines no wider than `width` (Chinese breaks between any two characters).
    @discardableResult
    func wrap(_ width: CGFloat) -> CGFloat {
        guard runs.count == 1, let r = runs.first else { return height }
        let attr = NSAttributedString(string: r.text, attributes: [.init(kCTFontAttributeName as String): r.font])
        let typesetter = CTTypesetterCreateWithAttributedString(attr)
        var start = 0, out: [InlineLine] = []
        let ns = r.text as NSString
        while start < ns.length {
            let n = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            var part = r
            part.text = ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces)
            out.append(InlineLine([part]))
            start += n
        }
        if out.isEmpty { out = [InlineLine([r])] }
        lines = out
        setNeedsDisplay()
        return height
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.textMatrix = .identity
        var top: CGFloat = 0
        for line in lines {
            var x: CGFloat = align == .right ? bounds.width - line.width : align == .center ? (bounds.width - line.width) / 2 : 0
            let baseline = top + line.above
            for (r, w) in zip(line.runs, line.widths) {
                let s = NSAttributedString(string: r.text, attributes: [
                    .init(kCTFontAttributeName as String): r.font,
                    .init(kCTForegroundColorAttributeName as String): r.color.resolvedColor(with: traitCollection).cgColor,
                ])
                let ct = CTLineCreateWithAttributedString(s)
                ctx.saveGState()
                ctx.translateBy(x: x, y: baseline)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(ct, ctx)
                ctx.restoreGState()
                x += w + r.marginRight
            }
            top += line.height
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsDisplay()
    }
}

/// A plain filled box: rules, lines, sheets. Stretches with the rotation.
final class Box: UIView {
    init(_ color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = color
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A CSS border drawn on a view: per-side widths, one colour, solid or dashed.
final class Border: UIView {
    var color: UIColor { didSet { setNeedsDisplay() } }
    var widths: UIEdgeInsets { didSet { setNeedsDisplay() } }
    var dashed = false { didSet { setNeedsDisplay() } }
    var fill: UIColor? { didSet { setNeedsDisplay() } }

    init(_ color: UIColor = .ink, _ widths: UIEdgeInsets, fill: UIColor? = nil) {
        self.color = color
        self.widths = widths
        self.fill = fill
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let fill { ctx.setFillColor(fill.resolvedColor(with: traitCollection).cgColor); ctx.fill(bounds) }
        let c = color.resolvedColor(with: traitCollection).cgColor
        let b = bounds, w = widths
        let sides: [(CGFloat, CGRect, Bool)] = [
            (w.top, CGRect(x: b.minX, y: b.minY, width: b.width, height: w.top), true),
            (w.bottom, CGRect(x: b.minX, y: b.maxY - w.bottom, width: b.width, height: w.bottom), true),
            (w.left, CGRect(x: b.minX, y: b.minY, width: w.left, height: b.height), false),
            (w.right, CGRect(x: b.maxX - w.right, y: b.minY, width: w.right, height: b.height), false),
        ]
        for (t, r, horizontal) in sides where t > 0 {
            if dashed { Border.dash(ctx, c, r, t, horizontal) } else { ctx.setFillColor(c); ctx.fill(r) }
        }
    }

    /// WebKit's dashes: 3 × the width on, as much off, from the start of the side.
    static func dash(_ ctx: CGContext, _ c: CGColor, _ r: CGRect, _ t: CGFloat, _ horizontal: Bool) {
        ctx.setFillColor(c)
        let len = horizontal ? r.width : r.height
        var p: CGFloat = 0
        while p < len {
            let d = min(3 * t, len - p)
            ctx.fill(horizontal ? CGRect(x: r.minX + p, y: r.minY, width: d, height: t) : CGRect(x: r.minX, y: r.minY + p, width: t, height: d))
            p += 6 * t
        }
    }
}

// ---- icons: the site's one set, 24 viewBox, 2px stroke, square caps -------------------------------------------------

enum Icon {
    static let swap = "M7 4v16M7 20l-4-4M7 20l4-4M17 20V4M17 4l-4 4M17 4l4 4"
    static let chevronDown = "M6 9l6 6 6-6"
    static let chevronUp = "M6 15l6-6 6 6"
    static let cross = "M6 6l12 12M18 6L6 18"
    static let refresh = "M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5"

    /// The small SVG path language these icons use: M/m, L/l, H/h, V/v and one A/a arc.
    static func path(_ d: String) -> UIBezierPath {
        let p = UIBezierPath()
        var tokens: [String] = [], cur = ""
        for ch in d {
            if ch.isLetter { if !cur.isEmpty { tokens.append(cur) }; tokens.append(String(ch)); cur = "" }
            else if ch == " " || ch == "," { if !cur.isEmpty { tokens.append(cur) }; cur = "" }
            else if ch == "-" { if !cur.isEmpty && cur.last != "e" { tokens.append(cur); cur = "-" } else { cur.append(ch) } }
            else if ch == "." && cur.contains(".") { tokens.append(cur); cur = "." }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { tokens.append(cur) }
        var i = 0, cmd = "M", pt = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if tokens[i].first!.isLetter { cmd = tokens[i]; i += 1 }
            let rel = cmd == cmd.lowercased()
            switch cmd.uppercased() {
            case "M": let x = num(), y = num(); pt = rel ? CGPoint(x: pt.x + x, y: pt.y + y) : CGPoint(x: x, y: y); p.move(to: pt); cmd = rel ? "l" : "L"
            case "L": let x = num(), y = num(); pt = rel ? CGPoint(x: pt.x + x, y: pt.y + y) : CGPoint(x: x, y: y); p.addLine(to: pt)
            case "H": let x = num(); pt.x = rel ? pt.x + x : x; p.addLine(to: pt)
            case "V": let y = num(); pt.y = rel ? pt.y + y : y; p.addLine(to: pt)
            case "A":
                let r = num(); _ = num(); _ = num(); let large = num() != 0, sweep = num() != 0
                let x = num(), y = num()
                let end = rel ? CGPoint(x: pt.x + x, y: pt.y + y) : CGPoint(x: x, y: y)
                arc(p, from: pt, to: end, r: r, large: large, sweep: sweep)
                pt = end
            default: i += 1
            }
        }
        return p
    }

    /// A circular SVG arc (endpoint form) as a UIBezierPath arc around its centre.
    private static func arc(_ p: UIBezierPath, from a: CGPoint, to b: CGPoint, r rIn: CGFloat, large: Bool, sweep: Bool) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y, chord = hypot(dx, dy)
        let r = max(rIn, chord / 2)
        let h = sqrt(max(0, r * r - chord * chord / 4))
        let s: CGFloat = large == sweep ? -1 : 1
        let c = CGPoint(x: mid.x - s * h * dy / chord, y: mid.y + s * h * dx / chord)
        let a0 = atan2(a.y - c.y, a.x - c.x), a1 = atan2(b.y - c.y, b.x - c.x)
        p.addArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: sweep)
    }
}

final class IconView: UIView {
    private let shape = CAShapeLayer()
    var tint: UIColor = .ink { didSet { update() } }
    var d: String { didSet { update() } }
    let size: CGFloat

    init(_ d: String, size: CGFloat = 20) {
        self.d = d
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        shape.fillColor = nil
        shape.lineCap = .square
        shape.lineJoin = .miter
        layer.addSublayer(shape)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let path = Icon.path(d)
        path.apply(CGAffineTransform(scaleX: size / 24, y: size / 24))
        shape.path = path.cgPath
        shape.lineWidth = 2 * size / 24
        shape.strokeColor = tint.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        update()
    }
}
