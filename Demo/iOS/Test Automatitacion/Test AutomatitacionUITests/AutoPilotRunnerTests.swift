import XCTest

// MARK: - AutoPilotRunnerTests
//
// Entry point for the XCTest runner. The testServe() method starts a TCP
// server on loopback and blocks via XCTWaiter until a "quit" command is
// received or the test times out (default: 24 hours).
//
// This test is invoked by autopilotd via:
//   xcodebuild test-without-building -xctestrun <path> \
//     -only-testing:AutoPilotRunnerUITests/AutoPilotRunnerTests/testServe

final class AutoPilotRunnerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let portStr = env["AUTOPILOT_RUNNER_PORT"] ?? "22087"
        let port = UInt16(portStr) ?? 22087
        let timeoutStr = env["AUTOPILOT_RUNNER_TIMEOUT"] ?? "86400"
        let timeout = Double(timeoutStr) ?? 86400 // 24 hours default

        // Launch the target app if a bundle ID is provided
        let app: XCUIApplication
        if let bundleId = env["AUTOPILOT_TARGET_BUNDLE"] {
            app = XCUIApplication(bundleIdentifier: bundleId)
        } else {
            app = XCUIApplication()
        }
        // Don't auto-launch — let commands decide when to launch/attach
        // app.launch()

        let server = RunnerServer(port: port, app: app)

        let done = XCTestExpectation(description: "server quit")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.start()
            } catch {
                NSLog("AutoPilotRunner: server error: \(error)")
            }
            done.fulfill()
        }

        let waiter = XCTWaiter()
        let result = waiter.wait(for: [done], timeout: timeout)

        if result == .timedOut {
            NSLog("AutoPilotRunner: server timed out after \(Int(timeout))s")
        }
    }
}
