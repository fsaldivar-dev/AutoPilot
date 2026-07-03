import Foundation

// AST del lenguaje `.auto` extendido con control flow.
//
// Contract:
//   - Primitivas del CLI son `.action(tokens:)` — se ejecutan vía dispatcher.
//   - `if/else`, `repeat`, `try/catch`, `assert` son nodos estructurales
//     que envuelven otros statements.
//   - Predicados (`Predicate`) se evalúan llamando a Actions-predicado
//     (`.exists`, `.isVisible`, etc.) vía `ActionRouter`.
//
// Keywords reservadas: if, else, end, repeat, times, while, until,
// for, in, try, catch, assert, and, or, not, is.

// MARK: - ScriptStatement

public indirect enum ScriptStatement: Equatable {
    /// Una primitiva CLI: ["tap", "Login"], ["type", "user", "in", "Field"], etc.
    case action(tokens: [String], lineNumber: Int)

    case ifBlock(cond: Predicate, then: [ScriptStatement], else_: [ScriptStatement])

    case repeatBlock(kind: RepeatKind, body: [ScriptStatement])

    case tryBlock(body: [ScriptStatement], catch_: [ScriptStatement])

    case assertStatement(cond: Predicate, lineNumber: Int)
}

// MARK: - RepeatKind

public enum RepeatKind: Equatable {
    case times(Int)
    case whileCond(Predicate)
    case untilCond(Predicate)
    case forEach(variable: String, list: String)
}

// MARK: - Predicate

public indirect enum Predicate: Equatable {
    /// Un "call" de predicado: nombre + argumentos. Ejemplos:
    ///   exists "Login"                  → .call("exists", ["Login"])
    ///   visible "Submit"                → .call("visible", ["Submit"])
    ///   platform is ios                 → .call("platform", ["is", "ios"])
    ///   text of "Label" is "Hola"       → .call("text", ["of", "Label", "is", "Hola"])
    ///
    /// El interpreter mapea estos nombres a `Action` concretos.
    case call(name: String, args: [String])

    case and(Predicate, Predicate)
    case or(Predicate, Predicate)
    case not(Predicate)
}

// MARK: - Parse errors

public enum ScriptParseError: Error, Equatable, CustomStringConvertible {
    case unexpectedEnd(line: Int)
    case unclosedBlock(keyword: String, startLine: Int)
    case expectedKeyword(expected: String, got: String, line: Int)
    case invalidPredicate(message: String, line: Int)
    case invalidRepeat(message: String, line: Int)
    case emptyScript

    public var description: String {
        switch self {
        case .unexpectedEnd(let line):
            return "Unexpected `end` at line \(line) (no matching block)"
        case .unclosedBlock(let keyword, let line):
            return "Unclosed `\(keyword)` block starting at line \(line)"
        case .expectedKeyword(let expected, let got, let line):
            return "Expected `\(expected)` but got `\(got)` at line \(line)"
        case .invalidPredicate(let msg, let line):
            return "Invalid predicate at line \(line): \(msg)"
        case .invalidRepeat(let msg, let line):
            return "Invalid repeat at line \(line): \(msg)"
        case .emptyScript:
            return "Script is empty"
        }
    }
}

// MARK: - Interpreter errors

public enum InterpreterError: Error, Equatable, CustomStringConvertible {
    case assertionFailed(line: Int)
    case unknownPredicate(name: String, line: Int)
    case invalidBooleanResult(from: String, line: Int)
    /// Un comando o predicado falló con un error ajeno al interpreter
    /// (excepción de bridge/router). Envuelve el error original con el número
    /// de línea del statement — sin esto, un "Cannot connect to observer"
    /// abortaba el run sin decir en qué línea (#154).
    case commandFailed(line: Int, message: String)

    public var description: String {
        switch self {
        case .assertionFailed(let line):
            return "Assertion failed at line \(line)"
        case .unknownPredicate(let name, let line):
            return "Unknown predicate `\(name)` at line \(line)"
        case .invalidBooleanResult(let from, let line):
            return "Predicate `\(from)` at line \(line) did not return a boolean"
        case .commandFailed(let line, let message):
            return "FAIL at line \(line): \(message)"
        }
    }
}
