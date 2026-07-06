import Foundation

/// Variables de script (#195): `$nombre = valor` como línea válida de .auto.
///
///     $ocr = images/ocr-test.png
///     camera feed $ocr
///
/// Sustitución textual de `$nombre` en líneas posteriores. No toca `$0`/`$N`
/// del element index (los nombres empiezan con letra o `_`) ni variables no
/// definidas (quedan intactas para el env del editor u otros consumidores).
/// Mismo contrato que substituteVars del editor — el script corre igual en
/// terminal y en el composer.
public final class VarTable {
    private var vars: [String: String] = [:]
    public init() {}

    private static let bindingRegex = try! NSRegularExpression(
        pattern: "^\\$([A-Za-z_][A-Za-z0-9_.]*)\\s*=\\s*(.+)$"
    )

    /// Si la línea es un binding lo registra y devuelve una descripción
    /// (`$clave = valor`) para el frame/log; si no, nil.
    @discardableResult
    public func consumeBinding(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = Self.bindingRegex.firstMatch(in: line, range: range),
              let keyRange = Range(m.range(at: 1), in: line),
              let valueRange = Range(m.range(at: 2), in: line)
        else { return nil }
        let key = String(line[keyRange])
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
        vars[key] = value
        return "$\(key) = \(value)"
    }

    /// Sustituye `$nombre` por su valor; lo no definido queda intacto.
    public func substitute(_ line: String) -> String {
        guard !vars.isEmpty, line.contains("$") else { return line }
        var result = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "$" {
                var j = line.index(after: i)
                var name = ""
                while j < line.endIndex,
                      line[j].isLetter || line[j].isNumber || line[j] == "_" || line[j] == "." {
                    name.append(line[j])
                    j = line.index(after: j)
                }
                if let first = name.first, first.isLetter || first == "_",
                   let value = vars[name] {
                    result += value
                    i = j
                    continue
                }
            }
            result.append(line[i])
            i = line.index(after: i)
        }
        return result
    }

    /// Preprocesa un script completo: consume los bindings línea a línea
    /// (se quitan del output) y sustituye en el resto. Comentarios y líneas
    /// en blanco pasan intactos. La numeración de líneas del parser cambia
    /// solo en los bindings removidos — aceptable para mensajes de error.
    public static func preprocess(_ content: String) -> String {
        let table = VarTable()
        var out: [String] = []
        for raw in content.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(raw)
                continue
            }
            if table.consumeBinding(trimmed) != nil { continue }
            out.append(table.substitute(raw))
        }
        return out.joined(separator: "\n")
    }
}
