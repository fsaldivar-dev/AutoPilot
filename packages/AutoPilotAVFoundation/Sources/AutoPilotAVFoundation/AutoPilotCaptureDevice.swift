import Foundation
import AVFoundation

/// Reemplazo de AVCaptureDevice para simulador.
/// Siempre reporta camara disponible cuando hay env var.
public class AutoPilotCaptureDevice: NSObject {

    public let position: AVCaptureDevice.Position
    public let deviceType: AVCaptureDevice.DeviceType

    private init(type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) {
        self.deviceType = type
        self.position = position
        super.init()
    }

    /// Misma firma que AVCaptureDevice.default(_:for:position:)
    public static func `default`(
        _ type: AVCaptureDevice.DeviceType,
        for mediaType: AVMediaType,
        position: AVCaptureDevice.Position
    ) -> AutoPilotCaptureDevice? {
        // Si hay env var, siempre retornar un device
        if AutoPilotConfig.isMockEnabled {
            NSLog("[AutoPilot] CaptureDevice.default → device virtual")
            return AutoPilotCaptureDevice(type: type, position: position)
        }
        // Sin mock, intentar el real
        if let real = AVCaptureDevice.default(type, for: mediaType, position: position) {
            NSLog("[AutoPilot] CaptureDevice.default → device real")
            // Wrappear el real... por ahora retornamos virtual
            return AutoPilotCaptureDevice(type: type, position: position)
        }
        return nil
    }

    /// Misma firma que AVCaptureDevice.authorizationStatus(for:)
    public static func authorizationStatus(for mediaType: AVMediaType) -> AVAuthorizationStatus {
        if AutoPilotConfig.isMockEnabled && mediaType == .video {
            NSLog("[AutoPilot] authorizationStatus → .authorized (mock)")
            return .authorized
        }
        return AVCaptureDevice.authorizationStatus(for: mediaType)
    }

    /// Misma firma que AVCaptureDevice.requestAccess(for:completionHandler:)
    public static func requestAccess(for mediaType: AVMediaType, completionHandler: @escaping (Bool) -> Void) {
        if AutoPilotConfig.isMockEnabled && mediaType == .video {
            NSLog("[AutoPilot] requestAccess → true (mock)")
            completionHandler(true)
            return
        }
        AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completionHandler)
    }
}
