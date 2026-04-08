import Foundation

/// REPL helpers shared by the iOS and Android CLIs.
///
/// The interactive mode keeps a bridge + stabilizer alive between commands so
/// the editor (or any persistent client) can run a whole script without paying
/// the ~100ms cold-start per step and without losing the UIStabilizer state.
///
/// Protocol: newline-delimited JSON (NDJSON). The host sends one script line
/// per `stdin` write; the CLI replies with exactly one JSON object per line.
///
/// Responses always include `ok` (bool) and `ms` (int). Optional fields:
///   - `ready` on the startup banner
///   - `platform` on the startup banner
///   - `out`   stdout captured during the command
///   - `err`   error description (only when `ok=false`)
///   - `skip`  true when the line was empty/comment (ms=0)
///   - `bye`   true when the loop is exiting
public enum InteractiveJSON {

    /// Escape `s` for inclusion inside a JSON string literal.
    /// Hand-rolled so we don't depend on JSONSerialization (keeps the binary
    /// lean and avoids Foundation edge cases with non-UTF8 bytes).
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\":        out.append("\\\\")
            case "\"":        out.append("\\\"")
            case "\n":        out.append("\\n")
            case "\r":        out.append("\\r")
            case "\t":        out.append("\\t")
            case "\u{08}":    out.append("\\b")
            case "\u{0C}":    out.append("\\f")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.append(Character(ch))
                }
            }
        }
        return out
    }

    /// Build a response line for a successful command.
    public static func ok(ms: Int, out: String? = nil) -> String {
        var fields: [String] = ["\"ok\":true", "\"ms\":\(ms)"]
        if let out = out, !out.isEmpty {
            fields.append("\"out\":\"\(escape(out))\"")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    /// Build a response line for a failed command.
    public static func error(ms: Int, message: String, out: String? = nil) -> String {
        var fields: [String] = ["\"ok\":false", "\"ms\":\(ms)", "\"err\":\"\(escape(message))\""]
        if let out = out, !out.isEmpty {
            fields.append("\"out\":\"\(escape(out))\"")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    /// Build the startup banner emitted right before the REPL accepts input.
    public static func ready(platform: String) -> String {
        "{\"ready\":true,\"platform\":\"\(escape(platform))\"}"
    }

    /// Build the response for an empty or comment line (no-op).
    public static func skipped() -> String {
        "{\"ok\":true,\"ms\":0,\"skip\":true}"
    }

    /// Build the farewell response for `exit` / `quit`.
    public static func bye() -> String {
        "{\"ok\":true,\"ms\":0,\"bye\":true}"
    }
}

/// Result of running a command under `captureStdout`.
public struct CapturedCommandResult {
    public let output: String
    public let error: Error?
    public init(output: String, error: Error?) {
        self.output = output
        self.error = error
    }
}

/// Captures everything written to stdout during `block` and returns it, along
/// with any thrown error. The original stdout is restored in every code path.
///
/// This is how the REPL turns the existing `executeCommand(...)` call sites
/// (which use `print(...)` directly) into something whose output can be
/// wrapped in a JSON envelope without refactoring every case to return a
/// string. The dup2-based capture also picks up writes from C code that
/// writes directly to fd 1, which matters for any future additions.
///
/// The pipe is drained concurrently by a background thread so that commands
/// which print more than the kernel's pipe buffer (e.g. `tree` for a
/// full-screen app) don't deadlock inside `write()`.
public func captureStdout(_ block: () -> Void) -> String {
    // Flush anything queued for the real stdout so it doesn't leak into the
    // captured output.
    fflush(stdout)

    let savedStdout = dup(fileno(stdout))
    if savedStdout < 0 {
        block()
        return ""
    }

    var pipeFds: [Int32] = [0, 0]
    let pipeResult = pipe(&pipeFds)
    if pipeResult != 0 {
        close(savedStdout)
        block()
        return ""
    }
    let readFd = pipeFds[0]
    let writeFd = pipeFds[1]

    // Redirect fd 1 to the write end of the pipe.
    dup2(writeFd, fileno(stdout))
    close(writeFd)

    // Drain the read end on a background thread so the writer never blocks
    // on a full pipe buffer. The thread exits when it hits EOF, which
    // happens after we restore the original stdout (no more writers hold
    // the write end).
    let capturedBox = CapturedBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let bufferSize = 4096
        var buf = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = read(readFd, &buf, bufferSize)
            if n > 0 {
                capturedBox.lock.lock()
                capturedBox.data.append(buf, count: n)
                capturedBox.lock.unlock()
            } else {
                // 0 = EOF (no more writers), negative = error.
                break
            }
        }
        close(readFd)
        done.signal()
    }

    // Run the user's block. Output goes into the pipe; the drain queue
    // empties it concurrently so the writer never blocks.
    block()

    // Flush the buffered `stdout` and restore the original descriptor. Once
    // we close the dup'd pipe write end (by restoring), the drain thread
    // will see EOF on its next `read` and exit.
    fflush(stdout)
    dup2(savedStdout, fileno(stdout))
    close(savedStdout)

    // Wait for the drain to finish so we have all the bytes.
    done.wait()

    capturedBox.lock.lock()
    let result = String(data: capturedBox.data, encoding: .utf8) ?? ""
    capturedBox.lock.unlock()
    return result
}

/// Thread-safe scratchpad the pipe-drain thread writes into.
private final class CapturedBox {
    let lock = NSLock()
    var data = Data()
}

/// Like `captureStdout` but also runs a throwing block and returns any error
/// alongside the captured output, so the caller can include the partial stdout
/// in its error response.
public func captureStdoutThrowing(_ block: () throws -> Void) -> CapturedCommandResult {
    var thrown: Error? = nil
    let captured = captureStdout {
        do {
            try block()
        } catch {
            thrown = error
        }
    }
    return CapturedCommandResult(output: captured, error: thrown)
}
