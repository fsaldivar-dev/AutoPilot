//
//  Test_AutomatitacionUITests.swift
//  Test AutomatitacionUITests
//
//  Created by Francisco Javier Saldivar Rubio on 31/03/26.
//

import XCTest

final class Test_AutomatitacionUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - AutoPilot Runner Spike
    //
    // These tests are part of the XCUIBridge spike (plan: tranquil-knitting-truffle.md).
    // They validate two hypotheses that unblock the whole XCUIBridge implementation:
    //
    //   1. Can XCUIApplication see SwiftUI NavigationBar toolbar buttons that the
    //      external macOS AX of Simulator.app cannot? (testAutoPilotSpikeNavBarVisibility)
    //
    //   2. Can an XCTestCase host a long-lived TCP loopback server inside the runner
    //      process, stay alive via XCTWaiter, and respond to JSON commands?
    //      (testAutoPilotSpikeServeLoopback, gated on AUTOPILOT_SPIKE_SERVE env var)
    //
    // These tests are spike code and will be moved to a dedicated runner target in Ola 2.

    @MainActor
    func testAutoPilotSpikeNavBarVisibility() throws {
        // Use the iOS Settings app: guaranteed present in the simulator, guaranteed
        // to have a NavigationBar with interactive elements (large title + buttons),
        // and does not depend on any app-specific state or authentication flow.
        // This validates the core XCUIBridge hypothesis without fragile navigation.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        // Wait for the root view to settle.
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10),
                      "Settings app failed to reach foreground")

        // Give UIKit a moment to render the initial nav bar.
        _ = settings.navigationBars.firstMatch.waitForExistence(timeout: 5)

        // Dump the full element tree for inspection. We will eyeball this against
        // `auto tree` output from SimulatorBridge to compare what each path sees.
        print("=== AUTOPILOT_SPIKE_TREE_SETTINGS_ROOT ===")
        print(settings.debugDescription)
        print("=== END_TREE_SETTINGS_ROOT ===")

        // Core assertion: XCUIApplication exposes navigationBars as first-class
        // elements with children (static texts / buttons). This is exactly what
        // SimulatorBridge's external macOS AX path cannot see reliably for SwiftUI
        // toolbars: navigation bar content does not surface to AXChildren in many
        // cases (see CLAUDE.md "Limitaciones conocidas iOS").
        let navBarCount = settings.navigationBars.count
        print("=== AUTOPILOT_SPIKE_NAVBAR_COUNT: \(navBarCount) ===")
        XCTAssertGreaterThan(navBarCount, 0,
                             "No navigation bars visible to XCUIApplication — hypothesis FAILED")

        let firstNavBar = settings.navigationBars.firstMatch
        let navBarStaticTexts = firstNavBar.staticTexts.count
        let navBarButtons = firstNavBar.buttons.count
        print("=== AUTOPILOT_SPIKE_NAVBAR_CONTENT: statics=\(navBarStaticTexts) buttons=\(navBarButtons) ===")

        // The NavBar must have at least one child (the title).
        XCTAssertGreaterThan(navBarStaticTexts + navBarButtons, 0,
                             "Navigation bar had zero queryable children — hypothesis WEAKENED")

        // Navigate into a detail screen to trigger a back button in the NavBar.
        // Use a locale-agnostic strategy: tap the first table cell, which in any
        // locale of Settings should drill into a sub-screen with a back button.
        let firstCell = settings.cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            // Give the navigation push a moment to settle.
            Thread.sleep(forTimeInterval: 1.0)
            print("=== AUTOPILOT_SPIKE_TREE_SETTINGS_DETAIL ===")
            print(settings.debugDescription)
            print("=== END_TREE_SETTINGS_DETAIL ===")

            let detailNavBars = settings.navigationBars.count
            print("=== AUTOPILOT_SPIKE_DETAIL_NAVBARS: \(detailNavBars) ===")
            // On a detail screen we expect a back button in the nav bar.
            let detailButtons = settings.navigationBars.firstMatch.buttons.count
            print("=== AUTOPILOT_SPIKE_DETAIL_NAVBAR_BUTTONS: \(detailButtons) ===")
        } else {
            print("=== AUTOPILOT_SPIKE_NO_FIRST_CELL — could not drill into detail view ===")
        }

        print("=== AUTOPILOT_SPIKE_RESULT: XCUIApplication CAN query navigationBars directly ===")
    }

    @MainActor
    func testAutoPilotSpikeServeLoopback() throws {
        // Gated: only runs when explicitly requested, to keep normal test runs fast.
        let env = ProcessInfo.processInfo.environment
        guard env["AUTOPILOT_SPIKE_SERVE"] == "1" else {
            throw XCTSkip("Set AUTOPILOT_SPIKE_SERVE=1 to run the loopback server spike")
        }

        let app = XCUIApplication()
        app.launch()

        // Start a TCP loopback server on 127.0.0.1:22087 and handle JSON commands.
        // Supported methods: {"method":"ping"}, {"method":"snapshot"}, {"method":"quit"}.
        let port: UInt16 = 22087
        let serverFD = try createLoopbackServer(port: port)
        defer { Darwin.close(serverFD) }

        print("=== AUTOPILOT_SPIKE_SERVE_READY port=\(port) ===")

        // Accept loop on a background queue so the test can block on an expectation.
        let done = XCTestExpectation(description: "server quit")
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = Darwin.accept(serverFD, &clientAddr, &clientLen)
                if clientFD < 0 { continue }

                // Read one line.
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(clientFD, &buf, buf.count)
                if n > 0 {
                    let data = Data(buf[0..<Int(n)])
                    let line = String(data: data, encoding: .utf8) ?? ""
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    let response = Self.handleSpikeCommand(trimmed, app: app)
                    let respData = (response + "\n").data(using: .utf8) ?? Data()
                    respData.withUnsafeBytes { bufPtr in
                        _ = Darwin.write(clientFD, bufPtr.baseAddress, respData.count)
                    }
                    if trimmed.contains("\"quit\"") {
                        Darwin.close(clientFD)
                        done.fulfill()
                        return
                    }
                }
                Darwin.close(clientFD)
            }
        }

        // Block the test on the expectation. Short timeout for the automated spike — 30s is
        // enough to connect, ping, and quit from a helper script. A production runner would
        // use a much longer or effectively infinite timeout here.
        let waiter = XCTWaiter()
        let timeout: TimeInterval = TimeInterval(env["AUTOPILOT_SPIKE_TIMEOUT"].flatMap { Double($0) } ?? 30)
        let result = waiter.wait(for: [done], timeout: timeout)
        XCTAssertEqual(result, .completed, "spike server did not receive quit within budget")
    }

    // MARK: - Spike helpers

    private static func handleSpikeCommand(_ line: String, app: XCUIApplication) -> String {
        if line.contains("\"ping\"") {
            return #"{"ok":true,"result":"pong"}"#
        }
        if line.contains("\"snapshot\"") {
            let tree = app.debugDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "{\"ok\":true,\"result\":\"\(tree)\"}"
        }
        if line.contains("\"quit\"") {
            return #"{"ok":true,"result":"bye"}"#
        }
        return #"{"ok":false,"error":"unknown method"}"#
    }

    private func createLoopbackServer(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "AutoPilotSpike", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                              socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian // 127.0.0.1
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult >= 0 else {
            Darwin.close(fd)
            throw NSError(domain: "AutoPilotSpike", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }

        guard Darwin.listen(fd, 4) >= 0 else {
            Darwin.close(fd)
            throw NSError(domain: "AutoPilotSpike", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        return fd
    }
}
