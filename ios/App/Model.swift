import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The planner, the timetable and 12306, with no server: a Swift port of DE0CH/china-train's lib/planner.ts,
// lib/train-api.ts and worker/index.ts. Foundation only, so it also builds and runs on Linux (Tests/).

struct Station {
    let code, name, pinyin, abbr, city: String
}

struct Train {
    let code, no: String
    let stops: [Int]   // [station index, arrive, depart] minutes, flattened
}

/// The national timetable (timetable.json, crawled weekly by china-train's crawler/ from 12306).
final class Timetable {
    let generated: String
    let stations: [Station]
    let trains: [Train]
    let byStation: [[(train: Int, pos: Int)]]   // station → [train, stop position]
    let byCode: [String: Int]
    let byCity: [String: [Int]]                 // only stations with trains, in station order

    init(json: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let generated = raw["generated"] as? String,
              let st = raw["stations"] as? [[String]], let tr = raw["trains"] as? [[Any]] else {
            throw PlanError.message("时刻表格式不对")
        }
        self.generated = generated
        stations = st.map { Station(code: $0[0], name: $0[1], pinyin: $0[2], abbr: $0[3], city: $0[4]) }
        trains = tr.map { t in
            Train(code: t[0] as? String ?? "", no: t[1] as? String ?? "",
                  stops: (t[2] as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? 0 })
        }
        var by = [[(train: Int, pos: Int)]](repeating: [], count: stations.count)
        for (ti, t) in trains.enumerated() {
            for p in 0..<(t.stops.count / 3) { by[t.stops[p * 3]].append((ti, p)) }
        }
        byStation = by
        var codes: [String: Int] = [:]
        for (i, s) in stations.enumerated() where codes[s.code] == nil { codes[s.code] = i }
        byCode = codes
        var city: [String: [Int]] = [:]
        for (i, s) in stations.enumerated() where !by[i].isEmpty { city[s.city, default: []].append(i) }
        byCity = city
    }

    func index(of nameOrCode: String) -> Int? {
        byCode[nameOrCode] ?? stations.firstIndex { $0.name == nameOrCode }
    }
}

enum PlanError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

struct Leg: Equatable {
    let train, trainNo: String
    let from, to: Int           // station indices
    let depart, arrive: Int     // minutes from midnight of the travel date (may pass 1440)
}

struct Route: Equatable {
    let legs: [Leg]
    let depart, arrive, transfers: Int
}

struct PlanOptions: Codable, Equatable {
    var sameStationChange = 15   // minimum minutes to change trains in one station
    var crossTownChange = 60     // minimum minutes to change between two stations of one city
    var maxWait = 240            // longest wait for the second train
    var sameCityEnds = false     // also start/end at the other stations of the chosen cities
}

