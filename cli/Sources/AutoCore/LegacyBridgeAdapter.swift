import Foundation
import CoreGraphics

/// Adapter transicional que envuelve cualquier `DeviceBridge` como `Backend`.
///
/// **Rol durante la migración (Fases 0-4):** Los backends nativos
/// (`AXBackend`, `XCUIBackend`, `SimCtlBackend`, `MediaBackend`, `AgentBackend`,
/// `AdbBackend`) son wrappers thin sobre los bridges existentes — usan
/// `LegacyBridgeAdapter` internamente para el delegate call. El `ConstrainedBackend`
/// les limita las capabilities a lo que cada uno "sabe hacer", pero el mapping
/// Action→método sigue viviendo acá.
///
/// **Se elimina cuando** los backends extraigan su código físicamente de los
/// bridges existentes (`SimulatorBridge` 1964 LOC → `AXBackend` + `SimCtlBackend`
/// + `MediaBackend`). Eso es un PR focalizado aparte, no parte de ARD-001.
public final class LegacyBridgeAdapter: Backend, @unchecked Sendable {

    public let capabilities: Set<ActionKind> = Set(ActionKind.allCases)

    private let bridge: any DeviceBridge

    /// Diagnóstico: reportar el bridge concreto (iOSAgentBridge, XCUIBridge...),
    /// no el adapter — es lo que el usuario reconoce en un warning del router.
    public var name: String { String(describing: type(of: bridge)) }

    public init(_ bridge: any DeviceBridge) {
        self.bridge = bridge
    }

