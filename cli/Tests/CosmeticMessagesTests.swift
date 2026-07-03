import XCTest
@testable import AutoCore

/// Tests del lote cosmético #162 — solo la parte pura (formateo de mensajes).
final class CosmeticMessagesTests: XCTestCase {

    // MARK: - Item 1: errores del agente ya no dicen "ADB failed:"

    func testAgentFailedDescriptionUsesAgentPrefix() {
        let err = BridgeError.agentFailed("Cannot connect to agent at 127.0.0.1:9008. Is the agent running?")
        XCTAssertTrue(err.description.hasPrefix("Agent error: "))
        XCTAssertFalse(err.description.contains("ADB failed"))
    }

    // MARK: - Item 2: desanidar "element not found" ya formateado

    func testUnwrapElementNotFoundRunnerFormat() {
        // Formato del runner XCUI iOS: "element not found: X"
        let err = BridgeError.unwrapElementNotFound("element not found: Guardar")
        guard case .elementNotFound(let target)? = err else {
            return XCTFail("Expected elementNotFound, got \(String(describing: err))")
        }
        XCTAssertEqual(target, "Guardar")
    }

    func testUnwrapElementNotFoundAgentFormat() {
        // Formato del agente Android: "Element not found: 'X'"
        let err = BridgeError.unwrapElementNotFound("Element not found: 'Login'")
        guard case .elementNotFound(let target)? = err else {
            return XCTFail("Expected elementNotFound, got \(String(describing: err))")
        }
        XCTAssertEqual(target, "Login")
    }

    func testUnwrapElementNotFoundIgnoresOtherMessages() {
        XCTAssertNil(BridgeError.unwrapElementNotFound("tap failed: gesture rejected"))
        XCTAssertNil(BridgeError.unwrapElementNotFound(""))
    }

    func testElementNotFoundDescriptionDoesNotDuplicatePrefix() {
        // Antes: Error: Element not found: 'element not found: X' (#162)
        let err = BridgeError.unwrapElementNotFound("element not found: Cancelar")!
        let occurrences = err.description
            .lowercased()
            .components(separatedBy: "element not found")
            .count - 1
        XCTAssertEqual(occurrences, 1, "El prefijo debe aparecer exactamente una vez:\n\(err.description)")
    }

    // MARK: - Item 3: header de grabaciones con el binario correcto

    func testScriptGeneratorHeaderDefaultsToAuto() {
        let script = ScriptGenerator().render()
        XCTAssertTrue(script.contains("# Run with: auto run <this-file>"))
    }

    func testScriptGeneratorHeaderAndroid() {
        let script = ScriptGenerator(binaryName: "auto-android").render()
        XCTAssertTrue(script.contains("# Run with: auto-android run <this-file>"))
        XCTAssertFalse(script.contains("# Run with: auto run"))
    }

    // MARK: - Item 7: tip de exploración en elementNotFound

    func testElementNotFoundIncludesExplorationTip() {
        let saved = BridgeError.binaryName
        defer { BridgeError.binaryName = saved }

        BridgeError.binaryName = "auto"
        let ios = BridgeError.elementNotFound("Guardar").description
        XCTAssertTrue(ios.contains("Element not found: 'Guardar'"))
        XCTAssertTrue(ios.contains("Tip: explora la pantalla con `auto layout` o `auto tree -s"))

        BridgeError.binaryName = "auto-android"
        let android = BridgeError.elementNotFound("Guardar").description
        XCTAssertTrue(android.contains("`auto-android layout`"))
        XCTAssertTrue(android.contains("`auto-android tree -s"))
    }
}
