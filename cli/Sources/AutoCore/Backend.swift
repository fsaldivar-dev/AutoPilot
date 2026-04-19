import Foundation
import CoreGraphics

// MARK: - ActionKind

/// Capabilities que un Backend puede declarar.
public enum ActionKind: Hashable, CaseIterable {
    // Accessibility tree
    case tree
    case search
    case elementAt

    // Tap & gestures
    case tap
    case doubleTap
    case longPress
    case tapAtCoordinate
    case drag
    case dragCoordinates

    // Text input
    case typeText
    case clear
    case eraseText
    case pressKey
    case hideKeyboard
    case copyTextFrom

    // Scroll & swipe
    case scroll
    case swipe
    case scrollTo

    // App lifecycle
    case launchApp
    case terminateApp
    case clearState
    case uninstallApp

    // Device management
    case listDevices
    case bootDevice
    case shutdownDevice
    case installApp
    case getBootedDeviceId

    // Media & IO
    case screenshot
    case addMedia
    case openURL
    case setPasteboard
    case getPasteboard

    // Biometric
    case biometricEnroll
    case biometricUnenroll
    case biometricMatch
    case biometricFail
    case biometricIsEnrolled

    // Logs & permissions
    case getLogs
    case setPermission

    // Device orientation & state
    case rotate
    case lockDevice
    case unlockDevice
    case resetKeychain

    // Screen recording
    case startRecording
    case stopRecording

    // Location & appearance
    case setLocation
    case setAppearance

    // File transfer
    case pushFile
    case pullFile

    // Viewport
    case viewport
}

// MARK: - Action

/// Comando como valor. El caller describe qué quiere — el router decide quién lo ejecuta.
public enum Action {
    // Accessibility tree
    case tree
    case search(query: String)
    case elementAt(x: Double, y: Double)

    // Tap & gestures
    case tap(target: String)
    case doubleTap(target: String)
    case longPress(target: String, duration: Double)
    case tapAtCoordinate(x: Double, y: Double)
    case drag(from: String, to: String, duration: Double)
    case dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double)

    // Text input
    case typeText(String)
    case clear(target: String)
    case eraseText(count: Int)
    case pressKey(key: String)
    case hideKeyboard
    case copyTextFrom(target: String)

    // Scroll & swipe
    case scroll(target: String, direction: String)
    case swipe(direction: String)
    case scrollTo(target: String, direction: String, maxAttempts: Int)

    // App lifecycle
    case launchApp(bundleId: String, envVars: [String: String])
    case terminateApp(bundleId: String)
    case clearState(bundleId: String)
    case uninstallApp(bundleId: String)

    // Device management
    case listDevices
    case bootDevice(String)
    case shutdownDevice(String)
    case installApp(path: String)
    case getBootedDeviceId

    // Media & IO
    case screenshot(path: String)
    case addMedia(path: String)
    case openURL(String)
    case setPasteboard(text: String)
    case getPasteboard

    // Biometric
    case biometricEnroll
    case biometricUnenroll
    case biometricMatch
    case biometricFail
    case biometricIsEnrolled

    // Logs & permissions
    case getLogs(bundleId: String?, lines: Int)
    case setPermission(action: String, service: String, bundleId: String)

    // Device orientation & state
    case rotate(direction: String)
    case lockDevice
    case unlockDevice
    case resetKeychain

    // Screen recording
    case startRecording
    case stopRecording(outputPath: String)

    // Location & appearance
    case setLocation(latitude: Double, longitude: Double)
    case setAppearance(mode: String)

    // File transfer
    case pushFile(localPath: String, remotePath: String)
    case pullFile(remotePath: String, localPath: String)

    // Viewport
    case viewport

    /// El ActionKind correspondiente a esta acción.
    public var kind: ActionKind {
        switch self {
        case .tree: return .tree
        case .search: return .search
        case .elementAt: return .elementAt
        case .tap: return .tap
        case .doubleTap: return .doubleTap
        case .longPress: return .longPress
        case .tapAtCoordinate: return .tapAtCoordinate
        case .drag: return .drag
        case .dragCoordinates: return .dragCoordinates
        case .typeText: return .typeText
        case .clear: return .clear
        case .eraseText: return .eraseText
        case .pressKey: return .pressKey
        case .hideKeyboard: return .hideKeyboard
        case .copyTextFrom: return .copyTextFrom
        case .scroll: return .scroll
        case .swipe: return .swipe
        case .scrollTo: return .scrollTo
        case .launchApp: return .launchApp
        case .terminateApp: return .terminateApp
        case .clearState: return .clearState
        case .uninstallApp: return .uninstallApp
        case .listDevices: return .listDevices
        case .bootDevice: return .bootDevice
        case .shutdownDevice: return .shutdownDevice
        case .installApp: return .installApp
        case .getBootedDeviceId: return .getBootedDeviceId
        case .screenshot: return .screenshot
        case .addMedia: return .addMedia
        case .openURL: return .openURL
        case .setPasteboard: return .setPasteboard
        case .getPasteboard: return .getPasteboard
        case .biometricEnroll: return .biometricEnroll
        case .biometricUnenroll: return .biometricUnenroll
        case .biometricMatch: return .biometricMatch
        case .biometricFail: return .biometricFail
        case .biometricIsEnrolled: return .biometricIsEnrolled
        case .getLogs: return .getLogs
        case .setPermission: return .setPermission
        case .rotate: return .rotate
        case .lockDevice: return .lockDevice
        case .unlockDevice: return .unlockDevice
        case .resetKeychain: return .resetKeychain
        case .startRecording: return .startRecording
        case .stopRecording: return .stopRecording
        case .setLocation: return .setLocation
        case .setAppearance: return .setAppearance
        case .pushFile: return .pushFile
        case .pullFile: return .pullFile
        case .viewport: return .viewport
        }
    }
}

// MARK: - ActionResult

/// Resultado tipado de ejecutar una acción.
public enum ActionResult {
    case void
    case text(String)
    case elements([[String: Any]])
    case deviceList([[String: Any]])
    case bool(Bool)
    case rect(CGRect)
    case element([String: Any])
    case deviceId(String)
    case logs(String)
}

// MARK: - Backend protocol

/// Un backend declara sus capabilities y ejecuta acciones dentro de ellas.
/// No implementa lo que no sabe hacer — simplemente no lo declara.
public protocol Backend: AnyObject, Sendable {
    var capabilities: Set<ActionKind> { get }
    func execute(_ action: Action) async throws -> ActionResult
}
