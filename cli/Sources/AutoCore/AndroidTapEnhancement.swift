import Foundation

/// Tap enhancements Android-específicos: `$N`, `label[N]`, multi-tap por coma
/// (`tap 1,2,3,4` — paridad con iOS via `TapTargets`, #145) y Compose
/// clickable parent. Pasa todas las acciones de device por el `ActionRouter`
/// (ARD-001).
public enum AndroidTapEnhancement {

    public static func execute(args: [String], router: ActionRouter, start: CFAbsoluteTime) async throws {
        let raw = args.dropFirst().joined(separator: " ")

        // Multi-tap: "a,b,c" — misma regla que iOS (#145): la coma solo separa
        // si el label completo NO existe como elemento del árbol (match exacto
        // sobre title/label/identifier/id, nunca sobre value). TapTargets solo
        // consulta el árbol si el argumento contiene coma.
        let targets = try await TapTargets.resolve(raw) { try await tree(router: router) }
        for target in targets {
            try await executeSingle(target: target, router: router, start: start)
        }
    }

    private static func executeSingle(target: String, router: ActionRouter, start: CFAbsoluteTime) async throws {
        // $N index reference
        if let idx = TargetResolverShared.parseIndex(target) {
            let tree = try await tree(router: router)
            let index = ElementIndexShared()
            index.build(from: tree)
            guard let entry = index.get(idx) else {
                print("Index $\(idx) not found (max $\(index.count - 1))")
                return
            }
            let tapTarget = entry.label.isEmpty ? entry.id : entry.label
            _ = try await router.execute(.tap(target: tapTarget))
            print("Tapped $\(idx) '\(tapTarget)' (\(elapsedMs(start))ms)")
            return
        }

        // Label[N] occurrence syntax
        let (label, occurrence) = TargetResolverShared.parse(target)
        if let occ = occurrence {
            let tree = try await tree(router: router)
            let matches = TargetResolverShared.findAll(in: tree, matching: label)
            guard let match = matches.first(where: { $0.occurrence == occ }) else {
                print("'\(label)[\(occ)]' not found (\(matches.count) occurrence(s) total)")
                return
            }
            if let frame = match.element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = Double(fx + fw / 2)
                let cy = Double(fy + fh / 2)
                _ = try await router.execute(.tapAtCoordinate(x: cx, y: cy))
            } else {
                let tapLabel = (match.element["title"] as? String) ?? (match.element["label"] as? String) ?? label
                _ = try await router.execute(.tap(target: tapLabel))
            }
            print("Tapped '\(label)[\(occ)]' (\(elapsedMs(start))ms)")
            return
        }

        // Plain label — Compose clickable resolution
        let tree = try await tree(router: router)
        let matches = TargetResolverShared.findAll(in: tree, matching: target)
        if let match = matches.first {
            let clickable = AndroidComposeResolver.findClickableFrame(for: match.element, in: tree)
            if clickable != nil {
                // El frame resuelto puede venir de cualquier ancestro clickable
                // (Button, EditText, contenedor Compose...), así que reportamos
                // el rol real del elemento matcheado en vez de "Button" (issue #139).
                let role = (match.element["role"] as? String) ?? "element"
                fputs("[tap] found clickable frame for '\(target)' (\(role))\n", stderr)
            }
            let tapFrame = clickable ?? match.element["frame"] as? [String: Any]
            if let frame = tapFrame,
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = Double(fx + fw / 2)
                let cy = Double(fy + fh / 2)
                _ = try await router.execute(.tapAtCoordinate(x: cx, y: cy))
                print("Tapped '\(target)' (\(elapsedMs(start))ms)")
                return
            }
        }
        _ = try await router.execute(.tap(target: target))
        print("Tapped '\(target)' (\(elapsedMs(start))ms)")
    }

    /// Unwrapper del router.execute(.tree) — mantiene el resto del código legible.
    private static func tree(router: ActionRouter) async throws -> [[String: Any]] {
        let result = try await router.execute(.tree)
        guard case .elements(let tree) = result else { return [] }
        return tree
    }
}
