import Foundation

/// Tokenizes a script line respecting quoted strings.
/// - "tap \"Login Button\"" -> ["tap", "Login Button"]
/// - "type 'Hello World'" -> ["type", "Hello World"]
public func tokenize(_ line: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inQuote: Character? = nil

    for char in line {
        if let q = inQuote {
            if char == q {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char == " " {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

// MARK: - ParsedCommand (role + within support)

/// A parsed command with optional role verification and scope.
/// Supports: tap[button] "Camera[2]" within "Toolbar"
public struct ParsedCommand {
    public let command: String      // "tap"
    public let role: String?        // "button" (from tap[button])
    public let target: String       // "Camera" or "Camera[2]"
    public let within: String?      // "Toolbar"
    public let extraArgs: [String]  // remaining args
}

/// Parse tokens into a ParsedCommand, extracting optional [role] and within scope.
/// Returns nil if tokens has fewer than 2 elements.
public func parseCommand(_ tokens: [String]) -> ParsedCommand? {
    guard tokens.count >= 2 else { return nil }

    var command = tokens[0]
    var role: String? = nil

    // Detect role: tap[button] → command="tap", role="button"
    if let bracket = command.firstIndex(of: "["),
       let end = command.lastIndex(of: "]"),
       bracket < end {
        role = String(command[command.index(after: bracket)..<end])
        command = String(command[command.startIndex..<bracket])
    }

    let target = tokens[1]
    var within: String? = nil
    var extraArgs: [String] = []

    var i = 2
    while i < tokens.count {
        if tokens[i].lowercased() == "within" && i + 1 < tokens.count {
            within = tokens[i + 1]
            i += 2
        } else {
            extraArgs.append(tokens[i])
            i += 1
        }
    }

    return ParsedCommand(command: command, role: role, target: target, within: within, extraArgs: extraArgs)
}

/// Checks if a string looks like a device UDID (vs a device name).
public func isDeviceUDID(_ input: String) -> Bool {
    input.count > 30 && input.contains("-")
}

/// Parses a .auto script file into executable lines (skipping comments and blanks).
public func parseScript(_ content: String) -> [(lineNumber: Int, tokens: [String])] {
    var result: [(lineNumber: Int, tokens: [String])] = []
    let lines = content.components(separatedBy: .newlines)

    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let tokens = tokenize(trimmed)
        if !tokens.isEmpty {
            result.append((lineNumber: i + 1, tokens: tokens))
        }
    }
    return result
}

// MARK: - Structural parser (if/repeat/try/assert + predicates)
//
// `parseStatements(_:)` devuelve un AST `[ScriptStatement]`. Reusa `parseScript`
// para lexing + comment/blank filtering. El parser es recursive-descent sobre
// líneas tokenizadas, sin indent-sensitivity: los bloques se cierran con `end`
// (estilo Pascal). `else` y `catch` son separadores internos del bloque padre.
//
// Keywords reservadas: if, else, end, repeat, times, while, until, for, in,
// try, catch, assert, and, or, not, is.

public func parseStatements(_ content: String) throws -> [ScriptStatement] {
    let lines = parseScript(content)
    var idx = 0
    let (stmts, next) = try parseStatementBlock(lines: lines, from: idx, stopAt: [])
    idx = next
    if idx < lines.count {
        // Shouldn't happen — top-level parser should consume all.
        throw ScriptParseError.unexpectedEnd(line: lines[idx].lineNumber)
    }
    return stmts
}

/// Parsea un bloque de statements hasta alcanzar uno de los keywords en
/// `stopAt` (o EOF). Devuelve (stmts, índice siguiente).
/// El token que detiene NO se consume — el caller decide qué hacer con él.
private func parseStatementBlock(
    lines: [(lineNumber: Int, tokens: [String])],
    from start: Int,
    stopAt: Set<String>
) throws -> ([ScriptStatement], Int) {
    var stmts: [ScriptStatement] = []
    var i = start

    while i < lines.count {
        let line = lines[i]
        let head = line.tokens[0]

        if stopAt.contains(head) {
            return (stmts, i)
        }

        switch head {
        case "end":
            // `end` solo es válido si el caller lo esperaba (stopAt).
            throw ScriptParseError.unexpectedEnd(line: line.lineNumber)

        case "if":
            let (node, next) = try parseIfStatement(lines: lines, from: i)
            stmts.append(node)
            i = next

        case "repeat":
            let (node, next) = try parseRepeatStatement(lines: lines, from: i)
            stmts.append(node)
            i = next

        case "try":
            let (node, next) = try parseTryStatement(lines: lines, from: i)
            stmts.append(node)
            i = next

        case "assert":
            let predTokens = Array(line.tokens.dropFirst())
            let pred = try parsePredicate(tokens: predTokens, line: line.lineNumber)
            stmts.append(.assertStatement(cond: pred, lineNumber: line.lineNumber))
            i += 1

        default:
            stmts.append(.action(tokens: line.tokens, lineNumber: line.lineNumber))
            i += 1
        }
    }

    return (stmts, i)
}

private func parseIfStatement(
    lines: [(lineNumber: Int, tokens: [String])],
    from start: Int
) throws -> (ScriptStatement, Int) {
    let head = lines[start]
    // head.tokens == ["if", <predicate tokens>...]
    let predTokens = Array(head.tokens.dropFirst())
    let cond = try parsePredicate(tokens: predTokens, line: head.lineNumber)

    let (thenBody, afterThen) = try parseStatementBlock(
        lines: lines, from: start + 1, stopAt: ["else", "end"]
    )

    guard afterThen < lines.count else {
        throw ScriptParseError.unclosedBlock(keyword: "if", startLine: head.lineNumber)
    }

    var elseBody: [ScriptStatement] = []
    var next = afterThen
    if lines[afterThen].tokens[0] == "else" {
        let (body, afterElse) = try parseStatementBlock(
            lines: lines, from: afterThen + 1, stopAt: ["end"]
        )
        guard afterElse < lines.count else {
            throw ScriptParseError.unclosedBlock(keyword: "if", startLine: head.lineNumber)
        }
        elseBody = body
        next = afterElse
    }

    // Ahora lines[next].tokens[0] == "end"
    return (.ifBlock(cond: cond, then: thenBody, else_: elseBody), next + 1)
}

private func parseRepeatStatement(
    lines: [(lineNumber: Int, tokens: [String])],
    from start: Int
) throws -> (ScriptStatement, Int) {
    let head = lines[start]
    let tokens = head.tokens
    // Posibilidades:
    //   repeat N times
    //   repeat while <pred>
    //   repeat until <pred>
    //   repeat for $var in $list
    guard tokens.count >= 2 else {
        throw ScriptParseError.invalidRepeat(
            message: "missing arguments",
            line: head.lineNumber
        )
    }

    let kind: RepeatKind
    switch tokens[1] {
    case "while":
        let pred = try parsePredicate(tokens: Array(tokens.dropFirst(2)), line: head.lineNumber)
        kind = .whileCond(pred)
    case "until":
        let pred = try parsePredicate(tokens: Array(tokens.dropFirst(2)), line: head.lineNumber)
        kind = .untilCond(pred)
    case "for":
        // repeat for $var in $list
        guard tokens.count >= 5, tokens[3] == "in" else {
            throw ScriptParseError.invalidRepeat(
                message: "expected `for $var in $list`",
                line: head.lineNumber
            )
        }
        kind = .forEach(variable: tokens[2], list: tokens[4])
    default:
        // repeat N times
        guard let n = Int(tokens[1]),
              tokens.count >= 3, tokens[2] == "times" else {
            throw ScriptParseError.invalidRepeat(
                message: "expected `repeat N times`, `while`, `until` or `for`",
                line: head.lineNumber
            )
        }
        kind = .times(n)
    }

    let (body, after) = try parseStatementBlock(
        lines: lines, from: start + 1, stopAt: ["end"]
    )
    guard after < lines.count else {
        throw ScriptParseError.unclosedBlock(keyword: "repeat", startLine: head.lineNumber)
    }
    return (.repeatBlock(kind: kind, body: body), after + 1)
}

private func parseTryStatement(
    lines: [(lineNumber: Int, tokens: [String])],
    from start: Int
) throws -> (ScriptStatement, Int) {
    let head = lines[start]
    let (body, afterBody) = try parseStatementBlock(
        lines: lines, from: start + 1, stopAt: ["catch", "end"]
    )
    guard afterBody < lines.count else {
        throw ScriptParseError.unclosedBlock(keyword: "try", startLine: head.lineNumber)
    }

    var catchBody: [ScriptStatement] = []
    var next = afterBody
    if lines[afterBody].tokens[0] == "catch" {
        let (cb, afterCatch) = try parseStatementBlock(
            lines: lines, from: afterBody + 1, stopAt: ["end"]
        )
        guard afterCatch < lines.count else {
            throw ScriptParseError.unclosedBlock(keyword: "try", startLine: head.lineNumber)
        }
        catchBody = cb
        next = afterCatch
    }

    return (.tryBlock(body: body, catch_: catchBody), next + 1)
}

// MARK: - Predicate parser

/// Parsea una expresión de predicado con operadores `and`, `or`, `not`.
/// Precedencia: `not` > `and` > `or`.
public func parsePredicate(tokens: [String], line: Int) throws -> Predicate {
    var idx = 0
    let pred = try parseOr(tokens: tokens, at: &idx, line: line)
    if idx < tokens.count {
        throw ScriptParseError.invalidPredicate(
            message: "trailing tokens: \(tokens.dropFirst(idx).joined(separator: " "))",
            line: line
        )
    }
    return pred
}

private func parseOr(tokens: [String], at idx: inout Int, line: Int) throws -> Predicate {
    var left = try parseAnd(tokens: tokens, at: &idx, line: line)
    while idx < tokens.count, tokens[idx] == "or" {
        idx += 1
        let right = try parseAnd(tokens: tokens, at: &idx, line: line)
        left = .or(left, right)
    }
    return left
}

private func parseAnd(tokens: [String], at idx: inout Int, line: Int) throws -> Predicate {
    var left = try parseNot(tokens: tokens, at: &idx, line: line)
    while idx < tokens.count, tokens[idx] == "and" {
        idx += 1
        let right = try parseNot(tokens: tokens, at: &idx, line: line)
        left = .and(left, right)
    }
    return left
}

private func parseNot(tokens: [String], at idx: inout Int, line: Int) throws -> Predicate {
    if idx < tokens.count, tokens[idx] == "not" {
        idx += 1
        let inner = try parseNot(tokens: tokens, at: &idx, line: line)
        return .not(inner)
    }
    return try parseAtom(tokens: tokens, at: &idx, line: line)
}

private func parseAtom(tokens: [String], at idx: inout Int, line: Int) throws -> Predicate {
    guard idx < tokens.count else {
        throw ScriptParseError.invalidPredicate(message: "unexpected end", line: line)
    }

    if tokens[idx] == "(" {
        idx += 1
        let inner = try parseOr(tokens: tokens, at: &idx, line: line)
        guard idx < tokens.count, tokens[idx] == ")" else {
            throw ScriptParseError.invalidPredicate(message: "missing `)`", line: line)
        }
        idx += 1
        return inner
    }

    // Atom: name + args until next operator boundary or end
    let name = tokens[idx]
    idx += 1
    var args: [String] = []
    let boundary: Set<String> = ["and", "or", "not", ")"]
    while idx < tokens.count, !boundary.contains(tokens[idx]) {
        args.append(tokens[idx])
        idx += 1
    }

    return .call(name: name, args: args)
}
