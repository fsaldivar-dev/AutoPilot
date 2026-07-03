import Foundation

/// Resolución de targets multi-tap (#124).
///
/// `tap 1,2,3,4` es multi-tap, pero los labels estándar pueden contener comas
/// ("Nombre, iPhone" en celdas iOS: el AX label es "título, valor"). La coma
/// solo actúa como separador si el target completo NO existe como elemento
/// en el árbol actual.
///
/// El chequeo es match EXACTO sobre title/label/identifier/id — nunca sobre
/// `value`: un textfield que muestre "1,2,3,4" no debe desactivar el multi-tap.
/// Se evalúa sobre el árbol rápido (sin escalación deep) y los errores del
/// provider se propagan: un fallo transitorio del bridge no debe degradar en
/// silencio a multi-tap sobre fragmentos.
public enum TapTargets {

    /// Decide los targets a tapear a partir del argumento crudo.
    /// - Parameters:
    ///   - raw: argumento de `tap` tal como llegó del CLI o del script.
    ///   - treeProvider: entrega el árbol rápido de la plataforma. Solo se
    ///     invoca si `raw` contiene coma.
    public static func resolve(
        _ raw: String,
        treeProvider: () throws -> [[String: Any]]
    ) rethrows -> [String] {
        guard raw.contains(",") else { return [raw] }
        if hasExactMatch(raw, in: try treeProvider()) { return [raw] }
        return split(raw)
    }

    /// Variante async de `resolve` — misma semántica, para rutas donde el
    /// árbol viene del `ActionRouter` (Android, ScriptInterpreter). Ver #145:
    /// las tres rutas de tap deben compartir esta resolución.
    public static func resolve(
        _ raw: String,
        treeProvider: () async throws -> [[String: Any]]
    ) async rethrows -> [String] {
        guard raw.contains(",") else { return [raw] }
        if hasExactMatch(raw, in: try await treeProvider()) { return [raw] }
        return split(raw)
    }

    private static func split(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Match exacto (case-insensitive) contra title/label/identifier/id de
    /// cualquier nodo del árbol, recursivo sobre children.
    public static func hasExactMatch(_ raw: String, in tree: [[String: Any]]) -> Bool {
        let query = raw.lowercased()
        for node in tree {
            for key in ["title", "label", "identifier", "id"] {
                if let value = node[key] as? String, value.lowercased() == query {
                    return true
                }
            }
            if let children = node["children"] as? [[String: Any]],
               hasExactMatch(raw, in: children) {
                return true
            }
        }
        return false
    }
}
