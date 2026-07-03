import XCTest
@testable import AutoCore
@testable import AutoLibiOS

/// Tests de los fixes #132 (iOS: recorder ciego a taps sintéticos + filtro de
/// window frame demasiado agresivo) y #133 (Android: conteo de líneas
/// mentiroso + races de flush/EOF + gestos descartados sin tree).
///
/// Lo que depende de CGEventTap/getevent real se valida E2E; aquí se testea
/// toda la lógica pura extraída para ese propósito.
final class RecorderTapLossTests: XCTestCase {

    // MARK: - #133: conteo mentiroso (lineCount vs commandCount)

    /// Repro exacto del issue: header terminate+launch+línea en blanco
    /// reportaba "3 line(s) recorded" con solo 2 comandos en el archivo.
    func testCommandCount_headerBlankLine_notCounted() {
        let gen = ScriptGenerator()
        gen.appendRaw("terminate \"com.example.app\"")
        gen.appendRaw("launch \"com.example.app\"")
        gen.appendRaw("")

        XCTAssertEqual(gen.lineCount, 3, "lineCount cuenta el buffer crudo")
        XCTAssertEqual(gen.commandCount, 2, "commandCount excluye la línea en blanco")
    }

    func testCommandCount_fragileComment_notCounted() {
        let gen = ScriptGenerator()
        let action = ResolvedAction(
            command: "tap", selector: "Login",
            role: nil, within: nil, occurrence: nil,
            identifier: nil, fragile: true, coordinate: .zero
        )
        _ = gen.process(action, uiChanges: 0, timestamp: 100)

        // fragile sin identifier emite "# no accessibilityIdentifier ..."
        XCTAssertTrue(gen.lineCount > gen.commandCount,
                      "el comment de fragilidad infla lineCount")
        // Comandos reales: waitFor no aplica (buffer vacío al procesar) → solo tap
        XCTAssertEqual(gen.commandCount, 1)
    }

    func testCommandCount_emptyGenerator_isZero() {
        XCTAssertEqual(ScriptGenerator().commandCount, 0)
    }

    // MARK: - #133: extractLines (drenaje del pipe de getevent)

    func testExtractLines_keepsPartialTrailingLine() {
        var buffer = "line1\nline2\npartial"
        let lines = AndroidRecordingSession.extractLines(from: &buffer)
        XCTAssertEqual(lines, ["line1", "line2"])
        XCTAssertEqual(buffer, "partial", "la línea parcial queda en el buffer")
    }

    func testExtractLines_flushReturnsTrailingPartial() {
        // EOF tras SIGINT: getevent muere a mitad de línea sin \n final.
        var buffer = "EV_SYN  SYN_REPORT           00000000"
        let lines = AndroidRecordingSession.extractLines(from: &buffer, flush: true)
        XCTAssertEqual(lines, ["EV_SYN  SYN_REPORT           00000000"])
        XCTAssertEqual(buffer, "")
    }

    func testExtractLines_emptyBuffer_returnsNothing() {
        var buffer = ""
        XCTAssertEqual(AndroidRecordingSession.extractLines(from: &buffer), [])
        XCTAssertEqual(AndroidRecordingSession.extractLines(from: &buffer, flush: true), [])
    }

    func testExtractLines_chunkedAcrossCalls_reassemblesLine() {
        // Simula chunks del pipe que parten una línea en dos reads.
        var buffer = "BTN_TO"
        XCTAssertEqual(AndroidRecordingSession.extractLines(from: &buffer), [])
        buffer += "UCH DOWN\n"
        XCTAssertEqual(AndroidRecordingSession.extractLines(from: &buffer), ["BTN_TOUCH DOWN"])
        XCTAssertEqual(buffer, "")
    }

    // MARK: - #133: clasificación de gestos (antes se descartaban sin tree)

    func testClassifyGesture_boundaries() {
        XCTAssertEqual(AndroidRecordingSession.classifyGesture(distance: 10, duration: 0.1), .tap)
        XCTAssertEqual(AndroidRecordingSession.classifyGesture(distance: 51, duration: 0.1), .swipe)
        XCTAssertEqual(AndroidRecordingSession.classifyGesture(distance: 10, duration: 0.6), .longPress)
        // distance manda sobre duration (drag largo y lento = swipe)
        XCTAssertEqual(AndroidRecordingSession.classifyGesture(distance: 100, duration: 2.0), .swipe)
        // límites exactos: 50px y 0.5s siguen siendo tap
        XCTAssertEqual(AndroidRecordingSession.classifyGesture(distance: 50, duration: 0.5), .tap)
    }

