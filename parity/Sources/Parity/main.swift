import Foundation

// parity TIMETABLE FROM TO [sameCityEnds] [maxWait]: the routes as lines "depart arrive transfers train>train"
// (stations as telecodes), and the station search hits, the same format plan.mjs prints.
let a = CommandLine.arguments
let tt = try Timetable(json: Data(contentsOf: URL(fileURLWithPath: a[1])))
var o = PlanOptions()
if a.count > 4 { o.sameCityEnds = a[4] == "1" }
if a.count > 5 { o.maxWait = Int(a[5])! }
for r in plan(tt, from: tt.index(of: a[2])!, to: tt.index(of: a[3])!, o) {
    print(r.depart, r.arrive, r.transfers, r.legs.map { "\($0.train)/\($0.trainNo)@\(tt.stations[$0.from].code)-\(tt.stations[$0.to].code) \($0.depart)-\($0.arrive)" }.joined(separator: " > "))
}
for q in ["sz", "shenzhen", "香港", "IFQ", "北京", "gz"] { print("search", q, searchStations(tt, q).map { tt.stations[$0].code }.joined(separator: ",")) }
print("clock", clock(1500), clock(65), span(48), span(120), span(135), addDays("2026-12-31", 1))