/// Every direct train and every one-transfer pair, then only the routes no other route beats on both departure and
/// arrival. The iteration order is the page's (Map/Set insertion order), so ties come out the same.
func plan(_ tt: Timetable, from: Int, to: Int, _ o: PlanOptions = PlanOptions()) -> [Route] {
    func ends(_ i: Int) -> [Int] { o.sameCityEnds ? tt.byCity[tt.stations[i].city] ?? [i] : [i] }
    let origins = ends(from), dests = ends(to)
    let originSet = Set(origins), destSet = Set(dests)
    // train → its first stop position at a destination station (insertion order kept in destOrder)
    var destPos: [Int: Int] = [:], destOrder: [Int] = []
    for d in dests {
        for (ti, p) in tt.byStation[d] {
            if let q = destPos[ti] { if p < q { destPos[ti] = p } } else { destPos[ti] = p; destOrder.append(ti) }
        }
    }
    // station → the trains boarding there that go on to a destination: [train, position]
    var boardAt: [Int: [(Int, Int)]] = [:]
    for ti in destOrder {
        let dq = destPos[ti]!
        for p in 0..<dq { boardAt[tt.trains[ti].stops[p * 3], default: []].append((ti, p)) }
    }

    var routes: [Route] = []
    for o0 in origins {
        for (t1, p1) in tt.byStation[o0] {
            let T1 = tt.trains[t1].stops
            let start = T1[p1 * 3 + 2] % 1440, shift = start - T1[p1 * 3 + 2]   // the train's times → the day's clock
            func leg1(_ q: Int) -> Leg {
                Leg(train: tt.trains[t1].code, trainNo: tt.trains[t1].no, from: o0, to: T1[q * 3], depart: start, arrive: T1[q * 3 + 1] + shift)
            }
            let n = T1.count / 3
            if let dp = destPos[t1], dp > p1 {
                let l = leg1(dp)
                routes.append(Route(legs: [l], depart: l.depart, arrive: l.arrive, transfers: 0))
                continue   // a direct train is never improved by leaving it for another one
            }
            guard p1 + 1 < n else { continue }
            for q in (p1 + 1)..<n {
                let x = T1[q * 3]
                if destSet.contains(x) || originSet.contains(x) { continue }
                let l1 = leg1(q)
                for y in tt.byCity[tt.stations[x].city] ?? [x] {
                    let minChange = y == x ? o.sameStationChange : o.crossTownChange
                    for (t2, p2) in boardAt[y] ?? [] where t2 != t1 {
                        let dq = destPos[t2]!
                        let T2 = tt.trains[t2].stops, bdep = T2[p2 * 3 + 2]
                        // the first departure of t2 from y (it runs daily at the same clock time) after the change
                        var dep2 = bdep % 1440 + (l1.arrive / 1440) * 1440
                        while dep2 < l1.arrive + minChange { dep2 += 1440 }
                        if dep2 - l1.arrive > o.maxWait { continue }
                        let arr2 = T2[dq * 3 + 1] - bdep + dep2
                        let l2 = Leg(train: tt.trains[t2].code, trainNo: tt.trains[t2].no, from: y, to: T2[dq * 3], depart: dep2, arrive: arr2)
                        routes.append(Route(legs: [l1, l2], depart: start, arrive: arr2, transfers: 1))
                    }
                }
            }
        }
    }
    return pareto(routes)
}

/// Sorts like Array.prototype.sort (stable): ties keep their order.
private func stableSorted<T>(_ xs: [T], _ less: (T, T) -> Bool) -> [T] {
    xs.enumerated().sorted { a, b in less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset) }.map(\.element)
}

/// Keep a route unless another departs no earlier, arrives no later and has no more transfers; among equals the
/// shortest wait wins.
private func pareto(_ rs: [Route]) -> [Route] {
    func wait(_ r: Route) -> Int { r.legs.count > 1 ? r.legs[1].depart - r.legs[0].arrive : 0 }
    let sorted = stableSorted(rs) { a, b in
        if a.arrive != b.arrive { return a.arrive < b.arrive }
        if a.depart != b.depart { return a.depart > b.depart }
        if a.transfers != b.transfers { return a.transfers < b.transfers }
        return wait(a) < wait(b)
    }
    var kept: [Route] = []
    for r in sorted where !kept.contains(where: { $0.depart >= r.depart && $0.arrive <= r.arrive && $0.transfers <= r.transfers }) {
        kept.append(r)
    }
    return stableSorted(kept) { a, b in a.depart != b.depart ? a.depart < b.depart : a.arrive < b.arrive }
}

/// Station search for the pickers: name, full pinyin, initials or telecode.
/// Station search, as lib/planner.ts: exact and prefix matches on the name, initials, telecode and the Latin keys
/// (pinyin and an English name: a trailing 北/南/东/西 read as north/south/east/west) first; then the typed characters in
/// order with gaps (深北 → 深圳北, szhbei → shenzhenbei), fewest gaps first; then a key with a typo or two (1 edit from
/// 4 letters, 2 from 7, against the key's best prefix). Spaces and a final "station" are ignored.
private let direction: [Character: (String, String)] = ["北": ("bei", "north"), "南": ("nan", "south"), "东": ("dong", "east"), "西": ("xi", "west")]
private let extraKeys = ["香港西九龙": ["xianggangxijiulong", "hongkongwestkowloon", "westkowloon", "xijiulong"]]   // 12306's pinyin isn't

