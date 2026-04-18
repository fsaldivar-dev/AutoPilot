import XCTest
@testable import AutoCore

/// Tests de integración de la arquitectura Backend + Registry + Router.
/// Valida que el routing por capability funciona end-to-end con múltiples
/// backends simulados (sin depender de Simulator/emulador reales).
final class BackendRegistrationTests: XCTestCase {

    // MARK: - Capability routing

    func testRouterDispatchesByCapability() async throws {
        let registry = CapabilityRegistry()

        // Simulamos la topología iOS: AX + SimCtl + Media, cada uno con
        // sus capabilities declaradas.
        let axBackend = MockBackend(capabilities: [.tap, .tree, .scroll])
        let simctlBackend = MockBackend(capabilities: [.launchApp, .installApp, .biometricMatch])
        let mediaBackend = MockBackend(capabilities: [.screenshot, .startRecording])

        await registry.register(axBackend)
        await registry.register(simctlBackend)
        await registry.register(mediaBackend)

        let router = ActionRouter(registry: registry)

        _ = try await router.execute(.tap(target: "Login"))
        _ = try await router.execute(.installApp(path: "/tmp/app.app"))
        _ = try await router.execute(.screenshot(path: "/tmp/out.png"))

        XCTAssertEqual(axBackend.executeCallCount, 1, "AX should handle .tap")
        XCTAssertEqual(simctlBackend.executeCallCount, 1, "SimCtl should handle .installApp")
        XCTAssertEqual(mediaBackend.executeCallCount, 1, "Media should handle .screenshot")
    }

    func testActionIsNotRoutedToIncapableBackend() async throws {
        let registry = CapabilityRegistry()

        let axBackend = MockBackend(capabilities: [.tap])
        let simctlBackend = MockBackend(capabilities: [.installApp])

        await registry.register(axBackend)
        await registry.register(simctlBackend)

        let router = ActionRouter(registry: registry)

        _ = try await router.execute(.tap(target: "Login"))

        XCTAssertEqual(axBackend.executeCallCount, 1)
        XCTAssertEqual(simctlBackend.executeCallCount, 0, "SimCtl should NOT receive .tap — it doesn't declare that capability")
    }

    // MARK: - Escalation AX → XCUI

    func testAXToXCUIEscalationOnElementNotFound() async throws {
        let registry = CapabilityRegistry()

        // Topología real iOS: AX primero, XCUI segundo.
        let axBackend = MockBackend(capabilities: [.tap])
        axBackend.shouldThrowElementNotFound = true  // simula NavBar SwiftUI invisible para AX

        let xcuiBackend = MockBackend(capabilities: [.tap])
        xcuiBackend.resultToReturn = .void

        await registry.register(axBackend)   // primero
        await registry.register(xcuiBackend) // escalation

        let router = ActionRouter(registry: registry)

        _ = try await router.execute(.tap(target: "Back"))

        XCTAssertEqual(axBackend.executeCallCount, 1, "AX should try first")
        XCTAssertEqual(xcuiBackend.executeCallCount, 1, "XCUI should receive the action after AX fails")
    }

    // MARK: - ConstrainedBackend

    func testConstrainedBackendEnforcesCapabilities() async throws {
        let delegate = MockBackend(capabilities: Set(ActionKind.allCases))
        let constrained = ConstrainedBackend(
            capabilities: [.tap, .screenshot],
            delegate: delegate
        )

        XCTAssertEqual(constrained.capabilities, [.tap, .screenshot])

        _ = try await constrained.execute(.tap(target: "Button"))
        XCTAssertEqual(delegate.executeCallCount, 1)

        do {
            _ = try await constrained.execute(.installApp(path: "/tmp/app.app"))
            XCTFail("Should have thrown — .installApp is outside declared capabilities")
        } catch let error as ActionRouterError {
            if case .noBackendForAction(let kind) = error {
                XCTAssertEqual(kind, .installApp)
            } else {
                XCTFail("Unexpected ActionRouterError: \(error)")
            }
        }

        XCTAssertEqual(delegate.executeCallCount, 1, "Delegate should not be called for actions outside capabilities")
    }
}