    public func execute(_ action: Action) async throws -> ActionResult {
        switch action {

        // MARK: Tree
        case .tree:
            let result = try bridge.tree()
            return .elements(result)

        case .search(let query):
            let result = try bridge.search(query: query)
            return .elements(result)

        case .elementAt(let x, let y):
            if let element = try bridge.elementAt(x: x, y: y) {
                return .element(element)
            }
            return .elements([])

        // MARK: Tap & gestures
        case .tap(let target):
            try bridge.tap(target: target)
            return .void

        case .doubleTap(let target):
            try bridge.doubleTap(target: target)
            return .void

        case .longPress(let target, let duration):
            try bridge.longPress(target: target, duration: duration)
            return .void

        case .tapAtCoordinate(let x, let y):
            try bridge.tapAtCoordinate(x: x, y: y)
            return .void

        case .drag(let from, let to, let duration):
            try bridge.drag(from: from, to: to, duration: duration)
            return .void

        case .dragCoordinates(let x1, let y1, let x2, let y2, let duration):
            try bridge.dragCoordinates(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
            return .void

        // MARK: Text input
        case .typeText(let text):
            try bridge.typeText(text)
            return .void

        case .clear(let target):
            try bridge.clear(target: target)
            return .void

        case .eraseText(let count):
            try bridge.eraseText(count: count)
            return .void

        case .pressKey(let key):
            try bridge.pressKey(key: key)
            return .void

        case .hideKeyboard:
            try bridge.hideKeyboard()
            return .void

        case .copyTextFrom(let target):
            let text = try bridge.copyTextFrom(target: target)
            return .text(text)

        // MARK: Scroll & swipe
        case .scroll(let target, let direction):
            try bridge.scroll(target: target, direction: direction)
            return .void

        case .swipe(let direction):
            try bridge.swipe(direction: direction)
            return .void

        case .scrollTo(let target, let direction, let maxAttempts):
            try bridge.scrollTo(target: target, direction: direction, maxAttempts: maxAttempts)
            return .void

        // MARK: App lifecycle
        case .launchApp(let bundleId, let envVars):
            try bridge.launchApp(bundleId: bundleId, envVars: envVars)
            return .void

        case .terminateApp(let bundleId):
            try bridge.terminateApp(bundleId: bundleId)
            return .void

        case .clearState(let bundleId):
            try bridge.clearState(bundleId: bundleId)
            return .void

        case .uninstallApp(let bundleId):
            try bridge.uninstallApp(bundleId: bundleId)
            return .void

        // MARK: Device management
        case .listDevices:
            let result = try bridge.listDevices()
            return .deviceList(result)

        case .bootDevice(let nameOrUdid):
            try bridge.bootDevice(nameOrUdid)
            return .void

        case .shutdownDevice(let nameOrUdid):
            try bridge.shutdownDevice(nameOrUdid)
            return .void

        case .installApp(let path):
            try bridge.installApp(path: path)
            return .void

        case .getBootedDeviceId:
            let id = try bridge.getBootedDeviceId()
            return .deviceId(id)

        // MARK: Media & IO
        case .screenshot(let path):
            try bridge.screenshot(path: path)
            return .void

        case .addMedia(let path):
            try bridge.addMedia(path: path)
            return .void

        case .openURL(let url):
            try bridge.openURL(url)
            return .void

        case .setPasteboard(let text):
            try bridge.setPasteboard(text: text)
            return .void

        case .getPasteboard:
            let text = try bridge.getPasteboard()
            return .text(text)

        // MARK: Biometric
        case .biometricEnroll:
            try bridge.biometricEnroll()
            return .void

        case .biometricUnenroll:
            try bridge.biometricUnenroll()
            return .void

        case .biometricMatch:
            try bridge.biometricMatch()
            return .void

        case .biometricFail:
            try bridge.biometricFail()
            return .void

        case .biometricIsEnrolled:
            let enrolled = try bridge.biometricIsEnrolled()
            return .bool(enrolled)

        // MARK: Logs & permissions
        case .getLogs(let bundleId, let lines):
            let logs = try bridge.getLogs(bundleId: bundleId, lines: lines)
            return .logs(logs)

        case .setPermission(let action, let service, let bundleId):
            try bridge.setPermission(action: action, service: service, bundleId: bundleId)
            return .void

        // MARK: Device orientation & state
        case .rotate(let direction):
            try bridge.rotate(direction: direction)
            return .void

        case .lockDevice:
            try bridge.lockDevice()
            return .void

        case .unlockDevice:
            try bridge.unlockDevice()
            return .void

        case .resetKeychain:
            try bridge.resetKeychain()
            return .void

        // MARK: Screen recording
        case .startRecording:
            try bridge.startRecording()
            return .void

        case .stopRecording(let outputPath):
            try bridge.stopRecording(outputPath: outputPath)
            return .void

        // MARK: Location & appearance
        case .setLocation(let lat, let lon):
            try bridge.setLocation(latitude: lat, longitude: lon)
            return .void

        case .setAppearance(let mode):
            try bridge.setAppearance(mode: mode)
            return .void

        // MARK: File transfer
        case .pushFile(let localPath, let remotePath):
            try bridge.pushFile(localPath: localPath, remotePath: remotePath)
            return .void

        case .pullFile(let remotePath, let localPath):
            try bridge.pullFile(remotePath: remotePath, localPath: localPath)
            return .void

        // MARK: Viewport
        case .viewport:
            let rect = try bridge.viewport()
            return .rect(rect)

        // MARK: Predicates
        //
        // Los predicados devuelven `.bool` cuando el elemento falta (en vez de
        // throw `.elementNotFound`), para que `ActionRouter` no escale una
        // respuesta negativa legítima. Ver PredicateTests y plan fase 1.

        case .exists(let target):
            let results = try bridge.search(query: target)
            return .bool(!results.isEmpty)

        case .isVisible(let target):
            let tree = try bridge.tree()
            guard let element = ViewportUtil.findFirst(in: tree, matching: target),
                  let frame = ViewportUtil.rect(from: element["frame"] as? [String: Any])
            else {
                return .bool(false)
            }
            let viewport = try bridge.viewport()
            return .bool(ViewportUtil.isVisible(frame: frame, inViewport: viewport))

        case .hasText(let target, let text):
            let tree = try bridge.tree()
            guard let element = ViewportUtil.findFirst(in: tree, matching: target) else {
                return .bool(false)
            }
            let label = element["label"] as? String ?? ""
            let value = element["value"] as? String ?? ""
            let title = element["title"] as? String ?? ""
            let match = label.contains(text) || value.contains(text) || title.contains(text)
            return .bool(match)

        case .getPlatform:
            // Plataforma efectiva del runtime. iOS CLI corre en iOS simulator host;
            // Android CLI hace override via override más adelante si hace falta.
            return .text("ios")

        case .getOrientation:
            let rect = try bridge.viewport()
            return .text(rect.height >= rect.width ? "portrait" : "landscape")
        }
    }
}