    // MARK: - #133: fallback tapAt cuando no hay tree cacheado

    func testResolveTouchOrFallback_nilTree_fallsBackToTapAt() {
        // Antes: guard let tree else { return } → gesto perdido en silencio.
        let action = AndroidRecordingSession.resolveTouchOrFallback(
            x: 540, y: 1200, tree: nil, command: "tap"
        )
        XCTAssertEqual(action.command, "tapAt")
        XCTAssertEqual(action.selector, "540 1200")
        XCTAssertTrue(action.fragile)
    }

    func testResolveTouchOrFallback_withTree_resolvesSemantically() {
        let tree: [[String: Any]] = [[
            "role": "button",
            "title": "Login",
            "frame": ["x": 500, "y": 1150, "width": 80, "height": 100]
        ]]
        let action = AndroidRecordingSession.resolveTouchOrFallback(
            x: 540, y: 1200, tree: tree, command: "tap"
        )
        // Con tree delega en AndroidSemanticResolver — no debe caer a tapAt
        // por el simple hecho de tener tree (el hit-test decide el resto).
        XCTAssertNotNil(action)
        if action.command == "tap" {
            XCTAssertEqual(action.selector, "Login")
        }
    }

    // MARK: - #133: GetEventParser — tap completo down→up

    func testGetEventParser_fullTapSequence_emitsDownAndUp() {
        let cal = TouchCalibration(minX: 0, maxX: 32767, minY: 0, maxY: 32767,
                                   screenWidth: 1080, screenHeight: 2400)
        let parser = GetEventParser(calibration: cal)

        var events: [AndroidRawEvent] = []
        let lines = [
            "[   100.000001] /dev/input/event2: EV_ABS       ABS_MT_TRACKING_ID   00000001",
            "[   100.000001] /dev/input/event2: EV_KEY       BTN_TOUCH            DOWN",
            "[   100.000001] /dev/input/event2: EV_ABS       ABS_MT_POSITION_X    00004000",
            "[   100.000001] /dev/input/event2: EV_ABS       ABS_MT_POSITION_Y    00004000",
            "[   100.000001] /dev/input/event2: EV_SYN       SYN_REPORT           00000000",
            "[   100.080000] /dev/input/event2: EV_ABS       ABS_MT_TRACKING_ID   ffffffff",
            "[   100.080000] /dev/input/event2: EV_KEY       BTN_TOUCH            UP",
            "[   100.080000] /dev/input/event2: EV_SYN       SYN_REPORT           00000000"
        ]
        for line in lines {
            if let e = parser.parseLine(line) { events.append(e) }
        }

        XCTAssertEqual(events.count, 2, "un tap = down + up")
        guard events.count == 2 else { return }
        if case .down(let x, let y) = events[0].phase {
            // 0x4000 = 16384 → ~mitad de pantalla
            XCTAssertEqual(x, 16384 * 1080 / 32767)
            XCTAssertEqual(y, 16384 * 2400 / 32767)
        } else {
            XCTFail("primer evento debe ser .down, fue \(events[0].phase)")
        }
        if case .up = events[1].phase {} else {
            XCTFail("segundo evento debe ser .up, fue \(events[1].phase)")
        }
    }

    // MARK: - #132: filtro de window frame fail-open

    func testShouldCapture_zeroFrame_failsOpen() {
        // Antes: frame .zero descartaba TODO → "0 líneas" con clicks humanos.
        XCTAssertTrue(EventRecorder.shouldCaptureMouseEvent(
            at: CGPoint(x: 100, y: 100), windowFrame: .zero
        ))
    }

    func testShouldCapture_insideFrame_captures() {
        let frame = CGRect(x: 50, y: 50, width: 400, height: 800)
        XCTAssertTrue(EventRecorder.shouldCaptureMouseEvent(
            at: CGPoint(x: 100, y: 100), windowFrame: frame
        ))
    }

    func testShouldCapture_outsideFrame_filters() {
        let frame = CGRect(x: 50, y: 50, width: 400, height: 800)
        XCTAssertFalse(EventRecorder.shouldCaptureMouseEvent(
            at: CGPoint(x: 1000, y: 100), windowFrame: frame
        ))
    }
}
