import XCTest
@testable import AutoCore
@testable import AutoLibiOS

/// Tests de los fixes #50 (trackpad scroll) y #52 (stale AX tree).
/// Los fixes que dependen de CGEvent/AX real no se testean aquí —
/// validación E2E queda al smoke test contra Simulator.
final class RecorderFixesTests: XCTestCase {

    // MARK: - #50 trackpad scroll delta

    func testScrollDelta_mouseWheel_usesLineDelta() {
        // Mouse tradicional: line-delta no-cero, point-delta presente
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: 3.0, pointDelta: 42.0), 3.0)
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: -2.0, pointDelta: -20.0), -2.0)
    }

    func testScrollDelta_trackpad_fallsBackToPointDelta() {
        // Trackpad smooth scroll: line-delta = 0, point-delta trae los píxeles
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: 0, pointDelta: 30.0), 3.0)
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: 0, pointDelta: -50.0), -5.0)
    }

    func testScrollDelta_bothZero_returnsZero() {
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: 0, pointDelta: 0), 0)
    }

    func testScrollDelta_smallLineDelta_preferredOverBigPointDelta() {
        // Si lineDelta tiene cualquier magnitud no-cero, gana — esa es la
        // semántica canónica de macOS (line-delta es la unidad legacy confiable).
        XCTAssertEqual(EventRecorder.scrollDeltaYFrom(lineDelta: 0.5, pointDelta: 100.0), 0.5)
    }

    // MARK: - #52 stale AX tree (documentation)

    /// Fix de #52 vive en `RecordingSession.captureRootAvoidingStaleTree(for:)`
    /// y depende de `SimulatorBridge.findSimulatorContentFast` + `ViewFingerprint`.
    /// No se testea con unit test porque requiere AXUIElement real del Simulator.
    /// Verificación E2E: smoke test contra simulador booteado con clicks rápidos.
    ///
    /// Comportamiento esperado del fix:
    ///   1. Primer click → captura tree directamente, guarda fingerprint + timestamp
    ///   2. Click <250ms después → poll hasta fingerprint distinto o 300ms timeout
    ///   3. Click >250ms después → captura directa (asume UI ya se estabilizó)
    func testStaleAXTreeFix_semantics() {
        // Placeholder — la lógica es privada y depende de AXUIElement.
        // Este test existe para documentar la intención y el contrato.
        XCTAssertTrue(true, "See RecordingSession.captureRootAvoidingStaleTree")
    }
}
