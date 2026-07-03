import XCTest
@testable import AutoCore

// Tests del evaluator del AST. Usa `MockBackend` (definido en ActionRouterTests)
// como backend raíz del `ActionRouter`. El interpreter consume el router
// estándar — predicados se evalúan vía Actions-predicado de Fase 1.
//
// El interpreter NO ejecuta directamente comandos CLI como strings — eso
// pertenece al CLI main.swift (integración). Acá testeamos la semántica pura
// del AST: control flow, predicates, assert, try/catch.

// MARK: - InterpreterMockBackend
//
// Backend programable que acepta cualquier ActionKind y registra todas las
// acciones recibidas. Se usa para verificar que el interpreter traduce
// correctamente AST → Actions.
final class InterpreterMockBackend: Backend, @unchecked Sendable {
    let capabilities: Set<ActionKind> = Set(ActionKind.allCases)
    var executed: [Action] = []

    // Sequencial de resultados para `.bool` predicates (consume uno por call).
    var boolResults: [Bool] = []
    // Árbol que devuelve `.tree` (para la resolución multi-tap de #145).
    var treeNodes: [[String: Any]] = []
    // Resultados para Actions que no son predicado.
    var defaultResult: ActionResult = .void
    // Si es no nil, la próxima ejecución de una Action con ese ActionKind throws.
    var throwKinds: Set<ActionKind> = []
    // Kinds que fallan con connectionFailed (#154) — simula observer muerto.
    var connectionFailKinds: Set<ActionKind> = []

    func execute(_ action: Action) async throws -> ActionResult {
        executed.append(action)
        if throwKinds.contains(action.kind) {
            throw BridgeError.elementNotFound("mock throw")
        }
        if connectionFailKinds.contains(action.kind) {
            throw BridgeError.connectionFailed("Cannot connect to observer (mock)")
        }
        switch action.kind {
        case .exists, .isVisible, .hasText:
            let value = boolResults.isEmpty ? false : boolResults.removeFirst()
            return .bool(value)
        case .getPlatform:
            return .text("ios")
        case .getOrientation:
            return .text("portrait")
        case .tree:
            return .elements(treeNodes)
        default:
            return defaultResult
        }
    }
}

final class ScriptInterpreterTests: XCTestCase {

    private func makeInterpreter(_ backend: InterpreterMockBackend) async -> ScriptInterpreter {
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        return ScriptInterpreter(router: router)
    }

    // MARK: - Actions primitivas

    func testExecutesSimpleTap() async throws {
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend)
        let stmts = try parseStatements(#"tap "Login""#)

        try await interp.run(stmts)

        XCTAssertEqual(backend.executed.count, 1)
        if case .tap(let target) = backend.executed[0] {
            XCTAssertEqual(target, "Login")
        } else {
            XCTFail("Expected .tap")
        }
    }

    // MARK: - Multi-tap por coma en modo router directo (#145)

    /// `tap "1,2,3,4"` sin match del label completo → cuatro `.tap`, uno por
    /// fragmento. Antes de #145 el modo router directo mandaba un único
    /// `.tap(target: "1,2,3,4")` sin split ni pre-check.
    func testTapCommaSplitsInDirectRouterMode() async throws {
        let backend = InterpreterMockBackend()
        backend.treeNodes = [["label": "1"], ["label": "2"]]
        let interp = await makeInterpreter(backend)

        try await interp.run(try parseStatements(#"tap "1,2,3,4""#))

        let taps = backend.executed.compactMap { action -> String? in
            if case .tap(let target) = action { return target }
            return nil
        }
        XCTAssertEqual(taps, ["1", "2", "3", "4"])
        // Consultó el árbol para el pre-check del label completo.
        XCTAssertTrue(backend.executed.contains { $0.kind == .tree })
    }

    /// Label con coma que SÍ existe como elemento → un solo `.tap` con el
    /// label completo (misma regla que iOS/Android via TapTargets).
    func testTapCommaFullLabelDoesNotSplit() async throws {
        let backend = InterpreterMockBackend()
        backend.treeNodes = [["label": "Nombre, iPhone"]]
        let interp = await makeInterpreter(backend)

        try await interp.run(try parseStatements(#"tap "Nombre, iPhone""#))

        let taps = backend.executed.compactMap { action -> String? in
            if case .tap(let target) = action { return target }
            return nil
        }
        XCTAssertEqual(taps, ["Nombre, iPhone"])
    }

    /// Target sin coma: ni consulta el árbol ni cambia el comportamiento previo.
    func testTapWithoutCommaSkipsTree() async throws {
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend)

        try await interp.run(try parseStatements(#"tap "Login""#))

        XCTAssertFalse(backend.executed.contains { $0.kind == .tree })
        XCTAssertEqual(backend.executed.count, 1)
    }

    // MARK: - if / else

    func testIfBranch_executesThenWhenTrue() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [true]  // exists → true
        let interp = await makeInterpreter(backend)

        let script = """
        if exists "Login"
            tap "Login"
        else
            tap "Register"
        end
        """
        try await interp.run(try parseStatements(script))

        // Must execute: exists, then tap "Login" (NOT tap "Register")
        XCTAssertEqual(backend.executed.count, 2)
        XCTAssertEqual(backend.executed[0].kind, .exists)
        if case .tap(let target) = backend.executed[1] {
            XCTAssertEqual(target, "Login")
        } else { XCTFail() }
    }

    func testIfBranch_executesElseWhenFalse() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]
        let interp = await makeInterpreter(backend)

        let script = """
        if exists "Login"
            tap "Login"
        else
            tap "Register"
        end
        """
        try await interp.run(try parseStatements(script))

        XCTAssertEqual(backend.executed.count, 2)
        if case .tap(let target) = backend.executed[1] {
            XCTAssertEqual(target, "Register")
        } else { XCTFail() }
    }

    func testIfNoElse_skipsWhenFalse() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]
        let interp = await makeInterpreter(backend)

        let script = """
        if exists "Ad"
            tap "Close"
        end
        """
        try await interp.run(try parseStatements(script))

        XCTAssertEqual(backend.executed.count, 1)  // just the predicate
    }

