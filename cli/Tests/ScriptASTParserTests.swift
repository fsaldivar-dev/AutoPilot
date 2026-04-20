import XCTest
@testable import AutoCore

// Tests del parser estructural `parseStatements(_:)` — convierte `.auto`
// crudo en `[ScriptStatement]` (AST). Cubre:
//   - Acciones atómicas (backward compat con parseScript existente)
//   - if/else/end (con y sin rama else)
//   - repeat N times / while / until / foreach
//   - try/catch
//   - assert
//   - Predicados: call simple, and/or/not, paréntesis
//   - Errores de sintaxis: end huérfano, bloque sin cerrar, etc.

final class ScriptASTParserTests: XCTestCase {

    // MARK: - Acciones planas (backward compat)

    func testParse_singleAction() throws {
        let script = #"tap "Login""#
        let stmts = try parseStatements(script)

        XCTAssertEqual(stmts.count, 1)
        guard case .action(let tokens, _) = stmts[0] else {
            return XCTFail("Expected .action, got \(stmts[0])")
        }
        XCTAssertEqual(tokens, ["tap", "Login"])
    }

    func testParse_multipleActionsPreserveOrder() throws {
        let script = """
        tap "A"
        type "hello"
        screenshot out.png
        """
        let stmts = try parseStatements(script)

        XCTAssertEqual(stmts.count, 3)
        if case .action(let t, _) = stmts[0] { XCTAssertEqual(t[0], "tap") } else { XCTFail() }
        if case .action(let t, _) = stmts[1] { XCTAssertEqual(t[0], "type") } else { XCTFail() }
        if case .action(let t, _) = stmts[2] { XCTAssertEqual(t[0], "screenshot") } else { XCTFail() }
    }

    func testParse_skipsCommentsAndBlankLines() throws {
        let script = """
        # header comment
        tap "A"

        # another
        tap "B"
        """
        let stmts = try parseStatements(script)
        XCTAssertEqual(stmts.count, 2)
    }

    // MARK: - if / else / end

    func testParse_ifBlockWithoutElse() throws {
        let script = """
        if exists "Login"
            tap "Login"
        end
        """
        let stmts = try parseStatements(script)

        XCTAssertEqual(stmts.count, 1)
        guard case .ifBlock(let cond, let then, let else_) = stmts[0] else {
            return XCTFail("Expected .ifBlock")
        }
        XCTAssertEqual(cond, .call(name: "exists", args: ["Login"]))
        XCTAssertEqual(then.count, 1)
        XCTAssertTrue(else_.isEmpty)
    }

    func testParse_ifBlockWithElse() throws {
        let script = """
        if platform is ios
            tap "iOS"
        else
            tap "Android"
        end
        """
        let stmts = try parseStatements(script)

        XCTAssertEqual(stmts.count, 1)
        guard case .ifBlock(let cond, let then, let else_) = stmts[0] else {
            return XCTFail()
        }
        XCTAssertEqual(cond, .call(name: "platform", args: ["is", "ios"]))
        XCTAssertEqual(then.count, 1)
        XCTAssertEqual(else_.count, 1)
    }

    // MARK: - repeat

    func testParse_repeatTimes() throws {
        let script = """
        repeat 3 times
            tap "Next"
        end
        """
        let stmts = try parseStatements(script)

        XCTAssertEqual(stmts.count, 1)
        guard case .repeatBlock(let kind, let body) = stmts[0] else {
            return XCTFail()
        }
        if case .times(let n) = kind { XCTAssertEqual(n, 3) } else { XCTFail("Expected .times") }
        XCTAssertEqual(body.count, 1)
    }

    func testParse_repeatWhile() throws {
        let script = """
        repeat while visible "Siguiente"
            tap "Siguiente"
        end
        """
        let stmts = try parseStatements(script)
        guard case .repeatBlock(let kind, _) = stmts[0] else { return XCTFail() }
        if case .whileCond(let p) = kind {
            XCTAssertEqual(p, .call(name: "visible", args: ["Siguiente"]))
        } else { XCTFail("Expected .whileCond") }
    }

