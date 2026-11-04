import CoreText
import UIKit

// The page's parts, each laid out by hand to china-train's src/index.css at phone width (the `max-width: 900px`
// rules, which every iPhone gets in both orientations): `layout(_ width:) -> height` places the subviews and returns
// the part's height. Comments name the CSS rule a number comes from.

/// A tappable area; `onTap` runs on touch-up inside.
class Tap: UIControl {
    var onTap: () -> Void = {}
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    /// The button's words: its own label, or the text drawn inside it.
    override var accessibilityLabel: String? {
        get { super.accessibilityLabel ?? subviews.compactMap { ($0 as? TextView)?.accessibilityLabel }.joined() }
        set { super.accessibilityLabel = newValue }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onTap() }
}


// ---- header: `.top` ---------------------------------------------------------------------------------------------

final class Header: UIView {
    let title = TextView("火车路线规划", size: 24, weight: 800, lineHeight: 28.8)   // h1 1.5rem/800, line-height 1.2
    let sub = TextView("", size: 13, color: .muted)                                  // .sub 0.875rem
    init() {
        super.init(frame: .zero)
        addSubview(title)
        addSubview(sub)
        sub.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(generated: String?) {
        guard let g = generated, g.count >= 10 else { sub.isHidden = true; return }
        let md = g.dropFirst(5).prefix(5).replacingOccurrences(of: "-", with: "月")
        sub.set([Run(text: "时刻表更新于 \(md)日，余票实时查询 12306", size: 13, color: .muted)])
        sub.isHidden = false
    }

    /// flex-wrap, align-items baseline, gap 4px 20px.
    func layout(_ w: CGFloat) -> CGFloat {
        title.frame = CGRect(x: 0, y: 0, width: title.naturalWidth, height: title.height)
        guard !sub.isHidden else { return title.height }
        sub.unwrap()
        if title.naturalWidth + 20 + sub.naturalWidth <= w {
            let above = max(title.firstBaseline, sub.firstBaseline)
            title.frame.origin.y = above - title.firstBaseline
            sub.frame = CGRect(x: title.naturalWidth + 20, y: above - sub.firstBaseline, width: sub.naturalWidth, height: sub.height)
            return max(title.frame.maxY, sub.frame.maxY)
        }
        let h = sub.wrap(w)
        sub.frame = CGRect(x: 0, y: title.height + 4, width: w, height: h)
        return sub.frame.maxY
    }
}

// ---- a station-name sign you can type into: `.sign` --------------------------------------------------------------

final class StationSign: UIView {
    let label: TextView
    let field = UITextField()
    let underline = Box(.clear)
    let line = Box(.ink)
    let node = Border(.ink, UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), fill: .panel)   // .node 18px, 4px ink
    let isStart: Bool

    init(label text: String, start: Bool) {
        isStart = start
        label = TextView(text, size: 13, color: .muted)
        super.init(frame: .zero)
        for v in [line, node, label, field, underline] as [UIView] { addSubview(v) }
        field.font = Fonts.font(.text, 32, 800) as UIFont   // .sign input 2rem/800 at phone width
        field.textColor = .ink
        field.tintColor = .focus
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.accessibilityIdentifier = text
        placeholder("正在载入车站")
    }
    required init?(coder: NSCoder) { fatalError() }

    func placeholder(_ s: String) {
        // ::placeholder: muted, 600, 1.375rem
        field.attributedPlaceholder = NSAttributedString(string: s, attributes: [.font: Fonts.font(.text, 24, 600) as UIFont, .foregroundColor: UIColor.muted])
    }

    func focused(_ on: Bool) { underline.backgroundColor = on ? .focus : .clear }

    /// Phone grid: a 44px track column and the text column after an 8px gap; padding 12px 16px 12px 0.
    func layout(_ w: CGFloat) -> CGFloat {
        let top: CGFloat = 12, x: CGFloat = 52, tw = max(0, w - x - 16)
        let lh = label.height   // .sign label: 13px, line-height 1.5 (19)
        label.frame = CGRect(x: x, y: top, width: tw, height: lh)
        // input: padding 2px 0, border-bottom 3px; WebKit gives its text at least the font's own height (ascent +
        // descent, rounded up: 45px), not the 36px of line-height 1.15
        let (a, d) = Fonts.metrics(Fonts.font(.text, 32, 800)), fh = max(36, a + d)
        field.frame = CGRect(x: x, y: top + lh + 2, width: tw, height: fh)
        underline.frame = CGRect(x: x, y: top + lh + 2 + fh + 2, width: tw, height: 3)
        let inner = lh + fh + 7, h = inner + 24   // the label and the input (no pinyin line)
        let cy = top + inner / 2
        node.frame = CGRect(x: 13, y: cy - 9, width: 18, height: 18)
        // the line runs from the node to the next part: left calc(50% - 3px), 6px, 12px past the track
        line.frame = isStart ? CGRect(x: 19, y: cy, width: 6, height: h - cy) : CGRect(x: 19, y: 0, width: 6, height: cy)
        return h
    }
}

