import XCTest
@testable import AutoCore

// Tests para las nuevas Actions-predicado introducidas en la Fase 1 del
// plan del interpreter. Cubren:
//   - Forma: ActionKind enumerable, Action.kind mapping correcto
//   - Router: ejecuta predicado en el primer backend capaz
//   - Contrato: `.bool(false)` NO dispara escalation (sí la escala es solo
//     para errores de backend, no para respuestas negativas legítimas)
//
// Reusa `MockBackend` declarado en ActionRouterTests.swift (mismo target).

final class PredicateTests: XCTestCase {

    // MARK: - ActionKind enumeration & Action.kind mapping

    func testActionKind_includesAllPredicates() {
        XCTAssertTrue(ActionKind.allCases.contains(.exists))
        XCTAssertTrue(ActionKind.allCases.contains(.isVisible))
        XCTAssertTrue(ActionKind.allCases.contains(.hasText))
        XCTAssertTrue(ActionKind.allCases.contains(.getPlatform))
        XCTAssertTrue(ActionKind.allCases.contains(.getOrientation))
    }

    func testActionKind_mappingForPredicates() {
        XCTAssertEqual(Action.exists(target: "X").kind, .exists)
        XCTAssertEqual(Action.isVisible(target: "X").kind, .isVisible)
        XCTAssertEqual(Action.hasText(target: "X", text: "Y").kind, .hasText)
        XCTAssertEqual(Action.getPlatform.kind, .getPlatform)
        XCTAssertEqual(Action.getOrientation.kind, .getOrientation)
    }

    // MARK: - exists

    func testExists_returnsTrueWhenBackendFindsElement() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.exists])
        backend.resultToReturn = .bool(true)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.exists(target: "Login"))

        XCTAssertEqual(backend.executeCallCount, 1)
        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool result, got \(result)")
        }
        XCTAssertTrue(value)
    }

    func testExists_returnsFalseWhenBackendReportsMissing() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.exists])
        backend.resultToReturn = .bool(false)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.exists(target: "Nope"))

        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool result, got \(result)")
        }
        XCTAssertFalse(value)
    }

    func testExists_doesNotEscalateOnFalseResult() async throws {
        // Un predicado que retorna `.bool(false)` es una respuesta válida,
        // NO un error de backend. El router no debe probar el siguiente.
        let registry = CapabilityRegistry()

        let first = MockBackend(capabilities: [.exists])
        first.resultToReturn = .bool(false)

        let second = MockBackend(capabilities: [.exists])
        second.resultToReturn = .bool(true)

        await registry.register(first)
        await registry.register(second)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.exists(target: "Ghost"))

        XCTAssertEqual(first.executeCallCount, 1)
        XCTAssertEqual(second.executeCallCount, 0,
                       "Router must not escalate on a legitimate negative bool")
        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool, got \(result)")
        }
        XCTAssertFalse(value)
    }

    // MARK: - isVisible

    func testIsVisible_returnsTrueForVisibleElement() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.isVisible])
        backend.resultToReturn = .bool(true)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.isVisible(target: "Submit"))

        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool, got \(result)")
        }
        XCTAssertTrue(value)
    }

    func testIsVisible_returnsFalseForOffscreenElement() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.isVisible])
        backend.resultToReturn = .bool(false)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.isVisible(target: "Bottom"))

        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool, got \(result)")
        }
        XCTAssertFalse(value)
    }

    // MARK: - hasText

    func testHasText_returnsTrueOnMatch() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.hasText])
        backend.resultToReturn = .bool(true)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.hasText(target: "Greeting", text: "Hola"))

        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool, got \(result)")
        }
        XCTAssertTrue(value)
    }

    func testHasText_returnsFalseOnMismatch() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.hasText])
        backend.resultToReturn = .bool(false)
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.hasText(target: "Greeting", text: "Adiós"))

        guard case .bool(let value) = result else {
            return XCTFail("Expected .bool, got \(result)")
        }
        XCTAssertFalse(value)
    }

    // MARK: - getPlatform / getOrientation

    func testGetPlatform_returnsTextResult() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.getPlatform])
        backend.resultToReturn = .text("ios")
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.getPlatform)

        guard case .text(let value) = result else {
            return XCTFail("Expected .text, got \(result)")
        }
        XCTAssertEqual(value, "ios")
    }

    func testGetOrientation_returnsTextResult() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.getOrientation])
        backend.resultToReturn = .text("portrait")
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.getOrientation)

        guard case .text(let value) = result else {
            return XCTFail("Expected .text, got \(result)")
        }
        XCTAssertEqual(value, "portrait")
    }

    // MARK: - No backend for predicate

    func testPredicate_throwsWhenNoBackendRegistered() async throws {
        let registry = CapabilityRegistry()
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.exists(target: "X"))
            XCTFail("Expected ActionRouterError.noBackendForAction")
        } catch let error as ActionRouterError {
            if case .noBackendForAction(let kind) = error {
                XCTAssertEqual(kind, .exists)
            } else {
                XCTFail("Unexpected router error: \(error)")
            }
        }
    }
}
