# china-train-ios

**火车路线规划** for iPhone: the route planner at https://train.deyaochen.com (DE0CH/china-train) as a native
app with **no server**. TestFlight app "China Train DE0CH" (`dev.de0ch.chinatrain`, App Store Connect 6829764929).

- **Planner on the phone:** `ios/App/Model.swift` is a Swift port of the site's `lib/planner.ts` (direct trains and
  one transfer, same station or across town, keep what no other route beats). `parity/` runs both on the live
  timetable and checks they print the same routes and station-search hits (CI job `planner`, on Linux).
- **Timetable:** the site's static `timetable.json` (Workers Static Assets, no code runs), cached on the phone and
  fetched again when over a day old.
- **Live seats:** straight from the phone to 12306's `leftTicket/query<X>` (what the site's Worker does: path from
  the search page, its cookies, browser headers, rows filtered to the queried stations).
- **Screen = UIKit drawn to the site's HTML** (`uikit-from-html` in claude-env): `Components.swift` places every
  part by hand to `src/index.css`'s phone numbers, text as Core Text lines at WebKit's baselines (PingFang SC +
  bundled Archivo, OFL). A rotation lays the page out again inside iOS's own animation (`Screen.viewWillTransition`),
  so sheets and lines stretch with the turn.
- **Reference:** CI builds DE0CH/china-train and bundles its `dist/` as `ios/App/Site`; `-reference` shows that page
  in a WKWebView whose `train://` scheme handler serves `/timetable.json` and `/api/query` from the app's own code.
  Launch flags: `-fixture` (made-up seats, clock fixed at 2026-11-02 09:41), `-reset`, `-scroll N`.
- **CI** (`.github/workflows/ios.yml`): planner parity → the phone replica on an iPhone 17 simulator
  (`testEveryFlow`, `testLive12306` reported, `testMatchesReference`: native vs the page per state, `COMPARE` lines
  and native/html/diff attachments in the `replica-screens-light` artifact) → unsigned archive, cloud-signed export
  to TestFlight. Secrets `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_PRIVATE_KEY`.
