import XCTest
@testable import AutoCore

// Tests del fix #152: comando no reconocido dentro de un script debe fallar
// con `Unknown command '<cmd>'` + sugerencia Levenshtein, y el error debe
// propagarse por el interpreter (→ exit 1 en el CLI) en vez de tragarse.

final class UnknownCommandTests: XCTestCase {

    // MARK: - Levenshtein

    func testLevenshteinBasics() {
        XCTAssertEqual(CommandCatalog.levenshtein("tap", "tap"), 0)
        XCTAssertEqual(CommandCatalog.levenshtein("tapp", "tap"), 1)
        XCTAssertEqual(CommandCatalog.levenshtein("tap", ""), 3)
        XCTAssertEqual(CommandCatalog.levenshtein("", "swipe"), 5)
        XCTAssertEqual(CommandCatalog.levenshtein("kitten", "sitting"), 3)
    }

    // MARK: - Sugerencias

    func testSuggestsTapForTapp() {
        XCTAssertEqual(CommandCatalog.suggest("tapp"), "tap")
    }

    func testSuggestsWaitForForLowercaseTypo() {
        // Typo del issue #152: `waitfor` (case-sensitive) no matcheaba nada.
        XCTAssertEqual(CommandCatalog.suggest("waitfor"), "waitFor")
    }

    func testSuggestsScreenshotForTypo() {
        XCTAssertEqual(CommandCatalog.suggest("screenshoot"), "screenshot")
    }

    func testNoSuggestionForDistantTypo() {
        XCTAssertNil(CommandCatalog.suggest("frobnicate"))
        XCTAssertNil(CommandCatalog.suggest("xyzzy123"))
    }

    func testNoSuggestionForEmptyCommand() {
        XCTAssertNil(CommandCatalog.suggest(""))
    }

    func testSuggestionUsesPlatformExtras() {
        // `doctor` no está en el catálogo shared — viene del main del CLI.
        XCTAssertNil(CommandCatalog.suggest("doctr"))
        XCTAssertEqual(CommandCatalog.suggest("doctr", extra: ["doctor"]), "doctor")
    }

    // MARK: - Mensaje de error

    func testErrorDescriptionWithSuggestion() {
        let err = CommandCatalog.unknownCommandError("tapp")
        XCTAssertEqual(err.command, "tapp")
        XCTAssertEqual(err.suggestion, "tap")
        XCTAssertEqual("\(err)", "Unknown command 'tapp' (¿quisiste decir 'tap'?)")
    }

    func testErrorDescriptionWithoutSuggestion() {
        let err = CommandCatalog.unknownCommandError("frobnicate")
        XCTAssertNil(err.suggestion)
        XCTAssertEqual("\(err)", "Unknown command 'frobnicate'")
    }

    // MARK: - Propagación por el interpreter (cadena del CLI)

    /// Handler que imita el fallthrough de los mains: comandos del catálogo
    /// se "ejecutan" (no-op), desconocidos lanzan UnknownCommandError.
    private func makeInterpreter(
        backend: InterpreterMockBackend,
        executedLines: @escaping @Sendable ([String], Int) -> Void = { _, _ in }
    ) async -> ScriptInterpreter {
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        return ScriptInterpreter(router: router) { tokens, line in
            executedLines(tokens, line)
            let cmd = tokens[0]
            let known = CommandCatalog.shared.contains(cmd)
            guard known else {
                throw CommandCatalog.unknownCommandError(cmd)
            }
        }
    }

    func testUnknownCommandInScriptThrowsWithLineAndSuggestion() async throws {
        let backend = InterpreterMockBackend()

        final class LineBox: @unchecked Sendable {
            var failedLine: Int?
            let lock = NSLock()
            func record(_ tokens: [String], _ line: Int) {
                lock.lock(); defer { lock.unlock() }
                if tokens.first == "tapp" { failedLine = line }
            }
        }
        let box = LineBox()

        let interp = await makeInterpreter(backend: backend) { tokens, line in
            box.record(tokens, line)
        }

        // Línea 1 válida, línea 2 con typo — el script debe abortar en la 2.
        let statements = try parseStatements("tap \"Login\"\ntapp \"x\"\n")

        do {
            try await interp.run(statements)
            XCTFail("Expected UnknownCommandError to propagate")
        } catch let err as UnknownCommandError {
            XCTAssertEqual(err.command, "tapp")
            XCTAssertEqual(err.suggestion, "tap")
        }
        XCTAssertEqual(box.failedLine, 2, "El handler debe recibir el número de línea del typo")
    }

    func testUnknownCommandFarTypoThrowsWithoutSuggestion() async throws {
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend: backend)
        let statements = try parseStatements("frobnicate \"x\"\n")

        do {
            try await interp.run(statements)
            XCTFail("Expected UnknownCommandError to propagate")
        } catch let err as UnknownCommandError {
            XCTAssertEqual(err.command, "frobnicate")
            XCTAssertNil(err.suggestion)
        }
    }

    func testValidScriptRunsWithoutError() async throws {
        // Sin regresión: un script válido completo no lanza nada.
        let backend = InterpreterMockBackend()
        let interp = await makeInterpreter(backend: backend)
        let statements = try parseStatements("""
        tap "Login"
        type "user@example.com"
        screenshot evidencia.png
        waitFor "Bienvenido" 5
        """)
        try await interp.run(statements)
    }
}
