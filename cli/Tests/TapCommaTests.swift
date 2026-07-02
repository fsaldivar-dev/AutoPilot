import XCTest
@testable import AutoCore

/// Tests de resolución de targets en `tap` (#124) — helper TapTargets.
///
/// Labels estándar de celdas iOS contienen comas ("Nombre, iPhone" = título +
/// valor del AX label). La coma solo actúa como separador multi-tap si el
/// target completo NO existe como elemento (match EXACTO sobre
/// title/label/identifier/id del árbol rápido — nunca sobre `value`).
final class TapCommaTests: XCTestCase {

    var bridge: MockBridge!

    override func setUp() {
        bridge = MockBridge()
    }

    // MARK: - Dispatcher (executeSharedCommand)

    /// Label con coma que SÍ existe como elemento → un solo tap con el label completo.
    func testTapCommaLabelExistingElement() throws {
        bridge.treeNodes = [["label": "Nombre, iPhone", "role": "AXButton"]]
        let handled = try executeSharedCommand(["tap", "Nombre, iPhone"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("tap"), 1)
        XCTAssertEqual(bridge.lastCall()?.args, ["Nombre, iPhone"])
    }

    /// Multi-tap clásico: sin match del label completo → un tap por fragmento (trimmed).
    func testTapCommaMultiTapWhenNoFullMatch() throws {
        bridge.treeNodes = [["label": "1"], ["label": "2"], ["label": "3"], ["label": "4"]]
        let handled = try executeSharedCommand(["tap", "1,2,3,4"], bridge: bridge)
        XCTAssertTrue(handled)
        let tapped = bridge.calls.filter { $0.method == "tap" }.map { $0.args[0] }
        XCTAssertEqual(tapped, ["1", "2", "3", "4"])
    }

    /// Un textfield cuyo VALUE muestra el string con comas NO desactiva el
    /// multi-tap — el match exacto ignora `value` (escenario PIN: type 1,2,3,4
    /// seguido de tap 1,2,3,4 sobre el keypad).
    func testTapCommaValueMatchDoesNotSuppressMultiTap() throws {
        bridge.treeNodes = [["role": "AXTextField", "value": "1,2,3,4"]]
        _ = try executeSharedCommand(["tap", "1,2,3,4"], bridge: bridge)
        let tapped = bridge.calls.filter { $0.method == "tap" }.map { $0.args[0] }
        XCTAssertEqual(tapped, ["1", "2", "3", "4"])
    }

    /// Target sin coma: ni siquiera consulta el árbol, tap directo.
    func testTapSimpleNoCommaSkipsTree() throws {
        let handled = try executeSharedCommand(["tap", "Guardar"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("tree"), 0)
        XCTAssertEqual(bridge.lastCall()?.args, ["Guardar"])
    }

    /// Errores del bridge se PROPAGAN — un fallo transitorio no debe degradar
    /// en silencio a multi-tap sobre fragmentos.
    func testTapCommaTreeErrorPropagates() throws {
        bridge.treeError = BridgeError.adbFailed("agent reconnecting")
        XCTAssertThrowsError(try executeSharedCommand(["tap", "Nombre, iPhone"], bridge: bridge))
        XCTAssertEqual(bridge.callCount("tap"), 0)
    }

    /// Fragmentos con espacios tras la coma quedan trimmed ("a, b" → "a","b").
    func testTapCommaFragmentsTrimmed() throws {
        _ = try executeSharedCommand(["tap", "a, b"], bridge: bridge)
        let tapped = bridge.calls.filter { $0.method == "tap" }.map { $0.args[0] }
        XCTAssertEqual(tapped, ["a", "b"])
    }

    // MARK: - TapTargets directo

    /// Match exacto en nodos anidados (children).
    func testHasExactMatchNested() {
        let tree: [[String: Any]] = [
            ["role": "AXGroup", "children": [
                ["title": "Nombre, iPhone", "role": "AXCell"] as [String: Any]
            ]]
        ]
        XCTAssertTrue(TapTargets.hasExactMatch("Nombre, iPhone", in: tree))
        XCTAssertTrue(TapTargets.hasExactMatch("nombre, iphone", in: tree)) // case-insensitive
        XCTAssertFalse(TapTargets.hasExactMatch("Nombre", in: tree))       // exacto, no prefix
    }

    /// El match parcial (substring) NO cuenta — solo igualdad exacta.
    func testHasExactMatchRejectsSubstrings() {
        let tree: [[String: Any]] = [["title": "v1,2,3 release notes"]]
        XCTAssertFalse(TapTargets.hasExactMatch("1,2", in: tree))
    }

    /// Labels con coma decimal ("1,5 km") se respetan si existen como elemento.
    func testDecimalCommaLabelExisting() throws {
        bridge.treeNodes = [["title": "1,5 km"]]
        _ = try executeSharedCommand(["tap", "1,5 km"], bridge: bridge)
        XCTAssertEqual(bridge.callCount("tap"), 1)
        XCTAssertEqual(bridge.lastCall()?.args, ["1,5 km"])
    }
}
