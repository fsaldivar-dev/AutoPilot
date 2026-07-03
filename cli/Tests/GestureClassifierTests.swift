import XCTest
@testable import AutoCore
@testable import AutoLibiOS

/// Tests del clasificador de gestos del recorder iOS (#91).
///
/// `GestureClassifier.classify` es una función pura (trayectoria de
/// puntos+timestamps → gesto), así que se testea con trayectorias
/// sintéticas sin CGEvent ni Simulator.
final class GestureClassifierTests: XCTestCase {

    /// Helper: construye una trayectoria a partir de tuplas (x, y, t).
    private func points(_ tuples: [(Double, Double, Double)]) -> [GesturePoint] {
        tuples.map {
            GesturePoint(location: CGPoint(x: $0.0, y: $0.1), timestamp: $0.2)
        }
    }

    // MARK: - Tap

    func testTap_shortClickNoMovement() {
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.00),
            (100, 100, 0.08)
        ]))
        XCTAssertEqual(g, .tap)
    }

    func testTap_clickWithTremor_underThreshold() {
        // Temblor humano de ~5px no debe convertirse en drag
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.00),
            (103, 102, 0.05),
            (104, 103, 0.10)
        ]))
        XCTAssertEqual(g, .tap)
    }

    func testTap_singlePoint() {
        // Down y up en el mismo instante/punto (trayectoria degenerada)
        let g = GestureClassifier.classify(points: points([(50, 50, 0)]))
        XCTAssertEqual(g, .tap)
    }

    func testEmptyTrajectory_returnsNil() {
        XCTAssertNil(GestureClassifier.classify(points: []))
    }

    // MARK: - Long press

    func testLongPress_holdWithoutMovement() {
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (100, 100, 0.8)
        ]))
        XCTAssertEqual(g, .longPress(duration: 0.8))
    }

    func testLongPress_holdWithTremor() {
        // Hold largo con temblor <10px sigue siendo longPress, no drag
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (104, 103, 0.6),
            (102, 101, 1.4)
        ]))
        if case .longPress(let duration)? = g {
            XCTAssertEqual(duration, 1.4, accuracy: 0.001)
        } else {
            XCTFail("esperaba longPress, fue \(String(describing: g))")
        }
    }

    func testShortHold_underHalfSecond_isTap() {
        // 0.4s < umbral de 0.5s → tap
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (100, 100, 0.4)
        ]))
        XCTAssertEqual(g, .tap)
    }

    // MARK: - Swipe (scroll rápido axial)

    func testSwipe_fastVerticalUp() {
        // 200px hacia arriba en 0.2s = 1000px/s, recto y vertical → swipe up
        let g = GestureClassifier.classify(points: points([
            (200, 600, 0.00),
            (200, 550, 0.05),
            (200, 500, 0.10),
            (200, 450, 0.15),
            (200, 400, 0.20)
        ]))
        XCTAssertEqual(g, .swipe(direction: .up))
    }

    func testSwipe_fastVerticalDown() {
        let g = GestureClassifier.classify(points: points([
            (200, 300, 0.00),
            (202, 400, 0.08),
            (201, 500, 0.16)
        ]))
        XCTAssertEqual(g, .swipe(direction: .down))
    }

    func testSwipe_fastHorizontalLeft() {
        let g = GestureClassifier.classify(points: points([
            (400, 300, 0.00),
            (300, 302, 0.08),
            (200, 301, 0.16)
        ]))
        XCTAssertEqual(g, .swipe(direction: .left))
    }

    func testSwipe_fastHorizontalRight() {
        let g = GestureClassifier.classify(points: points([
            (100, 300, 0.00),
            (250, 300, 0.10)
        ]))
        XCTAssertEqual(g, .swipe(direction: .right))
    }

    func testSwipe_instantDisplacement_infiniteVelocity() {
        // Duración 0 con desplazamiento (timestamps con misma resolución):
        // velocidad efectiva infinita → swipe, no drag
        let g = GestureClassifier.classify(points: points([
            (200, 600, 1.0),
            (200, 400, 1.0)
        ]))
        XCTAssertEqual(g, .swipe(direction: .up))
    }

    // MARK: - Drag

    func testDrag_diagonal() {
        // Diagonal 45°: ningún eje domina → drag aunque sea rápido
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (175, 180, 0.1),
            (250, 260, 0.2)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 100, y: 100),
                                to: CGPoint(x: 250, y: 260)))
    }

    func testDrag_slowVertical_deliberateMove() {
        // Vertical y recto pero LENTO (200px/s < 500px/s): reorder de celda
        // o ajuste deliberado, no scroll inercial
        let g = GestureClassifier.classify(points: points([
            (200, 300, 0.0),
            (200, 400, 0.5),
            (200, 500, 1.0)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 200, y: 300),
                                to: CGPoint(x: 200, y: 500)))
    }

    func testDrag_wanderingPath_notSwipe() {
        // Zigzag: termina alineado al eje vertical y es rápido, pero el
        // camino recorrido es 1.5× el desplazamiento neto → drag libre
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.00),
            (160, 150, 0.05),
            (100, 200, 0.10),
            (160, 250, 0.15),
            (100, 300, 0.20)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 100, y: 100),
                                to: CGPoint(x: 100, y: 300)))
    }

    func testDrag_horizontalShortSlider() {
        // Slider adjustment: horizontal, corto y lento → drag (caso
        // patológico de la tabla del issue #91)
        let g = GestureClassifier.classify(points: points([
            (100, 500, 0.0),
            (130, 500, 0.3),
            (160, 501, 0.6)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 100, y: 500),
                                to: CGPoint(x: 160, y: 501)))
    }

    // MARK: - Umbrales / fronteras

    func testBoundary_justUnderTapThreshold_isTap() {
        // 9.9px < 10px → tap
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (109.9, 100, 0.1)
        ]))
        XCTAssertEqual(g, .tap)
    }

    func testBoundary_atTapThreshold_isNotTap() {
        // Exactamente 10px, lento y horizontal-corto → ya no es tap
        let g = GestureClassifier.classify(points: points([
            (100, 100, 0.0),
            (110, 100, 0.5)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 100, y: 100),
                                to: CGPoint(x: 110, y: 100)))
    }

    func testBoundary_fastButNotAxisDominant_isDrag() {
        // dy=150 dx=100: |dy| < 2×|dx| → ni vertical ni horizontal → drag
        let g = GestureClassifier.classify(points: points([
            (100, 400, 0.0),
            (200, 250, 0.1)
        ]))
        XCTAssertEqual(g, .drag(from: CGPoint(x: 100, y: 400),
                                to: CGPoint(x: 200, y: 250)))
    }

    func testCustomThresholds_respected() {
        var t = GestureClassifier.Thresholds()
        t.tapMaxDistance = 30
        // 20px de movimiento: drag con defaults, tap con umbral de 30px
        let trajectory = points([(100, 100, 0.0), (120, 100, 0.1)])
        XCTAssertEqual(GestureClassifier.classify(points: trajectory, thresholds: t), .tap)
        XCTAssertEqual(GestureClassifier.classify(points: trajectory),
                       .drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 100)))
    }

    // MARK: - #91: argsSuffix en ScriptGenerator (longPress con segundos)

    func testScriptGenerator_longPressWithDuration() {
        let gen = ScriptGenerator()
        gen.appendRaw("launch \"com.example\"")
        let action = ResolvedAction(
            command: "longPress", selector: "Foto",
            role: nil, within: nil, occurrence: nil,
            identifier: "Foto", fragile: false, coordinate: .zero,
            argsSuffix: "1.5"
        )
        let lines = gen.process(action, uiChanges: 0, timestamp: 100)
        XCTAssertTrue(lines.contains("longPress \"Foto\" 1.5"),
                      "esperaba longPress con segundos, fue \(lines)")
    }

    func testScriptGenerator_noSuffix_unchangedFormat() {
        let gen = ScriptGenerator()
        let action = ResolvedAction(
            command: "tap", selector: "Login",
            role: nil, within: nil, occurrence: nil,
            identifier: "Login", fragile: false, coordinate: .zero
        )
        let lines = gen.process(action, uiChanges: 0, timestamp: 100)
        XCTAssertEqual(lines, ["tap \"Login\""])
    }
}
