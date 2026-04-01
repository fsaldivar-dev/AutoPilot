import Foundation
import AVFoundation
import UIKit
import ObjectiveC

// Ruta de la imagen inyectada
private let kFeedImagePath = "/tmp/autopilot-camera-feed.jpg"
private let kSignalPath = "/tmp/autopilot-camera-active"

// Store para retener objetos entre llamadas
private var activeDelegate: AnyObject?
private var activeOutput: AnyObject?

// MARK: - Inicializacion (se ejecuta cuando la dylib se carga)

@_cdecl("AutoPilotCameraInit")
public func autoPilotCameraInit() {
    swizzleAll()
}

// Constructor automatico — se ejecuta al cargar la dylib
private let __autoPilotInit: Bool = {
    NSLog("[AutoPilot Swift] Dylib cargada — iniciando swizzle")
    swizzleAll()
    return true
}()

// Forzar la inicializacion
@_cdecl("_autopilot_force_init")
public func forceInit() { _ = __autoPilotInit }

// MARK: - Swizzle

private func swizzleAll() {
    swizzleAuthorizationStatus()
    swizzleRequestAccess()
    swizzleStartRunning()
    swizzleCapturePhoto()
    swizzleCanAddInput()
    swizzleCanAddOutput()
    swizzleDefaultDevice()
    swizzleAddInput()
    NSLog("[AutoPilot Swift] Swizzle completo")
}

// MARK: - authorizationStatus

private func swizzleAuthorizationStatus() {
    let original = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.authorizationStatus(for:)))!
    let replacement = class_getClassMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_authorizationStatus(for:)))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - requestAccess

private func swizzleRequestAccess() {
    let original = class_getClassMethod(AVCaptureDevice.self, #selector(AVCaptureDevice.requestAccess(for:completionHandler:)))!
    let replacement = class_getClassMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_requestAccess(for:completionHandler:)))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - startRunning

private func swizzleStartRunning() {
    let original = class_getInstanceMethod(AVCaptureSession.self, #selector(AVCaptureSession.startRunning))!
    let replacement = class_getInstanceMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_startRunning))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - canAddInput / canAddOutput

private func swizzleCanAddInput() {
    let original = class_getInstanceMethod(AVCaptureSession.self, #selector(AVCaptureSession.canAddInput(_:)))!
    let replacement = class_getInstanceMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_canAddInput(_:)))!
    method_exchangeImplementations(original, replacement)
}

private func swizzleCanAddOutput() {
    let original = class_getInstanceMethod(AVCaptureSession.self, #selector(AVCaptureSession.canAddOutput(_:)))!
    let replacement = class_getInstanceMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_canAddOutput(_:)))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - AVCaptureSession.addInput — aceptar cualquier input

private func swizzleAddInput() {
    let original = class_getInstanceMethod(AVCaptureSession.self, #selector(AVCaptureSession.addInput(_:)))!
    let replacement = class_getInstanceMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_addInput(_:)))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - AVCaptureDevice.default — retornar device falso

private func swizzleDefaultDevice() {
    // Swizzle default(_:for:position:) via selector string
    // El selector ObjC es: defaultDeviceWithDeviceType:mediaType:position:
    let sel = NSSelectorFromString("defaultDeviceWithDeviceType:mediaType:position:")
    guard let original = class_getClassMethod(AVCaptureDevice.self, sel) else {
        NSLog("[AutoPilot Swift] No se encontro defaultDeviceWithDeviceType:mediaType:position:")
        return
    }
    let mockSel = #selector(AutoPilotSwizzle.mock_defaultDevice(type:mediaType:position:))
    guard let replacement = class_getClassMethod(AutoPilotSwizzle.self, mockSel) else {
        NSLog("[AutoPilot Swift] No se encontro mock_defaultDevice")
        return
    }
    method_exchangeImplementations(original, replacement)
}

// MARK: - capturePhoto — la pieza clave

