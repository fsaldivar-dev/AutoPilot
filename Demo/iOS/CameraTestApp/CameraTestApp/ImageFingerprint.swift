import UIKit
import CryptoKit

/// Huella verificable de una imagen capturada, para que los tests de cámara
/// puedan comprobar que la imagen INYECTADA correcta llegó — no solo que se
/// capturó "algo". Antes los tabs de captura mostraban "(N bytes)", que no
/// distingue foto-1.jpg de una imagen negra del mismo peso.
///
/// Formato: "1512×2016 · sha 3a7f9c2b"
///   - dimensiones (ancho×alto): verifican tamaño (distingue de imagen vacía)
///   - hash: primeros 8 hex de SHA256 de los bytes — verifica que es
///     EXACTAMENTE esa imagen (distingue foto-1 de foto-2)
///
/// El test lo assertará con waitFor "1512×2016" o waitFor "sha 3a7f9c2b",
/// igual que QR/OCR verifican su contenido reconocido.
enum ImageFingerprint {
    static func of(_ image: UIImage, data: Data) -> String {
        let w = Int(image.size.width * image.scale)
        let h = Int(image.size.height * image.scale)
        let digest = SHA256.hash(data: data)
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(w)×\(h) · sha \(hex)"
    }
}
