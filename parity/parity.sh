#!/usr/bin/env bash
# The app's planner gives exactly the site's routes and search hits: both run on the live timetable for a set of
# station pairs and their output must be identical. Needs swift and node >= 22; CHINA_TRAIN = a checkout of DE0CH/china-train.
set -euo pipefail
cd "$(dirname "$0")"
: "${CHINA_TRAIN:?checkout of DE0CH/china-train}"
tt=$(mktemp); trap 'rm -f "$tt" "$tt".*' EXIT
curl -sfL https://train.deyaochen.com/timetable.json -o "$tt"
cp "$CHINA_TRAIN/lib/planner.ts" "$tt.planner.ts"
swift build -c release -q
fail=0
while read -r from to sce mw; do
  ./.build/release/Parity "$tt" "$from" "$to" $sce $mw > "$tt.swift"
  node --experimental-strip-types --no-warnings plan.mjs "$tt.planner.ts" "$tt" "$from" "$to" $sce $mw > "$tt.js"
  if cmp -s "$tt.swift" "$tt.js"; then echo "same: $from $to $sce $mw ($(grep -vc '^search\|^clock' "$tt.js") routes)"
  else echo "DIFFERENT: $from $to $sce $mw"; diff "$tt.js" "$tt.swift" | head -20; fail=1; fi
done <<'PAIRS'
香港西九龙 深圳坪山
深圳坪山 香港西九龙
北京南 上海虹桥
广州南 长沙南 1
香港西九龙 北京西 0 720
成都东 重庆北
昆明南 南宁东 1 600
PAIRS
exit $fail
