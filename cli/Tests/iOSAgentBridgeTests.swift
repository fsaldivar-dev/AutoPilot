import XCTest
@testable import AutoLibiOS
@testable import AutoCore

final class iOSAgentBridgeTests: XCTestCase {

    // MARK: - probeSocket

    func testProbeSocketReturnsFalseWhenNoServer() {
        // Port 19999 should have nothing listening in CI.
        let bridge = iOSAgentBridge(host: "127.0.0.1", port: 19999)
        XCTAssertFalse(bridge.probeSocket(), "probeSocket should return false when nothing listens on the port")
    }

    // MARK: - sendCommand error path (no server running)

    func testTreeThrowsWhenNotConnected() {
        let bridge = iOSAgentBridge(host: "127.0.0.1", port: 19999)
        XCTAssertThrowsError(try bridge.tree()) { error in
            // #154: el fallo de conexión es tipado (connectionFailed) para que
            // el ActionRouter degrade al siguiente backend en vez de abortar.
            guard case BridgeError.connectionFailed = error else {
                XCTFail("Expected BridgeError.connectionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - observedBundleId (#154)

    func testObservedBundleIdReturnsNilWhenNotConnected() {
        let bridge = iOSAgentBridge(host: "127.0.0.1", port: 19999)
        XCTAssertNil(bridge.observedBundleId(), "Sin socket no hay handshake — debe ser nil, no crash")
    }

    func testTapThrowsWhenNotConnected() {
        let bridge = iOSAgentBridge(host: "127.0.0.1", port: 19999)
        XCTAssertThrowsError(try bridge.tap(target: "Login"))
    }

    func testSearchThrowsWhenNotConnected() {
        // search() calls tree() internally — propagates the connection error.
        let bridge = iOSAgentBridge(host: "127.0.0.1", port: 19999)
        XCTAssertThrowsError(try bridge.search(query: "Login"))
    }

    // MARK: - iOSAgentBackend capabilities

    func testBackendCapabilitiesIncludesCoreUIActions() {
        let caps = iOSAgentBackend.capabilities
        XCTAssertTrue(caps.contains(.tap))
        XCTAssertTrue(caps.contains(.doubleTap))
        XCTAssertTrue(caps.contains(.longPress))
        XCTAssertTrue(caps.contains(.tree))
        XCTAssertTrue(caps.contains(.search))
        XCTAssertTrue(caps.contains(.elementAt))
        XCTAssertTrue(caps.contains(.typeText))
        XCTAssertTrue(caps.contains(.viewport))
    }

    func testBackendCapabilitiesExcludesLifecycleAndMedia() {
        let caps = iOSAgentBackend.capabilities
        // Lifecycle: handled by SimCtlBackend
        XCTAssertFalse(caps.contains(.launchApp))
        XCTAssertFalse(caps.contains(.terminateApp))
        XCTAssertFalse(caps.contains(.installApp))
        // Media: handled by MediaBackend
        XCTAssertFalse(caps.contains(.screenshot))
        XCTAssertFalse(caps.contains(.startRecording))
        // Biometric: handled by SimCtlBackend
        XCTAssertFalse(caps.contains(.biometricMatch))
    }

    // MARK: - iOSDeviceResolver initializes correctly regardless of observer state

    func testiOSDeviceResolverInitializesCorrectly() {
        // iOSDeviceResolver must initialize correctly whether or not the observer is running.
        // agentBridge is non-nil when the observer is reachable (port 7002), nil otherwise.
        let resolver = iOSDeviceResolver()
        // Core bridges must always be present (backwards compat invariant)
        XCTAssertNotNil(resolver.simulatorBridge)
        XCTAssertNotNil(resolver.xcuiBridge)
        XCTAssertNotNil(resolver.legacyBridge)
        // If observer is running agentBridge is set; if not it's nil — both are valid
        let probe = iOSAgentBridge()
        if probe.probeSocket() {
            XCTAssertNotNil(resolver.agentBridge, "agentBridge should be set when observer is reachable")
        } else {
            XCTAssertNil(resolver.agentBridge, "agentBridge should be nil when observer is not reachable")
        }
    }
}
