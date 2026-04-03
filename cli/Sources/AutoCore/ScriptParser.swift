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
