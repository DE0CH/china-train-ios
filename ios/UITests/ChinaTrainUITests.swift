import XCTest

/// The phone replica: every flow on the simulator, then the native screen against china-train's own page.
final class ChinaTrainUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
    }

    /// Waits for the seat check to commit (the status bar's settled title).
    private func settled(_ app: XCUIApplication, _ seconds: TimeInterval = 90) -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for t in ["余票已核对", "段余票查询失败", "分钟前的"] {
                let q = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", t)).firstMatch
                if q.exists { return q.label }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func texts(_ app: XCUIApplication) -> String { app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label).joined(separator: " | ") }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Every flow natively, on the fixture: the planner, the seats, filters, swap, dates, settings, typing a station,
    /// the rotation, and the stations remembered across a relaunch.
    func testEveryFlow() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(["-fixture", "-reset"])
        XCTAssertEqual(settled(app), "余票已核对", "no settled seat check: \(texts(app))")
        XCTAssertTrue(app.staticTexts["香港西九龙"].exists, texts(app))
        XCTAssertTrue(app.descendants(matching: .any)["status-ok"].firstMatch.exists || app.descendants(matching: .any)["status-none"].firstMatch.exists,
                      "no route status: \(texts(app))")
        shot("flow-launch")

        any(app, "直达").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '个方案'")).firstMatch.waitForExistence(timeout: 5))
        shot("flow-direct")
        any(app, "全部").tap()

        app.buttons["交换出发站和到达站"].tap()
        XCTAssertEqual(settled(app), "余票已核对")
        XCTAssertEqual(app.textFields["出发站"].value as? String, "深圳坪山", "swap: \(texts(app))")
        shot("flow-swapped")

        any(app, "day-2026-11-04").tap()   // the fixture's day after tomorrow
        XCTAssertEqual(settled(app), "余票已核对")

        app.buttons["换乘设置"].tap()
        XCTAssertTrue(app.textFields["最长等候"].waitForExistence(timeout: 5))
        app.buttons["同城其他车站"].tap()
        XCTAssertEqual(settled(app), "余票已核对")
        shot("flow-settings")
        app.buttons["换乘设置"].tap()

        // typing a station: initials, then a suggestion
        let field = app.textFields["出发站"]
        field.tap()
        field.typeText("bjx")
        let hit = app.buttons["suggest-北京西"]
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "no 北京西 suggestion: \(texts(app))")
        shot("flow-suggest")
        hit.tap()
        XCTAssertEqual(field.value as? String, "北京西")
        XCTAssertEqual(settled(app), "余票已核对")
        shot("flow-beijing")

        print("ROTATE flow landscape \(Date().timeIntervalSince1970)")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        shot("flow-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)

        app.terminate()
        app = launch(["-fixture"])
        XCTAssertEqual(settled(app), "余票已核对")
        XCTAssertEqual(app.textFields["出发站"].value as? String, "北京西", "stations not remembered: \(texts(app))")
        app.terminate()
    }

    /// The real thing: 12306 answers the phone directly (no server between). Reported, not gating: 12306 may refuse
    /// a CI runner's network.
    func testLive12306() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-reset"])
        let status = settled(app, 120)
        print("LIVE 12306: \(status ?? "no answer in 120 s") | \(texts(app))")
        shot("live-12306")
        app.terminate()
    }

    /// Where things are, both ways: prints WebKit's boxes and line rects and the native line boxes (GEOM lines), the
    /// numbers behind the pixel comparison.
    func testGeometry() throws {
        for mode in ["native", "html"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(["-fixture", "-reset", "-geometry"] + (mode == "html" ? ["-reference"] : []))
            XCTAssertEqual(settled(app), "余票已核对")
            let probe = app.descendants(matching: .any)["geometry"].firstMatch
            let end = Date().addingTimeInterval(10)
            while Date() < end && (probe.label.isEmpty || !probe.exists) { Thread.sleep(forTimeInterval: 0.5) }
            print("GEOM \(mode) \(probe.exists ? probe.label : "none")")
            app.terminate()
        }
    }

    /// The native screen against china-train's page (`-reference`), state by state on the fixture. Prints the share of
    /// differing pixels and attaches native/html/diff images.
    func testMatchesReference() throws {
        struct State { let name: String; let args: [String]; let landscape: Bool; let settings: Bool }
        let states = [State(name: "top", args: [], landscape: false, settings: false),
                      State(name: "routes", args: ["-scroll", "560"], landscape: false, settings: false),
                      State(name: "settings", args: [], landscape: false, settings: true),
                      State(name: "landscape", args: [], landscape: true, settings: false)]
        for s in states {
            var pair: [String: XCUIScreenshot] = [:]
            for mode in ["native", "html"] {
                XCUIDevice.shared.orientation = .portrait
                let app = launch(["-fixture", "-reset"] + s.args + (mode == "html" ? ["-reference"] : []))
                XCTAssertEqual(settled(app), "余票已核对", "\(s.name) \(mode): \(texts(app))")
                if s.settings { app.buttons["换乘设置"].tap() }
                if s.landscape {
                    print("ROTATE \(mode) landscape \(Date().timeIntervalSince1970)")
                    XCUIDevice.shared.orientation = .landscapeLeft
                }
                Thread.sleep(forTimeInterval: 2)
                pair[mode] = XCUIScreen.main.screenshot()
                app.terminate()
            }
            XCUIDevice.shared.orientation = .portrait
            compare(s.name, pair["native"]!, pair["html"]!)
        }
    }

    private func compare(_ name: String, _ native: XCUIScreenshot, _ html: XCUIScreenshot) {
        let a = Gray(native.image), b = Gray(html.image)
        guard a.width == b.width, a.height == b.height else { XCTFail("\(name): sizes differ"); return }
        var differ = 0
        var diff = [UInt8](repeating: 0, count: a.width * a.height * 4)
        for i in 0..<(a.width * a.height) {
            let (x, y) = (Int(a.pixels[i]), Int(b.pixels[i]))
            let same = abs(x - y) <= 60
            if !same { differ += 1 }
            // same: faded; only in the native screen: red; only in the HTML: blue
            let v = UInt8(min(255, 170 + x / 3))
            diff[i * 4 + 0] = same ? v : (x < y ? 230 : 30)
            diff[i * 4 + 1] = same ? v : 30
            diff[i * 4 + 2] = same ? v : (x < y ? 30 : 230)
            diff[i * 4 + 3] = 255
        }
        let share = Double(differ) / Double(a.width * a.height)
        print("COMPARE \(name): differing \(String(format: "%.4f", share * 100))%")
        for (label, image) in [("native", native.image), ("html", html.image), ("diff", Gray.image(diff, a.width, a.height))] {
            let attachment = XCTAttachment(image: image)
            attachment.name = "cmp-\(name)-\(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertLessThan(share, Self.maxDiffer, "\(name): \(share * 100)% of pixels differ")
    }

    /// The share of pixels allowed to differ between the native screen and the page.
    static let maxDiffer = 0.005   // 0.06–0.38% on 2026-11-02 (build 5)
}

/// A screenshot as 8-bit grey pixels.
private struct Gray {
    let width: Int, height: Int
    var pixels: [UInt8]

    init(_ image: UIImage) {
        let cg = image.cgImage!
        width = cg.width; height = cg.height
        pixels = [UInt8](repeating: 0, count: width * height)
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    static func image(_ rgba: [UInt8], _ width: Int, _ height: Int) -> UIImage {
        var data = rgba
        let cg = data.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        return UIImage(cgImage: cg)
    }
}
