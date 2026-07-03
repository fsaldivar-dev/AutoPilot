import XCTest
@testable import AutoCore

// MARK: - MockBackend

final class MockBackend: Backend, @unchecked Sendable {
    let capabilities: Set<ActionKind>
    var executeCallCount = 0
    var lastAction: Action?

    var shouldThrowElementNotFound = false
    var shouldThrowOtherError = false
    var shouldThrowConnectionFailed = false
    var resultToReturn: ActionResult = .void

    init(capabilities: Set<ActionKind>) {
        self.capabilities = capabilities
    }

    func execute(_ action: Action) async throws -> ActionResult {
        executeCallCount += 1
        lastAction = action
        if shouldThrowElementNotFound {
            throw BridgeError.elementNotFound("mock element")
        }
        if shouldThrowOtherError {
            throw BridgeError.simulatorNotRunning
        }
        if shouldThrowConnectionFailed {
            throw BridgeError.connectionFailed("Cannot connect to observer (mock)")
        }
        return resultToReturn
    }
}

// MARK: - ActionRouterTests

final class ActionRouterTests: XCTestCase {

    // MARK: Happy path

    func testExecutesOnFirstCapableBackend() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.tap])
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.tap(target: "Login"))

        XCTAssertEqual(backend.executeCallCount, 1)
        XCTAssertEqual(result, .void)
    }

    func testReturnsTextResult() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.copyTextFrom])
        backend.resultToReturn = .text("hello world")
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.copyTextFrom(target: "Label"))

        if case .text(let value) = result {
            XCTAssertEqual(value, "hello world")
        } else {
            XCTFail("Expected .text result")
        }
    }

    // MARK: Capability miss

    func testThrowsWhenNoBackendRegisteredForAction() async throws {
        let registry = CapabilityRegistry()
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Button"))
            XCTFail("Expected error")
        } catch let error as ActionRouterError {
            if case .noBackendForAction(let kind) = error {
                XCTAssertEqual(kind, .tap)
            } else {
                XCTFail("Unexpected ActionRouterError: \(error)")
            }
        }
    }

    func testThrowsWhenBackendDoesNotHaveCapability() async throws {
        let registry = CapabilityRegistry()
        let backend = MockBackend(capabilities: [.screenshot])  // solo screenshot
        await registry.register(backend)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Button"))
            XCTFail("Expected error")
        } catch let error as ActionRouterError {
            if case .noBackendForAction(let kind) = error {
                XCTAssertEqual(kind, .tap)
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: Escalation

    func testEscalatesOnElementNotFound() async throws {
        let registry = CapabilityRegistry()

        let first = MockBackend(capabilities: [.tap])
        first.shouldThrowElementNotFound = true

        let second = MockBackend(capabilities: [.tap])
        second.resultToReturn = .void

        await registry.register(first)
        await registry.register(second)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.tap(target: "NavBar Back"))

        XCTAssertEqual(first.executeCallCount, 1, "First backend should be tried")
        XCTAssertEqual(second.executeCallCount, 1, "Second backend should execute after escalation")
        XCTAssertEqual(result, .void)
    }

    func testPropagatesNonElementNotFoundErrors() async throws {
        let registry = CapabilityRegistry()

        let first = MockBackend(capabilities: [.tap])
        first.shouldThrowOtherError = true

        let second = MockBackend(capabilities: [.tap])

        await registry.register(first)
        await registry.register(second)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Button"))
            XCTFail("Expected error to propagate")
        } catch let error as BridgeError {
            if case .simulatorNotRunning = error {
                // correcto — no escaló
            } else {
                XCTFail("Unexpected BridgeError: \(error)")
            }
        }

        XCTAssertEqual(second.executeCallCount, 0, "Second backend should NOT be tried for non-elementNotFound errors")
    }

    func testThrowsLastElementNotFoundWhenAllBackendsFail() async throws {
        let registry = CapabilityRegistry()

        let first = MockBackend(capabilities: [.tap])
        first.shouldThrowElementNotFound = true

        let second = MockBackend(capabilities: [.tap])
        second.shouldThrowElementNotFound = true

        await registry.register(first)
        await registry.register(second)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Ghost Button"))
            XCTFail("Expected error")
        } catch let error as BridgeError {
            if case .elementNotFound = error {
                // correcto
            } else {
                XCTFail("Expected elementNotFound, got: \(error)")
            }
        }

        XCTAssertEqual(first.executeCallCount, 1)
        XCTAssertEqual(second.executeCallCount, 1)
    }

    // MARK: Degradación por fallo de conexión (#154)

    /// El contrato central del fix: si el backend prioritario falla por
    /// CONEXIÓN (observer muerto), el router degrada al siguiente backend
    /// en vez de abortar el run.
    func testDegradesToNextBackendOnConnectionFailure() async throws {
        let registry = CapabilityRegistry()

        let observer = MockBackend(capabilities: [.tap])
        observer.shouldThrowConnectionFailed = true

        let xcui = MockBackend(capabilities: [.tap])
        xcui.resultToReturn = .void

        await registry.register(observer)
        await registry.register(xcui)
        let router = ActionRouter(registry: registry)

        let result = try await router.execute(.tap(target: "Login"))

        XCTAssertEqual(observer.executeCallCount, 1)
        XCTAssertEqual(xcui.executeCallCount, 1, "Debe degradar al siguiente backend, no abortar")
        XCTAssertEqual(result, .void)
    }

    /// Si la degradación FUNCIONA, el backend muerto queda des-registrado
    /// por el resto del proceso: la siguiente acción no vuelve a pagar el
    /// intento de conexión fallido.
    func testQuarantinesDeadBackendAfterSuccessfulDegradation() async throws {
        let registry = CapabilityRegistry()

        let observer = MockBackend(capabilities: [.tap])
        observer.shouldThrowConnectionFailed = true

        let xcui = MockBackend(capabilities: [.tap])

        await registry.register(observer)
        await registry.register(xcui)
        let router = ActionRouter(registry: registry)

        _ = try await router.execute(.tap(target: "Login"))
        _ = try await router.execute(.tap(target: "Settings"))

        XCTAssertEqual(observer.executeCallCount, 1, "El backend muerto no debe reintentar tras la cuarentena")
        XCTAssertEqual(xcui.executeCallCount, 2)
    }

    /// Si NADIE responde, no hay cuarentena: el fallo pudo ser transitorio y
    /// la siguiente acción debe reintentar desde el principio.
    func testDoesNotQuarantineWhenAllBackendsFailConnection() async throws {
        let registry = CapabilityRegistry()

        let observer = MockBackend(capabilities: [.tap])
        observer.shouldThrowConnectionFailed = true

        let xcui = MockBackend(capabilities: [.tap])
        xcui.shouldThrowConnectionFailed = true

        await registry.register(observer)
        await registry.register(xcui)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Login"))
            XCTFail("Expected error")
        } catch let error as BridgeError {
            guard case .connectionFailed = error else {
                return XCTFail("Expected connectionFailed, got: \(error)")
            }
        }

        do {
            _ = try await router.execute(.tap(target: "Login"))
            XCTFail("Expected error")
        } catch { /* esperado */ }

        XCTAssertEqual(observer.executeCallCount, 2, "Sin degradación exitosa no hay cuarentena — se reintenta")
        XCTAssertEqual(xcui.executeCallCount, 2)
    }

    /// Sin fallback disponible, el error de conexión propaga (con el hint
    /// accionable del bridge) — no se convierte en silencio.
    func testConnectionFailurePropagatesWhenNoFallback() async throws {
        let registry = CapabilityRegistry()
        let observer = MockBackend(capabilities: [.tap])
        observer.shouldThrowConnectionFailed = true
        await registry.register(observer)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Login"))
            XCTFail("Expected error")
        } catch let error as BridgeError {
            guard case .connectionFailed = error else {
                return XCTFail("Expected connectionFailed, got: \(error)")
            }
        }
    }

    /// connectionFailed + elementNotFound del fallback: el error final es el
    /// del último backend (elementNotFound) y NO hay cuarentena (nadie "ganó").
    func testConnectionFailureThenElementNotFoundDoesNotQuarantine() async throws {
        let registry = CapabilityRegistry()

        let observer = MockBackend(capabilities: [.tap])
        observer.shouldThrowConnectionFailed = true

        let xcui = MockBackend(capabilities: [.tap])
        xcui.shouldThrowElementNotFound = true

        await registry.register(observer)
        await registry.register(xcui)
        let router = ActionRouter(registry: registry)

        do {
            _ = try await router.execute(.tap(target: "Ghost"))
            XCTFail("Expected error")
        } catch let error as BridgeError {
            guard case .elementNotFound = error else {
                return XCTFail("Expected elementNotFound (último backend), got: \(error)")
            }
        }

        _ = try? await router.execute(.tap(target: "Ghost"))
        XCTAssertEqual(observer.executeCallCount, 2, "Sin éxito del fallback no hay cuarentena")
    }

    // MARK: Registry

    func testRegistryIndexesByCapability() async {
        let registry = CapabilityRegistry()
        let tapBackend = MockBackend(capabilities: [.tap, .doubleTap])
        let screenshotBackend = MockBackend(capabilities: [.screenshot])

        await registry.register(tapBackend)
        await registry.register(screenshotBackend)

        let tapCandidates = await registry.capable(of: .tap)
        let screenshotCandidates = await registry.capable(of: .screenshot)
        let treeCandidates = await registry.capable(of: .tree)

        XCTAssertEqual(tapCandidates.count, 1)
        XCTAssertEqual(screenshotCandidates.count, 1)
        XCTAssertTrue(treeCandidates.isEmpty)
    }

    func testRegistryPreservesRegistrationOrder() async {
        let registry = CapabilityRegistry()
        let first = MockBackend(capabilities: [.tap])
        let second = MockBackend(capabilities: [.tap])
        let third = MockBackend(capabilities: [.tap])

        await registry.register(first)
        await registry.register(second)
        await registry.register(third)

        let candidates = await registry.capable(of: .tap)
        XCTAssertEqual(candidates.count, 3)
        // El orden de registro debe preservarse para que el escalation sea determinístico
        XCTAssertTrue(candidates[0] === first)
        XCTAssertTrue(candidates[1] === second)
        XCTAssertTrue(candidates[2] === third)
    }
}

// MARK: - ActionResult Equatable (para tests)

extension ActionResult: Equatable {
    public static func == (lhs: ActionResult, rhs: ActionResult) -> Bool {
        switch (lhs, rhs) {
        case (.void, .void): return true
        case (.text(let a), .text(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.deviceId(let a), .deviceId(let b)): return a == b
        case (.logs(let a), .logs(let b)): return a == b
        case (.rect(let a), .rect(let b)): return a == b
        default: return false
        }
    }
}