private func latinKeys(_ st: Station) -> [String] {
    var keys = [st.pinyin] + (extraKeys[st.name] ?? [])
    if let last = st.name.last, let dir = direction[last], st.name.count >= 3, st.pinyin.hasSuffix(dir.0) {
        keys.append(String(st.pinyin.dropLast(dir.0.count)) + dir.1)
    }
    return keys
}

/// q's characters found in s in order (each at the first place it can go): the gaps left between them, or -1.
private func gapsInOrder(_ q: [Character], _ s: [Character]) -> Int {
    var j = 0, gaps = 0, last = -1
    for (i, c) in s.enumerated() where j < q.count && c == q[j] {
        if last >= 0 && i > last + 1 { gaps += 1 }
        last = i
        j += 1
    }
    return j == q.count ? gaps : -1
}

/// Edits to turn q into some prefix of s (Levenshtein with a free tail of s).
private func prefixEdits(_ q: [Character], _ s: [Character]) -> Int {
    var prev = Array(0...s.count)
    for i in stride(from: 1, through: q.count, by: 1) {
        var cur = [i] + Array(repeating: 0, count: s.count)
        for j in stride(from: 1, through: s.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (q[i - 1] == s[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev.min()!
}

func searchStations(_ tt: Timetable, _ q: String, limit: Int = 8) -> [Int] {
    let t = q.trimmingCharacters(in: .whitespaces)
    var s = String(t.lowercased().filter { !$0.isWhitespace })
    let isLatin = { (x: String) in !x.isEmpty && x.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 } }
    if isLatin(s) && s.count > 7 {
        if s.hasSuffix("railwaystation") { s.removeLast(14) } else if s.hasSuffix("station") { s.removeLast(7) }
    }
    if s.isEmpty { return [] }
    let latin = isLatin(s)
    let typos = !latin || s.count < 4 ? 0 : s.count < 7 ? 1 : 2
    let qs = Array(s)
    var scored: [(Int, Int)] = []
    for (i, st) in tt.stations.enumerated() where !tt.byStation[i].isEmpty {
        let keys = latin ? latinKeys(st) : []
        var score = -1, near = 0
        if st.name == t { score = 0 }
        else if st.name.hasPrefix(t) { score = 1 }
        else if st.abbr == s || keys.contains(s) { score = 2 }
        else if st.abbr.hasPrefix(s) || keys.contains(where: { $0.hasPrefix(s) }) { score = 3 }
        else if st.code.lowercased() == s { score = 3 }
        else if st.name.contains(t) || st.city.hasPrefix(t) { score = 4 }
        else if qs.count >= 2 {
            let gaps = (latin ? keys.filter { $0.first == qs[0] } : [st.name]).map { gapsInOrder(qs, Array($0)) }.filter { $0 >= 0 }
            if let g = gaps.min() { score = 5; near = g }
            else if typos > 0, let d = keys.map({ prefixEdits(qs, Array($0)) }).min(), d <= typos { score = 6; near = d }
        }
        if score >= 0 { scored.append((score * 100000 + min(near, 9) * 10000 - min(tt.byStation[i].count, 9999), i)) }
    }
    return stableSorted(scored) { $0.0 < $1.0 }.prefix(limit).map(\.1)
}

func clock(_ m: Int) -> String {
    let d = Int((Double(m) / 1440).rounded(.down)), r = ((m % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", r / 60, r % 60) + (d > 0 ? " +\(d)" : "")
}

func span(_ m: Int) -> String { m >= 60 ? "\(m / 60)小时" + (m % 60 != 0 ? "\(m % 60)分" : "") : "\(m)分" }

func addDays(_ iso: String, _ n: Int) -> String {
    let f = isoFormatter(utc: true)
    guard let d = f.date(from: iso) else { return iso }
    return f.string(from: d.addingTimeInterval(Double(n) * 86400))
}

func isoFormatter(utc: Bool = false) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = utc ? TimeZone(identifier: "UTC") : .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}

func trainClass(_ code: String) -> String {
    guard let c = code.first, "GCD".contains(c) else { return "P" }
    return String(c)
}

let className = ["G": "高铁", "D": "动车", "C": "城际", "P": "普速"]

// ---- seats ------------------------------------------------------------------------------------------------------

struct Seats: Equatable {
    var sw, yd, ed, wz: String
    var canBuy: Bool
    var code: String
    var terminus = ""   // 终到站: 12306 gives its telecode; `named(_:)` turns it into the station's name
    var start = ""      // the date the train left its origin, YYYYMMDD (what the 检票口 lookup needs)
}

/// The seats with each terminus telecode replaced by its name from the timetable's station list (12306's full list).
func named(_ seats: [String: Seats], _ tt: Timetable) -> [String: Seats] {
    seats.mapValues { s in
        var s = s
        if let i = tt.byCode[s.terminus] { s.terminus = tt.stations[i].name }
        return s
    }
}

/// 12306's 检票口 text, shorter, as the page shows it: "16检票口,17检票口" -> "16 / 17"; nil when nothing is left.
func gateLabel(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let parts = raw.split(whereSeparator: { $0 == "," || $0 == "，" }).map { p -> String in
        var t = p.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("进站检票口") { t.removeLast(5) } else if t.hasSuffix("检票口") { t.removeLast(3) }
        if t.hasPrefix("检票口") { t.removeFirst(3) }
        return t.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && !$0.allSatisfy { $0 == "-" } }
    return parts.isEmpty ? nil : parts.joined(separator: " / ")
}

/// 12306's seat query, straight from the phone: the JSON endpoint its own search page uses
/// (kyfw.12306.cn/otn/leftTicket/query<X>). The path suffix changes a few times a year and is read from the search page,
/// whose cookies the query needs, with a browser User-Agent and Referer (else 12306 answers with an HTML redirect).
actor TwelveOhSix {
    static let shared = TwelveOhSix()
    private static let base = "https://kyfw.12306.cn"
    private static let initURL = URL(string: "\(base)/otn/leftTicket/init")!
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    // positions in a result row (undocumented; the community list used by 12306-mcp and every open-source client)
    private enum F { static let trainId = 2, trainNo = 3, terminusCode = 5, fromCode = 6, toCode = 7, canWebBuy = 11, startDate = 13, tz = 25, wz = 26, ze = 30, zy = 31, swz = 32 }

    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private var session: (cookie: String, path: String, at: Date)?
    private var cache: [String: Task<[String: Seats], Error>] = [:]

    /// Seats by 12306 train_no for one station pair and date. `fresh` asks 12306 again instead of the cached answer.
    func seats(from: String, to: String, date: String, fresh: Bool = false) async throws -> [String: Seats] {
        let key = "\(from)|\(to)|\(date)"
        if !fresh, let t = cache[key] { return try await t.value }
        let t = Task { try await self.query(from: from, to: to, date: date) }
        cache[key] = t
        do { return try await t.value } catch { cache[key] = nil; throw error }
    }

    private var gateCache: [String: Task<[String: String], Error>] = [:]

    /// 检票口 by station telecode for one train (its code and origin date YYYYMMDD), from the stops 12306's WeChat
    /// mini-program shows (mobile.12306.cn, no login). 12306 fills it in for trains running today; stations without one
    /// are left out. A failure is not cached, so a later look asks again.
    func gates(code: String, start: String) async throws -> [String: String] {
        let key = "\(code)|\(start)"
        if let t = gateCache[key] { return try await t.value }
        let t = Task { () -> [String: String] in
            var r = URLRequest(url: URL(string: "https://mobile.12306.cn/wxxcx/wechat/main/travelServiceQrcodeTrainInfo")!)
            r.httpMethod = "POST"
            r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "trainCode", value: code), URLQueryItem(name: "startDay", value: start),
                               URLQueryItem(name: "startTime", value: ""), URLQueryItem(name: "endDay", value: ""), URLQueryItem(name: "endTime", value: "")]
            r.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            let (data, _) = try await self.http.data(for: r)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let stops = ((json?["data"] as? [String: Any])?["trainDetail"] as? [String: Any])?["stopTime"] as? [[String: Any]] ?? []
            var out: [String: String] = [:]
            for s in stops {
                let w = (s["wicket"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if let c = s["stationTelecode"] as? String, !w.isEmpty, !w.allSatisfy({ $0 == "-" }) { out[c] = w }
            }
            return out
        }
        gateCache[key] = t
        do { return try await t.value } catch { gateCache[key] = nil; throw error }
    }

    private func get(_ url: URL, _ headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await http.data(for: r)
        guard let h = response as? HTTPURLResponse else { throw PlanError.message("12306 没有回应") }
        return (data, h)
    }

    private func openSession() async throws -> (cookie: String, path: String, at: Date) {
        let (data, r) = try await get(Self.initURL)
        let html = String(decoding: data, as: UTF8.self)
        var path = "leftTicket/query"
        if let m = html.range(of: #"var CLeftTicketUrl\s*=\s*'([^']+)'"#, options: .regularExpression) {
            let s = html[m]
            if let a = s.firstIndex(of: "'"), let b = s.lastIndex(of: "'"), a < b { path = String(s[s.index(after: a)..<b]) }
        }
        var fields: [String: String] = [:]
        for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: Self.initURL).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return (cookie, path, Date())
    }

    private func query(from: String, to: String, date: String) async throws -> [String: Seats] {
        var errors: [String] = []
        for _ in 0..<2 {   // one retry with a fresh search-page session
            do {
                if session == nil || Date().timeIntervalSince(session!.at) > 8 * 60 { session = try await openSession() }
                let s = session!
                var u = URLComponents(string: "\(Self.base)/otn/\(s.path)")!
                u.queryItems = [URLQueryItem(name: "leftTicketDTO.train_date", value: date), URLQueryItem(name: "leftTicketDTO.from_station", value: from),
                                URLQueryItem(name: "leftTicketDTO.to_station", value: to), URLQueryItem(name: "purpose_codes", value: "ADULT")]
                let (data, r) = try await get(u.url!, ["Cookie": s.cookie, "Referer": Self.initURL.absoluteString,
                                                       "Accept": "application/json, text/javascript, */*; q=0.01", "X-Requested-With": "XMLHttpRequest",
                                                       "If-Modified-Since": "0", "Cache-Control": "no-cache"])
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    session = nil
                    throw PlanError.message("12306 answered \(r.statusCode) with non-JSON")
                }
                guard (json["httpstatus"] as? Int) == 200, let d = json["data"] as? [String: Any] else {
                    session = nil
                    throw PlanError.message("12306 error: \((json["messages"] as? [String])?.joined(separator: "; ") ?? "empty response")")
                }
                return Self.parse(d["result"] as? [String] ?? [], from: from, to: to)
            } catch {
                errors.append("\(error)")
            }
        }
        throw PlanError.message("12306 查询失败（\(errors.joined(separator: " | "))）")
    }

    /// 12306 answers with every station in the queried cities: keep only rows boarding and alighting at the asked ones.
    static func parse(_ rows: [String], from: String, to: String) -> [String: Seats] {
        var out: [String: Seats] = [:]
        for row in rows {
            let f = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count > F.swz, f[F.fromCode] == from, f[F.toCode] == to else { continue }
            func seat(_ i: Int) -> String { let v = f[i].trimmingCharacters(in: .whitespaces); return v.isEmpty ? "--" : v }
            // 商务座 falls back to 特等座 (older sets label the top class that way)
            out[f[F.trainId]] = Seats(sw: seat(F.swz) != "--" ? seat(F.swz) : seat(F.tz), yd: seat(F.zy), ed: seat(F.ze), wz: seat(F.wz),
                                      canBuy: f[F.canWebBuy] == "Y", code: f[F.trainNo],
                                      terminus: f[F.terminusCode], start: f[F.startDate])
        }
        return out
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// `-fixture`: made-up seats for every train the timetable runs between the two stations, the same answer each time
/// (one train in eleven "does not run"), so the replica can draw identical states natively and in the HTML.
func fixtureSeats(_ tt: Timetable, from: String, to: String, date: String) -> [String: Seats] {
    guard let a = tt.byCode[from], let b = tt.byCode[to] else { return [:] }
    let counts = ["有", "无", "5", "12", "有", "无", "--", "有"]
    var out: [String: Seats] = [:]
    for (ti, pa) in tt.byStation[a] {
        guard tt.byStation[b].contains(where: { $0.train == ti && $0.pos > pa }) else { continue }
        let t = tt.trains[ti]
        let h = t.no.unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 1_000_003 }
        if h % 11 == 0 { continue }
        out[t.no] = Seats(sw: counts[h % 8], yd: counts[(h / 8) % 8], ed: counts[(h / 64) % 8], wz: h % 3 == 0 ? "--" : counts[(h / 512) % 8],
                          canBuy: h % 13 != 0, code: t.code, terminus: tt.stations[t.stops[t.stops.count - 3]].code,
                          start: date.replacingOccurrences(of: "-", with: ""))
    }
    return out
}

/// `-fixture`: made-up 检票口 for a train's stops, the same each time: some stations have none, some several.
func fixtureGates(_ tt: Timetable, code: String) -> [String: String] {
    guard let t = tt.trains.first(where: { $0.code == code }) else { return [:] }
    var out: [String: String] = [:]
    for p in 0..<(t.stops.count / 3) {
        let st = tt.stations[t.stops[p * 3]].code
        let h = (code + st).unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 1_000_003 }
        switch h % 4 {
        case 0: continue
        case 1: out[st] = "\(h % 20 + 1)检票口"
        case 2: out[st] = "\(h % 12 + 1)A、\(h % 12 + 2)A,\(h % 12 + 1)B、\(h % 12 + 2)B"
        default: out[st] = "检票口\(h % 9 + 1),检票口\(h % 9 + 2)"
        }
    }
    return out
}

/// The answer china-train's Worker gives for /api/query, so the reference page can be fed by the phone.
func apiJSON(_ seats: [String: Seats]) -> Data {
    let trains = seats.keys.sorted().map { k -> [String: Any] in
        let s = seats[k]!
        return ["trainno": s.code, "train_no": k, "terminus": s.terminus, "start": s.start, "canBuy": s.canBuy, "numsw": s.sw, "numyd": s.yd, "numed": s.ed, "numwz": s.wz]
    }
    return (try? JSONSerialization.data(withJSONObject: ["trains": trains])) ?? Data()
}

// ---- the timetable file -------------------------------------------------------------------------------------------

/// timetable.json from train.deyaochen.com's static assets (no code runs there), cached on the phone. The cached copy
/// is used at once; a new one is fetched when it is over a day old (the crawl is weekly).
enum TimetableStore {
    static let url = URL(string: "https://train.deyaochen.com/timetable.json")!
    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timetable.json")
    }

    static func cached() -> Data? { try? Data(contentsOf: file) }

    static var stale: Bool {
        guard let at = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(at) > 86400
    }

    static func download() async throws -> Data {
        var r = URLRequest(url: url)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PlanError.message("时刻表加载失败（HTTP \(status)）") }
        _ = try Timetable(json: data)
        try data.write(to: file, options: .atomic)
        return data
    }
}
