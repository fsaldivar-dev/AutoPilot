import XCTest
import CoreGraphics
@testable import AutoCore

/// Bridge mock programable para tests de `waitFor`/`waitUntilGone`.
/// Permite setear una secuencia de respuestas para `existsFast` y contar
/// cuántas veces fue consultado.
final class WaitForMockBridge: DeviceBridge {
    var existsSequence: [Bool] = []
    var existsFastCallCount = 0
    var searchCallCount = 0

    // Para casos `label[N]` con N>1 — waitFor cae a search()
    var searchResultsSequence: [[[String: Any]]] = []

    // MARK: - Overrides relevantes

    func existsFast(label: String) throws -> Bool {
        existsFastCallCount += 1
        if existsSequence.isEmpty { return false }
        return existsSequence.removeFirst()
    }

    func search(query: String) throws -> [[String: Any]] {
        searchCallCount += 1
        if searchResultsSequence.isEmpty { return [] }
        return searchResultsSequence.removeFirst()
    }

    // MARK: - Protocolo no relevante (stubs)

    func tree() throws -> [[String: Any]] { [] }
    func elementAt(x: Double, y: Double) throws -> [String: Any]? { nil }
    func tap(target: String) throws {}
    func longPress(target: String, duration: Double) throws {}
    func doubleTap(target: String) throws {}
    func clear(target: String) throws {}
    func typeText(_ text: String) throws {}
    func scroll(target: String, direction: String) throws {}
    func swipe(direction: String) throws {}
    func tapAtCoordinate(x: Double, y: Double) throws {}
    func launchApp(bundleId: String, envVars: [String: String]) throws {}
    func terminateApp(bundleId: String) throws {}
    func listDevices() throws -> [[String: Any]] { [] }
    func bootDevice(_ nameOrUdid: String) throws {}
    func shutdownDevice(_ nameOrUdid: String) throws {}
    func installApp(path: String) throws {}
    func getBootedDeviceId() throws -> String { "mock" }
    func screenshot(path: String) throws {}
    func addMedia(path: String) throws {}
    func openURL(_ url: String) throws {}
    func setPasteboard(text: String) throws {}
    func getPasteboard() throws -> String { "" }
    func biometricEnroll() throws {}
    func biometricUnenroll() throws {}
    func biometricMatch() throws {}
    func biometricFail() throws {}
    func biometricIsEnrolled() throws -> Bool { false }
    func getLogs(bundleId: String?, lines: Int) throws -> String { "" }
    func setPermission(action: String, service: String, bundleId: String) throws {}
    func rotate(direction: String) throws {}
    func drag(from: String, to: String, duration: Double) throws {}
    func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {}
    func pressKey(key: String) throws {}
    func hideKeyboard() throws {}
    func eraseText(count: Int) throws {}
    func copyTextFrom(target: String) throws -> String { "" }
    func clearState(bundleId: String) throws {}
    func uninstallApp(bundleId: String) throws {}
    func viewport() throws -> CGRect { .zero }
    func scrollTo(target: String, direction: String, maxAttempts: Int) throws {}
    func startRecording() throws {}
    func stopRecording(outputPath: String) throws {}
    func setLocation(latitude: Double, longitude: Double) throws {}
    func setAppearance(mode: String) throws {}
    func lockDevice() throws {}
    func unlockDevice() throws {}
    func pushFile(localPath: String, remotePath: String) throws {}
    func pullFile(remotePath: String, localPath: String) throws {}
}

// MARK: - Tests

final class WaitForTests: XCTestCase {

    var bridge: WaitForMockBridge!

    override func setUp() {
        bridge = WaitForMockBridge()
    }

    // MARK: - waitFor happy path

    func testWaitFor_returnsWhenElementAppears() throws {
        // Primera consulta: no existe. Segunda: aparece.
        bridge.existsSequence = [false, true]

        try executeSharedCommand(["waitFor", "Login", "1"], bridge: bridge)

        // existsFast debe haberse llamado al menos 2 veces
        XCTAssertGreaterThanOrEqual(bridge.existsFastCallCount, 2)
        XCTAssertEqual(bridge.searchCallCount, 0, "No debe caer a search() para label simple")
    }

    func testWaitFor_timesOutWhenElementNeverAppears() throws {
        // existSequence vacío → siempre false → timeout
        bridge.existsSequence = []

        XCTAssertThrowsError(
            try executeSharedCommand(["waitFor", "Ghost", "0.3"], bridge: bridge)
        ) { error in
            if let bridgeErr = error as? BridgeError,
               case .timeout(let msg) = bridgeErr {
                XCTAssertTrue(msg.contains("Ghost"))
            } else {
                XCTFail("Se esperaba BridgeError.timeout, obtuve: \(error)")
            }
        }

        // Con timeout 0.3s y poll 100ms: al menos 3 intentos, posiblemente más
        XCTAssertGreaterThanOrEqual(bridge.existsFastCallCount, 3)
    }

    // MARK: - waitUntilGone symmetric

    func testWaitUntilGone_returnsWhenElementDisappears() throws {
        // Presente → presente → desaparece
        bridge.existsSequence = [true, true, false]

        try executeSharedCommand(["waitUntilGone", "Dialog", "1"], bridge: bridge)

        XCTAssertGreaterThanOrEqual(bridge.existsFastCallCount, 3)
    }

    func testWaitUntilGone_timesOutWhenElementStays() throws {
        // Secuencia infinita de true → nunca se va → timeout
        // (con poll 100ms y timeout 0.3s, consumiremos ~3-4)
        bridge.existsSequence = Array(repeating: true, count: 20)

        XCTAssertThrowsError(
            try executeSharedCommand(["waitUntilGone", "Ad", "0.3"], bridge: bridge)
        )
    }

    // MARK: - label[N] syntax → fallback a search()

    func testWaitFor_withOccurrenceFallsBackToSearch() throws {
        // `label[2]` requiere contar → search, no existsFast
        let match: [String: Any] = ["label": "Item"]
        bridge.searchResultsSequence = [[match, match]]  // 2 matches de una

        try executeSharedCommand(["waitFor", "Item[2]", "1"], bridge: bridge)

        XCTAssertEqual(bridge.existsFastCallCount, 0, "Con label[N] N>1 NO debe llamar existsFast")
        XCTAssertGreaterThanOrEqual(bridge.searchCallCount, 1)
    }

    // MARK: - Poll interval aceleración (#79)

    /// Con pollInterval=100ms y timeout=1s, el loop debe intentar ~10 veces
    /// (era 2 con pollInterval=500ms). Esto confirma la aceleración del #79.
    func testWaitFor_pollsMoreFrequentlyThanLegacy() throws {
        bridge.existsSequence = []  // nunca encontrado

        _ = try? executeSharedCommand(["waitFor", "X", "1"], bridge: bridge)

        // Pre-fix: ~2 polls (500ms interval). Post-fix: ~10 polls (100ms interval).
        XCTAssertGreaterThanOrEqual(bridge.existsFastCallCount, 5,
            "Con pollInterval 100ms y timeout 1s deberíamos tener ≥5 polls")
    }
}
