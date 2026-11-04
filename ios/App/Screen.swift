import CoreText
import UIKit

/// Launch flags. `-reference`: the site's own page (Reference.swift) instead of the native screen. `-fixture`: made-up
/// seats and a fixed clock, so both draw the same states. `-reset`: forget the saved stations and settings.
/// `-scroll N`: once the seats are in, scroll the page to N points (both ways), for the replica.
enum Flags {
    static let args = ProcessInfo.processInfo.arguments
    static let reference = args.contains("-reference")
    static let fixture = args.contains("-fixture")
    static let reset = args.contains("-reset")
    static let geometry = args.contains("-geometry")
    static let scroll: CGFloat? = args.firstIndex(of: "-scroll").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]).map { CGFloat($0) } : nil }
    /// The fixture's clock: 2 November 2026, 09:41 on the phone's own time zone.
    static let fixedNow: Date = {
        let c = DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 41)
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    static func now() -> Date { fixture ? fixedNow : Date() }
}

let presets: [(String, String)] = [("香港西九龙", "深圳坪山"), ("深圳坪山", "香港西九龙")]
let short = { (name: String) -> String in
    for p in ["香港", "深圳"] where name.hasPrefix(p) && name.count >= p.count + 2 { return String(name.dropFirst(p.count)) }
    return name
}
let staleMinutes = 10   // seats older than this are called out, with the refresh button

enum Prefs {
    static let d = UserDefaults.standard
    static var opts: PlanOptions {
        get { (d.data(forKey: "opts")).flatMap { try? JSONDecoder().decode(PlanOptions.self, from: $0) } ?? PlanOptions() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "opts") }
    }
    static var recent: [String] {
        get { d.stringArray(forKey: "recent") ?? [] }
        set { d.set(newValue, forKey: "recent") }
    }
    static var last: [String]? {
        get { d.stringArray(forKey: "last") }
        set { d.set(newValue, forKey: "last") }
    }
}

/// The native screen: the page's phone layout in one scroll view, every part placed by hand (Components.swift).
final class Screen: UIViewController, UITextFieldDelegate {
    private let scroll = UIScrollView()
    private let header = Header()
    private let board = Board(presets: presets.map { "\(short($0.0))到\(short($0.1))" })
    private let suggest = SuggestList()
    private var errorView: UIView?
    private var resultViews: [UIView] = []
    private var statusBar: StatusBar?

    // state, as App.tsx keeps it
    private var tt: Timetable?
    private var from: Int?, to: Int?
    private var date: String
    private var opts = Prefs.opts
    private var showOpts = false
    private var filter = "all"
    private var routes: [Route]?
    private var legs: [String: Result<[String: Seats], Error>] = [:]
    private var days: [String: TrainDay?] = [:]   // "code|YYYYMMDD" → the train's run that day (nil inside: asking)
    private var gates: [String: String?] = [:]    // "code|YYYY-MM-DD|telecode" → 检票口 as 12306 writes it ("" none)
    private var dayQueue: [(job: String, date: String)] = []
    private var dayBusy = 0
    private var total = 0
    private var checkedAt: Date?
    private var now = Flags.now()
    private var recent = Prefs.recent
    private var run = 0
    private var loadError: String?
    // the picker being edited
    private var editingSign: StationSign?
    private var hits: [Int] = []
    private var hi = 0
    private var scrolledForTest = false

