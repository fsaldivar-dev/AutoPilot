import Foundation

/// Configuracion central — lee variables de entorno de AutoPilot.
public enum AutoPilotConfig {

    /// Hay imagen de camara inyectada?
    public static var isMockEnabled: Bool {
        return cameraImagePath != nil || qrCode != nil
    }

    /// Ruta a la imagen inyectada para camara
    public static var cameraImagePath: String? {
        return ProcessInfo.processInfo.environment["AUTOPILOT_CAMERA_IMAGE"]
    }

    /// Codigo QR inyectado
    public static var qrCode: String? {
        return ProcessInfo.processInfo.environment["AUTOPILOT_QR_CODE"]
    }

    /// Carga la imagen inyectada como Data
    public static func loadInjectedImage() -> Data? {
        guard let path = cameraImagePath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
