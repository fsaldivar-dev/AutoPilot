import XCTest
@testable import AutoLibiOS

final class SemanticResolverTests: XCTestCase {

    // MARK: - P0 bug: value of AXTextField must not leak into selector

    func testTextFieldValueIsNotUsedAsSelector() {
        // During recording, an email field has been typed into. The tree
        // shows its `value` as "success+714497402@example.com". Before the
        // fix, chooseBestSelector emitted that whole string, producing an
        // unreproducible `waitFor "success+..."` in the script.
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXTextField",
            title: nil,
            label: nil,
            identifier: nil,
            value: "success+714497402@example.com"
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertNil(selector, "value of AXTextField must not be used as selector")
    }

    func testSecureTextFieldValueIsNotUsedAsSelector() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXSecureTextField",
            title: nil,
            label: nil,
            identifier: nil,
            value: "Passw0rd!"
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertNil(selector)
    }

    func testTextAreaValueIsNotUsedAsSelector() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXTextArea",
            title: nil,
            label: nil,
            identifier: nil,
            value: "Multi-line user content"
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertNil(selector)
    }

    // MARK: - Normal priorities still work

    func testIdentifierWinsOverEverything() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXButton",
            title: "Login",
            label: "Log in button",
            identifier: "login_button",
            value: nil
        )
        let (selector, usedId) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertEqual(selector, "login_button")
        XCTAssertTrue(usedId)
    }

    func testTitleWinsWhenNoIdentifier() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXButton",
            title: "Continue",
            label: "Continue button",
            identifier: nil,
            value: nil
        )
        let (selector, usedId) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertEqual(selector, "Continue")
        XCTAssertFalse(usedId)
    }

    func testLabelWinsWhenNoTitle() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXImage",
            title: nil,
            label: "User avatar",
            identifier: nil,
            value: nil
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertEqual(selector, "User avatar")
    }

    // MARK: - value is still usable for non-input roles

    func testValueIsUsedForSwitch() {
        // A switch's value ("1" or "0") is not user-typed content, so it's
        // safe to fall back to. Typically the label comes first anyway;
        // this only hits in oddly accessible switches.
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXCheckBox",
            title: nil,
            label: nil,
            identifier: nil,
            value: "Enabled"
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertEqual(selector, "Enabled")
    }

    func testValueLongerThan50IsRejected() {
        let attrs = SemanticResolver.ElementAttributes(
            role: "AXStaticText",
            title: nil,
            label: nil,
            identifier: nil,
            value: String(repeating: "x", count: 60)
        )
        let (selector, _) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertNil(selector)
    }

    // MARK: - No attributes at all

    func testAllNilReturnsNil() {
        let attrs = SemanticResolver.ElementAttributes(
            role: nil, title: nil, label: nil, identifier: nil, value: nil
        )
        let (selector, usedId) = SemanticResolver.chooseBestSelector(attrs)
        XCTAssertNil(selector)
        XCTAssertFalse(usedId)
    }
}
