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

    // MARK: - Usable viewport (issue #153)

    /// iPhone 17 portrait: 402x874pt. Zona útil default (90% central):
    /// y ∈ [43.7, 830.3].
    private let iphone17 = CGRect(x: 0, y: 0, width: 402, height: 874)

    func testUsableViewportIsCentralBand() {
        let usable = ViewportUtil.usableViewport(iphone17)
        XCTAssertEqual(usable.minY, 874 * 0.05, accuracy: 0.01)
        XCTAssertEqual(usable.maxY, 874 * 0.95, accuracy: 0.01)
        XCTAssertEqual(usable.width, 402)
    }

    func testElementInCenterIsInUsableViewport() {
        // Elemento plenamente visible en el centro de la pantalla.
        let frame = CGRect(x: 20, y: 400, width: 200, height: 44)
        XCTAssertTrue(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17))
    }

    func testElementUnderTabBarIsNotInUsableViewport() {
        // El caso EXACTO del bug #153: frame y=829 en pantalla de 874pt.
        // 100% dentro de los screen bounds crudos (la mentira-en-verde) pero
        // bajo el tab bar → NO está en el viewport útil.
        let frame = CGRect(x: 20, y: 829, width: 200, height: 44)
        XCTAssertTrue(ViewportUtil.isVisible(frame: frame, inViewport: iphone17),
                      "el criterio crudo lo daba por visible (así mentía)")
        XCTAssertFalse(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17),
                       "el criterio útil debe rechazarlo")
    }

    func testElementPartiallyCutMajorityVisiblePasses() {
        // Parcialmente cortado por la franja inferior pero con >50% del área
        // dentro de la zona útil (y ∈ [43.7, 830.3]): 786..830.3 = 44.3 de 60.
        let frame = CGRect(x: 20, y: 786, width: 200, height: 60)
        XCTAssertTrue(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17))
    }

    func testElementPartiallyCutMajorityHiddenFails() {
        // Mayoría del área fuera de la zona útil: 810..830.3 = 20.3 de 60 (34%).
        let frame = CGRect(x: 20, y: 810, width: 200, height: 60)
        XCTAssertFalse(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17))
    }

    func testElementUnderDetectedTabBarFails() {
        // Tab bar real detectado en el tree (y=791, alto 83): la oclusión
        // sube el límite útil a 791 aunque la franja default llegue a 830.3.
        let tabBar = CGRect(x: 0, y: 791, width: 402, height: 83)
        // Elemento en 770..830: con solo la franja default (límite 830.3)
        // está ~100% dentro; con el tab bar detectado el límite baja a 791
        // → solo 770..791 = 21 de 60 (35%) dentro → falla.
        let frame = CGRect(x: 20, y: 770, width: 200, height: 60)
        XCTAssertTrue(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17))
        XCTAssertFalse(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17,
                                                       occlusions: [tabBar]))
    }

    func testTopNavBarOcclusionRaisesUpperBound() {
        let navBar = CGRect(x: 0, y: 0, width: 402, height: 96)
        // Elemento en 50..94: dentro de la franja default (43.7+) pero bajo
        // el nav bar detectado → falla con oclusión.
        let frame = CGRect(x: 20, y: 50, width: 200, height: 44)
        XCTAssertTrue(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17))
        XCTAssertFalse(ViewportUtil.isInUsableViewport(frame: frame, viewport: iphone17,
                                                       occlusions: [navBar]))
    }

    func testUsableViewportDegeneratesToEmptyWhenBarsCoverEverything() {
        let giant = CGRect(x: 0, y: 400, width: 402, height: 200)
        let topGiant = CGRect(x: 0, y: 0, width: 402, height: 420)
        let usable = ViewportUtil.usableViewport(iphone17, occlusions: [giant, topGiant])
        XCTAssertEqual(usable.height, 0)
        XCTAssertFalse(ViewportUtil.isInUsableViewport(
            frame: CGRect(x: 0, y: 500, width: 100, height: 44),
            viewport: iphone17, occlusions: [giant, topGiant]))
    }

    // MARK: - occludingBars(in:screen:)

    func testOccludingBarsDetectsObserverTabGroup() {
        // Observer iOS serializa UITabBar como AXTabGroup.
        let tree: [[String: Any]] = [[
            "role": "AXWindow",
            "children": [
                ["role": "AXTabGroup",
                 "frame": ["x": 0, "y": 791, "width": 402, "height": 83]],
                ["role": "AXScrollArea",
                 "frame": ["x": 0, "y": 0, "width": 402, "height": 874]]
            ]
        ]]
        let bars = ViewportUtil.occludingBars(in: tree, screen: iphone17)
        XCTAssertEqual(bars, [CGRect(x: 0, y: 791, width: 402, height: 83)])
    }

    func testOccludingBarsDetectsXCUIRunnerRoles() {
        // XCUI runner serializa TabBar / NavigationBar sin prefijo AX.
        let tree: [[String: Any]] = [
            ["role": "NavigationBar",
             "frame": ["x": 0, "y": 0, "width": 402, "height": 96]],
            ["role": "TabBar",
             "frame": ["x": 0, "y": 791, "width": 402, "height": 83]]
        ]
        let bars = ViewportUtil.occludingBars(in: tree, screen: iphone17)
        XCTAssertEqual(bars.count, 2)
    }

    func testOccludingBarsIgnoresTallPanels() {
        // Un "toolbar" de media pantalla no es una barra — no debe ocluir.
        let tree: [[String: Any]] = [
            ["role": "Toolbar",
             "frame": ["x": 0, "y": 400, "width": 402, "height": 474]]
        ]
        XCTAssertTrue(ViewportUtil.occludingBars(in: tree, screen: iphone17).isEmpty)
    }

    func testOccludingBarsIgnoresNarrowElements() {
        // Un elemento angosto (menos de media pantalla de ancho) no es barra.
        let tree: [[String: Any]] = [
            ["role": "TabBar",
             "frame": ["x": 0, "y": 791, "width": 100, "height": 83]]
        ]
        XCTAssertTrue(ViewportUtil.occludingBars(in: tree, screen: iphone17).isEmpty)
    }

    // MARK: - isBarDescendant(frame:in:)

    func testTabButtonInsideTabBarIsBarDescendant() {
        let tabButton: [String: Any] = [
            "role": "AXButton", "label": "Favoritos",
            "frame": ["x": 201, "y": 795, "width": 100, "height": 48]
        ]
        let tree: [[String: Any]] = [[
            "role": "AXTabGroup",
            "frame": ["x": 0, "y": 791, "width": 402, "height": 83],
            "children": [tabButton]
        ]]
        XCTAssertTrue(ViewportUtil.isBarDescendant(
            frame: CGRect(x: 201, y: 795, width: 100, height: 48), in: tree))
    }

    func testScrollContentUnderTabBarIsNotBarDescendant() {
        // Contenido scrolleado que CAE geométricamente bajo el tab bar pero
        // vive en el scroll view — no es chrome, sí puede estar ocluido.
        let tree: [[String: Any]] = [[
            "role": "AXScrollArea",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            "children": [[
                "role": "AXButton", "label": "Agregar a favoritos",
                "frame": ["x": 20, "y": 829, "width": 200, "height": 44]
            ]]
        ]]
        XCTAssertFalse(ViewportUtil.isBarDescendant(
            frame: CGRect(x: 20, y: 829, width: 200, height: 44), in: tree))
    }

    // MARK: - swipeGesture(forSearchDirection:)

    func testSearchDirectionInvertsToGesture() {
        // Buscar hacia ABAJO del documento = dedo hacia ARRIBA (y viceversa).
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "down"), "up")
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "up"), "down")
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "left"), "right")
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "right"), "left")
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "DOWN"), "up")
        XCTAssertEqual(ViewportUtil.swipeGesture(forSearchDirection: "bogus"), "up")
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
