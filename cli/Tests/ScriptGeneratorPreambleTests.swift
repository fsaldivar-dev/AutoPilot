import XCTest
@testable import AutoCore

/// #161: preambulo terminate+launch del recorder segun si la grabacion
/// empezo con la app ya corriendo (mid-session) o desde cero.
final class ScriptGeneratorPreambleTests: XCTestCase {

    // MARK: - Grabacion desde cero (midSession: false)

    func testFreshRecording_emitsActivePreamble() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: false)

        let script = generator.render()
        XCTAssertTrue(script.contains("terminate \"com.example.app\"\nlaunch \"com.example.app\"\n"),
                      "el preambulo activo debe emitir terminate+launch consecutivos")
        XCTAssertFalse(script.contains("# terminate"),
                       "grabacion desde cero: nada comentado")
        XCTAssertFalse(script.contains("mitad de sesión"),
                       "grabacion desde cero: sin advertencia mid-session")
    }

    func testFreshRecording_preambleCountsAsCommands() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: false)

        // terminate + launch son ejecutables; la linea en blanco no (#133)
        XCTAssertEqual(generator.commandCount, 2)
        XCTAssertEqual(generator.lineCount, 3)
    }

    // MARK: - Grabacion mid-session (midSession: true)

    func testMidSessionRecording_emitsCommentedPreamble() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: true)

        let script = generator.render()
        XCTAssertTrue(script.contains("# Grabado a mitad de sesión — el replay asume el estado de pantalla donde estabas."))
        XCTAssertTrue(script.contains("# Descomenta para replay desde cero (la app arrancará en su estado inicial):"))
        XCTAssertTrue(script.contains("# terminate \"com.example.app\""))
        XCTAssertTrue(script.contains("# launch \"com.example.app\""))
    }

    func testMidSessionRecording_noActiveTerminateOrLaunch() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: true)

        let executable = generator.render()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertTrue(executable.isEmpty,
                      "mid-session: ninguna linea ejecutable debe salir del preambulo, hay: \(executable)")
    }

    func testMidSessionRecording_preambleDoesNotCountAsCommands() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: true)

        // Todo comentado → 0 comandos ejecutables (#133: el contador no miente)
        XCTAssertEqual(generator.commandCount, 0)
    }

    func testMidSessionRecording_exactCommentedBlock() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.demo.pkg", midSession: true)

        let expected = """
        # Grabado a mitad de sesión — el replay asume el estado de pantalla donde estabas.
        # Descomenta para replay desde cero (la app arrancará en su estado inicial):
        # terminate "com.demo.pkg"
        # launch "com.demo.pkg"
        """
        XCTAssertTrue(generator.render().contains(expected),
                      "el bloque comentado debe salir integro y en ese orden")
    }

    // MARK: - Preambulo + acciones grabadas

    func testPreamble_followedByAction_keepsOrder() {
        let generator = ScriptGenerator()
        generator.appendLaunchPreamble(bundleId: "com.example.app", midSession: true)

        let action = ResolvedAction(
            command: "tap", selector: "Guardar",
            role: nil, within: nil, occurrence: nil,
            identifier: "save_button", fragile: false, coordinate: .zero
        )
        _ = generator.process(action, uiChanges: 0, timestamp: 100)

        let script = generator.render()
        let preambleIdx = script.range(of: "# launch \"com.example.app\"")!.lowerBound
        let tapIdx = script.range(of: "tap \"Guardar\"")!.lowerBound
        XCTAssertLessThan(preambleIdx, tapIdx,
                          "el preambulo comentado precede a los comandos grabados")
        XCTAssertEqual(generator.commandCount, 2, "waitFor inicial + tap")
    }
}