    init() {
        if Flags.reset { ["opts", "recent", "last"].forEach(UserDefaults.standard.removeObject) }
        opts = Prefs.opts
        recent = Prefs.recent
        date = isoFormatter().string(from: Flags.now().addingTimeInterval(86400))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .ground
        scroll.backgroundColor = .ground
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        for v in [header, board] as [UIView] { scroll.addSubview(v) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapOutside(_:)))
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)

        for (sign, isFrom) in [(board.fromSign, true), (board.toSign, false)] {
            sign.field.delegate = self
            sign.field.isEnabled = false
            sign.field.addTarget(self, action: #selector(typed(_:)), for: .editingChanged)
            _ = isFrom
        }
        suggest.onPick = { [weak self] i in self?.pick(i) }
        board.swap.onTap = { [weak self] in
            guard let self else { return }
            (from, to) = (to, from)
            changed()
        }
        board.days.onPick = { [weak self] iso in self?.date = iso; self?.changed() }
        for (p, (a, b)) in zip(board.presets, presets) {
            p.onTap = { [weak self] in
                guard let self, let tt else { return }
                from = tt.stations.firstIndex { $0.name == a }
                to = tt.stations.firstIndex { $0.name == b }
                changed()
            }
        }
        board.settings.onTap = { [weak self] in self?.toggleOptions() }
        board.days.set(today: now, selected: date)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, checkedAt != nil else { return }
            now = Flags.now()
            renderResults()
        }
    }

    // ---- the timetable ----

    private func load() {
        if !Flags.fixture { Task { await GateLabels.refresh(); renderResults() } }   // the 检票口 short forms, refreshed daily
        if let data = TimetableStore.cached(), let t = try? Timetable(json: data) {
            loaded(t)
            if TimetableStore.stale { Task { if let d = try? await TimetableStore.download(), let t = try? Timetable(json: d) { loaded(t) } } }
            return
        }
        Task {
            do { loaded(try Timetable(json: try await TimetableStore.download())) }
            catch { loadError = "时刻表加载失败：\(error.localizedDescription)"; render() }
        }
    }

    private func loaded(_ t: Timetable) {
        let names = (from.map { tt?.stations[$0].name ?? "" }, to.map { tt?.stations[$0].name ?? "" })
        tt = t
        loadError = nil
        header.set(generated: t.generated)
        let pair = (names.0 != nil && names.1 != nil) ? [names.0!, names.1!] : (Prefs.last ?? [presets[0].0, presets[0].1])
        from = t.index(of: pair[0])
        to = pair.count > 1 ? t.index(of: pair[1]) : nil
        for s in [board.fromSign, board.toSign] { s.field.isEnabled = true; s.placeholder("站名、拼音、英文或首字母") }
        changed()
    }

    // ---- searching ----

    private func legKey(_ tt: Timetable, _ l: Leg) -> String {
        "\(tt.stations[l.from].code)|\(tt.stations[l.to].code)|\(addDays(date, Int((Double(l.depart) / 1440).rounded(.down))))"
    }

    /// Something the search depends on changed (stations, date, settings): search again, as the page's effect does.
    private func changed() {
        board.days.set(today: now, selected: date)
        showStations()
        search()
        render()
    }

    private func search(fresh: Bool = false) {
        guard let tt, let from, let to, from != to else { return }
        run += 1
        let id = run
        Prefs.last = [tt.stations[from].name, tt.stations[to].name]
        let rs = plan(tt, from: from, to: to, opts)
        var keys: [String] = [], seen = Set<String>()
        for r in rs { for l in r.legs { let k = legKey(tt, l); if seen.insert(k).inserted { keys.append(k) } } }
        routes = rs
        legs = [:]
        total = keys.count
        checkedAt = keys.isEmpty ? Flags.now() : nil
        scrolledForTest = false
        let q = Progress()
        for _ in 0..<4 {   // a few queries at a time
            Task { @MainActor in
                while q.next < keys.count && run == id {
                    let k = keys[q.next]
                    q.next += 1
                    let p = k.split(separator: "|").map(String.init)
                    let v: Result<[String: Seats], Error>
                    do { v = .success(try await seats(tt, p[0], p[1], p[2], fresh: fresh)) } catch { v = .failure(error) }
                    if run != id { return }
                    legs[k] = v
                    askDays()
                    q.done += 1
                    if q.done == keys.count { checkedAt = Flags.now(); now = Flags.now() }
                    renderResults()
                }
            }
        }
    }

    private final class Progress { var next = 0, done = 0 }

    private func seats(_ tt: Timetable, _ a: String, _ b: String, _ d: String, fresh: Bool) async throws -> [String: Seats] {
        if Flags.fixture {
            try await Task.sleep(nanoseconds: 50_000_000)
            return named(fixtureSeats(tt, from: a, to: b, date: d), tt)
        }
        return named(try await TwelveOhSix.shared.seats(from: a, to: b, date: d, fresh: fresh), tt)
    }

    /// Minutes since the travel date's midnight when it is today, else nil: today, trains that left are kept while their
    /// route is under way.
    private var nowMinutes: Int? {
        guard date == isoFormatter().string(from: now) else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return c.hour! * 60 + c.minute!
    }
    private let salesClose = 60   // minutes before departure within which a train missing from the seats is checked

    /// "code|YYYYMMDD" of the day a leg's train left its origin: from 12306's seats when there, else the timetable.
    private func trainKey(_ tt: Timetable, _ l: Leg, _ s: Seats?) -> String {
        if let s, !s.start.isEmpty { return "\(s.code)|\(s.start)" }
        var dep = 0
        if let t = tt.trains.first(where: { $0.no == l.trainNo }) {
            for p in 0..<(t.stops.count / 3) where t.stops[p * 3] == l.from { dep = t.stops[p * 3 + 2]; break }
        }
        let day = addDays(date, Int((Double(l.depart) / 1440).rounded(.down)) - Int((Double(dep) / 1440).rounded(.down)))
        return "\(l.train)|\(day.replacingOccurrences(of: "-", with: ""))"
    }

    /// For today's trains missing from the seat answer that left or stop selling within the hour: whether they run (12306
    /// lists their stops); and every shown leg's 检票口 (12306's own 检票口 query, known days ahead). Three lookups at a
    /// time; one still waiting when the date changes is dropped.
    private func askDays() {
        guard let tt, let routes else { return }
        let nowMin = nowMinutes
        for r in routes where nowMin == nil || r.arrive > nowMin! {
            for l in r.legs {
                guard case .success(let m) = legs[legKey(tt, l)] else { continue }
                let s = m[l.trainNo]
                let tk = trainKey(tt, l, s)
                if s == nil {
                    guard let n = nowMin, l.depart < n + salesClose else { continue }
                    if days[tk] == nil { days[tk] = .some(nil); dayQueue.append(("run|" + tk, date)) }
                }
                let gk = gateKey(s?.code ?? l.train, l, tt)
                if gates[gk] == nil {
                    gates[gk] = .some(nil)
                    dayQueue.append(("gate|" + gk + "|" + String(tk.split(separator: "|")[1]), date))
                }
            }
        }
        while dayBusy < 3, !dayQueue.isEmpty {
            let (job, asked) = dayQueue.removeFirst()
            let p = job.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if asked != date {
                if p[0] == "run" { days[p[1] + "|" + p[2]] = nil } else { gates[p[1...3].joined(separator: "|")] = nil }
                continue
            }
            dayBusy += 1
            Task { @MainActor in
                if p[0] == "run" {
                    var r: Bool? = true
                    if !Flags.fixture { r = try? await TwelveOhSix.shared.runs(code: p[1], start: p[2]) }
                    days[p[1] + "|" + p[2]] = .some(TrainDay(runs: r))
                } else {
                    var g = ""
                    if Flags.fixture { g = fixtureGate(code: p[1], station: p[3]) }
                    else { g = (try? await TwelveOhSix.shared.gate(code: p[1], date: p[2], station: p[3], start: p[4])) ?? "" }   // a failure: none
                    gates[p[1...3].joined(separator: "|")] = .some(g)
                }
                dayBusy -= 1
                renderSoon()
                askDays()
            }
        }
    }

    /// One redraw for the side lookups that land within 100 ms of each other: each would otherwise rebuild every row,
    /// and a hundred of them in a row keep the screen changing for seconds.
    private var renderPending = false
    private func renderSoon() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in renderPending = false; renderResults() }
    }

    /// "code|YYYY-MM-DD|telecode": a leg's train, the date it leaves its boarding station, and that station.
    private func gateKey(_ code: String, _ l: Leg, _ tt: Timetable) -> String {
        "\(code)|\(addDays(date, Int((Double(l.depart) / 1440).rounded(.down))))|\(tt.stations[l.from].code)"
    }

    // ---- the pickers ----

    private func sign(of field: UITextField) -> StationSign { field === board.fromSign.field ? board.fromSign : board.toSign }
    private func value(_ s: StationSign) -> Int? { s === board.fromSign ? from : to }
    private func shown(_ s: StationSign) -> String { value(s).flatMap { tt?.stations[$0].name } ?? "" }

    private func showStations() {
        for s in [board.fromSign, board.toSign] {
            let st = value(s).flatMap { tt?.stations[$0] }
            if editingSign !== s { s.field.text = st?.name ?? "" }
            s.pinyin.set([Run(text: st != nil && editingSign !== s ? pinyinLabel(st!) : " ", face: .num, size: 17, weight: 500, color: .muted)])
            s.field.accessibilityValue = st?.name
        }
    }

    private var recentIdx: [Int] {
        guard let tt else { return [] }
        var out: [Int] = [], seen = Set<Int>()
        for n in recent + presets.flatMap({ [$0.0, $0.1] }) {
            if let i = tt.stations.firstIndex(where: { $0.name == n }), seen.insert(i).inserted { out.append(i) }
        }
        return out
    }

    private func updateHits() {
        guard let tt, let s = editingSign else { return }
        let text = s.field.text ?? "", q = text.trimmingCharacters(in: .whitespaces)
        hits = !q.isEmpty && q != shown(s) ? searchStations(tt, q) : Array(recentIdx.filter { $0 != value(s) }.prefix(8))
        suggest.set(tt, hits: hits, head: q.isEmpty || text == shown(s), hi: hi)
        if hits.isEmpty { suggest.removeFromSuperview() } else { scroll.addSubview(suggest) }
        layoutPage()
    }

    func textFieldDidBeginEditing(_ f: UITextField) {
        let s = sign(of: f)
        editingSign = s
        s.focused(true)
        hi = 0
        DispatchQueue.main.async { f.selectAll(nil) }   // the page's select() on focus: typing replaces the name
        showStations()
        updateHits()
        scroll.scrollRectToVisible(CGRect(x: 0, y: board.frame.minY + s.frame.minY, width: 1, height: s.frame.height + 200), animated: true)
    }

    @objc private func typed(_ f: UITextField) {
        hi = 0
        updateHits()
    }

    func textFieldShouldReturn(_ f: UITextField) -> Bool {
        if hits.indices.contains(hi) { pick(hits[hi]) } else { f.resignFirstResponder() }
        return false
    }

    func textFieldDidEndEditing(_ f: UITextField) {
        let s = sign(of: f)
        s.focused(false)
        if editingSign === s { editingSign = nil }
        suggest.removeFromSuperview()
        showStations()
        layoutPage()
    }

    private func pick(_ i: Int) {
        guard let tt, let s = editingSign else { return }
        if s === board.fromSign { from = i } else { to = i }
        recent = [tt.stations[i].name] + recent.filter { $0 != tt.stations[i].name }
        recent = Array(recent.prefix(8))
        Prefs.recent = recent
        s.field.text = tt.stations[i].name
        s.field.resignFirstResponder()
        changed()
    }

    @objc private func tapOutside(_ g: UITapGestureRecognizer) {
        guard editingSign != nil else { return }
        let p = g.location(in: scroll)
        if suggest.superview != nil && suggest.frame.contains(p) { return }
        if let s = editingSign, s.convert(s.bounds, to: scroll).contains(p) { return }
        view.endEditing(true)
    }

    private func toggleOptions() {
        showOpts.toggle()
        board.setOptionsOpen(showOpts)
        board.options?.removeFromSuperview()
        board.options = nil
        if showOpts {
            let o = OptionsPanel(opts)
            o.same.onChange = { [weak self] v in self?.opts.sameStationChange = v; self?.optsChanged() }
            o.cross.onChange = { [weak self] v in self?.opts.crossTownChange = v; self?.optsChanged() }
            o.wait.onChange = { [weak self] v in self?.opts.maxWait = v; self?.optsChanged() }
            o.check.onTap = { [weak self, weak o] in
                guard let self, let o else { return }
                o.check.on.toggle()
                opts.sameCityEnds = o.check.on
                optsChanged()
            }
            board.options = o
            board.addSubview(o)
        }
        layoutPage()
    }

    private func optsChanged() {
        Prefs.opts = opts
        search()
        renderResults()
    }

    // ---- drawing ----

    private func render() {
        errorView?.removeFromSuperview()
        errorView = nil
        if let e = loadError {
            // .error: border-left 6px crimson, padding 8px 12px, on the panel
            let v = Border(.line("G"), UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0), fill: .panel)
            v.addSubview(TextView(e))
            scroll.addSubview(v)
            errorView = v
        }
        renderResults()
    }

    /// A route is hidden once 12306 says one of its trains does not run that day, or (today) once it has arrived.
    private func runs(_ r: Route) -> Bool {
        guard let tt else { return true }
        if let n = nowMinutes, r.arrive <= n { return false }
        return r.legs.allSatisfy { legState(tt, $0)?.missing != true }
    }

    /// What a leg shows: seats, 当日不开行, or for today's train that stopped selling, 已发车 / 停止售票 once its run is known.
    private func legState(_ tt: Timetable, _ l: Leg) -> LegState? {
        switch legs[legKey(tt, l)] {
        case .none: return nil
        case .failure(let e): return LegState(error: "\(e)")
        case .success(let m):
            if let s = m[l.trainNo] { return LegState(seats: s) }
            guard let n = nowMinutes, l.depart < n + salesClose else { return LegState(missing: true) }
            guard case .some(.some(let d)) = days[trainKey(tt, l, nil)] else { return nil }   // still asking
            if d.runs == false { return LegState(missing: true) }
            return l.depart <= n ? LegState(departed: true) : LegState(closed: true)
        }
    }

    private func renderResults() {
        resultViews.forEach { $0.removeFromSuperview() }
        resultViews = []
        statusBar = nil
        guard let tt, let routes else { layoutPage(); return }
        let failed = legs.values.filter { if case .failure = $0 { return true }; return false }.count
        let age = checkedAt.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
        if from != to {
            let s = StatusBar()
            if let at = checkedAt {
                let t = clock(Calendar.current.component(.hour, from: at) * 60 + Calendar.current.component(.minute, from: at))
                s.set(failed > 0 ? .failed(count: failed, at: t) : age >= staleMinutes ? .stale(minutes: age, at: t) : .ok(at: t))
                s.refresh.onTap = { [weak self] in self?.search(fresh: true); self?.renderResults() }
            } else {
                s.set(.checking(done: legs.count, total: total, routes: routes.count))
            }
            statusBar = s
            resultViews.append(s)
        }
        if checkedAt != nil {
            let visible = routes.filter(runs).filter { filter == "all" || (filter == "direct" ? $0.transfers == 0 : $0.transfers > 0) }
            let hidden = routes.filter { !runs($0) }.count
            resultViews.append(filtersView(count: visible.count, hidden: hidden))
            if !visible.isEmpty { resultViews.append(legend(visible)) }
            if visible.isEmpty { resultViews.append(TextView("没有找到方案。在换乘设置里延长最长等候，或勾选同城其他车站，再看一次。", color: .muted)) }
            for r in visible { resultViews.append(row(tt, r)) }
        }
        resultViews.forEach { scroll.insertSubview($0, belowSubview: board) }
        layoutPage()
        if Flags.geometry, checkedAt != nil { dumpGeometry() }
        if let y = Flags.scroll, checkedAt != nil, !scrolledForTest {
            // 1.5 s after the seats are in, when the 检票口 lookups have landed (as the reference does)
            scrolledForTest = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                scroll.layoutIfNeeded()
                scroll.contentOffset.y = min(y, max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)) - scroll.adjustedContentInset.top
            }
        }
    }

    /// .filters: the segmented control (2px ink frame, buttons 44px high, padding 0 18px) and the count.
    private func filtersView(count: Int, hidden: Int) -> UIView {
        let v = UIView()
        let seg = Border(.ink, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        var x: CGFloat = 2
        for (k, (key, label)) in [("all", "全部"), ("direct", "直达"), ("xfer", "中转")].enumerated() {
            let on = filter == key
            let b = Tap()
            b.backgroundColor = on ? .ink : .clear
            let t = TextView(label, size: 15, color: on ? .panel : .ink)
            b.addSubview(t)
            b.accessibilityIdentifier = "filter-\(key)"
            b.isAccessibilityElement = true
            b.accessibilityLabel = label
            b.accessibilityTraits = on ? [.button, .selected] : .button
            if k > 0 { let r = Box(.ink); r.frame = CGRect(x: x, y: 2, width: 2, height: 44); seg.addSubview(r); x += 2 }
            let w = 18 + t.naturalWidth + 18
            b.frame = CGRect(x: x, y: 2, width: w, height: 44)
            t.frame = CGRect(x: 18, y: (44 - t.height) / 2, width: t.naturalWidth, height: t.height)
            b.onTap = { [weak self] in self?.filter = key; self?.renderResults() }
            seg.addSubview(b)
            x += w
        }
        seg.isUserInteractionEnabled = true
        seg.frame = CGRect(x: 0, y: 0, width: x + 2, height: 48)
        v.addSubview(seg)
        let c = TextView("\(count) 个方案" + (hidden > 0 ? "，\(hidden) 个当日不开行已隐藏" : ""), size: 14, color: .muted)
        v.addSubview(c)
        return v
    }

    /// .legend: one swatch per train class on screen, and the walk when a route changes stations.
    private func legend(_ visible: [Route]) -> UIView {
        let v = UIView()
        for c in ["G", "D", "C", "P"] where visible.contains(where: { $0.legs.contains { trainClass($0.train) == c } }) {
            let sw = Box(.line(c))
            sw.frame.size = CGSize(width: 28, height: 6)
            v.addSubview(sw)
            v.addSubview(TextView(className[c]!, size: 14, color: .muted))
        }
        if visible.contains(where: { r in r.legs.indices.contains { $0 > 0 && r.legs[$0 - 1].to != r.legs[$0].from } }) {
            let sw = Border(.muted, UIEdgeInsets(top: 3, left: 0, bottom: 0, right: 0))
            sw.dashed = true
            sw.frame.size = CGSize(width: 28, height: 3)
            v.addSubview(sw)
            v.addSubview(TextView("出站换乘", size: 14, color: .muted))
        }
        return v
    }

    private func row(_ tt: Timetable, _ r: Route) -> RouteRow {
        let st = { (i: Int) in tt.stations[i].name }
        let info = r.legs.map { l -> (Leg, LegState?, String, String, (raw: String, label: String?)?, String?) in
            let s = legState(tt, l)
            let code = s?.seats?.code ?? l.train
            // 检票口: the station's researched short form of 12306's exact string, else the string itself
            var gate: (raw: String, label: String?)?
            if let s, s.error == nil, !s.missing, case .some(.some(let g)) = gates[gateKey(code, l, tt)], !g.isEmpty {
                let station = tt.stations[l.from].code
                gate = (g, Flags.fixture ? fixtureLabels[station]?[g] : GateLabels.label(g, at: station))
            }
            // 终到站 from 12306's seats, else the train's last stop in the timetable
            var terminus = s?.seats?.terminus
            if s?.departed == true || s?.closed == true, let t = tt.trains.first(where: { $0.no == l.trainNo }) { terminus = tt.stations[t.stops[t.stops.count - 3]].name }
            return (l, s, code, trainClass(code), gate, terminus)
        }
        var items: [RouteRow.Item] = []
        for (k, (l, s, code, cls, gate, terminus)) in info.enumerated() {
            if k == 0 {
                items.append(.init(kind: .stop(name: st(l.from), times: [(clock(l.depart), "开")], note: nil, gate: gate, inLine: nil, outLine: cls, xchg: false)))
            } else {
                let p = info[k - 1], wait = span(l.depart - p.0.arrive)
                if p.0.to == l.from {
                    items.append(.init(kind: .stop(name: st(l.from), times: [(clock(p.0.arrive), "到"), (clock(l.depart), "开")], note: "换乘，等候\(wait)", gate: gate,
                                                   inLine: p.3, outLine: cls, xchg: true)))
                } else {
                    items.append(.init(kind: .stop(name: st(p.0.to), times: [(clock(p.0.arrive), "到")], note: nil, gate: nil, inLine: p.3, outLine: "W", xchg: true)))
                    items.append(.init(kind: .walk(text: "\(st(p.0.to))出站，到\(st(l.from))换乘，等候\(wait)")))
                    items.append(.init(kind: .stop(name: st(l.from), times: [(clock(l.depart), "开")], note: nil, gate: gate, inLine: "W", outLine: cls, xchg: true)))
                }
            }
            items.append(.init(kind: .leg(code: code, cls: cls, minutes: l.arrive - l.depart, terminus: terminus, state: s)))
            if k == info.count - 1 {
                items.append(.init(kind: .stop(name: st(l.to), times: [(clock(l.arrive), "到")], note: nil, gate: nil, inLine: cls, outLine: nil, xchg: false)))
            }
        }
        // one status for the whole route: every leg still to come needs at least one class on sale (one under way counts)
        func avail(_ s: LegState?) -> Bool {
            if s?.departed == true { return true }
            guard let x = s?.seats, x.canBuy else { return false }
            return [x.sw, x.yd, x.ed, x.wz].contains { $0 == "有" || Int($0) != nil }
        }
        let status = info.contains { $0.1 == nil } ? "pending" : info.contains { $0.1?.error != nil } ? "error"
            : info.allSatisfy { $0.1?.departed == true } ? "gone" : info.allSatisfy { avail($0.1) } ? "ok" : "none"
        return RouteRow(depart: r.depart, arrive: r.arrive, status: status, items: items)
    }

    /// `-geometry`: every drawn text's line box and baseline in page coordinates, and the fonts' metrics, as JSON in an
    /// accessibility element the replica reads (the reference reports WebKit's boxes the same way).
    private func dumpGeometry() {
        view.layoutIfNeeded()
        var items: [[Any]] = []
        func walk(_ v: UIView) {
            if let t = v as? TextView, !t.isHidden {
                let r = t.convert(t.bounds, to: scroll)
                items.append([t.accessibilityLabel ?? "", r.minX, r.minY, t.naturalWidth, t.height, t.firstBaseline])
            }
            v.subviews.forEach(walk)
        }
        walk(scroll)
        var fonts: [String: [CGFloat]] = [:]
        for (face, size, weight) in [(Face.text, 14.0, 400), (.text, 16, 700), (.text, 28, 800), (.text, 32, 800), (.num, 18, 600), (.num, 24, 700), (.num, 17, 500)] {
            let f = Fonts.font(face, CGFloat(size), weight)
            fonts["\(face)-\(Int(size))-\(weight)"] = [CTFontGetAscent(f), CTFontGetDescent(f), CTFontGetLeading(f), CTFontGetCapHeight(f)]
        }
        let json = (try? JSONSerialization.data(withJSONObject: ["items": items, "fonts": fonts])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        GeometryProbe.show(json, in: view)
    }

    // ---- layout ----

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPage()
    }

    /// main: max-width 1080px, padding 20px 16px 72px, inside the safe area's sides (as WebKit lays out a page
    /// without viewport-fit=cover).
    private func layoutPage() {
        scroll.frame = view.bounds
        let safe = view.safeAreaInsets
        let avail = view.bounds.width - safe.left - safe.right
        let w = min(1080, avail - 32), x = safe.left + (avail - w) / 2
        var y: CGFloat = 20
        let hh = header.layout(w)
        header.frame = CGRect(x: x, y: y, width: w, height: hh)
        y += hh + 20
        if let e = errorView, let t = e.subviews.first as? TextView {
            let th = t.wrap(w - 24)
            t.frame = CGRect(x: 12, y: 8, width: w - 24, height: th)
            e.frame = CGRect(x: x, y: y, width: w, height: th + 16)
            y += th + 16 + 12
        }
        let bh = board.layout(w)
        board.frame = CGRect(x: x, y: y, width: w, height: bh)
        if let s = editingSign, suggest.superview != nil {
            let sh = suggest.layout(w)
            suggest.frame = CGRect(x: x, y: y + s.frame.maxY, width: w, height: sh)
            scroll.bringSubviewToFront(suggest)
        }
        y += bh + 28
        for v in resultViews {
            switch v {
            case let s as StatusBar:
                let h = s.layout(w)
                s.frame = CGRect(x: x, y: y, width: w, height: h)
                y += h + 12
            case let r as RouteRow:
                let h = r.layout(w)
                r.frame = CGRect(x: x, y: y, width: w, height: h)
                y += h + 8
            case let t as TextView:   // .empty: padding 24px 0
                let h = t.wrap(w)
                t.frame = CGRect(x: x, y: y + 24, width: w, height: h)
                y += h + 48
            default:
                let h = flowRow(v, w)
                v.frame = CGRect(x: x, y: y, width: w, height: h)
                y += h + 12
            }
        }
        scroll.contentSize = CGSize(width: view.bounds.width, height: y + 72)   // the last part's margin stays inside the padding
    }

    /// The filters row (flex-wrap, centre, gap 8px 16px) and the legend (flex-wrap, gap 6px 20px; swatch + 8px + label).
    private func flowRow(_ v: UIView, _ w: CGFloat) -> CGFloat {
        let views = v.subviews
        if let seg = views.first as? Border, let count = views.last as? TextView, views.count == 2 {
            if seg.frame.width + 16 + count.naturalWidth <= w {
                count.frame = CGRect(x: seg.frame.width + 16, y: (48 - count.height) / 2, width: count.naturalWidth, height: count.height)
                return 48
            }
            count.frame = CGRect(x: 0, y: 48 + 8, width: count.naturalWidth, height: count.height)
            return 48 + 8 + count.height
        }
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for i in stride(from: 0, to: views.count - 1, by: 2) {
            let sw = views[i], t = views[i + 1] as! TextView
            let iw = 28 + 8 + t.naturalWidth
            if x > 0 && x + iw > w { x = 0; y += lineH + 6; lineH = 0 }
            let h = t.height
            sw.frame.origin = CGPoint(x: x, y: y + (h - sw.frame.height) / 2)
            t.frame = CGRect(x: x + 36, y: y, width: t.naturalWidth, height: h)
            lineH = max(lineH, h)
            x += iw + 20
        }
        return y + lineH
    }

    /// The rotation: the page is laid out again inside iOS's own animation for the turn, so the sheets and lines stretch
    /// with it and the text moves to its new place; the top of the screen stays on the same part of the page.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let anchor = (([header, board] as [UIView]) + resultViews).last { $0.frame.minY <= top }
        let into = anchor.map { top - $0.frame.minY } ?? top
        coordinator.animate(alongsideTransition: { _ in
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            let target = (anchor?.frame.minY ?? 0) + min(into, anchor?.frame.height ?? into)
            let maxY = max(0, self.scroll.contentSize.height - self.scroll.bounds.height + self.scroll.adjustedContentInset.bottom)
            self.scroll.contentOffset.y = min(target, maxY) - self.scroll.adjustedContentInset.top
        })
    }

    @objc private func keyboard(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(end, from: nil).minY - view.safeAreaInsets.bottom)
        scroll.contentInset.bottom = overlap
    }
}
