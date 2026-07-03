import XCTest
@testable import AutoCore

final class ViewFingerprintTests: XCTestCase {

    func testEqualFingerprintsAreEqual() {
        let a = ViewFingerprint(rootChildCount: 3, topLevelSignature: "AXWindow::0,0,400,800")
        let b = ViewFingerprint(rootChildCount: 3, topLevelSignature: "AXWindow::0,0,400,800")
        XCTAssertEqual(a, b)
    }

    func testDifferentChildCountNotEqual() {
        let a = ViewFingerprint(rootChildCount: 3, topLevelSignature: "x")
        let b = ViewFingerprint(rootChildCount: 4, topLevelSignature: "x")
        XCTAssertNotEqual(a, b)
    }

    func testDifferentSignatureNotEqual() {
        let a = ViewFingerprint(rootChildCount: 3, topLevelSignature: "before")
        let b = ViewFingerprint(rootChildCount: 3, topLevelSignature: "after")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - capture(tree:) — fingerprint compartido sobre DeviceBridge.tree() (#159)

    private func node(role: String, title: String = "", identifier: String = "",
                      frame: (Int, Int, Int, Int)? = nil,
                      children: [[String: Any]] = []) -> [String: Any] {
        var el: [String: Any] = ["role": role, "title": title, "identifier": identifier]
        if let f = frame {
            el["frame"] = ["x": f.0, "y": f.1, "width": f.2, "height": f.3]
        }
        if !children.isEmpty { el["children"] = children }
        return el
    }

    func testCaptureTreeStableForSameTree() {
        let tree = [node(role: "AXWindow", title: "Main", frame: (0, 0, 400, 800),
                         children: [node(role: "AXButton", title: "OK")])]
        XCTAssertEqual(ViewFingerprint.capture(tree: tree),
                       ViewFingerprint.capture(tree: tree))
    }

    func testCaptureTreeDetectsTopLevelChange() {
        let before = [node(role: "AXWindow", title: "Login", frame: (0, 0, 400, 800))]
        let after = [node(role: "AXWindow", title: "Home", frame: (0, 0, 400, 800))]
        XCTAssertNotEqual(ViewFingerprint.capture(tree: before),
                          ViewFingerprint.capture(tree: after))
    }

    func testCaptureTreeDetectsChildCountChange() {
        let before = [node(role: "AXWindow"), node(role: "AXSheet")]
        let after = [node(role: "AXWindow")]
        XCTAssertNotEqual(ViewFingerprint.capture(tree: before),
                          ViewFingerprint.capture(tree: after))
    }

    func testCaptureTreeDetectsGrandchildChange() {
        let before = [node(role: "AXWindow",
                           children: [node(role: "AXGroup", identifier: "form")])]
        let after = [node(role: "AXWindow",
                          children: [node(role: "AXGroup", identifier: "keyboard")])]
        XCTAssertNotEqual(ViewFingerprint.capture(tree: before),
                          ViewFingerprint.capture(tree: after))
    }

    func testCaptureTreeIgnoresBeyondLimits() {
        // Cambios más allá de maxChildren no alteran la firma top-level,
        // pero sí el rootChildCount — el fingerprint completo cambia.
        let base = (0..<6).map { node(role: "AXGroup", identifier: "g\($0)") }
        let extended = base + [node(role: "AXGroup", identifier: "g6")]
        let fpBase = ViewFingerprint.capture(tree: base)
        let fpExt = ViewFingerprint.capture(tree: extended)
        XCTAssertEqual(fpBase.topLevelSignature, fpExt.topLevelSignature)
        XCTAssertNotEqual(fpBase, fpExt)
    }

    func testCaptureTreeAndroidRoles() {
        // Claves Android (EditText, sin identifier) también producen firmas útiles
        let before = [node(role: "android.widget.FrameLayout", title: "root",
                           children: [node(role: "android.widget.EditText", title: "Email")])]
        let after = [node(role: "android.widget.FrameLayout", title: "root",
                          children: [node(role: "android.widget.EditText", title: "Email"),
                                     node(role: "android.inputmethodservice.SoftInputWindow", title: "IME")])]
        // El nieto extra queda fuera de maxGrandchildren=1... pero el primer
        // nieto es igual: aquí lo que cambia es el children count del root, no
        // la firma → iguales. Documenta la asimetría: equal NO prueba sin cambio.
        XCTAssertEqual(ViewFingerprint.capture(tree: before),
                       ViewFingerprint.capture(tree: after))
    }

}
