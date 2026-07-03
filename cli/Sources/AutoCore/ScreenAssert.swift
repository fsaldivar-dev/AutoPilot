import Foundation

/// Resultado de comparar un screenshot contra su baseline (#56).
public struct ScreenAssertResult {
    /// Distancia de Hamming entre los dHash (0-64 bits distintos).
    public let distance: Int
    /// Máximo de bits distintos permitido para considerar MATCH.
    public let tolerance: Int

    public var isMatch: Bool { distance <= tolerance }
}

/// Lógica de comparación visual para `assertScreen` — pura, sin tocar el device,
/// para que sea testeable con imágenes sintéticas.
public enum ScreenAssert {

    /// Tolerancia default: 10/64 bits (~84% de similitud). Suficiente para
    /// tolerar texto dinámico (hora, fecha) sin dejar pasar cambios de layout.
    public static let defaultTolerance = 10

    /// Compara dos imágenes en disco por perceptual hash.
    /// - Throws: `BridgeError.baselineNotFound` si el baseline no existe,
    ///           `BridgeError.imageDecodeFailed` si alguna imagen no decodifica.
    public static func compare(
        currentPath: String,
        baselinePath: String,
        tolerance: Int = defaultTolerance
    ) throws -> ScreenAssertResult {
        guard FileManager.default.fileExists(atPath: baselinePath) else {
            throw BridgeError.baselineNotFound(baselinePath)
        }
        let baselineHash = try PerceptualHash.dHash(imagePath: baselinePath)
        let currentHash = try PerceptualHash.dHash(imagePath: currentPath)
        let distance = PerceptualHash.hammingDistance(baselineHash, currentHash)
        return ScreenAssertResult(distance: distance, tolerance: tolerance)
    }

    /// Compara y lanza `BridgeError.screenMismatch` si supera la tolerancia.
    @discardableResult
    public static func assertMatch(
        currentPath: String,
        baselinePath: String,
        tolerance: Int = defaultTolerance
    ) throws -> ScreenAssertResult {
        let result = try compare(
            currentPath: currentPath,
            baselinePath: baselinePath,
            tolerance: tolerance
        )
        guard result.isMatch else {
            throw BridgeError.screenMismatch(distance: result.distance, tolerance: tolerance)
        }
        return result
    }
}
