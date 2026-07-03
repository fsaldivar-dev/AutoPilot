import XCTest
@testable import AutoCore

// MARK: - AndroidTapMockBackend
//
// Backend programable para testear AndroidTapEnhancement vía ActionRouter.
// Responde `.tree` con un árbol fijo y registra todas las acciones.
final class AndroidTapMockBackend: Backend, @unchecked Sendable {
    let capabilities: Set<ActionKind> = [.tree, .tap, .tapAtCoordinate]
    var treeNodes: [[String: Any]] = []
    var executed: [Action] = []

    func execute(_ action: Action) async throws -> ActionResult {
        executed.append(action)
        if case .tree = action { return .elements(treeNodes) }
        return .void
    }
}

/// Multi-tap por coma en la ruta Android (#145) — paridad con iOS: la coma
/// solo separa si el label completo NO existe como elemento del árbol
/// (misma regla de `TapTargets` que consume `iOSTapEnhancement` tras #144).
final class AndroidTapEnhancementTests: XCTestCase {

    private var backend: AndroidTapMockBackend!

    override func setUp() {
        super.setUp()
        backend = AndroidTapMockBackend()
    }

    private func run(_ args: [String]) async throws {
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        try await AndroidTapEnhancement.execute(args: args, router: router, start: CFAbsoluteTimeGetCurrent())
    }

    private var tappedTargets: [String] {
        backend.executed.compactMap {
            if case .tap(let target) = $0 { return target }
            return nil
        }
    }

    /// `tap 1,2,3,4` sin match del label completo → un tap por fragmento.
    /// Antes de #145 Android hacía UN solo tap fallido con "1,2,3,4".
    func testMultiTapSplitsWhenNoFullLabelMatch() async throws {
        backend.treeNodes = [["label": "1"], ["label": "2"], ["label": "3"], ["label": "4"]]
        try await run(["tap", "1,2,3,4"])
        XCTAssertEqual(tappedTargets, ["1", "2", "3", "4"])
    }

    /// Label con coma que SÍ existe como elemento → un solo tap con el label
    /// completo (celdas con "título, valor").
    func testFullLabelWithCommaDoesNotSplit() async throws {
        backend.treeNodes = [["label": "Nombre, iPhone"]]
        try await run(["tap", "Nombre, iPhone"])
        XCTAssertEqual(tappedTargets, ["Nombre, iPhone"])
    }

    /// Un `value` que muestra el string con comas NO desactiva el multi-tap —
    /// el match exacto ignora `value` (escenario PIN sobre keypad).
    func testValueMatchDoesNotSuppressMultiTap() async throws {
        backend.treeNodes = [["role": "EditText", "value": "1,2,3,4"]]
        try await run(["tap", "1,2,3,4"])
        XCTAssertEqual(tappedTargets, ["1", "2", "3", "4"])
    }

    /// Fragmentos con frame tapean por coordenada (centro del frame), igual
    /// que el tap de label único de siempre.
    func testMultiTapFragmentsUseCoordinateWhenFrameAvailable() async throws {
        backend.treeNodes = [
            ["label": "a", "frame": ["x": 0, "y": 0, "width": 100, "height": 100] as [String: Any]],
            ["label": "b", "frame": ["x": 100, "y": 0, "width": 100, "height": 100] as [String: Any]],
        ]
        try await run(["tap", "a,b"])
        let coords = backend.executed.compactMap { action -> (Double, Double)? in
            if case .tapAtCoordinate(let x, let y) = action { return (x, y) }
            return nil
        }
        XCTAssertEqual(coords.count, 2)
        XCTAssertEqual(coords[0].0, 50); XCTAssertEqual(coords[0].1, 50)
        XCTAssertEqual(coords[1].0, 150); XCTAssertEqual(coords[1].1, 50)
    }

    /// Target sin coma no consulta el árbol para resolver (TapTargets solo
    /// mira el árbol si hay coma) y hace un único tap.
    func testSingleLabelWithoutCommaStillSingleTap() async throws {
        backend.treeNodes = [["label": "Guardar"]]
        try await run(["tap", "Guardar"])
        XCTAssertEqual(tappedTargets, ["Guardar"])
    }
}
