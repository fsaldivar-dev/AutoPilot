import Foundation
import CoreGraphics
import ImageIO

/// Perceptual hash de imágenes via dHash (difference hash) — sin dependencias.
///
/// Algoritmo (#56):
///   1. Decodificar la imagen con ImageIO (corre en el Mac host, no en el device).
///   2. Reducir a 9x8 píxeles en escala de grises (CGContext hace el resampling,
///      lo que promedia regiones y descarta detalle fino — ruido, antialiasing,
///      texto dinámico pequeño).
///   3. Comparar cada píxel con su vecino derecho: brillo sube → bit 1, baja → 0.
///      8 filas x 8 comparaciones = hash de 64 bits.
///   4. Similitud entre dos imágenes = distancia de Hamming entre sus hashes
///      (bits distintos, 0 = idénticas perceptualmente, 64 = opuestas).
///
/// dHash captura el *gradiente* de la imagen, no valores absolutos, así que es
/// robusto a cambios globales de brillo/contraste y a diferencias de resolución.
public enum PerceptualHash {

    /// Bits del hash — 8 filas x 8 diferencias horizontales.
    public static let bits = 64

    /// Calcula el dHash de 64 bits de una imagen en disco (PNG/JPEG/lo que ImageIO soporte).
    public static func dHash(imagePath: String) throws -> UInt64 {
        let url = URL(fileURLWithPath: imagePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BridgeError.imageDecodeFailed(imagePath)
        }
        return try dHash(image: image)
    }

    /// Calcula el dHash de 64 bits de un CGImage ya decodificado.
    public static func dHash(image: CGImage) throws -> UInt64 {
        // 9 columnas → 8 diferencias horizontales por fila.
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // .high usa un filtro que promedia todos los píxeles de origen al
            // reducir — clave para que el hash represente la imagen completa.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw BridgeError.unknown("dHash: failed to create grayscale context")
        }

        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + col] < pixels[row * width + col + 1] {
                    hash |= 1
                }
            }
        }
        return hash
    }

    /// Distancia de Hamming entre dos hashes — cantidad de bits distintos (0-64).
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
