import XCTest
@testable import AutoLib

final class ScriptParserTests: XCTestCase {

    // MARK: - parseScript

    func testParsesSimpleScript() {
        let script = """
        launch com.example.app
        tap "Login"
        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].tokens, ["launch", "com.example.app"])
        XCTAssertEqual(steps[1].tokens, ["tap", "Login"])
    }

    func testSkipsComments() {
        let script = """
        # This is a comment
        tap "Login"
        # Another comment
        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].tokens, ["tap", "Login"])
    }

    func testSkipsBlankLines() {
        let script = """
        tap "Login"

        tap "Password"

        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 2)
    }

    func testPreservesLineNumbers() {
        let script = """
        # comment

        tap "Login"
        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].lineNumber, 3)
    }

    func testEmptyScript() {
        let steps = parseScript("")
        XCTAssertEqual(steps.count, 0)
    }

    func testOnlyComments() {
        let script = """
        # comment 1
        # comment 2
        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 0)
    }

    func testComplexScript() {
        let script = """
        # Login flow
        launch com.example.app
        waitFor "Login" 5
        tap "Username"
        type "user@test.com"
        tap "Password"
        type "secret123"
        tap "Sign In"
        waitFor "Welcome" 10
        screenshot result.png
        """
        let steps = parseScript(script)
        XCTAssertEqual(steps.count, 9)
        XCTAssertEqual(steps[2].tokens, ["tap", "Username"])
        XCTAssertEqual(steps[3].tokens, ["type", "user@test.com"])
    }

    // MARK: - isDeviceUDID

    func testRecognizesUDID() {
        XCTAssertTrue(isDeviceUDID("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
    }

    func testRejectsDeviceName() {
        XCTAssertFalse(isDeviceUDID("iPhone 16"))
    }

    func testRejectsShortString() {
        XCTAssertFalse(isDeviceUDID("short-but-has-dashes"))
    }

    func testRejectsLongWithoutDashes() {
        XCTAssertFalse(isDeviceUDID("A1B2C3D4E5F67890ABCDEF1234567890NOHYPHENS"))
    }
}
