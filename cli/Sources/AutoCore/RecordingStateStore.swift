import Foundation

// MARK: - RecordingStateStore (issue #125)
//
// `startRecording` / `stopRecording` deben funcionar como comandos CLI sueltos:
// cada invocación es un proceso distinto, así que el estado de la grabación no
// puede vivir en memoria (propiedades de instancia del bridge). En su lugar se
// persiste en un archivo JSON en /tmp — mismo patrón que el pidfile de
// `autopilotd` (`/tmp/autopilot-<udid>.pid`, ver Sources/Daemon/main.swift).
//
// El proceso de grabación se lanza DETACHED (ver `DetachedProcess.launch`):
// un `/bin/sh` intermedio lo pone en background y muere, con lo que el
// grabador queda reparented a launchd. El CLI nunca es su parent directo,
// así que nunca hay zombies y `kill(pid, 0)` detecta vida de forma idéntica
// dentro de un script `.auto` (mismo proceso) y entre invocaciones CLI.

/// Estado persistido de una grabación de pantalla en curso.
public struct RecordingState: Codable, Equatable {
    /// PID del proceso local de grabación (simctl recordVideo en iOS,
    /// cliente `adb shell screenrecord` en Android).
    public let pid: Int32
    /// Identificador del device (UDID del simulador iOS o serial adb).
    public let deviceId: String
    /// Path temporal del video: local en iOS, remoto (/sdcard/...) en Android.
    public let tempPath: String
    /// Timestamp de inicio (diagnóstico).
    public let startedAt: Date

    public init(pid: Int32, deviceId: String, tempPath: String, startedAt: Date = Date()) {
        self.pid = pid
        self.deviceId = deviceId
        self.tempPath = tempPath
        self.startedAt = startedAt
    }
}

/// Persistencia del estado de grabación en un archivo JSON por device.
public struct RecordingStateStore {

    /// Directorio donde viven los archivos de estado. Inyectable para tests.
    private let directory: String

    public init(directory: String = "/tmp") {
        self.directory = directory
    }

    /// Solo alfanumérico + guión, igual que `sanitizedUDID` del daemon,
    /// para evitar path injection con seriales adb raros (tcp:5555, etc.).
    static func sanitizedDeviceId(_ deviceId: String) -> String {
        String(deviceId.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
    }

    /// Path del archivo de estado para un device.
    public func statePath(deviceId: String) -> String {
        "\(directory)/autopilot-recording-\(Self.sanitizedDeviceId(deviceId)).json"
    }

    /// Persiste el estado (sobrescribe si ya existía).
    public func save(_ state: RecordingState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: URL(fileURLWithPath: statePath(deviceId: state.deviceId)), options: .atomic)
    }

    /// Lee el estado si existe y es parseable; nil si no hay grabación registrada.
    public func load(deviceId: String) -> RecordingState? {
        let path = statePath(deviceId: deviceId)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingState.self, from: data)
    }

    /// Borra el archivo de estado (idempotente).
    public func clear(deviceId: String) {
        try? FileManager.default.removeItem(atPath: statePath(deviceId: deviceId))
    }

    /// `kill(pid, 0)` — true si el proceso sigue vivo. Como el grabador nunca
    /// es hijo directo del CLI (ver `DetachedProcess`), no hay zombies que den
    /// falsos positivos.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

/// Lanzamiento de procesos que sobreviven al CLI.
public enum DetachedProcess {

    /// Escapa una string para incrustarla entre comillas simples en sh.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Lanza `command` en background vía `/bin/sh -c "nohup <cmd> ... &"`.
    /// El sh intermedio imprime el PID del hijo y muere, dejando al proceso
    /// reparented a launchd — sobrevive a la salida del CLI y no queda como
    /// zombie de nadie. Devuelve el PID del proceso lanzado.
    public static func launch(_ command: String) throws -> Int32 {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "nohup \(command) </dev/null >/dev/null 2>&1 & echo $!"]
        let stdout = Pipe()
        sh.standardOutput = stdout
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        sh.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw BridgeError.unknown("Failed to launch detached recording process")
        }
        return pid
    }
}
