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
