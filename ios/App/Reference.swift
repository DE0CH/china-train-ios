import UIKit
import WebKit

/// `-reference`: china-train's own page (its `dist/`, built by CI from DE0CH/china-train and bundled as Site/) in a
/// WKWebView, the HTML the native screen is drawn from. A `train://` scheme handler serves the page's files and
/// answers what its server would: /timetable.json from the phone's cached copy, /api/query from the phone's own 12306
/// query (or the fixture), so the reference needs no server either. The replica compares the two screen by screen.
final class ReferenceController: UIViewController {
    private let handler = SiteScheme()

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "train")
        config.websiteDataStore = .nonPersistent()
        var script = ""
        if Flags.fixture {
            // the fixture's clock, as Flags.now() gives the native screen
            script += """
            (() => { const T = \(Int(Flags.fixedNow.timeIntervalSince1970 * 1000)); const R = Date;
              function D(...a) { if (!new.target) return new R(T).toString(); return a.length ? new R(...a) : new R(T); }
              D.prototype = R.prototype; D.now = () => T; D.UTC = R.UTC; D.parse = R.parse; window.Date = D; })();
            """
        }
        if let y = Flags.scroll {
            script += """
            (() => { const t = setInterval(() => { if (document.querySelector('.status:not(.s-checking)')) {
              clearInterval(t); window.scrollTo(0, \(Int(y))); } }, 100); })();
            """
        }
        if !script.isEmpty {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.backgroundColor = .ground
        web.underPageBackgroundColor = .ground
        web.scrollView.showsVerticalScrollIndicator = false
        web.load(URLRequest(url: URL(string: "train://app/index.html")!))
        view = web
    }
}

final class SiteScheme: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()
    private var timetable: Timetable?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        Task { @MainActor in
            do {
                let (data, type) = try await answer(url)
                guard !stopped.contains(ObjectIdentifier(task)) else { return }
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"])!)
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !stopped.contains(ObjectIdentifier(task)) else { return }
                let body = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
                task.didReceive(HTTPURLResponse(url: url, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
                task.didReceive(body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    @MainActor private func table() async throws -> (Data, Timetable) {
        let data: Data
        if let d = TimetableStore.cached() { data = d } else { data = try await TimetableStore.download() }
        if timetable == nil { timetable = try Timetable(json: data) }
        return (data, timetable!)
    }

    @MainActor private func answer(_ url: URL) async throws -> (Data, String) {
        switch url.path {
        case "/timetable.json":
            return (try await table().0, "application/json")
        case "/api/query":
            let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { a, _ in a })
            let (from, to, date) = (q["from"] ?? "", q["to"] ?? "", q["date"] ?? "")
            if Flags.fixture {
                try await Task.sleep(nanoseconds: 50_000_000)
                return (apiJSON(fixtureSeats(try await table().1, from: from, to: to)), "application/json")
            }
            return (apiJSON(try await TwelveOhSix.shared.seats(from: from, to: to, date: date)), "application/json")
        default:
            let path = url.path == "/" || url.path.isEmpty ? "/index.html" : url.path
            guard let site = Bundle.main.url(forResource: "Site", withExtension: nil),
                  let data = try? Data(contentsOf: site.appendingPathComponent(String(path.dropFirst()))) else {
                throw PlanError.message("not found: \(path)")
            }
            let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "svg": "image/svg+xml", "json": "application/json"]
            return (data, types[(path as NSString).pathExtension] ?? "application/octet-stream")
        }
    }
}