    func testParse_repeatUntil() throws {
        let script = """
        repeat until exists "Finalizado"
            tap "Procesar"
        end
        """
        let stmts = try parseStatements(script)
        guard case .repeatBlock(let kind, _) = stmts[0] else { return XCTFail() }
        if case .untilCond(let p) = kind {
            XCTAssertEqual(p, .call(name: "exists", args: ["Finalizado"]))
        } else { XCTFail("Expected .untilCond") }
    }

    func testParse_repeatForeach() throws {
        let script = """
        repeat for $item in $items
            type $item in "Input"
        end
        """
        let stmts = try parseStatements(script)
        guard case .repeatBlock(let kind, _) = stmts[0] else { return XCTFail() }
        if case .forEach(let variable, let list) = kind {
            XCTAssertEqual(variable, "$item")
            XCTAssertEqual(list, "$items")
        } else { XCTFail("Expected .forEach") }
    }

    // MARK: - try / catch

    func testParse_tryCatch() throws {
        let script = """
        try
            waitFor "Success"
        catch
            screenshot error.png
        end
        """
        let stmts = try parseStatements(script)
        guard case .tryBlock(let body, let catch_) = stmts[0] else {
            return XCTFail()
        }
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(catch_.count, 1)
    }

    // MARK: - assert

    func testParse_assert() throws {
        let script = #"assert visible "Home""#
        let stmts = try parseStatements(script)
        guard case .assertStatement(let cond, _) = stmts[0] else {
            return XCTFail()
        }
        XCTAssertEqual(cond, .call(name: "visible", args: ["Home"]))
    }

    // MARK: - Predicate composition

    func testParse_predicateAnd() throws {
        let script = """
        if exists "A" and visible "B"
            tap "A"
        end
        """
        let stmts = try parseStatements(script)
        guard case .ifBlock(let cond, _, _) = stmts[0] else { return XCTFail() }
        guard case .and(let lhs, let rhs) = cond else {
            return XCTFail("Expected .and, got \(cond)")
        }
        XCTAssertEqual(lhs, .call(name: "exists", args: ["A"]))
        XCTAssertEqual(rhs, .call(name: "visible", args: ["B"]))
    }

    func testParse_predicateNot() throws {
        let script = """
        if not exists "Error"
            tap "Retry"
        end
        """
        let stmts = try parseStatements(script)
        guard case .ifBlock(let cond, _, _) = stmts[0] else { return XCTFail() }
        guard case .not(let inner) = cond else {
            return XCTFail("Expected .not, got \(cond)")
        }
        XCTAssertEqual(inner, .call(name: "exists", args: ["Error"]))
    }

    func testParse_predicateOr() throws {
        let script = """
        if exists "A" or exists "B"
            tap "A"
        end
        """
        let stmts = try parseStatements(script)
        guard case .ifBlock(let cond, _, _) = stmts[0] else { return XCTFail() }
        guard case .or = cond else {
            return XCTFail("Expected .or, got \(cond)")
        }
    }

    // MARK: - Nesting

    func testParse_nestedIfInsideRepeat() throws {
        let script = """
        repeat 3 times
            if exists "Ad"
                tap "Close"
            end
            tap "Next"
        end
        """
        let stmts = try parseStatements(script)
        XCTAssertEqual(stmts.count, 1)
        guard case .repeatBlock(_, let body) = stmts[0] else { return XCTFail() }
        XCTAssertEqual(body.count, 2)
        if case .ifBlock = body[0] {} else { XCTFail("Expected nested .ifBlock") }
        if case .action = body[1] {} else { XCTFail("Expected trailing .action") }
    }

    // MARK: - Errors

    func testParse_unclosedIfThrows() throws {
        let script = """
        if exists "X"
            tap "Y"
        """
        XCTAssertThrowsError(try parseStatements(script)) { err in
            guard let parseErr = err as? ScriptParseError,
                  case .unclosedBlock(let kw, _) = parseErr else {
                return XCTFail("Expected .unclosedBlock, got \(err)")
            }
            XCTAssertEqual(kw, "if")
        }
    }

    func testParse_orphanEndThrows() throws {
        let script = "end"
        XCTAssertThrowsError(try parseStatements(script)) { err in
            if case ScriptParseError.unexpectedEnd = err { return }
            XCTFail("Expected .unexpectedEnd, got \(err)")
        }
    }
}
