import UIKit
import WebKit

/// `-geometry`: a nearly invisible accessibility element whose label is a JSON dump of where things were laid out,
/// natively or by WebKit, for the replica to print and compare (not a pixel test: the numbers behind it).
enum GeometryProbe {
    static func show(_ json: String, in view: UIView) {
        let v = view.viewWithTag(7_331) ?? {
            let p = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            p.tag = 7_331
            p.alpha = 0.02
            p.backgroundColor = .black
            p.isAccessibilityElement = true
            p.accessibilityIdentifier = "geometry"
            view.addSubview(p)
            return p
        }()
        v.accessibilityLabel = json
    }

    /// In the page: every text element's box and its first text line's rect (an inline box: WebKit's ascent above the
    /// baseline to its descent below), with the page scroll removed, posted once the seat check settles.
    static let script = """
    (() => { const t = setInterval(() => {
      if (!document.querySelector('.status:not(.s-checking)')) return;
      clearInterval(t);
      setTimeout(() => {
        const sel = 'h1,.sub,.sign label,.swap-label,.day span,.day b,.preset,.status-text b,.status-text span,.refresh,.seg button,.count,.legend li,.when .t,.when .dur,.verdict,.stop-name,.stop-time b,.stop-time span,.train,.leg-dur,.seat span,.seat b,.xfer-text,.sign input,.stop-gate,.leg-to';
        const items = [];
        document.querySelectorAll(sel).forEach((e, i) => {
          if (i > 400) return;
          const r = e.getBoundingClientRect();
          let line = null;
          const tn = [...e.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
          if (tn) { const g = document.createRange(); g.selectNodeContents(tn); const q = g.getClientRects()[0];
            if (q) line = [q.x, q.y + scrollY, q.width, q.height]; }
          items.push([e.tagName.toLowerCase() + '.' + (e.className || ''), (e.value || e.textContent || '').trim().slice(0, 16), r.x, r.y + scrollY, r.width, r.height, line]);
        });
        window.webkit.messageHandlers.geometry.postMessage(JSON.stringify({ items, width: innerWidth }));
      }, 2000);   // after the 检票口 lookups that follow the seats
    }, 100); })();
    """
}

final class GeometryHandler: NSObject, WKScriptMessageHandler {
    weak var view: UIView?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let s = message.body as? String, let view { GeometryProbe.show(s, in: view) }
    }
}
