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

        // ARD-002: register the observer backend at highest priority when reachable.
        // Escalation to AX/XCUI happens automatically via ActionRouter (ARD-001);
        // no DeviceBridge-level wrapper is needed.
        let agent = iOSAgentBridge()
        let observerLive = agent.probeSocket()
        if observerLive {
            self.agentBridge = agent
            backends.append(iOSAgentBackend.make(bridge: agent))
        } else {
            self.agentBridge = nil
        }
        self.legacyBridge = Self.makeLegacyBridge(sim: sim, xcui: xcui, observerLive: observerLive)

        // When the observer is live, skip AXBackend entirely — AX macOS is the
        // only path that requires `NSRunningApplication.activate()` and it's
        // what robs focus from the caller (editor). The observer covers all of
        // AX's capabilities sin tocar Simulator.app foreground.
        //
        // Can be forced back on with AUTO_FORCE_AX=1 for debugging (ej: si el
        // observer tiene un bug puntual y queremos comparar).
        let forceAX = ProcessInfo.processInfo.environment["AUTO_FORCE_AX"] == "1"
        if !observerLive || forceAX {
            backends.append(AXBackend.make(simulatorBridge: sim))
        }

        backends.append(contentsOf: [
            XCUIBackend.make(xcuiBridge: xcui),
            SimCtlBackend.make(simulatorBridge: sim),
            MediaBackend.make(simulatorBridge: sim)
        ])
        registerBackendsSynchronously(backends, in: registry)
        self.router = ActionRouter(registry: registry)
    }

    /// El bridge legacy que los comandos iOS-específicos (no migrados a router)
    /// siguen consumiendo. AUTO_BRIDGE controla cuál es el default:
    ///   - simulator: AX puro (rápido, ciego a NavBar SwiftUI) — requiere sim foreground
    ///   - xcui: XCTest puro (lento, ve todo) — no requiere foreground
    ///   - hybrid (default sin observer): escalation manual sim → xcui
    ///   - auto (default con observer vivo): el propio observer es el fast path.
    ///     XCUI queda como fallback deep. Sim (AX macOS) NO se usa — así no
    ///     activamos Simulator.app.
    private static func makeLegacyBridge(
        sim: SimulatorBridge, xcui: XCUIBridge, observerLive: Bool
    ) -> any DeviceBridge {
        let mode = ProcessInfo.processInfo.environment["AUTO_BRIDGE"]
        if let explicit = mode {
            switch explicit {
            case "simulator": return sim
            case "xcui":      return xcui
            case "hybrid":    return HybridBridge(fast: sim, deep: xcui)
            default:          break
            }
        }
        if observerLive {
            // Legacy commands van directo a XCUI cuando no los cubre el router.
            // Evita activar Simulator.app via AX macOS.
            return xcui
        }
        return HybridBridge(fast: sim, deep: xcui)
    }
}
