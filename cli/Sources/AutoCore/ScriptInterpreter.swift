import Foundation

// ScriptInterpreter — evaluator del AST producido por `parseStatements(_:)`.
//
// **Responsabilidad:** traducir el AST en llamadas a `ActionRouter.execute(_:)`.
// NO sabe nada de bridges concretos — usa el router existente para respetar
// el paradigma ARD-001 (Command + Capability Discovery).
//
// **Mapping tokens → Action:**
//   - Comandos comunes (tap, type, screenshot, wait, etc.) se traducen
//     directo en `actionFromTokens(_:)`.
//   - `wait N` usa Task.sleep local (no es una Action del router).
//   - Predicados en if/repeat/assert se evalúan llamando `.exists` /
//     `.isVisible` / `.hasText` / `.getPlatform` / `.getOrientation`.
//
// **Propiedades preservadas:**
//   - `try/catch` en AST suprime errores dentro del body → ejecuta catch_.
//   - `and/or` short-circuit evalúan solo lo necesario.
//   - `repeat while/until` comparten la semántica tradicional.

public actor ScriptInterpreter {

    /// Callback que el interpreter invoca cuando un token de acción no tiene
    /// mapping directo a `Action` (por ejemplo `ping`, `index`, `doctor`,
    /// `camera`, `config`). El CLI puede delegar al dispatcher legacy acá
    /// para preservar retro-compatibilidad sin duplicar lógica.
    public typealias UnknownCommandHandler = @Sendable ([String], Int) async throws -> Void

    private let router: ActionRouter
    private let onUnknownCommand: UnknownCommandHandler?

    public init(router: ActionRouter, onUnknownCommand: UnknownCommandHandler? = nil) {
        self.router = router
        self.onUnknownCommand = onUnknownCommand
    }

    // MARK: - Public entry

    public func run(_ statements: [ScriptStatement]) async throws {
        for stmt in statements {
            try await execute(stmt)
        }
    }

    // MARK: - Dispatcher

    private func execute(_ stmt: ScriptStatement) async throws {
        switch stmt {
        case .action(let tokens, let line):
            try await executeAction(tokens: tokens, line: line)

        case .ifBlock(let cond, let then, let else_):
            let ok = try await evaluate(cond, line: 0)
            let body = ok ? then : else_
            for s in body { try await execute(s) }

        case .repeatBlock(let kind, let body):
            try await executeRepeat(kind: kind, body: body)

        case .tryBlock(let body, let catch_):
            do {
                for s in body { try await execute(s) }
            } catch {
                for s in catch_ { try await execute(s) }
            }

        case .assertStatement(let cond, let line):
            let ok = try await evaluate(cond, line: line)
            guard ok else { throw InterpreterError.assertionFailed(line: line) }
        }
    }

    // MARK: - Repeat

    private func executeRepeat(kind: RepeatKind, body: [ScriptStatement]) async throws {
        switch kind {
        case .times(let n):
            for _ in 0..<max(n, 0) {
                for s in body { try await execute(s) }
            }

        case .whileCond(let pred):
            // Safety guard: max 10_000 iterations to avoid runaway loops.
            var guardCount = 0
            while try await evaluate(pred, line: 0) {
                for s in body { try await execute(s) }
                guardCount += 1
                if guardCount > 10_000 { break }
            }

        case .untilCond(let pred):
            var guardCount = 0
            while !(try await evaluate(pred, line: 0)) {
                for s in body { try await execute(s) }
                guardCount += 1
                if guardCount > 10_000 { break }
            }

        case .forEach:
            // Variables y listas aún no implementadas en el evaluator.
            // Placeholder por ahora: no ejecutar body.
            // TODO(fase-futura): soporte completo con variable binding.
            break
        }
    }

    // MARK: - Predicate evaluation

    private func evaluate(_ pred: Predicate, line: Int) async throws -> Bool {
        switch pred {
        case .call(let name, let args):
            return try await evalPredicateCall(name: name, args: args, line: line)
        case .and(let lhs, let rhs):
            if !(try await evaluate(lhs, line: line)) { return false }
            return try await evaluate(rhs, line: line)
        case .or(let lhs, let rhs):
            if try await evaluate(lhs, line: line) { return true }
            return try await evaluate(rhs, line: line)
        case .not(let inner):
            return !(try await evaluate(inner, line: line))
        }
    }

    private func evalPredicateCall(name: String, args: [String], line: Int) async throws -> Bool {
        switch name {
        case "exists":
            guard let target = args.first else {
                throw InterpreterError.unknownPredicate(name: "exists (no target)", line: line)
            }
            return try await resolveBool(action: .exists(target: target), name: name, line: line)

        case "visible", "isVisible":
            guard let target = args.first else {
                throw InterpreterError.unknownPredicate(name: "visible (no target)", line: line)
            }
            return try await resolveBool(action: .isVisible(target: target), name: name, line: line)

        case "hasText":
            // hasText "Label" "text"
            guard args.count >= 2 else {
                throw InterpreterError.unknownPredicate(name: "hasText (missing args)", line: line)
            }
            return try await resolveBool(action: .hasText(target: args[0], text: args[1]), name: name, line: line)

        case "text":
            // text of "Label" is "value"   (args: ["of", "Label", "is", "value"])
            // Desugar a hasText.
            guard args.count >= 4, args[0] == "of", args[2] == "is" else {
                throw InterpreterError.unknownPredicate(name: "text (bad form)", line: line)
            }
            return try await resolveBool(action: .hasText(target: args[1], text: args[3]), name: name, line: line)

        case "platform":
            // platform is ios   →   args: ["is", "ios"]
            guard args.count >= 2, args[0] == "is" else {
                throw InterpreterError.unknownPredicate(name: "platform (bad form)", line: line)
            }
            let result = try await router.execute(.getPlatform)
            guard case .text(let actual) = result else {
                throw InterpreterError.invalidBooleanResult(from: "platform", line: line)
            }
            return actual.lowercased() == args[1].lowercased()

        case "orientation":
            guard args.count >= 2, args[0] == "is" else {
                throw InterpreterError.unknownPredicate(name: "orientation (bad form)", line: line)
            }
            let result = try await router.execute(.getOrientation)
            guard case .text(let actual) = result else {
                throw InterpreterError.invalidBooleanResult(from: "orientation", line: line)
            }
            return actual.lowercased() == args[1].lowercased()

        default:
            throw InterpreterError.unknownPredicate(name: name, line: line)
        }
    }

    private func resolveBool(action: Action, name: String, line: Int) async throws -> Bool {
        let result = try await router.execute(action)
        guard case .bool(let value) = result else {
            throw InterpreterError.invalidBooleanResult(from: name, line: line)
        }
        return value
    }

    // MARK: - Action execution (token → Action)

    private func executeAction(tokens: [String], line: Int) async throws {
        guard !tokens.isEmpty else { return }
        let cmd = tokens[0]

        // Comandos meta (sin Action correspondiente).
        if cmd == "wait" {
            // wait <ms>
            guard let ms = tokens.count > 1 ? Int(tokens[1]) : nil else { return }
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            return
        }

        // Dos estrategias:
        //   1. Si hay `onUnknownCommand` (integración CLI real), delegar TODO
        //      allí para preservar stabilizer, logs y dispatcher completo.
        //      `tap` incluido: los CLIs resuelven multi-tap por coma en sus
        //      enhancements (iOSTapEnhancement / AndroidTapEnhancement), que
        //      ya consumen `TapTargets` (#144/#145).
        //   2. Si no hay handler (modo router directo: tests, embebido),
        //      mapear a Actions conocidas y ejecutar vía el router.
        if let onUnknownCommand {
            try await onUnknownCommand(tokens, line)
            return
        }

        // `tap` en modo router directo pasa por la MISMA resolución multi-tap
        // que los CLIs (#145): la coma solo separa si el label completo no
        // existe como elemento del árbol rápido.
        if cmd == "tap", tokens.count >= 2 {
            let targets = try await TapTargets.resolve(tokens[1]) {
                guard case .elements(let tree) = try await router.execute(.tree) else { return [] }
                return tree
            }
            for target in targets {
                _ = try await router.execute(.tap(target: target))
            }
            return
        }

        if let action = actionFromTokens(tokens) {
            _ = try await router.execute(action)
        }
        // Token no mapeable sin handler → ignorar silenciosamente.
    }

    /// Convierte tokens de una línea de script en una `Action`. Solo mapea
    /// primitivas comunes de flows típicos. Extensible sin romper backward
    /// compat (token desconocido → nil → caller maneja).
    private func actionFromTokens(_ tokens: [String]) -> Action? {
        let cmd = tokens[0]
        switch cmd {
        // Nota: `tap` NO se mapea acá — `executeAction` lo intercepta antes
        // para pasar por `TapTargets.resolve` (multi-tap por coma, #145).
        case "doubleTap":
            guard tokens.count >= 2 else { return nil }
            return .doubleTap(target: tokens[1])

        case "longPress":
            guard tokens.count >= 2 else { return nil }
            let duration = tokens.count >= 3 ? (Double(tokens[2]) ?? 1.0) : 1.0
            return .longPress(target: tokens[1], duration: duration)

        case "type":
            guard tokens.count >= 2 else { return nil }
            return .typeText(tokens[1])

        case "clear":
            guard tokens.count >= 2 else { return nil }
            return .clear(target: tokens[1])

        case "screenshot":
            let path = tokens.count >= 2 ? tokens[1] : "screenshot.png"
            return .screenshot(path: path)

        case "swipe":
            guard tokens.count >= 2 else { return nil }
            return .swipe(direction: tokens[1])

        case "scroll":
            guard tokens.count >= 3 else { return nil }
            return .scroll(target: tokens[1], direction: tokens[2])

        case "launch":
            guard tokens.count >= 2 else { return nil }
            return .launchApp(bundleId: tokens[1], envVars: [:])

        case "terminate":
            guard tokens.count >= 2 else { return nil }
            return .terminateApp(bundleId: tokens[1])

        case "exists":
            // También expuesto como predicado, pero standalone puede ejecutarse
            // sólo por efecto lateral (ignoramos el resultado).
            guard tokens.count >= 2 else { return nil }
            return .exists(target: tokens[1])

        case "visible", "isVisible":
            guard tokens.count >= 2 else { return nil }
            return .isVisible(target: tokens[1])

        case "tree":
            return .tree

        default:
            return nil
        }
    }
}
