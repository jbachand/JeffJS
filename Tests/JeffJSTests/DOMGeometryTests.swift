// DOMGeometryTests.swift
// JeffJS — element geometry on the DOM bridge: layout-rect store,
// getBoundingClientRect/getClientRects, offset*/client*/scroll* accessors,
// offsetParent, scrollTop/scrollLeft, window.scrollX/scrollY, scrollingElement.
//
// Usage:
//   JEFFJS_ZOMBIES=1 swift test --filter DOMGeometryTests

import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import JeffJS

final class DOMGeometryTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @MainActor
    private func nodeID(_ env: JeffJSEnvironment, _ selector: String) -> UUID {
        let s = evalString(env, "document.querySelector('\(selector)').nativeNodeID")
        guard let id = UUID(uuidString: s) else {
            XCTFail("no nativeNodeID for \(selector): \(s)")
            return UUID()
        }
        return id
    }

    /// Builds the fixture document through the bridge itself and pushes a layout.
    ///
    ///   html/body   (0,0)   390 x 2000
    ///   #outer      (10,100) 300 x 500   position: relative   -> offsetParent for #inner/#leaf
    ///   #inner      (20,120) 200 x 900   (taller than #outer: overflow)
    ///   #leaf       (30,130)  50 x 20
    ///   #late       no rect; inline width/height only (created "after layout")
    @MainActor
    private func makeEnvironment() -> (JeffJSEnvironment, [String: UUID]) {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        _ = evalString(env, """
        document.body.innerHTML =
          '<div id="outer" style="position: relative">' +
            '<div id="inner"><span id="leaf"></span></div>' +
          '</div>' +
          '<p id="late" style="width: 120px; height: 30px"></p>';
        """)
        let ids: [String: UUID] = [
            "html": nodeID(env, "html"),
            "body": nodeID(env, "body"),
            "outer": nodeID(env, "#outer"),
            "inner": nodeID(env, "#inner"),
            "leaf": nodeID(env, "#leaf"),
            "late": nodeID(env, "#late"),
        ]
        env.updateLayoutRects([
            ids["html"]!: CGRect(x: 0, y: 0, width: 390, height: 2000),
            ids["body"]!: CGRect(x: 0, y: 0, width: 390, height: 2000),
            ids["outer"]!: CGRect(x: 10, y: 100, width: 300, height: 500),
            ids["inner"]!: CGRect(x: 20, y: 120, width: 200, height: 900),
            ids["leaf"]!: CGRect(x: 30, y: 130, width: 50, height: 20),
        ], viewport: CGSize(width: 390, height: 844))
        return (env, ids)
    }

    // MARK: - Tests

    @MainActor
    func testBoundingClientRectUsesLayoutRectsAndScrollOffset() {
        let (env, _) = makeEnvironment()
        defer { env.teardown() }

        XCTAssertEqual(
            evalString(env, "JSON.stringify(document.getElementById('outer').getBoundingClientRect())"),
            #"{"x":10,"y":100,"width":300,"height":500,"top":100,"right":310,"bottom":600,"left":10}"#)

        // Viewport coordinates: document rect minus the root scroll offset.
        env.scrollOffset = CGPoint(x: 0, y: 50)
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getBoundingClientRect().top"), "50")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getBoundingClientRect().bottom"), "550")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getBoundingClientRect().y"), "50")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getBoundingClientRect().left"), "10")

        // getClientRects(): one-element array-like with item().
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getClientRects().length"), "1")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getClientRects()[0].width"), "300")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getClientRects().item(0).height"), "500")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getClientRects().item(1)"), "null")
    }

    @MainActor
    func testOffsetClientScrollMetrics() {
        let (env, _) = makeEnvironment()
        defer { env.teardown() }

        let outer = "document.getElementById('outer')"
        XCTAssertEqual(evalString(env, "\(outer).offsetWidth"), "300")
        XCTAssertEqual(evalString(env, "\(outer).offsetHeight"), "500")
        XCTAssertEqual(evalString(env, "\(outer).clientWidth"), "300")
        XCTAssertEqual(evalString(env, "\(outer).clientHeight"), "500")
        XCTAssertEqual(evalString(env, "\(outer).clientTop"), "0")
        // #inner (120 + 900 = 1020) overflows #outer (100 + 500): extent from outer's origin = 920.
        XCTAssertEqual(evalString(env, "\(outer).scrollHeight"), "920")
        XCTAssertEqual(evalString(env, "\(outer).scrollWidth"), "300")
        XCTAssertEqual(evalString(env, "\(outer).scrollHeight > \(outer).clientHeight"), "true")

        // Integers, not floats (offsetWidth is a `long`).
        XCTAssertEqual(evalString(env, "Number.isInteger(\(outer).offsetWidth) && (\(outer).offsetWidth | 0) === 300"), "true")

        // documentElement.clientWidth/clientHeight report the viewport; body reports its rect.
        XCTAssertEqual(evalString(env, "document.documentElement.clientWidth"), "390")
        XCTAssertEqual(evalString(env, "document.documentElement.clientHeight"), "844")
        XCTAssertEqual(evalString(env, "document.documentElement.scrollHeight"), "2000")
        XCTAssertEqual(evalString(env, "document.body.clientHeight"), "2000")
        XCTAssertEqual(evalString(env, "document.scrollingElement === document.documentElement"), "true")
    }

    @MainActor
    func testOffsetParentAndOffsetTopLeft() {
        let (env, _) = makeEnvironment()
        defer { env.teardown() }

        // #outer is position: relative with a rect -> offsetParent of #inner and of #leaf (#inner is static).
        XCTAssertEqual(evalString(env, "document.getElementById('inner').offsetParent === document.getElementById('outer')"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('leaf').offsetParent === document.getElementById('outer')"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').offsetTop"), "20")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').offsetLeft"), "10")
        XCTAssertEqual(evalString(env, "document.getElementById('leaf').offsetTop"), "30")
        XCTAssertEqual(evalString(env, "document.getElementById('leaf').offsetLeft"), "20")

        // No positioned ancestor -> body; body/html -> null.
        XCTAssertEqual(evalString(env, "document.getElementById('outer').offsetParent === document.body"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').offsetTop"), "100")
        XCTAssertEqual(evalString(env, "document.body.offsetParent"), "null")
        XCTAssertEqual(evalString(env, "document.documentElement.offsetParent"), "null")

        // Detached element: null offsetParent, zero metrics.
        XCTAssertEqual(evalString(env, "document.createElement('div').offsetParent"), "null")
        XCTAssertEqual(evalString(env, "document.createElement('div').offsetWidth"), "0")
        XCTAssertEqual(evalString(env, "JSON.stringify(document.createElement('div').getBoundingClientRect())"),
                       #"{"x":0,"y":0,"width":0,"height":0,"top":0,"right":0,"bottom":0,"left":0}"#)
    }

    @MainActor
    func testNoRectFallsBackToInlineStyleThenIncrementalSetLayoutRect() {
        let (env, ids) = makeEnvironment()
        defer { env.teardown() }

        // #late has no rect: inline width/height px are used (JSC path parity), position is 0.
        XCTAssertEqual(evalString(env, "document.getElementById('late').offsetWidth"), "120")
        XCTAssertEqual(evalString(env, "document.getElementById('late').getBoundingClientRect().height"), "30")
        XCTAssertEqual(evalString(env, "document.getElementById('late').offsetTop"), "0")

        // Incremental update for a single node.
        env.setLayoutRect(CGRect(x: 0, y: 600, width: 50, height: 60), for: ids["late"]!)
        XCTAssertEqual(evalString(env, "document.getElementById('late').offsetWidth"), "50")
        XCTAssertEqual(evalString(env, "document.getElementById('late').offsetHeight"), "60")
        XCTAssertEqual(evalString(env, "document.getElementById('late').offsetTop"), "600")
        // The document element's scroll extent is recomputed after the change (cache invalidated).
        XCTAssertEqual(evalString(env, "document.documentElement.scrollHeight"), "2000")
        env.setLayoutRect(CGRect(x: 0, y: 2500, width: 50, height: 60), for: ids["late"]!)
        XCTAssertEqual(evalString(env, "document.documentElement.scrollHeight"), "2560")
    }

    @MainActor
    func testScrollTopLeftStoredPerNodeAndNotifies() {
        let (env, ids) = makeEnvironment()
        defer { env.teardown() }

        var mutated: Set<UUID> = []
        let notified = expectation(description: "mutation callback")
        notified.assertForOverFulfill = false
        env.onDOMMutation = { changed in
            mutated.formUnion(changed)
            notified.fulfill()
        }
        var scrollEvents: [(UUID?, CGPoint)] = []
        env.onScrollChange = { node, pos in scrollEvents.append((node?.id, pos)) }

        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollTop"), "0")
        _ = evalString(env, "document.getElementById('inner').scrollTop = 40; document.getElementById('inner').scrollLeft = 7;")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollTop"), "40")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollLeft"), "7")
        // Other nodes are unaffected.
        XCTAssertEqual(evalString(env, "document.getElementById('outer').scrollTop"), "0")

        wait(for: [notified], timeout: 2)
        XCTAssertTrue(mutated.contains(ids["inner"]!), "scrollTop setter should notify via the mutation callback")
        XCTAssertEqual(scrollEvents.last?.0, ids["inner"]!)
        XCTAssertEqual(scrollEvents.last?.1, CGPoint(x: 7, y: 40))

        // element.scrollTo / scrollBy
        _ = evalString(env, "document.getElementById('inner').scrollTo({ top: 100, left: 5 })")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollTop"), "100")
        _ = evalString(env, "document.getElementById('inner').scrollBy(0, 25)")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollTop"), "125")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollLeft"), "5")

        // Negative values clamp to 0 like a real scroller.
        _ = evalString(env, "document.getElementById('inner').scrollTop = -10")
        XCTAssertEqual(evalString(env, "document.getElementById('inner').scrollTop"), "0")
    }

    @MainActor
    func testWindowScrollAndDocumentElementScrollTopShareScrollOffset() {
        let (env, _) = makeEnvironment()
        defer { env.teardown() }

        XCTAssertEqual(evalString(env, "[window.scrollX, window.scrollY, window.pageXOffset, window.pageYOffset].join(',')"), "0,0,0,0")

        env.scrollOffset = CGPoint(x: 3, y: 120)
        XCTAssertEqual(evalString(env, "window.scrollY"), "120")
        XCTAssertEqual(evalString(env, "window.pageYOffset"), "120")
        XCTAssertEqual(evalString(env, "window.scrollX"), "3")
        XCTAssertEqual(evalString(env, "document.documentElement.scrollTop"), "120")
        XCTAssertEqual(evalString(env, "document.scrollingElement.scrollLeft"), "3")

        // JS writes flow back to the bridge (the host polyfill's scrollTo assigns window.scrollY).
        _ = evalString(env, "window.scrollY = 75; window.scrollX = 0;")
        XCTAssertEqual(env.scrollOffset, CGPoint(x: 0, y: 75))
        _ = evalString(env, "document.documentElement.scrollTop = 200")
        XCTAssertEqual(env.scrollOffset, CGPoint(x: 0, y: 200))
        XCTAssertEqual(evalString(env, "window.scrollY"), "200")
        // and getBoundingClientRect() follows.
        XCTAssertEqual(evalString(env, "document.getElementById('outer').getBoundingClientRect().top"), "-100")
    }

    @MainActor
    func testScrollIntoViewRecordsRequest() {
        let (env, ids) = makeEnvironment()
        defer { env.teardown() }

        XCTAssertEqual(evalString(env, "typeof document.getElementById('leaf').scrollIntoView"), "function")
        XCTAssertEqual(evalString(env, "document.getElementById('leaf').scrollIntoView({ block: 'start' })"), "undefined")
        _ = evalString(env, "document.getElementById('outer').scrollIntoView(true)")
        XCTAssertEqual(env.drainScrollIntoViewRequests(), [ids["leaf"]!, ids["outer"]!])
        XCTAssertEqual(env.drainScrollIntoViewRequests(), [])
    }

    @MainActor
    func testGeometryAccessorsLiveOnThePrototype() {
        let (env, _) = makeEnvironment()
        defer { env.teardown() }

        // Accessors are inherited (non-own) so `'offsetWidth' in el` is true and
        // per-element objects do not carry copies.
        XCTAssertEqual(evalString(env, "'offsetWidth' in document.getElementById('outer')"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('outer').hasOwnProperty('offsetWidth')"), "false")
        XCTAssertEqual(evalString(env, "'offsetParent' in document.getElementById('outer')"), "true")
        XCTAssertEqual(evalString(env, "typeof document.getElementById('outer').getClientRects"), "function")
    }
}
