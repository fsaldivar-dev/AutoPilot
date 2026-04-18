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
        public let bridge: any DeviceBridge

        public init(simulatorBridge: SimulatorBridge, elementIndex: ElementIndex, bridge: any DeviceBridge) {
            self.simulatorBridge = simulatorBridge
            self.elementIndex = elementIndex
            self.bridge = bridge
        }
    }

    /// Ejecuta el tap con sintaxis enhanced. Retorna el tiempo total en ms.
    public static func execute(args: [String], deps: Dependencies, start: CFAbsoluteTime) throws {

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

        // Multi-tap: "a,b,c" o sintaxis individual
        let targets = args[1].split(separator: ",").map(String.init)
        for target in targets {
            try executeSingle(target: target, deps: deps, start: start)
        }
    }

    private static func executeSingle(target: String, deps: Dependencies, start: CFAbsoluteTime) throws {
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

        // Default: delega al bridge genérico
        try deps.bridge.tap(target: target)
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
