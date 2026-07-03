import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import AutoCore

// Tests de OCRAssert (#55) — sin device: generamos la imagen con texto
// dibujado via CoreGraphics/CoreText y verificamos que Vision lo encuentra.
final class OCRAssertTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() {
        for path in tempPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        tempPaths = []
        super.tearDown()
    }

    // MARK: - Image helper

    /// Dibuja `texts` (string + posición en coordenadas CG, origen abajo-izq)
    /// sobre fondo blanco y guarda un PNG temporal. Devuelve el path.
    private func renderImage(
        texts: [(string: String, at: CGPoint)],
        width: Int,
        height: Int,
        fontSize: CGFloat = 36
    ) throws -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BridgeError.unknown("test: CGContext creation failed")
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        for (string, position) in texts {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: black,
            ]
            guard let attrString = CFAttributedStringCreate(
                nil, string as CFString, attrs as CFDictionary
            ) else {
                throw BridgeError.unknown("test: CFAttributedString creation failed")
            }
            let line = CTLineCreateWithAttributedString(attrString)
            ctx.textPosition = position
            CTLineDraw(line, ctx)
        }

        guard let image = ctx.makeImage() else {
            throw BridgeError.unknown("test: makeImage failed")
        }
        let path = NSTemporaryDirectory() + "ocr-test-\(UUID().uuidString).png"
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
        ) else {
            throw BridgeError.unknown("test: CGImageDestination creation failed")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BridgeError.unknown("test: PNG finalize failed")
        }
        tempPaths.append(path)
        return path
    }

    // MARK: - OCR end-to-end (imagen generada → Vision)

    func testRecognizesDrawnText() throws {
        let path = try renderImage(
            texts: [("Operacion exitosa 1299", CGPoint(x: 40, y: 80))],
            width: 640, height: 200
        )
        let recognized = try OCRAssert.recognizeText(imagePath: path)
        XCTAssertFalse(recognized.isEmpty, "Vision should recognize the drawn text")

        // Case-insensitive contains
        let match = OCRAssert.findMatch(for: "operacion EXITOSA", in: recognized)
        XCTAssertNotNil(match, "recognized: \(recognized.map(\.string))")
        XCTAssertGreaterThan(match?.confidence ?? 0, 0.3)

        // Substring numérico (caso precios del issue)
        XCTAssertNotNil(OCRAssert.findMatch(for: "1299", in: recognized))
    }

    func testTextNotDrawnIsNotFound() throws {
        let path = try renderImage(
            texts: [("Bienvenido a AutoPilot", CGPoint(x: 40, y: 80))],
            width: 640, height: 200
        )
        let recognized = try OCRAssert.recognizeText(imagePath: path)
        XCTAssertNil(OCRAssert.findMatch(for: "Error fatal", in: recognized))
        // El error tipado expone lo que SÍ se reconoció para debug
        let err = BridgeError.ocrTextNotFound(
            expected: "Error fatal",
            recognized: recognized.map(\.string)
        )
        XCTAssertTrue(err.description.contains("Error fatal"))
    }

    func testRegionCropsBeforeOCR() throws {
        // "IZQUIERDA" en la mitad izquierda, "DERECHA" en la derecha.
        // Región = mitad izquierda (píxeles, origen arriba-izquierda).
        let path = try renderImage(
            texts: [
                ("IZQUIERDA", CGPoint(x: 40, y: 180)),
                ("DERECHA", CGPoint(x: 500, y: 180)),
            ],
            width: 800, height: 400
        )
        let region = OCRAssert.Region(x: 0, y: 0, width: 380, height: 400)
        let recognized = try OCRAssert.recognizeText(imagePath: path, region: region)
        XCTAssertNotNil(OCRAssert.findMatch(for: "IZQUIERDA", in: recognized),
                        "recognized in region: \(recognized.map(\.string))")
        XCTAssertNil(OCRAssert.findMatch(for: "DERECHA", in: recognized),
                     "crop should exclude right half")
    }

    func testRegionOutOfBoundsThrows() throws {
        let path = try renderImage(
            texts: [("Hola", CGPoint(x: 40, y: 80))],
            width: 200, height: 200
        )
        let region = OCRAssert.Region(x: 500, y: 500, width: 100, height: 100)
        XCTAssertThrowsError(try OCRAssert.recognizeText(imagePath: path, region: region))
    }

    func testMissingImageThrows() {
        XCTAssertThrowsError(
            try OCRAssert.recognizeText(imagePath: "/nonexistent/ocr-missing.png")
        )
    }

    // MARK: - Region.parse

    func testRegionParseValid() throws {
        let r = try OCRAssert.Region.parse("10,20,300,400")
        XCTAssertEqual(r, OCRAssert.Region(x: 10, y: 20, width: 300, height: 400))
    }

    func testRegionParseWithSpaces() throws {
        let r = try OCRAssert.Region.parse("10, 20, 300, 400")
        XCTAssertEqual(r, OCRAssert.Region(x: 10, y: 20, width: 300, height: 400))
    }

    func testRegionParseRejectsMalformed() {
        XCTAssertThrowsError(try OCRAssert.Region.parse("10,20,300"))
        XCTAssertThrowsError(try OCRAssert.Region.parse("a,b,c,d"))
        XCTAssertThrowsError(try OCRAssert.Region.parse("0,0,-5,10"))
        XCTAssertThrowsError(try OCRAssert.Region.parse("0,0,100,0"))
        XCTAssertThrowsError(try OCRAssert.Region.parse(""))
    }

    // MARK: - findMatch (lógica pura, sin Vision)

    func testFindMatchJoinsSplitObservations() {
        // Vision a veces parte una frase en varias observaciones —
        // el fallback matchea sobre el texto unido con espacios.
        let texts = [
            OCRAssert.RecognizedText(string: "Operacion", confidence: 0.9),
            OCRAssert.RecognizedText(string: "exitosa", confidence: 0.8),
        ]
        let match = OCRAssert.findMatch(for: "Operacion exitosa", in: texts)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.confidence, 0.8, "joined match reports min confidence")
    }

    func testFindMatchEmptyNeedleReturnsNil() {
        let texts = [OCRAssert.RecognizedText(string: "algo", confidence: 0.9)]
        XCTAssertNil(OCRAssert.findMatch(for: "", in: texts))
    }

    func testFindMatchEmptyResultsReturnsNil() {
        XCTAssertNil(OCRAssert.findMatch(for: "algo", in: []))
    }
}
