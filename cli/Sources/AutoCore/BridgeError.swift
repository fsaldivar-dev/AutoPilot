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
    case avdNotFound(String, [String])
    case eventTapFailed
    case timeout(String)
    case recordingAlreadyInProgress(String)
    case noRecordingInProgress
    case invalidRegion(String)
    case ocrTextNotFound(expected: String, recognized: [String])
    case unknown(String)

    public var description: String {
        switch self {
        case .simulatorNotRunning: return "Simulator is not running. Open it first."
        case .noWindow: return "No simulator window found. Is the Simulator open?"
        case .accessibilityNotTrusted: return "Accessibility permission denied. Grant access in: System Settings → Privacy & Security → Accessibility. Add Terminal (or the app running this command)."
        case .elementNotFound(let t): return "Element not found: '\(t)'"
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
        case .avdNotFound(let name, let avds):
            let list = avds.isEmpty
                ? "(none — create one with Android Studio or avdmanager)"
                : avds.joined(separator: ", ")
            return "AVD not found: '\(name)'. Available AVDs: \(list)"
        case .eventTapFailed: return "CGEventTap creation failed. Grant Accessibility permissions in: System Settings > Privacy & Security > Accessibility."
        case .timeout(let msg): return msg
        case .recordingAlreadyInProgress(let device): return "Recording already in progress on '\(device)'. Run stopRecording first."
        case .noRecordingInProgress: return "No recording in progress. Run startRecording first."
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
