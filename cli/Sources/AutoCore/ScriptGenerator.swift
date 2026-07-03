import Foundation

/// Converts a stream of ResolvedActions into .auto script lines.
public final class ScriptGenerator {

    private var lines: [String] = []
    private var lastSelector: String?
    private var lastTimestamp: CFAbsoluteTime = 0
    private var lastCommand: String?

    /// Binario con el que se reproduce el script ("auto" iOS /
    /// "auto-android"). El header de las grabaciones Android decía
    /// "Run with: auto run" — binario equivocado (#162).
    private let binaryName: String

    public init(binaryName: String = "auto") {
        self.binaryName = binaryName
    }

    /// Process a resolved action, return the lines to print (and append to buffer).
    /// - uiChanges: number of AX changes since last action (from UIStabilizer)
    public func process(_ action: ResolvedAction, uiChanges: Int, timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [String] {
        var output: [String] = []

        // Dedup: same selector within 300ms is likely bounce noise
        if let last = lastSelector, last == action.selector,
           timestamp - lastTimestamp < 0.3 {
            return []
        }

        // Insert waitFor to make the script state-aware:
        // 1. Before the FIRST semantic tap (after launch/terminate header)
        // 2. After a time gap >1.5s (screen transition)
        // 3. When switching from tapAt to semantic tap (screen likely changed)
        let timeSinceLast = timestamp - lastTimestamp
        let isNavigationGap = timeSinceLast > 1.5 && lastTimestamp > 0 && !lines.isEmpty
        let isFirstTap = lastCommand == nil && !lines.isEmpty
        let switchedFromCoords = lastCommand == "tapAt" && action.command != "tapAt"
        let needsWaitFor = isFirstTap || isNavigationGap || switchedFromCoords

        if needsWaitFor && action.command != "tapAt" {
            // Keep [N] in waitFor — it waits for N+ matches (e.g., dialog to appear)
            let waitLine = "waitFor \"\(action.selector)\""
            lines.append(waitLine)
            output.append(waitLine)
        } else if isNavigationGap && action.command == "tapAt" {
            let waitLine = "wait 1"
            lines.append(waitLine)
            output.append(waitLine)
        }

        // Build the command line
        let line = buildLine(action)

        // Add fragile warning comment
        if action.fragile && action.identifier == nil {
            let warning = "# no accessibilityIdentifier — selector may be fragile"
            lines.append(warning)
            output.append(warning)
        }

        lines.append(line)
        output.append(line)

        lastSelector = action.selector
        lastTimestamp = timestamp
        lastCommand = action.command

        return output
    }

    /// Append a raw line (for terminate/launch/waitFor injection).
    public func appendRaw(_ line: String) {
        lines.append(line)
    }

    /// Preámbulo `terminate` + `launch` del recorder (#161).
    ///
    /// - `midSession: false` (la app NO corría al arrancar la grabación):
    ///   preámbulo activo — el replay reproduce exactamente lo grabado,
    ///   desde el estado inicial de la app.
    /// - `midSession: true` (la app YA corría): preámbulo COMENTADO con
    ///   explicación. Reiniciar la app llevaría al estado inicial, pero los
    ///   pasos grabados asumen la pantalla donde estaba el usuario →
    ///   `FAIL: Timeout` en replay. El usuario decide: replay in-situ
    ///   (default) o descomentar para replay desde cero.
    public func appendLaunchPreamble(bundleId: String, midSession: Bool) {
        if midSession {
            appendRaw("# Grabado a mitad de sesión — el replay asume el estado de pantalla donde estabas.")
            appendRaw("# Descomenta para replay desde cero (la app arrancará en su estado inicial):")
            appendRaw("# terminate \"\(bundleId)\"")
            appendRaw("# launch \"\(bundleId)\"")
        } else {
            appendRaw("terminate \"\(bundleId)\"")
            appendRaw("launch \"\(bundleId)\"")
        }
        appendRaw("")
    }

    /// Render the complete script with header.
    public func render() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = dateFormatter.string(from: Date())

        var script = "# Recorded by AutoPilot — \(date)\n"
        script += "#\n"
        script += "# Run with: \(binaryName) run <this-file>\n"
        script += "#\n\n"

        for line in lines {
            script += line + "\n"
        }

        return script
    }

    /// Number of lines in the script buffer (includes blank separators and comments).
    public var lineCount: Int { lines.count }

    /// Number of executable command lines — excludes blank separators and
    /// `#` comments. Es lo que hay que reportar al usuario: `lineCount`
    /// contaba la línea en blanco del header terminate/launch y los comments
    /// de fragilidad, produciendo el "3 line(s) recorded" con solo 2 comandos
    /// en el archivo (#133).
    public var commandCount: Int {
        lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }

    // MARK: - Private

    private func buildLine(_ action: ResolvedAction) -> String {
        // tapAt uses raw coordinates: tapAt 308 515
        if action.command == "tapAt" {
            return "tapAt \(action.selector)"
        }

        var cmd = action.command

        // Add [role] if present
        if let role = action.role {
            cmd += "[\(role)]"
        }

        var line = "\(cmd) \"\(action.selector)\""

        // Add within scope
        if let within = action.within {
            line += " within \"\(within)\""
        }

        // Trailing args (#91): e.g. longPress "Foto" 1.5
        if let suffix = action.argsSuffix {
            line += " \(suffix)"
        }

        return line
    }
}
