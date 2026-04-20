import Foundation
import AutoCore

/// Resolver de plataforma iOS. Bootstrap de los backends nativos:
/// - iOSAgentBackend (ARD-002, in-process observer) — primario si disponible
/// - AXBackend (fast, AX macOS) — fallback cuando observer no está
/// - XCUIBackend (deep, XCTest runner) — escalation automático
/// - SimCtlBackend (device mgmt vía simctl)
/// - MediaBackend (screenshot + recording)
///
/// Respeta la variable de entorno `AUTO_BRIDGE=simulator|xcui|hybrid` para
/// compatibilidad con scripts existentes — afecta solo al `legacyBridge` que
/// aún consumen los comandos iOS-específicos (ping, index, tap con $N, etc.).
public final class iOSDeviceResolver: DeviceResolver {

    public let router: ActionRouter
    public let simulatorBridge: SimulatorBridge
    public let xcuiBridge: XCUIBridge
    public let legacyBridge: any DeviceBridge
    /// Non-nil when the app under test has libAutoPilotObserver linked (ARD-002).
    public let agentBridge: iOSAgentBridge?

    public init() {
        let sim = SimulatorBridge()
        let xcui = XCUIBridge()
        self.simulatorBridge = sim
        self.xcuiBridge = xcui

        let registry = CapabilityRegistry()
        var backends: [any Backend] = []

        // ARD-002: if the in-process observer is reachable, register it first so
        // it takes priority over AX for all UI actions (tree/tap/etc.).
        // Also wraps legacyBridge so CommandDispatcher routes through the observer.
        // Falls back to AX+XCUI transparently when the observer is not available.
        let agent = iOSAgentBridge()
        if agent.probeSocket() {
            self.agentBridge = agent
            let hybridFallback = Self.makeLegacyBridge(sim: sim, xcui: xcui)
            self.legacyBridge = ObserverBridge(observer: agent, fallback: hybridFallback)
            backends.append(iOSAgentBackend.make(bridge: agent))
        } else {
            self.agentBridge = nil
            self.legacyBridge = Self.makeLegacyBridge(sim: sim, xcui: xcui)
        }

        backends.append(contentsOf: [
            AXBackend.make(simulatorBridge: sim),
            XCUIBackend.make(xcuiBridge: xcui),
            SimCtlBackend.make(simulatorBridge: sim),
            MediaBackend.make(simulatorBridge: sim)
        ])
        registerBackendsSynchronously(backends, in: registry)
        self.router = ActionRouter(registry: registry)
    }

    /// El bridge legacy que los comandos iOS-específicos (no migrados a router)
    /// siguen consumiendo. AUTO_BRIDGE controla cuál es el default:
    ///   - simulator: AX puro (rápido, ciego a NavBar SwiftUI)
    ///   - xcui: XCTest puro (lento, ve todo)
    ///   - hybrid (default): escalation manual — será deprecado en Fase 5
    ///     una vez que todos los comandos pasen por el router.
    private static func makeLegacyBridge(sim: SimulatorBridge, xcui: XCUIBridge) -> any DeviceBridge {
        let mode = ProcessInfo.processInfo.environment["AUTO_BRIDGE"] ?? "hybrid"
        switch mode {
        case "simulator": return sim
        case "xcui":      return xcui
        default:          return HybridBridge(fast: sim, deep: xcui)
        }
    }
}