private func swizzleCapturePhoto() {
    let original = class_getInstanceMethod(AVCapturePhotoOutput.self, #selector(AVCapturePhotoOutput.capturePhoto(with:delegate:)))!
    let replacement = class_getInstanceMethod(AutoPilotSwizzle.self, #selector(AutoPilotSwizzle.mock_capturePhoto(with:delegate:)))!
    method_exchangeImplementations(original, replacement)
}

// MARK: - Swizzle implementations

class AutoPilotSwizzle: NSObject {

    @objc dynamic class func mock_authorizationStatus(for mediaType: AVMediaType) -> AVAuthorizationStatus {
        if mediaType == .video {
            NSLog("[AutoPilot Swift] authorizationStatus(.video) -> .authorized")
            return .authorized
        }
        // Llamar al original (que ahora es nuestro metodo por el exchange)
        return mock_authorizationStatus(for: mediaType)
    }

    @objc dynamic class func mock_requestAccess(for mediaType: AVMediaType, completionHandler: @escaping (Bool) -> Void) {
        if mediaType == .video {
            NSLog("[AutoPilot Swift] requestAccess(.video) -> true")
            completionHandler(true)
            return
        }
        mock_requestAccess(for: mediaType, completionHandler: completionHandler)
    }

    @objc dynamic func mock_startRunning() {
        NSLog("[AutoPilot Swift] startRunning interceptado — no iniciando session real")
    }

    @objc dynamic class func mock_defaultDevice(type: AVCaptureDevice.DeviceType, mediaType: AVMediaType, position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Llamar original
        let device = mock_defaultDevice(type: type, mediaType: mediaType, position: position)
        if device != nil { return device }

        if mediaType == .video {
            NSLog("[AutoPilot Swift] default device nil — creando device falso via runtime")
            // Crear instancia via runtime (bypass de init privado)
            guard let cls = NSClassFromString("AVCaptureDevice"),
                  let instance = class_createInstance(cls, 0) else {
                NSLog("[AutoPilot Swift] No se pudo crear AVCaptureDevice")
                return nil
            }
            return unsafeBitCast(instance, to: AVCaptureDevice.self)
        }
        return nil
    }

    @objc dynamic func mock_addInput(_ input: AVCaptureInput) {
        NSLog("[AutoPilot Swift] addInput interceptado — aceptando sin validar")
        // No llamar al original — evita crash con device falso
    }

    @objc dynamic func mock_canAddInput(_ input: AVCaptureInput) -> Bool {
        NSLog("[AutoPilot Swift] canAddInput -> true")
        return true
    }

    @objc dynamic func mock_canAddOutput(_ output: AVCaptureOutput) -> Bool {
        NSLog("[AutoPilot Swift] canAddOutput -> true")
        return true
    }

    @objc dynamic func mock_capturePhoto(with settings: AVCapturePhotoSettings, delegate: any AVCapturePhotoCaptureDelegate) {
        NSLog("[AutoPilot Swift] capturePhoto interceptado!")

        // Buscar imagen: primero env var, luego archivo signal
        let envPath = ProcessInfo.processInfo.environment["AUTOPILOT_CAMERA_IMAGE"]
        let signalExists = FileManager.default.fileExists(atPath: kSignalPath)

        let imagePath = envPath ?? (signalExists ? kFeedImagePath : nil)

        guard let path = imagePath,
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            NSLog("[AutoPilot Swift] No hay imagen para inyectar (path: %@)", imagePath ?? "nil")
            return
        }

        NSLog("[AutoPilot Swift] Imagen cargada: %d bytes desde %@", imageData.count, path)

        // Crear AVCapturePhoto falso via runtime
        // Swizzleamos fileDataRepresentation ANTES de crear la instancia
        swizzleFileDataRepresentation(with: imageData)

        // Crear instancia via runtime (bypass de init unavailable)
        guard let photoClass = NSClassFromString("AVCapturePhoto"),
              let instance = class_createInstance(photoClass, 0) else {
            NSLog("[AutoPilot Swift] No se pudo crear instancia de AVCapturePhoto")
            return
        }

        let fakePhoto = unsafeBitCast(instance, to: AVCapturePhoto.self)
        let output = unsafeBitCast(self, to: AVCapturePhotoOutput.self)

        // Retener referencias
        activeDelegate = delegate as AnyObject
        activeOutput = output

        NSLog("[AutoPilot Swift] Llamando delegate.photoOutput(didFinishProcessingPhoto)")

        DispatchQueue.main.async {
            delegate.photoOutput?(output, didFinishProcessingPhoto: fakePhoto, error: nil)
            NSLog("[AutoPilot Swift] Delegate invocado exitosamente!")
        }
    }
}

// MARK: - Swizzle fileDataRepresentation

private var injectedImageData: Data?

private func swizzleFileDataRepresentation(with data: Data) {
    injectedImageData = data

    // Solo swizzlear una vez
    struct Once { static var token = false }
    guard !Once.token else { return }
    Once.token = true

    let sel = NSSelectorFromString("fileDataRepresentation")
    guard let original = class_getInstanceMethod(AVCapturePhoto.self, sel) else {
        NSLog("[AutoPilot Swift] No se encontro fileDataRepresentation")
        return
    }

    let block: @convention(block) (AnyObject) -> Data? = { _ in
        NSLog("[AutoPilot Swift] fileDataRepresentation -> %d bytes", injectedImageData?.count ?? 0)
        return injectedImageData
    }

    let imp = imp_implementationWithBlock(block)
    method_setImplementation(original, imp)
    NSLog("[AutoPilot Swift] fileDataRepresentation swizzleado")
}