/// The suggestion list under a sign: `.suggest`.
final class SuggestList: UIView {
    private let frameBorder = Border(.ink, UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), fill: .panel)
    private let list = UIScrollView()
    private var rows: [(view: UIView, height: CGFloat)] = []
    var onPick: (Int) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        addSubview(frameBorder)
        addSubview(list)
        list.showsVerticalScrollIndicator = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ tt: Timetable, hits: [Int], head: Bool, hi: Int) {
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
        if head {   // .suggest-head: min-height 32px, 0.8125rem muted
            let v = UIView()
            let t = TextView("最近使用", size: 13, color: .muted)
            t.frame = CGRect(x: 16, y: (32 - t.height) / 2, width: t.naturalWidth, height: t.height)
            v.addSubview(t)
            rows.append((v, 32))
        }
        for (k, i) in hits.enumerated() {
            let s = tt.stations[i], on = k == hi
            let row = Tap()
            row.backgroundColor = on ? .ink : .clear
            let name = TextView(s.name, size: 18, weight: 700, color: on ? .panel : .ink)   // .s-name 1.0625rem/700
            let meta = TextView(s.city != s.name ? s.city : "", .num, size: 15, color: on ? .panel : .muted)
            row.addSubview(name)
            row.addSubview(meta)
            row.accessibilityIdentifier = "suggest-\(s.name)"
            row.onTap = { [weak self] in self?.onPick(i) }
            rows.append((row, 48))
        }
    }

    /// `top: 100%` of the sign, full width, 3px ink frame, rows 48px with 1px rules between, at most 360px.
    func layout(_ w: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for (k, r) in rows.enumerated() {
            r.view.frame = CGRect(x: 0, y: y, width: w - 6, height: r.height)
            for case let t as TextView in r.view.subviews where r.view is Tap {
                let isName = t === r.view.subviews.first
                t.frame = CGRect(x: isName ? 16 : w - 6 - 16 - min(t.naturalWidth, w * 0.6), y: (r.height - t.height) / 2,
                                 width: isName ? t.naturalWidth : min(t.naturalWidth, w * 0.6), height: t.height)
                t.clipsToBounds = true
            }
            r.view.subviews.compactMap { $0 as? Box }.forEach { $0.removeFromSuperview() }
            if k < rows.count - 1 {
                let rule = Box(.rule)
                rule.frame = CGRect(x: 0, y: r.height - 1, width: w - 6, height: 1)
                r.view.addSubview(rule)
            }
            y += r.height
            if list.subviews.contains(r.view) == false { list.addSubview(r.view) }
        }
        let h = min(360, y + 6)
        frameBorder.frame = CGRect(x: 0, y: 0, width: w, height: h)
        list.frame = CGRect(x: 3, y: 3, width: w - 6, height: h - 6)
        list.contentSize = CGSize(width: w - 6, height: y)
        return h
    }
}

// ---- the date strip: `.days` -------------------------------------------------------------------------------------

final class DayStrip: UIScrollView {
    private var cells: [(Tap, TextView, TextView, Box, String)] = []
    var onPick: (String) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(today: Date, selected: String) {
        cells.forEach { $0.0.removeFromSuperview() }
        cells = []
        let f = isoFormatter(), cal = Calendar(identifier: .gregorian), week = Array("日一二三四五六")
        for i in 0..<15 {
            let d = today.addingTimeInterval(Double(i) * 86400), iso = f.string(from: d)
            let on = iso == selected
            let c = cal.dateComponents([.month, .day, .weekday], from: d)
            let rel = i < 3 ? ["今天", "明天", "后天"][i] : "周\(week[c.weekday! - 1])"
            let cell = Tap()
            cell.backgroundColor = on ? .ink : .clear
            let a = TextView(rel, size: 13, color: on ? .panel : .muted)                       // .day span 0.75rem
            let b = TextView("\(c.month!).\(c.day!)", .num, size: 18, weight: 600, color: on ? .panel : .ink, lineHeight: 19.8)   // .day b 1.25rem/600, 1.1
            let rule = Box(.rule)
            for v in [a, b, rule] as [UIView] { cell.addSubview(v) }
            cell.accessibilityIdentifier = "day-\(iso)"
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(rel) \(c.month!).\(c.day!)"
            cell.accessibilityTraits = on ? [.button, .selected] : .button
            cell.onTap = { [weak self] in self?.onPick(iso) }
            addSubview(cell)
            cells.append((cell, a, b, rule, iso))
        }
    }

    /// flex: 1 0 64px, min-height 60px, padding 6px 4px, 1px rule on the right but the last.
    func layout(_ w: CGFloat) -> CGFloat {
        let cw = max(64, w / CGFloat(max(cells.count, 1)))
        for (k, (cell, a, b, rule, _)) in cells.enumerated() {
            cell.frame = CGRect(x: CGFloat(k) * cw, y: 0, width: cw, height: 60)
            let top = (60 - (a.height + b.height)) / 2, last = k == cells.count - 1
            let inner = cw - (last ? 0 : 1)   // centred in the box inside its right rule
            a.frame = CGRect(x: (inner - a.naturalWidth) / 2, y: top, width: a.naturalWidth, height: a.height)
            b.frame = CGRect(x: (inner - b.naturalWidth) / 2, y: top + a.height, width: b.naturalWidth, height: b.height)
            rule.frame = CGRect(x: cw - 1, y: 0, width: 1, height: 60)
            rule.isHidden = k == cells.count - 1
        }
        contentSize = CGSize(width: cw * CGFloat(cells.count), height: 60)
        return 60
    }
}

