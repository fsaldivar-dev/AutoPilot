import Foundation

/// Resolver de plataforma Android. Bootstrap del backend nativo:
/// - AgentBackend (default) — socket TCP al agente nativo con UiAutomation + JVMTI
/// - AdbBackend (`--legacy`) — fallback vía `adb shell` + uiautomator dump
public final class AndroidDeviceResolver: DeviceResolver {

    public let router: ActionRouter
    public let legacyBridge: any DeviceBridge
    public let useLegacy: Bool

    public init(useLegacy: Bool) {
        self.useLegacy = useLegacy

        let registry = CapabilityRegistry()
        let backends: [any Backend]

        if useLegacy {
            let adb = AdbLegacyBridge()
            self.legacyBridge = adb
            backends = [AdbBackend.make(adbBridge: adb)]
        } else {
            let agent = AgentBridge()
            self.legacyBridge = agent
            backends = [AgentBackend.make(agentBridge: agent)]
        }

        registerBackendsSynchronously(backends, in: registry)
        self.router = ActionRouter(registry: registry)
    }
}
