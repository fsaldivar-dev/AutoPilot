import XCTest
@testable import AutoCore

// #195 — variables de script: $nombre = valor + sustitución.
final class VarTableTests: XCTestCase {

    func testBindingParseAndSubstitute() {
        let t = VarTable()
        XCTAssertEqual(t.consumeBinding("$ocr = images/ocr-test.png"), "$ocr = images/ocr-test.png")
        XCTAssertEqual(t.substitute("camera feed $ocr"), "camera feed images/ocr-test.png")
    }

    func testNonBindingLinesReturnNil() {
        let t = VarTable()
        XCTAssertNil(t.consumeBinding("tap \"Login\""))
        XCTAssertNil(t.consumeBinding("$0 = no es nombre válido"))
        XCTAssertNil(t.consumeBinding("$ocr ="))
    }

    func testElementIndexUntouched() {
        let t = VarTable()
        t.consumeBinding("$img = foto.jpg")
        // $0/$12 son element index — nunca se sustituyen.
        XCTAssertEqual(t.substitute("tap $0"), "tap $0")
        XCTAssertEqual(t.substitute("tap $12"), "tap $12")
    }

    func testUndefinedVarsLeftIntact() {
        let t = VarTable()
        t.consumeBinding("$a = 1")
        XCTAssertEqual(t.substitute("type $USER.email"), "type $USER.email")
    }

    func testRedefinitionLastWins() {
        let t = VarTable()
        t.consumeBinding("$img = a.png")
        t.consumeBinding("$img = b.png")
        XCTAssertEqual(t.substitute("inject $img"), "inject b.png")
    }

    func testPreprocessRemovesBindingsAndSubstitutes() {
        let script = """
        # camera flow
        $ocr = images/ocr-test.png

        launch
        camera feed $ocr
        tap "Capturar Foto"
        """
        let out = VarTable.preprocess(script)
        XCTAssertFalse(out.contains("$ocr ="))
        XCTAssertTrue(out.contains("camera feed images/ocr-test.png"))
        XCTAssertTrue(out.contains("# camera flow"))
        XCTAssertTrue(out.contains("tap \"Capturar Foto\""))
    }

    func testPreprocessSequentialRedefinition() {
        let script = """
        $img = a.png
        inject $img
        $img = b.png
        inject $img
        """
        let lines = VarTable.preprocess(script).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["inject a.png", "inject b.png"])
    }
}
