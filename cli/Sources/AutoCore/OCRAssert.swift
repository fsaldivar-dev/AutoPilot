import CoreGraphics
import Foundation
import ImageIO
import Vision

// OCRAssert — verificación visual de texto via Vision.framework (#55).
//
// Vision corre en el Mac, NO en el device: opera sobre el PNG que produce
// `bridge.screenshot`, por eso el mismo código sirve para iOS (simctl) y
// Android (agente/adb). AutoCore compila solo para macOS (Package.swift:
// platforms .macOS(.v13)), así que importar Vision acá no ensucia ningún
// target — es un framework de sistema, no una dependencia externa.
//
// Complementa los asserts del árbol AX (`exists`, `hasText`, `waitFor`)
// para casos donde el texto solo existe en píxeles: canvas, webviews,
// imágenes, custom views sin accesibilidad.
public enum OCRAssert {

    /// Un string reconocido por el OCR con su confianza (0.0–1.0).
    public struct RecognizedText {
        public let string: String
        public let confidence: Float

        public init(string: String, confidence: Float) {
            self.string = string
            self.confidence = confidence
        }
    }

    /// Región de recorte en píxeles del screenshot, origen arriba-izquierda.
    /// Nota: son píxeles de la imagen (retina 2x/3x en iOS), no puntos.
    public struct Region: Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// Parsea "x,y,w,h" → Region. Throws `BridgeError.invalidRegion`
        /// si el formato no es 4 enteros o width/height no son positivos.
        public static func parse(_ raw: String) throws -> Region {
            let parts = raw.split(separator: ",").map {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 4,
                  let x = parts[0], let y = parts[1],
                  let w = parts[2], let h = parts[3],
                  w > 0, h > 0 else {
                throw BridgeError.invalidRegion(raw)
            }
            return Region(x: x, y: y, width: w, height: h)
        }
    }

    /// Corre `VNRecognizeTextRequest` (accurate, es+en) sobre la imagen en
    /// `imagePath`. Si `region` != nil, recorta antes del OCR con
    /// CoreGraphics (coordenadas en píxeles, origen arriba-izquierda).
    public static func recognizeText(
        imagePath: String,
        region: Region? = nil
    ) throws -> [RecognizedText] {
        let url = URL(fileURLWithPath: imagePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BridgeError.unknown("assertOCR: could not load image at '\(imagePath)'")
        }

        if let region {
            let rect = CGRect(x: region.x, y: region.y,
                              width: region.width, height: region.height)
            guard let cropped = image.cropping(to: rect) else {
                throw BridgeError.invalidRegion(
                    "\(region.x),\(region.y),\(region.width),\(region.height) " +
                    "(image is \(image.width)x\(image.height)px)"
                )
            }
            image = cropped
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(string: candidate.string,
                                  confidence: candidate.confidence)
        }
    }

    /// Match case-insensitive `contains` de `needle` sobre los textos
    /// reconocidos. Devuelve el match (con su confianza) o nil.
    ///
    /// Si ningún string individual matchea, intenta sobre el texto completo
    /// unido con espacios — cubre frases que Vision parte en varias
    /// observaciones (misma línea visual, columnas, etc.). En ese caso la
    /// confianza reportada es la mínima de las observaciones involucradas.
    public static func findMatch(
        for needle: String,
        in texts: [RecognizedText]
    ) -> RecognizedText? {
        let target = needle.lowercased()
        guard !target.isEmpty else { return nil }

        if let hit = texts.first(where: { $0.string.lowercased().contains(target) }) {
            return hit
        }

        let joined = texts.map(\.string).joined(separator: " ")
        if joined.lowercased().contains(target) {
            let minConfidence = texts.map(\.confidence).min() ?? 0
            return RecognizedText(string: joined, confidence: minConfidence)
        }
        return nil
    }
}
