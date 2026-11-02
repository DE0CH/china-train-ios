// The site's own planner (china-train lib/planner.ts, Node's type stripping) printing what Sources/Parity prints.
import { readFileSync } from "node:fs";
const [, , planner, file, from, to, sce, mw] = process.argv;
const P = await import(planner);
globalThis.fetch = async () => ({ ok: true, json: async () => JSON.parse(readFileSync(file, "utf8")) });
const tt = await P.loadTimetable();
const idx = (s) => tt.byCode.get(s) ?? tt.stations.findIndex((x) => x.name === s);
const o = { ...P.DEFAULT_OPTIONS, ...(sce ? { sameCityEnds: sce === "1" } : {}), ...(mw ? { maxWait: +mw } : {}) };
for (const r of P.plan(tt, idx(from), idx(to), o))
  console.log(r.depart, r.arrive, r.transfers, r.legs.map((l) => `${l.train}/${l.trainNo}@${tt.stations[l.from].code}-${tt.stations[l.to].code} ${l.depart}-${l.arrive}`).join(" > "));
for (const q of ["sz", "shenzhen", "香港", "IFQ", "北京", "gz"]) console.log("search", q, P.searchStations(tt, q).map((i) => tt.stations[i].code).join(","));
const addDays = (iso, n) => { const d = new Date(`${iso}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
console.log("clock", P.clock(1500), P.clock(65), P.span(48), P.span(120), P.span(135), addDays("2026-12-31", 1));
