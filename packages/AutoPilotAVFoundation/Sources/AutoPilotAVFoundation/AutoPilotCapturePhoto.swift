import Foundation

/// Reemplazo de AVCapturePhoto — misma interfaz, implementacion controlada.
/// Cuando hay imagen inyectada, fileDataRepresentation() retorna esa imagen.
/// Cuando no hay, se comporta como wrapper del real.
public class AutoPilotCapturePhoto: NSObject {

    private let imageData: Data?

    public init(imageData: Data?) {
        self.imageData = imageData
        super.init()
    }

    /// Misma firma que AVCapturePhoto.fileDataRepresentation()
    public func fileDataRepresentation() -> Data? {
        if let data = imageData {
            NSLog("[AutoPilot] fileDataRepresentation → imagen inyectada (%d bytes)", data.count)
            return data
        }
        NSLog("[AutoPilot] fileDataRepresentation → sin imagen")
        return nil
    }
}