// ---- transfer settings: `.opts` ----------------------------------------------------------------------------------

final class MinutesField: UITextField, UITextFieldDelegate {
    let range: ClosedRange<Int>
    var value: Int { didSet { if !isEditing { text = String(value) } } }
    var onChange: (Int) -> Void = { _ in }
    private let frameBorder = Border(.ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))

    init(_ value: Int, _ range: ClosedRange<Int>, id: String) {
        self.value = value
        self.range = range
        super.init(frame: .zero)
        text = String(value)
        font = Fonts.font(.num, 18, 400) as UIFont
        textColor = .ink
        tintColor = .focus
        backgroundColor = .panel
        keyboardType = .numberPad
        accessibilityIdentifier = id
        delegate = self
        addSubview(frameBorder)
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        frameBorder.frame = bounds
    }
    // padding 0 8px inside the 2px border
    override func textRect(forBounds b: CGRect) -> CGRect { b.insetBy(dx: 10, dy: 2) }
    override func editingRect(forBounds b: CGRect) -> CGRect { b.insetBy(dx: 10, dy: 2) }

    /// Only a whole number in range reaches the planner; leaving the box restores the value in effect.
    @objc private func changed() {
        if let t = text, let v = Int(t), range.contains(v) { value = v; onChange(v) }
    }
    func textFieldDidEndEditing(_ textField: UITextField) { text = String(value) }
}