    // MARK: - Predicate composition

    func testAndPredicate_evaluatesBoth() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [true, true]  // exists A, visible B
        let interp = await makeInterpreter(backend)

        let script = """
        if exists "A" and visible "B"
            tap "Yes"
        end
        """
        try await interp.run(try parseStatements(script))

        XCTAssertEqual(backend.executed.count, 3)
        XCTAssertEqual(backend.executed[0].kind, .exists)
        XCTAssertEqual(backend.executed[1].kind, .isVisible)
        XCTAssertEqual(backend.executed[2].kind, .tap)
    }

    func testAndPredicate_shortCircuitsOnFalse() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]  // only first consumed
        let interp = await makeInterpreter(backend)

        let script = """
        if exists "A" and visible "B"
            tap "Yes"
        end
        """
        try await interp.run(try parseStatements(script))

        // Only first predicate runs; second never evaluated; tap skipped
        XCTAssertEqual(backend.executed.count, 1)
        XCTAssertEqual(backend.executed[0].kind, .exists)
    }

    func testNotPredicate_invertsBool() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]  // not false → true
        let interp = await makeInterpreter(backend)

        let script = """
        if not exists "Error"
            tap "Continue"
        end
        """
        try await interp.run(try parseStatements(script))

        XCTAssertEqual(backend.executed.count, 2)
        XCTAssertEqual(backend.executed[1].kind, .tap)
    }

    // MARK: - repeat

    func testRepeatTimes_iteratesN() async throws {
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend)

        let script = """
        repeat 3 times
            tap "Next"
        end
        """
        try await interp.run(try parseStatements(script))

        let taps = backend.executed.filter { if case .tap = $0 { return true }; return false }
        XCTAssertEqual(taps.count, 3)
    }

    func testRepeatWhile_loopsUntilPredicateFalse() async throws {
        let backend = InterpreterMockBackend()
        // visible "X" true, true, false
        backend.boolResults = [true, true, false]
        let interp = await makeInterpreter(backend)

        let script = """
        repeat while visible "X"
            tap "Y"
        end
        """
        try await interp.run(try parseStatements(script))

        // Predicate ran 3 times, tap ran 2 times
        let visibleCalls = backend.executed.filter { if case .isVisible = $0 { return true }; return false }
        let tapCalls = backend.executed.filter { if case .tap = $0 { return true }; return false }
        XCTAssertEqual(visibleCalls.count, 3)
        XCTAssertEqual(tapCalls.count, 2)
    }

    func testRepeatUntil_loopsUntilPredicateTrue() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false, false, true]  // until true
        let interp = await makeInterpreter(backend)

        let script = """
        repeat until exists "Done"
            tap "Continue"
        end
        """
        try await interp.run(try parseStatements(script))

        let existsCalls = backend.executed.filter { if case .exists = $0 { return true }; return false }
        let tapCalls = backend.executed.filter { if case .tap = $0 { return true }; return false }
        XCTAssertEqual(existsCalls.count, 3)
        XCTAssertEqual(tapCalls.count, 2)
    }

    // MARK: - try / catch

    func testTryCatch_recoversFromError() async throws {
        let backend = InterpreterMockBackend()
        backend.throwKinds = [.tap]  // tap throws
        let interp = await makeInterpreter(backend)

        let script = """
        try
            tap "Fail"
        catch
            screenshot error.png
        end
        """
        try await interp.run(try parseStatements(script))

        // Both tap (failed) and screenshot (catch body) got executed
        XCTAssertEqual(backend.executed.count, 2)
        XCTAssertEqual(backend.executed[0].kind, .tap)
        XCTAssertEqual(backend.executed[1].kind, .screenshot)
    }

    func testTryWithoutCatch_swallowsError() async throws {
        let backend = InterpreterMockBackend()
        backend.throwKinds = [.tap]  // tap siempre throws; screenshot NO.
        let interp = await makeInterpreter(backend)

        let script = """
        try
            tap "Fail"
        end
        screenshot after.png
        """
        try await interp.run(try parseStatements(script))

        // Tap(Fail) tiró pero se tragó en el catch vacío; screenshot corre.
        XCTAssertEqual(backend.executed.count, 2)
        XCTAssertEqual(backend.executed[0].kind, .tap)
        XCTAssertEqual(backend.executed[1].kind, .screenshot)
    }

    // MARK: - assert

    func testAssert_passesWhenTrue() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [true]
        let interp = await makeInterpreter(backend)

        try await interp.run(try parseStatements(#"assert exists "Home""#))
        XCTAssertEqual(backend.executed.count, 1)
    }

    func testAssert_throwsWhenFalse() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]
        let interp = await makeInterpreter(backend)

        do {
            try await interp.run(try parseStatements(#"assert exists "Gone""#))
            XCTFail("Expected assertionFailed error")
        } catch let e as InterpreterError {
            if case .assertionFailed = e { return }
            XCTFail("Expected .assertionFailed, got \(e)")
        }
    }

    // MARK: - Line numbers en errores de bridge (#154)

    /// Un error de bridge (observer muerto) en una acción debe salir envuelto
    /// en `commandFailed` con la línea del statement — antes abortaba el run
    /// sin número de línea.
    func testBridgeErrorInActionCarriesLineNumber() async throws {
        let backend = InterpreterMockBackend()
        backend.connectionFailKinds = [.tap]
        let interp = await makeInterpreter(backend)

        let script = """
        screenshot before.png
        tap "Login"
        """
        do {
            try await interp.run(try parseStatements(script))
            XCTFail("Expected commandFailed error")
        } catch let e as InterpreterError {
            guard case .commandFailed(let line, let message) = e else {
                return XCTFail("Expected .commandFailed, got \(e)")
            }
            XCTAssertEqual(line, 2)
            XCTAssertTrue(message.contains("Cannot connect to observer"), "El error original debe preservarse: \(message)")
            XCTAssertTrue("\(e)".hasPrefix("FAIL at line 2:"), "Formato esperado 'FAIL at line N: <error>', got: \(e)")
        }
    }

    /// El mismo contrato aplica evaluando el predicado de un assert: un
    /// bridge que explota (no un assert falso) también reporta la línea.
    func testBridgeErrorInAssertPredicateCarriesLineNumber() async throws {
        let backend = InterpreterMockBackend()
        backend.connectionFailKinds = [.exists]
        let interp = await makeInterpreter(backend)

        let script = """
        screenshot before.png
        screenshot mid.png
        assert exists "Home"
        """
        do {
            try await interp.run(try parseStatements(script))
            XCTFail("Expected commandFailed error")
        } catch let e as InterpreterError {
            guard case .commandFailed(let line, _) = e else {
                return XCTFail("Expected .commandFailed, got \(e)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    /// El FAIL "semántico" del assert (predicado false, sin excepción) debe
    /// seguir siendo assertionFailed — no lo envolvemos.
    func testAssertFalseStillThrowsAssertionFailed() async throws {
        let backend = InterpreterMockBackend()
        backend.boolResults = [false]
        let interp = await makeInterpreter(backend)

        do {
            try await interp.run(try parseStatements(#"assert exists "Gone""#))
            XCTFail("Expected assertionFailed")
        } catch let e as InterpreterError {
            guard case .assertionFailed(let line) = e else {
                return XCTFail("Expected .assertionFailed sin envolver, got \(e)")
            }
            XCTAssertEqual(line, 1)
        }
    }

    // MARK: - Platform predicate

    func testPlatformPredicate_matchesIos() async throws {
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend)

        let script = """
        if platform is ios
            tap "iOS"
        else
            tap "Android"
        end
        """
        try await interp.run(try parseStatements(script))

        // getPlatform returns "ios" → branch taken
        let taps = backend.executed.filter { if case .tap = $0 { return true }; return false }
        XCTAssertEqual(taps.count, 1)
        if case .tap(let target) = taps[0] {
            XCTAssertEqual(target, "iOS")
        } else { XCTFail() }
    }
}
