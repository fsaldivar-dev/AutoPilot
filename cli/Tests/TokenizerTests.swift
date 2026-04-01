import XCTest
@testable import AutoLib

final class TokenizerTests: XCTestCase {

    // MARK: - Basic tokenization

    func testSimpleCommand() {
        XCTAssertEqual(tokenize("tap Login"), ["tap", "Login"])
    }

    func testSingleArgument() {
        XCTAssertEqual(tokenize("ping"), ["ping"])
    }

    func testMultipleArguments() {
        XCTAssertEqual(tokenize("type Username user@test.com"), ["type", "Username", "user@test.com"])
    }

    // MARK: - Quoted strings

    func testDoubleQuotedString() {
        XCTAssertEqual(tokenize("tap \"Login Button\""), ["tap", "Login Button"])
    }

    func testSingleQuotedString() {
        XCTAssertEqual(tokenize("tap 'Login Button'"), ["tap", "Login Button"])
    }

    func testMultipleQuotedArgs() {
        XCTAssertEqual(tokenize("type \"Username\" \"user@test.com\""), ["type", "Username", "user@test.com"])
    }

    func testMixedQuotedAndUnquoted() {
        XCTAssertEqual(tokenize("scroll \"tableView\" down"), ["scroll", "tableView", "down"])
    }

    func testQuotedStringWithSpaces() {
        XCTAssertEqual(tokenize("tap \"Sign In Button\""), ["tap", "Sign In Button"])
    }

    // MARK: - Edge cases

    func testEmptyString() {
        XCTAssertEqual(tokenize(""), [])
    }

    func testOnlySpaces() {
        XCTAssertEqual(tokenize("   "), [])
    }

    func testMultipleSpacesBetweenArgs() {
        XCTAssertEqual(tokenize("tap    Login"), ["tap", "Login"])
    }

    func testLeadingAndTrailingSpaces() {
        XCTAssertEqual(tokenize("  tap Login  "), ["tap", "Login"])
    }

    func testEmptyQuotedString() {
        // Empty quotes produce no token, but "type" is still parsed
        XCTAssertEqual(tokenize("type \"\""), ["type"])
    }

    // MARK: - Special characters

    func testURLArgument() {
        XCTAssertEqual(tokenize("openurl myapp://deep/link"), ["openurl", "myapp://deep/link"])
    }

    func testPathArgument() {
        XCTAssertEqual(tokenize("install /path/to/app.app"), ["install", "/path/to/app.app"])
    }

    func testCoordinateArguments() {
        XCTAssertEqual(tokenize("tapAt 200 400"), ["tapAt", "200", "400"])
    }
}
