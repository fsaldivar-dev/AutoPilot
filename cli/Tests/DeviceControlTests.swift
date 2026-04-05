import XCTest
@testable import AutoCore

/// Mock bridge that records all calls for verification.
final class MockBridge: DeviceBridge {
    var calls: [(method: String, args: [String])] = []

    private func record(_ method: String, _ args: String...) {
        calls.append((method, args))
    }

    func lastCall() -> (method: String, args: [String])? { calls.last }
    func callCount(_ method: String) -> Int { calls.filter { $0.method == method }.count }

    // MARK: - Keyboard
    func pressKey(key: String) throws { record("pressKey", key) }
    func hideKeyboard() throws { record("hideKeyboard") }
    func eraseText(count: Int) throws { record("eraseText", "\(count)") }

    // MARK: - Text
    func copyTextFrom(target: String) throws -> String {
        record("copyTextFrom", target)
        return "mock-text-value"
    }

    // MARK: - App Data
    func clearState(bundleId: String) throws { record("clearState", bundleId) }
    func uninstallApp(bundleId: String) throws { record("uninstallApp", bundleId) }

    // MARK: - Scroll
    func scrollTo(target: String, direction: String, maxAttempts: Int) throws {
        record("scrollTo", target, direction, "\(maxAttempts)")
    }

    // MARK: - Recording
    func startRecording() throws { record("startRecording") }
    func stopRecording(outputPath: String) throws { record("stopRecording", outputPath) }

    // MARK: - Environment
    func setLocation(latitude: Double, longitude: Double) throws {
        record("setLocation", "\(latitude)", "\(longitude)")
    }
    func setAppearance(mode: String) throws { record("setAppearance", mode) }
    func lockDevice() throws { record("lockDevice") }
    func unlockDevice() throws { record("unlockDevice") }

    // MARK: - Files
    func pushFile(localPath: String, remotePath: String) throws {
        record("pushFile", localPath, remotePath)
    }
    func pullFile(remotePath: String, localPath: String) throws {
        record("pullFile", remotePath, localPath)
    }

    // MARK: - Existing protocol methods (stubs)
    func tree() throws -> [[String: Any]] { [] }
    func search(query: String) throws -> [[String: Any]] { [] }
    func elementAt(x: Double, y: Double) throws -> [String: Any]? { nil }
    func tap(target: String) throws { record("tap", target) }
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
    func getBootedDeviceId() throws -> String { "mock-device-id" }
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
}

// MARK: - Tests

final class DeviceControlTests: XCTestCase {

    var bridge: MockBridge!

    override func setUp() {
        bridge = MockBridge()
    }

    // MARK: - pressKey

