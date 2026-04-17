import XCTest
import CoreGraphics
@testable import AutoCore

final class ViewportUtilTests: XCTestCase {

    // MARK: - rect(from:)

    func testRectFromIntDict() {
        let r = ViewportUtil.rect(from: ["x": 10, "y": 20, "width": 100, "height": 50])
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testRectFromDoubleDict() {
        let r = ViewportUtil.rect(from: ["x": 10.5, "y": 20.5, "width": 100.0, "height": 50.0])
        XCTAssertEqual(r, CGRect(x: 10.5, y: 20.5, width: 100.0, height: 50.0))
    }

    func testRectFromMissingKey() {
        XCTAssertNil(ViewportUtil.rect(from: ["x": 10, "y": 20, "width": 100]))
    }

    func testRectFromZeroSize() {
        XCTAssertNil(ViewportUtil.rect(from: ["x": 10, "y": 20, "width": 0, "height": 0]))
    }

    func testRectFromNil() {
        XCTAssertNil(ViewportUtil.rect(from: nil))
    }

    // MARK: - isVisible(frame:inViewport:)

    func testFullyInsideViewportIsVisible() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 50)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(ViewportUtil.isVisible(frame: frame, inViewport: viewport))
    }

    func testFullyOutsideViewportNotVisible() {
        let frame = CGRect(x: 100, y: 1000, width: 100, height: 50)  // below viewport
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertFalse(ViewportUtil.isVisible(frame: frame, inViewport: viewport))
    }

    func testPartiallyVisibleAbove50PercentIsVisible() {
        // 70% visible vertically
        let frame = CGRect(x: 0, y: 750, width: 100, height: 100)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 820)
        XCTAssertTrue(ViewportUtil.isVisible(frame: frame, inViewport: viewport))
    }

    func testPartiallyVisibleBelow50PercentNotVisible() {
        // Only 10px of 100px visible → 10%
        let frame = CGRect(x: 0, y: 790, width: 100, height: 100)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertFalse(ViewportUtil.isVisible(frame: frame, inViewport: viewport))
    }

    func testOnePixelTouchingBorderNotVisible() {
        // Frame touches bottom edge with 1px — must NOT count as visible.
        let frame = CGRect(x: 0, y: 799, width: 100, height: 100)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertFalse(ViewportUtil.isVisible(frame: frame, inViewport: viewport))
    }

    func testCustomCoverageThreshold() {
        // 30% visible, with 20% threshold → should pass
        let frame = CGRect(x: 0, y: 770, width: 100, height: 100)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(ViewportUtil.isVisible(frame: frame, inViewport: viewport, minCoverage: 0.2))
        XCTAssertFalse(ViewportUtil.isVisible(frame: frame, inViewport: viewport, minCoverage: 0.5))
    }

    // MARK: - resolveViewport(for:in:screenBounds:)

    func testResolveViewportFallsBackToScreenWhenNoScrollAncestor() {
        let target: [String: Any] = [
            "role": "Button",
            "label": "Login",
            "frame": ["x": 100, "y": 400, "width": 200, "height": 44]
        ]
        let tree: [[String: Any]] = [
            ["role": "Window", "children": [target]]
        ]
        let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
        let vp = ViewportUtil.resolveViewport(for: target, in: tree, screenBounds: screen)
        XCTAssertEqual(vp, screen)
    }

    func testResolveViewportUsesScrollAncestor() {
        let targetFrame: [String: Any] = ["x": 0, "y": 500, "width": 400, "height": 44]
        let target: [String: Any] = ["role": "Button", "label": "Logout", "frame": targetFrame]
        let scrollFrame: [String: Any] = ["x": 0, "y": 100, "width": 400, "height": 600]
        let tree: [[String: Any]] = [[
            "role": "Window",
            "children": [[
                "role": "AXScrollArea",
                "frame": scrollFrame,
                "children": [target]
            ]]
        ]]
        let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
        let vp = ViewportUtil.resolveViewport(for: target, in: tree, screenBounds: screen)
        XCTAssertEqual(vp, CGRect(x: 0, y: 100, width: 400, height: 600))
    }

    func testResolveViewportUsesNearestScrollAncestorWhenNested() {
        // outer ScrollView 0,0 400x800 ⊃ inner ScrollView 0,100 400x500 ⊃ target
        let target: [String: Any] = [
            "role": "Button",
            "label": "X",
            "frame": ["x": 0, "y": 400, "width": 400, "height": 44]
        ]
        let tree: [[String: Any]] = [[
            "role": "AXScrollArea",
            "frame": ["x": 0, "y": 0, "width": 400, "height": 800],
            "children": [[
                "role": "AXScrollArea",
                "frame": ["x": 0, "y": 100, "width": 400, "height": 500],
                "children": [target]
            ]]
        ]]
        let vp = ViewportUtil.resolveViewport(for: target, in: tree,
                                              screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        // Must return the INNER (nearest) scroll ancestor, not the outer.
        XCTAssertEqual(vp.origin.y, 100)
        XCTAssertEqual(vp.height, 500)
    }

    func testResolveViewportHandlesRecyclerView() {
        let targetFrame: [String: Any] = ["x": 0, "y": 500, "width": 1080, "height": 120]
        let target: [String: Any] = ["role": "android.widget.TextView", "label": "Logout", "frame": targetFrame]
        let scrollFrame: [String: Any] = ["x": 0, "y": 200, "width": 1080, "height": 1500]
        let tree: [[String: Any]] = [[
            "role": "android.view.ViewGroup",
            "children": [[
                "role": "androidx.recyclerview.widget.RecyclerView",
                "frame": scrollFrame,
                "children": [target]
            ]]
        ]]
        let screen = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let vp = ViewportUtil.resolveViewport(for: target, in: tree, screenBounds: screen)
        XCTAssertEqual(vp.origin.y, 200)
        XCTAssertEqual(vp.height, 1500)
    }

    // MARK: - findFirst

    func testFindFirstByLabel() {
        let btn: [String: Any] = ["role": "Button", "label": "Cerrar sesion",
                                  "frame": ["x": 10, "y": 100, "width": 200, "height": 44]]
        let tree: [[String: Any]] = [["role": "Window", "children": [btn]]]
        let found = ViewportUtil.findFirst(in: tree, matching: "Cerrar sesion")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?["label"] as? String, "Cerrar sesion")
    }

    func testFindFirstWithIndex() {
        let b1: [String: Any] = ["role": "Button", "label": "Item"]
        let b2: [String: Any] = ["role": "Button", "label": "Item"]
        let tree: [[String: Any]] = [["role": "Window", "children": [b1, b2]]]
        let found = ViewportUtil.findFirst(in: tree, matching: "Item[2]")
        XCTAssertNotNil(found)
    }

    func testFindFirstNotFound() {
        let tree: [[String: Any]] = [["role": "Window", "label": "Main"]]
        XCTAssertNil(ViewportUtil.findFirst(in: tree, matching: "DoesNotExist"))
    }
}
