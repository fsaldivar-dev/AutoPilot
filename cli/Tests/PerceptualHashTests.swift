import XCTest
import CoreGraphics
import ImageIO
@testable import AutoCore

/// Tests del dHash y de ScreenAssert (#56) con imágenes sintéticas generadas
/// en el propio test — sin fixtures binarios en el repo.
final class PerceptualHashTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Synthetic image helpers

    /// Crea una imagen gris de `size` x `size` dibujando con el closure.
    private func makeImage(size: Int = 200, draw: (CGContext, Int) -> Void) -> CGImage {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        draw(context, size)
        return context.makeImage()!
    }

    /// Gradiente horizontal: brillo crece de izquierda a derecha (o al revés).
    private func gradientImage(size: Int = 200, reversed: Bool = false) -> CGImage {
        makeImage(size: size) { ctx, s in
            for x in 0..<s {
                let level = CGFloat(x) / CGFloat(s - 1)
                ctx.setFillColor(gray: reversed ? 1.0 - level : level, alpha: 1.0)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: s))
            }
        }
    }

    /// Gradiente + parche pequeño en una esquina (~1% del área) — simula
    /// texto dinámico (hora, fecha) que cambia entre baseline y replay.
    private func gradientWithNoise(size: Int = 200) -> CGImage {
        makeImage(size: size) { ctx, s in
            for x in 0..<s {
                ctx.setFillColor(gray: CGFloat(x) / CGFloat(s - 1), alpha: 1.0)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: s))
            }
            ctx.setFillColor(gray: 0.5, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: s / 10, height: s / 10))
        }
    }

    private func writePNG(_ image: CGImage, name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw BridgeError.unknown("cannot create PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BridgeError.unknown("cannot finalize PNG")
        }
        return url.path
    }

    // MARK: - dHash

    func testIdenticalImagesDistanceZero() throws {
        let a = try writePNG(gradientImage(), name: "a.png")
        let b = try writePNG(gradientImage(), name: "b.png")
        let hashA = try PerceptualHash.dHash(imagePath: a)
        let hashB = try PerceptualHash.dHash(imagePath: b)
        XCTAssertEqual(PerceptualHash.hammingDistance(hashA, hashB), 0)
    }

    func testVeryDifferentImagesHighDistance() throws {
        // Gradiente L→R vs R→L: todos los bits de diferencia se invierten.
        let a = try writePNG(gradientImage(), name: "ltr.png")
        let b = try writePNG(gradientImage(reversed: true), name: "rtl.png")
        let hashA = try PerceptualHash.dHash(imagePath: a)
        let hashB = try PerceptualHash.dHash(imagePath: b)
        let distance = PerceptualHash.hammingDistance(hashA, hashB)
        XCTAssertGreaterThan(distance, 32, "opposite gradients should differ in most bits, got \(distance)")
    }

    func testSmallNoiseLowDistance() throws {
        // Parche del 1% del área — debe quedar dentro de la tolerancia default.
        let a = try writePNG(gradientImage(), name: "clean.png")
        let b = try writePNG(gradientWithNoise(), name: "noisy.png")
        let hashA = try PerceptualHash.dHash(imagePath: a)
        let hashB = try PerceptualHash.dHash(imagePath: b)
        let distance = PerceptualHash.hammingDistance(hashA, hashB)
        XCTAssertLessThanOrEqual(distance, ScreenAssert.defaultTolerance,
                                 "small localized noise should stay under default tolerance, got \(distance)")
        XCTAssertLessThan(distance, 32, "noise must not look like a different screen")
    }

    func testResolutionInvariance() throws {
        // La misma escena a 200px y 400px debe dar (casi) el mismo hash.
        let small = try writePNG(gradientImage(size: 200), name: "small.png")
        let large = try writePNG(gradientImage(size: 400), name: "large.png")
        let hashS = try PerceptualHash.dHash(imagePath: small)
        let hashL = try PerceptualHash.dHash(imagePath: large)
        XCTAssertLessThanOrEqual(PerceptualHash.hammingDistance(hashS, hashL), 2)
    }

    func testHammingDistance() {
        XCTAssertEqual(PerceptualHash.hammingDistance(0, 0), 0)
        XCTAssertEqual(PerceptualHash.hammingDistance(0, UInt64.max), 64)
        XCTAssertEqual(PerceptualHash.hammingDistance(0b1010, 0b0101), 4)
        XCTAssertEqual(PerceptualHash.hammingDistance(0xFF, 0xFE), 1)
    }

    func testDecodeFailureThrowsTypedError() throws {
        let notAnImage = tempDir.appendingPathComponent("garbage.png").path
        try "this is not a png".write(toFile: notAnImage, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PerceptualHash.dHash(imagePath: notAnImage)) { error in
            guard case BridgeError.imageDecodeFailed = error else {
                return XCTFail("expected imageDecodeFailed, got \(error)")
            }
        }
    }

    // MARK: - ScreenAssert

    func testCompareIdenticalIsMatch() throws {
        let a = try writePNG(gradientImage(), name: "base.png")
        let b = try writePNG(gradientImage(), name: "current.png")
        let result = try ScreenAssert.compare(currentPath: b, baselinePath: a)
        XCTAssertEqual(result.distance, 0)
        XCTAssertTrue(result.isMatch)
    }

    func testAssertMatchThrowsMismatchOverTolerance() throws {
        let a = try writePNG(gradientImage(), name: "base.png")
        let b = try writePNG(gradientImage(reversed: true), name: "current.png")
        XCTAssertThrowsError(
            try ScreenAssert.assertMatch(currentPath: b, baselinePath: a, tolerance: 10)
        ) { error in
            guard case BridgeError.screenMismatch(let distance, let tolerance) = error else {
                return XCTFail("expected screenMismatch, got \(error)")
            }
            XCTAssertGreaterThan(distance, 10)
            XCTAssertEqual(tolerance, 10)
            XCTAssertTrue("\(error)".hasPrefix("MISMATCH (distance "))
        }
    }

    func testAssertMatchRespectsCustomTolerance() throws {
        // Con tolerancia 64 todo pasa, incluso imágenes opuestas.
        let a = try writePNG(gradientImage(), name: "base.png")
        let b = try writePNG(gradientImage(reversed: true), name: "current.png")
        let result = try ScreenAssert.assertMatch(currentPath: b, baselinePath: a, tolerance: 64)
        XCTAssertTrue(result.isMatch)
    }

    func testMissingBaselineThrowsTypedError() throws {
        let current = try writePNG(gradientImage(), name: "current.png")
        let missing = tempDir.appendingPathComponent("no-existe.png").path
        XCTAssertThrowsError(
            try ScreenAssert.compare(currentPath: current, baselinePath: missing)
        ) { error in
            guard case BridgeError.baselineNotFound(let path) = error else {
                return XCTFail("expected baselineNotFound, got \(error)")
            }
            XCTAssertEqual(path, missing)
        }
    }
}
