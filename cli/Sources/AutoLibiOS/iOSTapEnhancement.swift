import Foundation
import ApplicationServices
import AutoCore

/// Tap enhancements iOS-específicos que van más allá del contrato genérico
/// del `DeviceBridge.tap`. El CLI delega aquí cuando el argumento de tap
/// contiene sintaxis iOS-only que requiere acceso a AX.
///
/// Sintaxis soportadas:
///   - `tap $N`                     → índice en ElementIndex
///   - `tap Camera[2]`              → segunda ocurrencia de Camera
///   - `tap a,b,c`                  → multi-tap secuencial
///   - `tap[button] "label"`        → verificación por role
///   - `tap "label" within "scope"` → búsqueda con scope
///
/// Retorna `true` si manejó el tap; `false` si debe caer al `bridge.tap` genérico.
public enum iOSTapEnhancement {

    public struct Dependencies {
        public let simulatorBridge: SimulatorBridge
        public let elementIndex: ElementIndex
        public let router: ActionRouter

        public init(simulatorBridge: SimulatorBridge, elementIndex: ElementIndex, router: ActionRouter) {
            self.simulatorBridge = simulatorBridge
            self.elementIndex = elementIndex
            self.router = router
        }
    }

    /// Ejecuta el tap con sintaxis enhanced. Retorna el tiempo total en ms.
    ///
    /// #157: el path default (router → observer/XCUI) corre bajo `AutoWait`:
    /// pre-acción espera estabilidad del árbol y post-tap verifica cambio de
    /// hash con un re-tap de cortesía. Los paths AX macOS ($N, label[N],
    /// role/within) quedan fuera — son el motor legacy opt-in (AUTO_FORCE_AX)
    /// y tapean por referencia AXUIElement directa, que no sufre la carrera
    /// de "frame intermedio". El backoff adaptativo de AutoWait cubre el caso
    /// XCUI puro (tree caro → se desactiva solo tras medir una lectura).
    public static func execute(
        args: [String],
        deps: Dependencies,
        start: CFAbsoluteTime,
        autoWait: AutoWait.Config = .current
    ) async throws {

        // Role o within → delega a findAXElementScoped
        if let parsed = parseCommand(args), (parsed.role != nil || parsed.within != nil) {
            let element = try deps.simulatorBridge.findAXElementScoped(
                target: parsed.target, role: parsed.role, within: parsed.within
            )
            deps.simulatorBridge.tapElement(element)
            var desc = "Tapped '\(parsed.target)'"
            if let role = parsed.role { desc += " [\(role)]" }
            if let within = parsed.within { desc += " within '\(within)'" }
            print("\(desc) (\(elapsedMs(start))ms)")
            return
        }

        // Multi-tap: "a,b,c" — la coma solo separa si el label completo no
        // existe como elemento (labels de celdas iOS contienen comas:
        // "Nombre, iPhone"). Match exacto sobre el árbol AX rápido (#124).
        let targets = try TapTargets.resolve(args[1]) { try deps.simulatorBridge.tree() }

        // #158: en multi-tap la estabilización pre-acción del path default
        // (router) se hace UNA sola vez, antes del primer target, y se reusa el
        // pre-hash para la verificación post-tap de cada dígito. El layout de un
        // keypad de PIN no cambia entre dígitos: re-estabilizar por dígito era
        // el grueso del costo creciente por tap tras #157.
        let isMultiTap = targets.count > 1
        var sharedSnapshot: AutoWait.Snapshot?
        if isMultiTap {
            sharedSnapshot = await AutoWait.stabilize(config: autoWait) {
                guard case .elements(let tree) = try await deps.router.execute(.tree) else { return [] }
                return tree
            }
        }
        for target in targets {
            // #158: cronómetro POR target — cada línea "Tapped 'X' (Nms)" mide
            // ese tap, no el acumulado desde el inicio del comando (antes todos
            // imprimían elapsedMs(start), números acumulados y engañosos).
            let targetStart = CFAbsoluteTimeGetCurrent()
            try await executeSingle(target: target, deps: deps, start: targetStart,
                                    sharedSnapshot: isMultiTap ? sharedSnapshot : nil,
                                    autoWait: autoWait)
        }
    }

    private static func executeSingle(
        target: String,
        deps: Dependencies,
        start: CFAbsoluteTime,
        sharedSnapshot: AutoWait.Snapshot? = nil,
        autoWait: AutoWait.Config = .current
    ) async throws {
        // $N → resolve por índice
        if target.hasPrefix("$"), let n = Int(target.dropFirst()) {
            if deps.elementIndex.count == 0 {
                let root = try deps.simulatorBridge.findSimulatorContent()
                deps.elementIndex.rebuild(from: root)
            }
            guard let entry = deps.elementIndex.get(n) else {
                print("Index $\(n) out of range (0..\(deps.elementIndex.count - 1))")
                return
            }
            AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
            let label = entry.label.isEmpty ? entry.id : entry.label
            print("Tapped $\(n) '\(label)' (\(elapsedMs(start))ms)")
            return
        }

        // label[N] → N-th occurrence
        let (label, occurrence) = TargetResolver.parse(target)
        if let occurrence {
            let root = try deps.simulatorBridge.findSimulatorContent()
            let matches = TargetResolver.findAll(in: root, matching: label)
            guard occurrence >= 1 && occurrence <= matches.count else {
                if matches.isEmpty {
                    print("No elements matching '\(label)'")
                } else {
                    print("'\(label)' has \(matches.count) match(es), requested [\(occurrence)]")
                }
                return
            }
            let (element, _) = matches[occurrence - 1]
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            print("Tapped '\(label)[\(occurrence)]' (\(elapsedMs(start))ms)")
            return
        }

        // Default: delega al router (→ AXBackend primero, escala a XCUIBackend)
        // #157: pre-estabilidad + verificación post-tap via el árbol del router
        // (mismo motor que ejecutará el tap). No mezclamos con el árbol AX de
        // TapTargets: hashes de fuentes distintas no son comparables.
        let fetchTree: () async throws -> [[String: Any]] = {
            guard case .elements(let tree) = try await deps.router.execute(.tree) else { return [] }
            return tree
        }
        let doTap: () async throws -> Void = {
            _ = try await deps.router.execute(.tap(target: target))
        }
        // #158: en multi-tap reusamos la estabilización única (sharedSnapshot);
        // en tap único estabilizamos aquí.
        let snapshot: AutoWait.Snapshot?
        if let sharedSnapshot {
            snapshot = sharedSnapshot
        } else {
            snapshot = await AutoWait.stabilize(config: autoWait, fetch: fetchTree)
        }
        try await doTap()
        if let snapshot {
            _ = await AutoWait.verifyTapEffect(target: target, preHash: snapshot.hash,
                                               config: autoWait, fetch: fetchTree, retap: doTap)
        }
        print("Tapped '\(target)' (\(elapsedMs(start))ms)")
    }

    public static func printUsage() {
        print("Usage: auto tap <label>")
        print("       auto tap Camera[2]           (second Camera)")
        print("       auto tap $N                  (by index)")
        print("       auto tap a,b,c               (multiple)")
        print("       auto tap[button] \"label\"      (role verification)")
        print("       auto tap \"label\" within \"scope\"  (scoped search)")
    }
}
