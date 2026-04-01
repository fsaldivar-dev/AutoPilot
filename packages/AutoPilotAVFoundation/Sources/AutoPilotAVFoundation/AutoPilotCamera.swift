import Foundation
import AVFoundation
import UIKit
import ObjectiveC

/// AutoPilotCamera — se inicializa automaticamente al importar el modulo.
/// Swizzlea AVFoundation para inyectar imagenes como camara en CI/CD.
///
/// Solo se activa si AUTOPILOT_CAMERA_IMAGE o AUTOPILOT_QR_CODE estan seteados.
/// En dispositivo fisico o sin env vars, no hace nada.
public enum AutoPilotCamera {

    static let cameraImagePath = ProcessInfo.processInfo.environment["AUTOPILOT_CAMERA_IMAGE"]
    static let qrCode = ProcessInfo.processInfo.environment["AUTOPILOT_QR_CODE"]

    public static let isEnabled: Bool = {
        return cameraImagePath != nil || qrCode != nil
    }()

    /// Callback registrado por la app para recibir fotos inyectadas
    public static var onPhotoCaptured: ((UIImage) -> Void)?

    /// Llamar desde el app para forzar la inicializacion del modulo
    public static func activate() {
        guard isEnabled else {
            NSLog("[AutoPilot] No env vars — modo passthrough")
            return
        }
        NSLog("[AutoPilot] Activando mock de camara")
        Swizzler.swizzleAll()
    }
}


// MARK: - Swizzler

private enum Swizzler {

    static func swizzleAll() {
        swizzleAuthorizationStatus()
        swizzleRequestAccess()
        swizzleStartRunning()
        swizzleCapturePhoto()
        NSLog("[AutoPilot] Swizzle completo")
    }

    // MARK: authorizationStatus -> .authorized

    static func swizzleAuthorizationStatus() {
        let original = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.authorizationStatus(for:)))!
        let swizzled = class_getClassMethod(SwizzleTarget.self, #selector(SwizzleTarget.ap_authorizationStatus(for:)))!
        method_exchangeImplementations(original, swizzled)
    }

    // MARK: requestAccess -> true

    static func swizzleRequestAccess() {
        let original = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.requestAccess(for:completionHandler:)))!
        let swizzled = class_getClassMethod(SwizzleTarget.self, #selector(SwizzleTarget.ap_requestAccess(for:completionHandler:)))!
        method_exchangeImplementations(original, swizzled)
    }

    // MARK: startRunning -> no-op (evita crash sin hardware)

    static func swizzleStartRunning() {
        let original = class_getInstanceMethod(AVCaptureSession.self, #selector(AVCaptureSession.startRunning))!
        let swizzled = class_getInstanceMethod(SwizzleTarget.self, #selector(SwizzleTarget.ap_startRunning))!
        method_exchangeImplementations(original, swizzled)
    }

    // MARK: capturePhoto -> inyectar imagen

    static func swizzleCapturePhoto() {
        let original = class_getInstanceMethod(
            AVCapturePhotoOutput.self,
            #selector(AVCapturePhotoOutput.capturePhoto(with:delegate:))
        )!
        let swizzled = class_getInstanceMethod(
            SwizzleTarget.self,
            #selector(SwizzleTarget.ap_capturePhoto(with:delegate:))
        )!
        method_exchangeImplementations(original, swizzled)
    }
}

// MARK: - Swizzle implementations

private class SwizzleTarget: NSObject {

    @objc dynamic class func ap_authorizationStatus(for mediaType: AVMediaType) -> AVAuthorizationStatus {
        if mediaType == .video && AutoPilotCamera.isEnabled {
            NSLog("[AutoPilot] authorizationStatus(.video) -> .authorized")
            return .authorized
        }
        // Llamar al original (intercambiado)
        return ap_authorizationStatus(for: mediaType)
    }

    @objc dynamic class func ap_requestAccess(for mediaType: AVMediaType, completionHandler: @escaping (Bool) -> Void) {
        if mediaType == .video && AutoPilotCamera.isEnabled {
            NSLog("[AutoPilot] requestAccess(.video) -> true")
            completionHandler(true)
            return
        }
        ap_requestAccess(for: mediaType, completionHandler: completionHandler)
    }

    @objc dynamic func ap_startRunning() {
        if AutoPilotCamera.isEnabled {
            NSLog("[AutoPilot] startRunning -> no-op (mock activo)")
            return
        }
        ap_startRunning() // original
    }

    @objc dynamic func ap_capturePhoto(with settings: AVCapturePhotoSettings, delegate: any AVCapturePhotoCaptureDelegate) {
        guard AutoPilotCamera.isEnabled,
              let path = AutoPilotCamera.cameraImagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = UIImage(data: data) else {
            NSLog("[AutoPilot] capturePhoto -> sin imagen, pasando al original")
            ap_capturePhoto(with: settings, delegate: delegate) // original
            return
        }

        NSLog("[AutoPilot] capturePhoto -> inyectando imagen (%d bytes)", data.count)

        // Usar el callback registrado por la app
        if let callback = AutoPilotCamera.onPhotoCaptured {
            NSLog("[AutoPilot] Invocando callback registrado")
            DispatchQueue.main.async {
                callback(image)
            }
            return
        }

        NSLog("[AutoPilot] No hay callback registrado — usa AutoPilotCamera.onPhotoCaptured")
    }
}
