import Foundation

/// Parser puro del output de `adb shell dumpsys account` (issue #86).
///
/// Extrae dos cosas del dump del AccountManagerService:
///
/// 1. **Cuentas registradas** — líneas `Account {name=..., type=...}` bajo
///    la sección `Accounts: N` de cada usuario.
/// 2. **Autenticadores registrados** — líneas de `RegisteredServicesCache`
///    con forma `ServiceInfo: AuthenticatorDescription {type=com.google},
///    ComponentInfo{com.google.android.gms/...}, uid 10144`. De ahí sale el
///    mapping tipo de cuenta → package que la provee, que es lo que
///    `clearAccounts` necesita para saber a quién hacerle `pm clear`.
///
/// El parseo es line-based y tolerante: líneas que no matchean se ignoran,
/// cuentas duplicadas (dumps multi-usuario o secciones repetidas) se
/// deduplican preservando el orden de aparición.
public struct AccountDump {

    public struct Account: Hashable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// Cuentas del sistema en orden de aparición, sin duplicados.
    public let accounts: [Account]

    /// Tipo de cuenta (`com.google`) → package del autenticador que la
    /// provee (`com.google.android.gms`).
    public let authenticators: [String: String]

    public static func parse(_ dump: String) -> AccountDump {
        var seen = Set<Account>()
        var accounts: [Account] = []
        var authenticators: [String: String] = [:]

        for rawLine in dump.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Account {"),
               let name = extract(from: line, after: "{name=", upTo: ", type="),
               let type = extract(from: line, after: ", type=", upTo: "}") {
                let account = Account(name: name, type: type)
                if seen.insert(account).inserted {
                    accounts.append(account)
                }
            } else if line.contains("AuthenticatorDescription {type="),
                      let type = extract(from: line, after: "AuthenticatorDescription {type=", upTo: "}"),
                      let package = extract(from: line, after: "ComponentInfo{", upTo: "/") {
                authenticators[type] = package
            }
        }

        return AccountDump(accounts: accounts, authenticators: authenticators)
    }

    /// Substring entre `prefix` y la primera ocurrencia de `suffix` después
    /// del prefix. `nil` si alguno de los dos no está.
    private static func extract(from line: String, after prefix: String, upTo suffix: String) -> String? {
        guard let prefixRange = line.range(of: prefix),
              let suffixRange = line.range(of: suffix, range: prefixRange.upperBound..<line.endIndex)
        else { return nil }
        return String(line[prefixRange.upperBound..<suffixRange.lowerBound])
    }
}
