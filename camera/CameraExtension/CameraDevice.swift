import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraStreamSource!

    init(localizedName: String) {
        super.init()

        let deviceID = UUID()
        streamSource = CameraStreamSource(localizedName: "AutoPilot Feed")

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        do {
            try device.addStream(streamSource.stream)
        } catch {
            logger.error("No se pudo agregar el stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "AutoPilot Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // Solo lectura
    }

    func startStreaming() {
        logger.info("Iniciando streaming")
        streamSource.startStreaming()
    }

    func stopStreaming() {
        logger.info("Deteniendo streaming")
        streamSource.stopStreaming()
    }
}
