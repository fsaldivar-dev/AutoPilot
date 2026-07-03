import Foundation

public enum BridgeError: Error, CustomStringConvertible {
    case simulatorNotRunning
    case noWindow
    case accessibilityNotTrusted
    case elementNotFound(String)
    case noFrame(String)
    case noBootedDevice
    case invalidDirection(String)
    case screenshotFailed
    case mediaInjectionFailed(String)
    case appleScriptFailed(String)
    case simctlFailed(String)
    case deviceNotFound(String)
    case cameraImageNotFound(String)
    case adbNotFound
    case adbFailed(String)
    /// El backend no pudo CONECTARSE a su proceso remoto (socket muerto,
    /// agente caído, observer no cargado). Distinto de `elementNotFound`:
    /// el ActionRouter degrada al siguiente backend en vez de abortar (#154).
    case connectionFailed(String)
    /// Error reportado por el agente nativo (no por adb) — prefijo "Agent error:" (#162).
    case agentFailed(String)
    case uiAutomationBusy
    case avdNotFound(String, [String])
    case eventTapFailed
    case timeout(String)
    case recordingAlreadyInProgress(String)
    case noRecordingInProgress
    case imageDecodeFailed(String)
    case baselineNotFound(String)
    case screenMismatch(distance: Int, tolerance: Int)
    case invalidRegion(String)
    case ocrTextNotFound(expected: String, recognized: [String])
    case unknown(String)

    /// Nombre del binario CLI en ejecución ("auto" iOS / "auto-android").
    /// Lo setea el main de cada plataforma al arrancar — los mensajes
    /// accionables lo usan para no sugerir el binario equivocado (#162).
    public static var binaryName = "auto"

    /// Detecta mensajes "element not found: X" / "Element not found: 'X'" que
    /// ya vienen formateados del runner XCUI o del agente Android y los
    /// convierte al caso tipado con el target desnudo. Sin esto el CLI
    /// duplicaba el prefijo: "Element not found: 'element not found: X'" (#162).
    /// Devuelve nil si el mensaje no es un element-not-found.
    public static func unwrapElementNotFound(_ message: String) -> BridgeError? {
        let prefix = "element not found"
        guard message.lowercased().hasPrefix(prefix) else { return nil }
        var target = String(message.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        if target.hasPrefix(":") {
            target = String(target.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if target.count >= 2, target.hasPrefix("'"), target.hasSuffix("'") {
            target = String(target.dropFirst().dropLast())
        }
        return .elementNotFound(target.isEmpty ? message : target)
    }

    public var description: String {
        switch self {
        case .simulatorNotRunning: return "Simulator is not running. Open it first."
        case .noWindow: return "No simulator window found. Is the Simulator open?"
        case .accessibilityNotTrusted: return "Accessibility permission denied. Grant access in: System Settings → Privacy & Security → Accessibility. Add Terminal (or the app running this command)."
        case .elementNotFound(let t):
            return "Element not found: '\(t)'\n"
                + "Tip: explora la pantalla con `\(Self.binaryName) layout` o `\(Self.binaryName) tree -s \"<texto>\"`"
        case .noFrame(let t): return "Element '\(t)' has no frame"
        case .noBootedDevice: return "No booted simulator. Run: xcrun simctl boot <device>"
        case .invalidDirection(let d): return "Invalid direction: \(d). Use up/down/left/right"
        case .screenshotFailed: return "Screenshot failed"
        case .mediaInjectionFailed(let p): return "Failed to inject media: \(p)"
        case .appleScriptFailed(let msg): return "AppleScript failed: \(msg)"
        case .simctlFailed(let msg): return "simctl failed: \(msg)"
        case .deviceNotFound(let name): return "Device not found: '\(name)'. Run: auto list"
        case .cameraImageNotFound(let p): return "Image not found: '\(p)'"
        case .adbNotFound: return "ADB not found. Set ANDROID_HOME or add adb to PATH."
        case .adbFailed(let msg): return "ADB failed: \(msg)"
        case .connectionFailed(let msg): return msg
        case .agentFailed(let msg): return "Agent error: \(msg)"
        case .uiAutomationBusy: return """
            El agente AutoPilot retiene la conexion UiAutomation (Android solo permite \
            un cliente a la vez), por lo que 'uiautomator dump' devuelve vacio.
            Para usar --legacy tree/tap deten el agente primero:
              auto-android agent stop   (o: adb shell am force-stop dev.autopilot.agent)
            Reactivalo despues con: auto-android agent start
            """
        case .avdNotFound(let name, let avds):
            let list = avds.isEmpty
                ? "(none — create one with Android Studio or avdmanager)"
                : avds.joined(separator: ", ")
            return "AVD not found: '\(name)'. Available AVDs: \(list)"
        case .eventTapFailed: return "CGEventTap creation failed. Grant Accessibility permissions in: System Settings > Privacy & Security > Accessibility."
        case .timeout(let msg): return msg
        case .recordingAlreadyInProgress(let device): return "Recording already in progress on '\(device)'. Run stopRecording first."
        case .noRecordingInProgress: return "No recording in progress. Run startRecording first."
        case .imageDecodeFailed(let p): return "Cannot decode image: '\(p)'"
        case .baselineNotFound(let p): return "Baseline not found: '\(p)'. Create it with: assertScreen \(p) --create"
        case .screenMismatch(let d, let t): return "MISMATCH (distance \(d)/\(PerceptualHash.bits), tolerance \(t))"
        case .invalidRegion(let raw): return "Invalid region: '\(raw)'. Use --region x,y,w,h (pixels, positive width/height)"
        case .ocrTextNotFound(let expected, let recognized):
            if recognized.isEmpty {
                return "OCR: '\(expected)' not found — no text recognized in screenshot"
            }
            let top = recognized.prefix(10).map { "  '\($0)'" }.joined(separator: "\n")
            return "OCR: '\(expected)' not found. Recognized text (top \(min(10, recognized.count))):\n\(top)"
        case .unknown(let msg): return msg
        }
    }
}
