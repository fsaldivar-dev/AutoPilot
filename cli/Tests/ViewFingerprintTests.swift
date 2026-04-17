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

}
