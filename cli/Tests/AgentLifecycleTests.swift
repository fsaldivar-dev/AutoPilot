import XCTest
@testable import AutoCore

/// Tests del manejo del conflicto de exclusividad UiAutomation (#135):
/// error tipado accionable + constantes del ciclo de vida del agente.
/// No requieren emulador — validan contratos puros.
final class AgentLifecycleTests: XCTestCase {

    // MARK: - Error accionable

    func testUiAutomationBusyDescriptionIsActionable() {
        let desc = BridgeError.uiAutomationBusy.description

        // Debe explicar la causa (exclusividad de UiAutomation)...
        XCTAssertTrue(desc.contains("UiAutomation"))
        // ...y dar los dos remedios: el subcomando nuevo y el adb crudo.
        XCTAssertTrue(desc.contains("auto-android agent stop"))
        XCTAssertTrue(desc.contains("am force-stop dev.autopilot.agent"))
        // ...y como volver al modo agente despues del benchmark.
        XCTAssertTrue(desc.contains("auto-android agent start"))
    }

    func testUiAutomationBusyMentionsAgentPackage() {
        // El mensaje debe referirse al package real del agente, no a otro.
        XCTAssertTrue(BridgeError.uiAutomationBusy.description.contains(AgentBridge.agentPackage))
    }

    // MARK: - Constantes del agente

    func testAgentComponentIsDerivedFromPackage() {
        // El componente de `am instrument` debe pertenecer al package que
        // paramos con force-stop — si divergen, `agent stop` no detendria
        // lo que `agent start` lanza.
        XCTAssertTrue(AgentBridge.agentComponent.hasPrefix(AgentBridge.agentPackage + "/"))
        XCTAssertEqual(AgentBridge.agentPackage, "dev.autopilot.agent")
        XCTAssertEqual(AgentBridge.agentComponent, "dev.autopilot.agent/.AgentInstrumentation")
    }

    // MARK: - AgentStatus

    func testAgentStatusRawValues() {
        // Los rawValues son parte del contrato de salida del CLI
        // (`auto-android agent status`) — no cambiarlos sin actualizar docs.
        XCTAssertEqual(AgentBridge.AgentStatus.running.rawValue, "running")
        XCTAssertEqual(AgentBridge.AgentStatus.processOnly.rawValue, "process-only")
        XCTAssertEqual(AgentBridge.AgentStatus.stopped.rawValue, "stopped")
    }
}
