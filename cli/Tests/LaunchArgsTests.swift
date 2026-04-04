import XCTest
@testable import AutoCore

final class LaunchArgsTests: XCTestCase {

    // MARK: - Basic parsing

    func testSimpleLaunch() {
        let result = parseLaunchArgs(["launch", "com.example.app"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.bundleId, "com.example.app")
        XCTAssertNil(result?.injectImage)
        XCTAssertTrue(result?.envVars.isEmpty ?? false)
    }

    func testLaunchWithInject() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--inject", "foto.jpg"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.bundleId, "com.example.app")
        XCTAssertEqual(result?.injectImage, "foto.jpg")
    }

    func testLaunchWithInjectAbsolutePath() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--inject", "/tmp/test-image.png"])
        XCTAssertEqual(result?.injectImage, "/tmp/test-image.png")
    }

    func testLaunchWithInjectNoArgFallsBackToConfig() {
        let config = ["image": "default-camera.jpg"]
        let result = parseLaunchArgs(["launch", "com.example.app", "--inject"], config: config)
        XCTAssertEqual(result?.injectImage, "default-camera.jpg")
    }

    func testLaunchWithInjectNoArgNoConfigReturnsNilImage() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--inject"])
        XCTAssertNil(result?.injectImage)
    }

    // MARK: - Env vars

    func testLaunchWithEnvVar() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--env", "KEY=value"])
        XCTAssertEqual(result?.envVars["KEY"], "value")
    }

    func testLaunchWithMultipleEnvVars() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--env", "A=1", "--env", "B=2"])
        XCTAssertEqual(result?.envVars["A"], "1")
        XCTAssertEqual(result?.envVars["B"], "2")
    }

    // MARK: - Combined flags

    func testLaunchWithInjectAndEnv() {
        let result = parseLaunchArgs(["launch", "com.example.app", "--inject", "foto.jpg", "--env", "DEBUG=true"])
        XCTAssertEqual(result?.bundleId, "com.example.app")
        XCTAssertEqual(result?.injectImage, "foto.jpg")
        XCTAssertEqual(result?.envVars["DEBUG"], "true")
    }

    func testFlagsBeforeBundleId() {
        // --inject before bundleId: bundleId is first non-flag arg
        let result = parseLaunchArgs(["launch", "--inject", "foto.jpg"])
        // No bundleId (--inject is a flag), returns nil
        XCTAssertNil(result)
    }

    // MARK: - Config fallback

    func testBundleIdFromConfig() {
        let config = ["bundle": "com.config.app"]
        let result = parseLaunchArgs(["launch", "--inject", "foto.jpg"], config: config)
        XCTAssertEqual(result?.bundleId, "com.config.app")
        XCTAssertEqual(result?.injectImage, "foto.jpg")
    }

    func testNoBundleIdNoConfigReturnsNil() {
        let result = parseLaunchArgs(["launch"])
        XCTAssertNil(result)
    }
}
