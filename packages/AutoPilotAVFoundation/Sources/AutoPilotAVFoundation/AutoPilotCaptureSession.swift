import Foundation
import AVFoundation

/// Reemplazo de AVCaptureSession.
/// En modo mock, simula una session activa sin hardware.
public class AutoPilotCaptureSession: NSObject {

    public var sessionPreset: AVCaptureSession.Preset = .photo
    private(set) public var isRunning = false
    private(set) public var inputs: [Any] = []
    private(set) public var outputs: [Any] = []

    public override init() {
        super.init()
    }

    public func beginConfiguration() {}
    public func commitConfiguration() {}

    public func canAddInput(_ input: Any) -> Bool {
        return true
    }

    public func addInput(_ input: Any) {
        inputs.append(input)
    }

    public func removeInput(_ input: Any) {
        inputs.removeAll()
    }

    public func canAddOutput(_ output: Any) -> Bool {
        return true
    }

    public func addOutput(_ output: Any) {
        outputs.append(output)
    }

    public func startRunning() {
        NSLog("[AutoPilot] Session.startRunning (mock=%d)", AutoPilotConfig.isMockEnabled)
        isRunning = true
    }

    public func stopRunning() {
        isRunning = false
    }
}
