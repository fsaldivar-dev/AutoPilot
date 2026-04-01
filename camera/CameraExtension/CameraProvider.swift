import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

let logger = Logger(subsystem: "dev.autopilot.camera", category: "Extension")

// Ruta donde el CLI escribe la imagen a transmitir
let kFeedImagePath = "/tmp/autopilot-camera-feed.jpg"
// Archivo signal — si existe, la camara esta activa
let kFeedSignalPath = "/tmp/autopilot-camera-active"

class CameraProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "AutoPilot Camera")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("No se pudo agregar el dispositivo: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        logger.info("Cliente conectado")
    }

    func disconnect(from client: CMIOExtensionClient) {
        logger.info("Cliente desconectado")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "AutoPilot"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // Solo lectura
    }
}
