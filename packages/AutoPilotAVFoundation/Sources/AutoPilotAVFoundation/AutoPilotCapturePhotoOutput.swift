import Foundation
import AVFoundation

/// Protocolo identico a AVCapturePhotoCaptureDelegate
public protocol AutoPilotPhotoCaptureDelegate: AnyObject {
    func photoOutput(
        _ output: AutoPilotCapturePhotoOutput,
        didFinishProcessingPhoto photo: AutoPilotCapturePhoto,
        error: Error?
    )
}

/// Reemplazo de AVCapturePhotoOutput.
/// En modo mock, capturePhoto() carga la imagen inyectada y llama al delegate.
public class AutoPilotCapturePhotoOutput: NSObject {

    public var supportedFlashModes: [AVCaptureDevice.FlashMode] {
        return [.off, .on, .auto]
    }

    public override init() {
        super.init()
    }

    public func capturePhoto(with settings: AutoPilotCapturePhotoSettings, delegate: AutoPilotPhotoCaptureDelegate) {
        if AutoPilotConfig.isMockEnabled, let imageData = AutoPilotConfig.loadInjectedImage() {
            NSLog("[AutoPilot] capturePhoto → inyectando imagen (%d bytes)", imageData.count)
            let photo = AutoPilotCapturePhoto(imageData: imageData)
            DispatchQueue.main.async {
                delegate.photoOutput(self, didFinishProcessingPhoto: photo, error: nil)
            }
            return
        }
        NSLog("[AutoPilot] capturePhoto → sin imagen inyectada")
    }
}

/// Reemplazo de AVCapturePhotoSettings
public class AutoPilotCapturePhotoSettings: NSObject {
    public var flashMode: AVCaptureDevice.FlashMode = .off

    public override init() {
        super.init()
    }
}

/// Reemplazo de AVCaptureDeviceInput
public class AutoPilotCaptureDeviceInput: NSObject {

    public let device: AutoPilotCaptureDevice

    public init(device: AutoPilotCaptureDevice) throws {
        self.device = device
        super.init()
    }
}
