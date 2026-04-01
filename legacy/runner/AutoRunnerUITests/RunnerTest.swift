import XCTest

/// Entry point for the automation runner.
/// This test case starts the socket server and keeps it alive, listening for commands.
final class RunnerTest: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        // Prevent timeout on the test
        let suite = XCTestSuite(forTestCaseClass: self)
        return suite
    }

    func testSocketServer() throws {
        let app = XCUIApplication()
        app.launch()

        let router = CommandRouter(app: app)

        let server = SocketServer { requestData in
            return router.handle(data: requestData)
        }

        // Handle graceful shutdown
        signal(SIGINT) { _ in
            print("[AutoApp] Shutting down...")
            exit(0)
        }

        print("[AutoApp] Runner started. Waiting for commands...")
        print("[AutoApp] Connect with: nc -U /tmp/autoapp.sock")

        try server.start()
    }
}