final class Checkbox: Tap {
    private let box = Border(.ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
    private let tick = IconView("M5 12l5 5 9-10", size: 18)
    var on = false { didSet { update() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(box)
        addSubview(tick)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        box.fill = on ? .ink : .panel
        tick.tint = .panel
        tick.isHidden = !on
        accessibilityTraits = on ? [.button, .selected] : .button
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        box.frame = CGRect(x: 0, y: (bounds.height - 22) / 2, width: 22, height: 22)
        tick.frame = CGRect(x: 2, y: box.frame.minY + 2, width: 18, height: 18)
    }
}

final class OptionsPanel: UIView {
    let same: MinutesField, cross: MinutesField, wait: MinutesField
    let check = Checkbox()
    private var items: [[UIView]] = []
    private let rule = Box(.rule)

    init(_ o: PlanOptions) {
        same = MinutesField(o.sameStationChange, 0...120, id: "同站换乘")
        cross = MinutesField(o.crossTownChange, 0...240, id: "同城换站")
        wait = MinutesField(o.maxWait, 10...720, id: "最长等候")
        super.init(frame: .zero)
        check.on = o.sameCityEnds
        check.accessibilityIdentifier = "同城其他车站"
        func t(_ s: String) -> TextView { TextView(s, size: 15) }
        items = [[t("同站换乘至少"), same, t("分钟")], [t("同城换站至少"), cross, t("分钟")], [t("最长等候"), wait, t("分钟")],
                 [check, t("也从同城其他车站出发、到达")]]
        addSubview(rule)
        items.flatMap { $0 }.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// border-top 1px, padding 16px 20px, flex-wrap gap 12px 28px; each label inline-flex, gap 6px, min-height 44px.
    func layout(_ w: CGFloat) -> CGFloat {
        rule.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        let inner = w - 40
        var x: CGFloat = 0, y: CGFloat = 0
        for item in items {
            let widths = item.map { v -> CGFloat in (v as? TextView)?.naturalWidth ?? (v is Checkbox ? 22 : 76) }
            let iw = widths.reduce(0, +) + 6 * CGFloat(item.count - 1)
            if x > 0 && x + iw > inner { x = 0; y += 44 + 12 }
            var cx = x
            for (v, vw) in zip(item, widths) {
                let h: CGFloat = v is TextView ? (v as! TextView).height : 44
                v.frame = CGRect(x: 20 + cx, y: 1 + 16 + y + (44 - h) / 2, width: vw, height: h)
                cx += vw + 6
            }
            x += iw + 28
        }
        return 1 + 16 + y + 44 + 16
    }
}

// ---- the query board: `.board` -----------------------------------------------------------------------------------

final class Board: UIView {
    let fromSign = StationSign(label: "出发站", start: true)
    let toSign = StationSign(label: "到达站", start: false)
    let swap = Tap()
    private let swapFrame = Border(.ink, UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), fill: .panel)
    private let swapIcon = IconView(Icon.swap)
    private let swapLine = Box(.ink)
    private let swapLabel = TextView("交换", size: 15, color: .muted)
    private let endsRule = Box(.rule), daysRule = Box(.rule)
    let days = DayStrip()
    let presets: [Tap]
    let settings = Tap()
    private let settingsText = TextView("换乘设置", size: 15, color: .muted)
    private let settingsIcon = IconView(Icon.chevronDown, size: 16)
    private var toolRules: [Box] = []
    var options: OptionsPanel?

    init(presets names: [String]) {
        presets = names.map { _ in Tap() }
        super.init(frame: .zero)
        backgroundColor = .panel
        swapIcon.tint = .ink
        settingsIcon.tint = .muted
        swap.addSubview(swapFrame)
        swap.addSubview(swapIcon)
        swap.accessibilityLabel = "交换出发站和到达站"
        swap.isAccessibilityElement = true
        swap.accessibilityTraits = .button
        for (p, n) in zip(presets, names) {
            let t = TextView(n, size: 15)
            p.addSubview(t)
            p.accessibilityIdentifier = n
            let r = Box(.rule)
            p.addSubview(r)
            toolRules.append(r)
        }
        settings.addSubview(settingsText)
        settings.addSubview(settingsIcon)
        settings.accessibilityIdentifier = "换乘设置"
        let left = Box(.rule)
        settings.addSubview(left)
        toolRules.append(left)
        for v in [swapLine, fromSign, toSign, swap, swapLabel, endsRule, days, daysRule] as [UIView] { addSubview(v) }
        presets.forEach(addSubview)
        addSubview(settings)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOptionsOpen(_ open: Bool) { settingsIcon.d = open ? Icon.chevronUp : Icon.chevronDown }

    func layout(_ w: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let h1 = fromSign.layout(w)
        fromSign.frame = CGRect(x: 0, y: y, width: w, height: h1)
        y += h1
        // .swap-cell: flex, align center, gap 12px, min-height 52px; the line at left 19px, 6px
        swapLine.frame = CGRect(x: 19, y: y, width: 6, height: 52)
        swap.frame = CGRect(x: 0, y: y + 4, width: 44, height: 44)
        swapFrame.frame = swap.bounds
        swapIcon.frame = CGRect(x: 12, y: 12, width: 20, height: 20)
        swapLabel.frame = CGRect(x: 56, y: y + (52 - swapLabel.height) / 2, width: swapLabel.naturalWidth, height: swapLabel.height)
        y += 52
        let h2 = toSign.layout(w)
        toSign.frame = CGRect(x: 0, y: y, width: w, height: h2)
        y += h2
        endsRule.frame = CGRect(x: 0, y: y, width: w, height: 1)
        y += 1
        let dh = days.layout(w)
        days.frame = CGRect(x: 0, y: y, width: w, height: dh)
        y += dh
        daysRule.frame = CGRect(x: 0, y: y, width: w, height: 1)
        y += 1
        // .tools: grid 1fr 1fr auto, buttons min-height 48px, padding 0 10px, 1px rules between
        let sw = 10 + settingsText.naturalWidth + 6 + 16 + 10 + 1
        let pw = (w - sw) / CGFloat(max(presets.count, 1))
        for (k, p) in presets.enumerated() {
            p.frame = CGRect(x: CGFloat(k) * pw, y: y, width: pw, height: 48)
            if let t = p.subviews.first as? TextView {
                t.frame = CGRect(x: (pw - 1 - t.naturalWidth) / 2, y: (48 - t.height) / 2, width: t.naturalWidth, height: t.height)
            }
            toolRules[k].frame = CGRect(x: pw - 1, y: 0, width: 1, height: 48)
        }
        settings.frame = CGRect(x: w - sw, y: y, width: sw, height: 48)
        toolRules.last?.frame = CGRect(x: 0, y: 0, width: 1, height: 48)
        let cw = settingsText.naturalWidth + 6 + 16, cx = 1 + (sw - 1 - cw) / 2
        settingsText.frame = CGRect(x: cx, y: (48 - settingsText.height) / 2, width: settingsText.naturalWidth, height: settingsText.height)
        settingsIcon.frame = CGRect(x: cx + settingsText.naturalWidth + 6, y: 16, width: 16, height: 16)
        y += 48
        if let o = options {
            let oh = o.layout(w)
            o.frame = CGRect(x: 0, y: y, width: w, height: oh)
            y += oh
        }
        return y
    }
}

// ---- the seat-check status: `.status` ----------------------------------------------------------------------------

final class StatusBar: UIView {
    enum State { case checking(done: Int, total: Int, routes: Int), ok(at: String), stale(minutes: Int, at: String), failed(count: Int, at: String) }
    private var parts: [UIView] = []
    private var title = TextView(""), detail = TextView("")
    private var pip: UIView?
    private var meter: (Border, Box, CGFloat)?
    let refresh = Tap()
    private var refreshText = TextView(""), refreshIcon = IconView(Icon.refresh, size: 18)
    private let refreshFrame = Border(.ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
    private var checking = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .panel
        refresh.addSubview(refreshFrame)
        refresh.addSubview(refreshIcon)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: State) {
        parts.forEach { $0.removeFromSuperview() }
        parts = []
        pip = nil
        meter = nil
        refresh.removeFromSuperview()
        switch s {
        case .checking(let done, let total, let routes):
            checking = true
            title = TextView("正在向 12306 核对余票", size: 15, weight: 700, color: .muted)
            detail = TextView("\(routes) 个方案，已查 \(done)/\(total) 段，查完一并列出", size: 13, color: .muted)
            let frame = Border(.ink, UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)), fill = Box(.ink)
            frame.addSubview(fill)
            meter = (frame, fill, CGFloat(done) / CGFloat(max(total, 1)))
            parts = [title, detail, frame]
        case .ok(let at), .stale(_, let at), .failed(_, let at):
            checking = false
            var failed = 0, stale = false
            if case .failed(let n, _) = s { failed = n }
            if case .stale = s { stale = true }
            let text: String
            switch s {
            case .failed(let n, _): text = "\(n) 段余票查询失败"
            case .stale(let m, _): text = "余票是 \(m) 分钟前的"
            default: text = "余票已核对"
            }
            title = TextView(text, size: 15, weight: 700)
            detail = TextView("\(at) 查询 12306" + (failed > 0 ? "，相关方案标为查询失败" : ""), size: 13, color: .muted)
            // .pip: 14px square, 2px ink; filled when fine, muted when stale, 20px dashed with a cross when failed
            let p: Border
            if failed > 0 {
                p = Border(.ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
                p.dashed = true
                let x = IconView(Icon.cross, size: 14)
                x.frame = CGRect(x: 3, y: 3, width: 14, height: 14)
                p.addSubview(x)
                p.frame.size = CGSize(width: 20, height: 20)
            } else {
                p = Border(stale ? .muted : .ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2), fill: stale ? nil : .ink)
                p.frame.size = CGSize(width: 14, height: 14)
            }
            pip = p
            let filled = failed > 0 || stale
            refresh.backgroundColor = filled ? .ink : .clear
            refreshIcon.tint = filled ? .panel : .ink
            refreshText.removeFromSuperview()
            refreshText = TextView(failed > 0 ? "重试" : "刷新", size: 15, color: filled ? .panel : .ink)
            refresh.addSubview(refreshText)
            refresh.accessibilityIdentifier = "refresh"
            parts = [p, title, detail]
            addSubview(refresh)
        }
        parts.forEach(addSubview)
    }

    /// The title and detail: flex-wrap, align-items baseline, gap 2px 12px. Returns the height.
    private func placeText(x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
        detail.unwrap()
        if title.naturalWidth + 12 + detail.naturalWidth <= w {
            let above = max(title.firstBaseline, detail.firstBaseline)
            let below = max(title.height - title.firstBaseline, detail.height - detail.firstBaseline)
            title.frame = CGRect(x: x, y: y + above - title.firstBaseline, width: title.naturalWidth, height: title.height)
            detail.frame = CGRect(x: x + title.naturalWidth + 12, y: y + above - detail.firstBaseline, width: detail.naturalWidth, height: detail.height)
            return above + below
        }
        title.frame = CGRect(x: x, y: y, width: min(w, title.naturalWidth), height: title.height)
        let dh = detail.wrap(w)
        detail.frame = CGRect(x: x, y: y + title.height + 2, width: w, height: dh)
        return title.height + 2 + dh
    }

    /// min-height 56px, padding 6px 6px 6px 16px (16px right while checking), flex-wrap, align center, gap 8px 14px.
    func layout(_ w: CGFloat) -> CGFloat {
        let left: CGFloat = 16, right: CGFloat = checking ? 16 : 6, inner = w - left - right
        if case let (frame, fill, share)? = meter {
            let th = placeText(x: left, y: 6, w: inner)
            frame.frame = CGRect(x: left, y: 6 + th + 8, width: inner, height: 12)
            fill.frame = CGRect(x: 1, y: 1, width: (inner - 2) * share, height: 10)
            let content = th + 8 + 12, h = max(56, content + 12)
            let shift = (h - 12 - content) / 2
            for v in [title, detail, frame] { v.frame.origin.y += shift }
            return h
        }
        guard let pip else { return 56 }
        // .refresh: min-height 44px, padding 0 14px, 2px ink, icon 18px + gap 6px + text
        let bw = 2 + 14 + 18 + 6 + refreshText.naturalWidth + 14 + 2
        let tw = inner - pip.frame.width - 14 - 14 - bw
        let probe = placeText(x: 0, y: 0, w: max(tw, 140))
        let lineH = max(44, probe, pip.frame.height)
        let h = max(56, lineH + 12)
        let cy = h / 2
        pip.frame.origin = CGPoint(x: left, y: cy - pip.frame.height / 2)
        _ = placeText(x: left + pip.frame.width + 14, y: cy - probe / 2, w: max(tw, 140))
        refresh.frame = CGRect(x: w - right - bw, y: cy - 22, width: bw, height: 44)
        refreshFrame.frame = refresh.bounds
        refreshIcon.frame = CGRect(x: 16, y: 13, width: 18, height: 18)
        refreshText.frame = CGRect(x: 16 + 18 + 6, y: (44 - refreshText.height) / 2, width: refreshText.naturalWidth, height: refreshText.height)
        return h
    }
}

// ---- a route as a line diagram: `.route` -------------------------------------------------------------------------

struct LegState {
    var seats: Seats?
    var missing = false
    var error: String?
    var departed = false   // today's train that left: 已发车
    var closed = false     // today's train that stopped selling but has not left: 停止售票
}

final class RouteRow: UIView {
    struct Item {
        enum Kind { case stop(name: String, times: [(String, String)], note: String?, gate: (raw: String, label: String?)?, inLine: String?, outLine: String?, xchg: Bool),
                         leg(code: String, cls: String, minutes: Int, terminus: String?, state: LegState?), xfer(text: String) }
        let kind: Kind
    }

    private let when = UIView()
    private let whenRule = Box(.rule)
    private var whenItems: [(UIView, CGFloat, CGFloat, CGFloat)] = []   // view, width, height, baseline
    private var rows: [(track: [UIView], content: [UIView], kind: Item.Kind)] = []

    init(depart: Int, arrive: Int, status: String, items: [Item]) {
        super.init(frame: .zero)
        backgroundColor = .panel
        addSubview(when)
        addSubview(whenRule)
        // .when .t 1.5rem/700 (arrival 600, muted), line-height 1.05; .dur 0.9375rem/600; the status after it
        let t1 = TextView(clock(depart), .num, size: 24, weight: 700, lineHeight: 25.2)
        let t2 = TextView(clock(arrive), .num, size: 24, weight: 600, color: .muted, lineHeight: 25.2)
        let dur = TextView(span(arrive - depart), .num, size: 15, weight: 600)
        for v in [t1, t2, dur] { whenItems.append((v as UIView, v.naturalWidth, v.height, v.firstBaseline)) }
        // .verdict: inline-flex, centre, gap 6px, 0.9375rem/700 (500 muted unless on sale or failed); a 12px pip first
        let label = ["pending": "查询中", "error": "查询失败", "ok": "有票", "none": "无票", "gone": "已发车"][status] ?? ""
        let quiet = status == "none" || status == "pending" || status == "gone"
        let vt = TextView(label, .num, size: 15, weight: quiet ? 500 : 700, color: quiet ? .muted : .ink)
        let v = UIView()
        v.addSubview(vt)
        v.isAccessibilityElement = true
        v.accessibilityLabel = label
        v.accessibilityIdentifier = "status-\(status)"
        let vh = vt.height
        if status != "pending" && status != "gone" {
            let pip = Border(status == "none" ? .muted : .ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2), fill: status == "ok" ? .ink : nil)
            pip.dashed = status == "error"
            pip.frame = CGRect(x: 0, y: (vh - 12) / 2, width: 12, height: 12)
            v.addSubview(pip)
            vt.frame = CGRect(x: 18, y: 0, width: vt.naturalWidth, height: vh)
            // a flex container's baseline is its first item's: the pip, which has none, so its bottom edge
            whenItems.append((v, 18 + vt.naturalWidth, vh, pip.frame.maxY))
        } else {
            vt.frame = CGRect(x: 0, y: 0, width: vt.naturalWidth, height: vh)
            whenItems.append((v, vt.naturalWidth, vh, vt.firstBaseline))
        }
        whenItems.forEach { when.addSubview($0.0) }
        for it in items { add(it.kind) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func line(_ cls: String?, solid: Bool = true) -> UIView {
        guard let cls else { return Box(.clear) }
        if cls == "W" { let b = Border(.muted, UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 0)); b.dashed = true; return b }
        return Box(.line(cls))
    }

    private func add(_ kind: Item.Kind) {
        var track: [UIView] = [], content: [UIView] = []
        switch kind {
        case .stop(let name, let times, let note, let gate, let inLine, let outLine, let xchg):
            track = [line(inLine), line(outLine), Border(.ink, UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), fill: .panel)]
            if xchg { track.append(Box(.ink)) }
            if !name.isEmpty { content.append(TextView(name, size: 18, weight: 700, lineHeight: 24.3)) }   // .stop-name 1rem/700, 1.35
            for (t, k) in times {
                // .stop-time 0.875rem muted, its time in <b> 1.125rem/600 Archivo with 3px after
                let strut = Run(text: "", size: 13, color: .muted)
                content.append(TextView(k.isEmpty ? [strut, Run(text: t, face: .num, size: 18, weight: 600, marginRight: 3)]
                                                  : [strut, Run(text: t, face: .num, size: 18, weight: 600, marginRight: 3), Run(text: k, size: 13, color: .muted)]))
            }
            if let note { content.append(TextView(note, size: 13, color: .muted)) }   // .stop-note 0.8125rem, its own line
            // .stop-gate 0.8125rem muted, inline after the time; the gate in <b> 600 ink
            // with a researched short form: "检票口 <b>10/11</b>"; else 12306's own words in <b>
            if let gate {
                content.append(TextView(gate.label.map { [Run(text: "检票口 ", size: 13, color: .muted), Run(text: $0, size: 13, weight: 600)] }
                                        ?? [Run(text: gate.raw, size: 13, weight: 600)]))
            }
        case .leg(let code, let cls, _, let terminus, let state):
            track = [Box(.line(cls))]
            let badge = Box(.line(cls))
            badge.isUserInteractionEnabled = false
            let bt = TextView(code, .num, size: 18, weight: 700, color: .onLine, lineHeight: 18)   // .train 1.125rem/700, line-height 1
            badge.addSubview(bt)
            content = [badge]
            // .leg-to 0.8125rem muted, the station in <b> 600 ink with 4px before it
            if let terminus, !terminus.isEmpty {
                content.append(TextView([Run(text: "终到站", size: 13, color: .muted, marginRight: 4), Run(text: terminus, size: 13, weight: 600)]))
            }
            content.append(contentsOf: seatViews(state))
        case .xfer(let text):
            // .xfer: the line breaks, joined by a dashed connector (.xfer .bar 3px dashed); the wait in the gap
            let b = Border(.muted, UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 0))
            b.dashed = true
            track = [b]
            content = [TextView(text, .num, size: 18, weight: 700)]   // .xfer-text 1.125rem/700 Archivo, ink: the wait is a key figure
        }
        (track + content).forEach(addSubview)
        rows.append((track, content, kind))
    }

