import XCTest
@testable import AutoCore

/// Tests del estado persistido de grabación (issue #125).
/// El store es la pieza que permite que `startRecording`/`stopRecording`
/// funcionen como comandos CLI sueltos: cada invocación es un proceso
/// distinto y el estado vive en un JSON en disco, no en memoria.
final class RecordingStateStoreTests: XCTestCase {

    private var tempDir: String!
    private var store: RecordingStateStore!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "recording-store-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        store = RecordingStateStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Roundtrip

    func testSaveLoadRoundtrip() throws {
        let state = RecordingState(
            pid: 12345,
            deviceId: "ABCD-1234-EF56",
            tempPath: "/tmp/autopilot-recording-xyz.mp4",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try store.save(state)

        let loaded = store.load(deviceId: "ABCD-1234-EF56")
        XCTAssertEqual(loaded, state)
    }

    func testSaveOverwritesPreviousState() throws {
        let first = RecordingState(pid: 111, deviceId: "dev-1", tempPath: "/tmp/a.mp4")
        let second = RecordingState(pid: 222, deviceId: "dev-1", tempPath: "/tmp/b.mp4")
        try store.save(first)
        try store.save(second)

        XCTAssertEqual(store.load(deviceId: "dev-1")?.pid, 222)
        XCTAssertEqual(store.load(deviceId: "dev-1")?.tempPath, "/tmp/b.mp4")
    }

    func testStatesArePerDevice() throws {
        try store.save(RecordingState(pid: 1, deviceId: "emulator-5554", tempPath: "/sdcard/a.mp4"))
        try store.save(RecordingState(pid: 2, deviceId: "emulator-5556", tempPath: "/sdcard/b.mp4"))

        XCTAssertEqual(store.load(deviceId: "emulator-5554")?.pid, 1)
        XCTAssertEqual(store.load(deviceId: "emulator-5556")?.pid, 2)
    }

    // MARK: - Load edge cases

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load(deviceId: "no-such-device"))
    }

    func testLoadCorruptJSONReturnsNil() throws {
        let path = store.statePath(deviceId: "dev-corrupt")
        try "not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load(deviceId: "dev-corrupt"))
    }

    func testLoadEmptyFileReturnsNil() throws {
        let path = store.statePath(deviceId: "dev-empty")
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertNil(store.load(deviceId: "dev-empty"))
    }

    // MARK: - Clear

    func testClearRemovesState() throws {
        try store.save(RecordingState(pid: 99, deviceId: "dev-clear", tempPath: "/tmp/c.mp4"))
        XCTAssertNotNil(store.load(deviceId: "dev-clear"))

        store.clear(deviceId: "dev-clear")
        XCTAssertNil(store.load(deviceId: "dev-clear"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.statePath(deviceId: "dev-clear")))
    }

    func testClearIsIdempotent() {
        store.clear(deviceId: "never-existed")
        store.clear(deviceId: "never-existed")
        // No crash, no throw — idempotente.
    }

    // MARK: - Sanitización del deviceId (path injection)

    func testStatePathSanitizesDeviceId() {
        // Serial adb por TCP con caracteres peligrosos para un path
        let path = store.statePath(deviceId: "192.168.1.5:5555/../etc")
        XCTAssertFalse(path.contains(".."))
        XCTAssertFalse(path.contains(":"))
        XCTAssertTrue(path.hasPrefix(tempDir + "/autopilot-recording-"))
        XCTAssertTrue(path.hasSuffix(".json"))
    }

    func testSanitizedRoundtripStillWorks() throws {
        let weirdId = "192.168.1.5:5555"
        try store.save(RecordingState(pid: 7, deviceId: weirdId, tempPath: "/sdcard/x.mp4"))
        XCTAssertEqual(store.load(deviceId: weirdId)?.pid, 7)
    }

    // MARK: - Detección de proceso vivo

    func testIsProcessAliveForCurrentProcess() {
        XCTAssertTrue(RecordingStateStore.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
    }

    func testIsProcessAliveForDeadPid() {
        // PID máximo de macOS es 99998; este nunca existe.
        XCTAssertFalse(RecordingStateStore.isProcessAlive(999_999))
    }

    func testIsProcessAliveForInvalidPid() {
        // pid <= 0 sería kill a un process group — debe rechazarse.
        XCTAssertFalse(RecordingStateStore.isProcessAlive(0))
        XCTAssertFalse(RecordingStateStore.isProcessAlive(-1))
    }

    // MARK: - Shell quoting del lanzamiento detached

    func testShellQuoteSimple() {
        XCTAssertEqual(DetachedProcess.shellQuote("abc"), "'abc'")
    }

    func testShellQuoteWithSpacesAndQuotes() {
        XCTAssertEqual(DetachedProcess.shellQuote("a b'c"), "'a b'\\''c'")
    }

    // MARK: - Lanzamiento detached (proceso real, sin device)

    func testDetachedLaunchReturnsAlivePid() throws {
        let pid = try DetachedProcess.launch("/bin/sleep 5")
        defer { kill(pid, SIGKILL) }
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(RecordingStateStore.isProcessAlive(pid))
    }

    func testDetachedProcessIsNotOurChild() throws {
        // El grabador queda reparented a launchd: tras morir NO debe quedar
        // zombie de este proceso (kill(pid, 0) pasaría con un zombie hijo).
        let pid = try DetachedProcess.launch("/usr/bin/true")
        let deadline = Date().addingTimeInterval(5)
        while RecordingStateStore.isProcessAlive(pid) && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(RecordingStateStore.isProcessAlive(pid))
    }
}