    func testPressKeyDispatch() throws {
        let handled = try executeSharedCommand(["pressKey", "home"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.method, "pressKey")
        XCTAssertEqual(bridge.lastCall()?.args, ["home"])
    }

    func testPressKeyNoArg() throws {
        let handled = try executeSharedCommand(["pressKey"], bridge: bridge)
        XCTAssertTrue(handled) // Prints usage, returns true
        XCTAssertEqual(bridge.callCount("pressKey"), 0) // No bridge call
    }

    func testPressKeyVariousKeys() throws {
        for key in ["enter", "delete", "tab", "escape", "volumeUp", "volumeDown", "back", "power"] {
            bridge.calls = []
            _ = try executeSharedCommand(["pressKey", key], bridge: bridge)
            XCTAssertEqual(bridge.lastCall()?.args, [key], "pressKey \(key) should pass through")
        }
    }

    // MARK: - hideKeyboard

    func testHideKeyboardDispatch() throws {
        let handled = try executeSharedCommand(["hideKeyboard"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("hideKeyboard"), 1)
    }

    // MARK: - eraseText

    func testEraseTextWithCount() throws {
        let handled = try executeSharedCommand(["eraseText", "5"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["5"])
    }

    func testEraseTextDefaultCount() throws {
        _ = try executeSharedCommand(["eraseText"], bridge: bridge)
        XCTAssertEqual(bridge.lastCall()?.args, ["1"]) // default 1
    }

    // MARK: - copyTextFrom

    func testCopyTextFromDispatch() throws {
        let handled = try executeSharedCommand(["copyTextFrom", "Total"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["Total"])
    }

    func testCopyTextFromNoArg() throws {
        let handled = try executeSharedCommand(["copyTextFrom"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("copyTextFrom"), 0)
    }

    // MARK: - clearState

    func testClearStateDispatch() throws {
        let handled = try executeSharedCommand(["clearState", "com.example.app"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["com.example.app"])
    }

    func testClearStateNoArg() throws {
        let handled = try executeSharedCommand(["clearState"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("clearState"), 0)
    }

    // MARK: - uninstall

    func testUninstallDispatch() throws {
        let handled = try executeSharedCommand(["uninstall", "com.example.app"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.method, "uninstallApp")
        XCTAssertEqual(bridge.lastCall()?.args, ["com.example.app"])
    }

    // MARK: - scrollTo

    func testScrollToDefaults() throws {
        let handled = try executeSharedCommand(["scrollTo", "Element"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["Element", "down", "20"])
    }

    func testScrollToWithDirection() throws {
        _ = try executeSharedCommand(["scrollTo", "Element", "up"], bridge: bridge)
        XCTAssertEqual(bridge.lastCall()?.args, ["Element", "up", "20"])
    }

    func testScrollToWithMaxAttempts() throws {
        _ = try executeSharedCommand(["scrollTo", "Element", "down", "5"], bridge: bridge)
        XCTAssertEqual(bridge.lastCall()?.args, ["Element", "down", "5"])
    }

    // MARK: - Recording

    func testStartRecordingDispatch() throws {
        let handled = try executeSharedCommand(["startRecording"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("startRecording"), 1)
    }

    func testStopRecordingDispatch() throws {
        let handled = try executeSharedCommand(["stopRecording", "video.mp4"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["video.mp4"])
    }

    func testStopRecordingNoArg() throws {
        let handled = try executeSharedCommand(["stopRecording"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("stopRecording"), 0)
    }

    // MARK: - setLocation

    func testSetLocationDispatch() throws {
        let handled = try executeSharedCommand(["setLocation", "19.4326", "-99.1332"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["19.4326", "-99.1332"])
    }

    func testSetLocationInvalidArgs() throws {
        let handled = try executeSharedCommand(["setLocation", "abc", "def"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("setLocation"), 0) // Invalid, no call
    }

    func testSetLocationTooFewArgs() throws {
        let handled = try executeSharedCommand(["setLocation", "19.4326"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("setLocation"), 0)
    }

    // MARK: - setAppearance

    func testSetAppearanceDark() throws {
        let handled = try executeSharedCommand(["setAppearance", "dark"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["dark"])
    }

    func testSetAppearanceLight() throws {
        _ = try executeSharedCommand(["setAppearance", "light"], bridge: bridge)
        XCTAssertEqual(bridge.lastCall()?.args, ["light"])
    }

    func testSetAppearanceNoArg() throws {
        let handled = try executeSharedCommand(["setAppearance"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("setAppearance"), 0)
    }

    // MARK: - lockDevice / unlockDevice

    func testLockDeviceDispatch() throws {
        let handled = try executeSharedCommand(["lockDevice"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("lockDevice"), 1)
    }

    func testUnlockDeviceDispatch() throws {
        let handled = try executeSharedCommand(["unlockDevice"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("unlockDevice"), 1)
    }

    // MARK: - pushFile / pullFile

    func testPushFileDispatch() throws {
        let handled = try executeSharedCommand(["pushFile", "/local/file.txt", "/remote/file.txt"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["/local/file.txt", "/remote/file.txt"])
    }

    func testPullFileDispatch() throws {
        let handled = try executeSharedCommand(["pullFile", "/remote/file.txt", "/local/file.txt"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.lastCall()?.args, ["/remote/file.txt", "/local/file.txt"])
    }

    func testPushFileTooFewArgs() throws {
        let handled = try executeSharedCommand(["pushFile", "/only-one"], bridge: bridge)
        XCTAssertTrue(handled)
        XCTAssertEqual(bridge.callCount("pushFile"), 0)
    }

    // MARK: - Unknown command returns false

    func testUnknownCommandNotHandled() throws {
        let handled = try executeSharedCommand(["unknownCmd"], bridge: bridge)
        XCTAssertFalse(handled)
    }
}