    /// .seats: plates "label | count", the count filled with ink when on sale; or one line of state.
    private func seatViews(_ s: LegState?) -> [UIView] {
        guard let s else { return [TextView("正在查询余票", size: 13, color: .muted)] }
        if s.departed || s.closed { return [TextView(s.departed ? "已发车" : "停止售票", size: 13, color: .muted)] }   // .seats.pending
        if s.error != nil || s.missing {
            let v = UIView()
            let x = IconView(Icon.cross, size: 16)
            let t = TextView(s.error != nil ? "余票查询失败" : "当日不开行", size: 13, weight: 600)
            v.addSubview(x)
            v.addSubview(t)
            x.frame = CGRect(x: 0, y: (t.height - 16) / 2, width: 16, height: 16)
            t.frame = CGRect(x: 20, y: 0, width: t.naturalWidth, height: t.height)
            v.frame.size = CGSize(width: 20 + t.naturalWidth, height: t.height)
            return [v]
        }
        let seats = s.seats!
        var out: [UIView] = []
        if !seats.canBuy {
            let p = Border(.rule, UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
            let t = TextView("暂不售票", size: 13, lineHeight: 20.8)
            p.addSubview(t)
            t.frame = CGRect(x: 1, y: 1, width: t.naturalWidth, height: t.height)
            p.frame.size = CGSize(width: t.naturalWidth + 2, height: 24 + 2)
            out.append(p)
        }
        for (k, v) in [("商务", seats.sw), ("一等", seats.yd), ("二等", seats.ed), ("无座", seats.wz)] where v != "--" {
            let ok = v == "有" || (Int(v) != nil && !v.isEmpty)
            let p = Border(ok ? .ink : .rule, UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
            let label = TextView(k, size: 13, color: ok ? .ink : .muted, lineHeight: 20.8)
            let count = TextView(v, .num, size: 15, weight: ok ? 700 : 500, color: ok ? .panel : .muted, lineHeight: 24)
            let cell = Box(ok ? .ink : .clear)
            p.addSubview(cell)
            p.addSubview(label)
            p.addSubview(count)
            // .seat > span padding 0 4px; .seat b padding 0 5px, min-width 24px
            let lw = 4 + label.naturalWidth + 4, cw = max(24, 5 + count.naturalWidth + 5)
            label.frame = CGRect(x: 1 + 4, y: 1, width: label.naturalWidth, height: label.height)
            cell.frame = CGRect(x: 1 + lw, y: 1, width: cw, height: count.height)
            count.frame = CGRect(x: 1 + lw + (cw - count.naturalWidth) / 2, y: 1, width: count.naturalWidth, height: count.height)
            p.frame.size = CGSize(width: lw + cw + 2, height: count.height + 2)   // the items stretch to the count's 25px
            p.isAccessibilityElement = true
            p.accessibilityLabel = "\(k) \(v)"
            out.append(p)
        }
        return out
    }

    /// Lays out views left to right, wrapping at `w`, with gaps; returns the frames' height. `align`: how each line's
    /// items sit (centre, or on a shared baseline given per view).
    private static func flow(_ items: [(UIView, CGSize, CGFloat?)], x0: CGFloat, y0: CGFloat, w: CGFloat, gapX: CGFloat, gapY: CGFloat,
                             breakBefore: (Int) -> Bool = { _ in false }) -> CGFloat {
        var lines: [[(UIView, CGSize, CGFloat?)]] = [[]]
        var x: CGFloat = 0
        for (k, it) in items.enumerated() {
            if !lines[lines.count - 1].isEmpty && (x + it.1.width > w || breakBefore(k)) { lines.append([]); x = 0 }
            lines[lines.count - 1].append(it)
            x += it.1.width + gapX
        }
        var y = y0
        for (n, line) in lines.enumerated() where !line.isEmpty {
            let baseline = line.allSatisfy { $0.2 != nil }
            let above: CGFloat = baseline ? line.map { $0.2! }.max()! : 0
            let height: CGFloat = baseline ? above + line.map { $0.1.height - $0.2! }.max()! : line.map { $0.1.height }.max()!
            var x = x0
            for (v, size, b) in line {
                let top = baseline ? y + above - b! : y + (height - size.height) / 2
                v.frame = CGRect(x: x, y: top, width: size.width, height: size.height)
                x += size.width + gapX
            }
            y += height + (n < lines.count - 1 ? gapY : 0)
        }
        return y - y0
    }

    func layout(_ w: CGFloat) -> CGFloat {
        // .when: padding 10px 16px, flex-wrap baseline, gap 4px 12px; the duration pushed right (margin-left auto)
        let inner = w - 32
        let total = whenItems.reduce(0) { $0 + $1.1 } + 12 * CGFloat(whenItems.count - 1)
        var whenH: CGFloat
        if total <= inner {
            let above = whenItems.map { $0.3 }.max()!, below = whenItems.map { $0.2 - $0.3 }.max()!
            var x: CGFloat = 16
            for (k, (v, iw, ih, b)) in whenItems.enumerated() {
                if k == 2 { x += inner - total }
                v.frame = CGRect(x: x, y: 10 + above - b, width: iw, height: ih)
                x += iw + 12
            }
            whenH = 10 + above + below + 10
        } else {
            whenH = 10 + RouteRow.flow(whenItems.map { ($0.0, CGSize(width: $0.1, height: $0.2), Optional($0.3)) }, x0: 16, y0: 10, w: inner, gapX: 12, gapY: 4) + 10
        }
        when.frame = CGRect(x: 0, y: 0, width: w, height: whenH)
        whenRule.frame = CGRect(x: 0, y: whenH, width: w, height: 1)
        // .diagram: padding 8px 16px 12px; rows of a 28px track and the text after it
        var y = whenH + 1 + 8
        let tx: CGFloat = 16, cx: CGFloat = 16 + 28, cw = w - 32 - 28
        for row in rows {
            var h: CGFloat
            switch row.kind {
            case .stop(_, _, let note, let gate, _, _, let xchg):
                // .stop-text: padding 8px 0 8px 12px, flex-wrap baseline, column-gap 10px; the note and the gate each on
                // their own line
                let texts = row.content.compactMap { $0 as? TextView }
                // the note on its own line; the 检票口 inline after the time (.stop-gate, no flex-basis), wrapping only if too long
                // texts: name, time(s), note?, 检票口?
                let noteAt = note == nil ? -1 : texts.count - 1 - (gate != nil ? 1 : 0)
                if noteAt >= 0 { texts[noteAt].wrap(cw - 12) }
                if gate != nil, let g = texts.last, g.naturalWidth > cw - 12 { g.wrap(cw - 12) }
                let items = texts.map { ($0 as UIView, CGSize(width: min($0.naturalWidth, cw - 12), height: $0.height), Optional($0.firstBaseline)) }
                let th = RouteRow.flow(items, x0: cx + 12, y0: y + 8, w: cw - 12, gapX: 10, gapY: 0,
                                       breakBefore: { $0 == noteAt })
                h = th + 16
                let size: CGFloat = xchg ? 22 : 18
                let (inL, outL, node) = (row.track[0], row.track[1], row.track[2] as! Border)
                // the line arriving (top half) and leaving (bottom half): left calc(50% - 3px), its own width
                let inW: CGFloat = inL is Border ? 3 : 6, outW: CGFloat = outL is Border ? 3 : 6
                inL.frame = CGRect(x: tx + 11, y: y, width: inW, height: h / 2)
                outL.frame = CGRect(x: tx + 11, y: y + h / 2, width: outW, height: h / 2)
                node.frame = CGRect(x: tx + (28 - size) / 2, y: y + (h - size) / 2, width: size, height: size)
                if xchg, row.track.count > 3 { row.track[3].frame = node.frame.insetBy(dx: 7, dy: 7) }   // ::after, inset 3px in the border
            case .leg(_, _, _, let terminus, _):
                // .leg-info: padding 4px 0 10px 12px, column, gap 6px; .leg-head: centre, gap 4px 10px
                let badge = row.content[0], bt = badge.subviews.first as! TextView
                let head = terminus?.isEmpty == false ? 2 : 1   // the badge, 终到站 when known
                badge.frame.size = CGSize(width: 8 + bt.naturalWidth + 8, height: 5 + bt.height + 4)
                bt.frame = CGRect(x: 8, y: 5, width: bt.naturalWidth, height: bt.height)
                let texts = row.content[1..<head].map { $0 as! TextView }
                let hh = RouteRow.flow([(badge, badge.frame.size, CGFloat?.none)] + texts.map { ($0 as UIView, CGSize(width: $0.naturalWidth, height: $0.height), CGFloat?.none) },
                                       x0: cx + 12, y0: y + 4, w: cw - 12, gapX: 10, gapY: 4)
                let seats = Array(row.content.dropFirst(head))
                var sh: CGFloat = 0
                if let only = seats.first as? TextView, seats.count == 1 {
                    only.frame = CGRect(x: cx + 12, y: y + 4 + hh + 6, width: only.naturalWidth, height: only.height)
                    sh = only.height
                } else if seats.count == 4 && cw - 12 <= 268 {
                    // @container (max-width: 268px): four plates two by two (max-content columns, gap 4px), never 3 + 1
                    let col0 = max(seats[0].frame.width, seats[2].frame.width), row0 = max(seats[0].frame.height, seats[1].frame.height)
                    let y0 = y + 4 + hh + 6
                    for (k, v) in seats.enumerated() {
                        v.frame.origin = CGPoint(x: cx + 12 + (k % 2 == 0 ? 0 : col0 + 4), y: y0 + (k < 2 ? 0 : row0 + 4))
                    }
                    sh = row0 + 4 + max(seats[2].frame.height, seats[3].frame.height)
                } else {
                    sh = RouteRow.flow(seats.map { ($0, $0.frame.size, CGFloat?.none) }, x0: cx + 12, y0: y + 4 + hh + 6, w: cw - 12,
                                       gapX: 4, gapY: seats.count == 1 ? 2 : 4)
                }
                h = max(56, 4 + hh + 6 + sh + 10)
                row.track[0].frame = CGRect(x: tx + 11, y: y, width: 6, height: h)
            case .xfer:
                // .xfer: min-height 36px; .xfer-text padding-left 12px, centred (align-self); the bar centred in the track
                let t = row.content[0] as! TextView
                let th = t.wrap(cw - 12)
                h = max(36, th)
                t.frame = CGRect(x: cx + 12, y: y + (h - th) / 2, width: cw - 12, height: th)
                row.track[0].frame = CGRect(x: tx + 12.5, y: y, width: 3, height: h)
            }
            y += h
        }
        return y + 12
    }
}
