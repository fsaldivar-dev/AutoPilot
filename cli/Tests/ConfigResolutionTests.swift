import XCTest
@testable import AutoCore

/// Tests de la resolución en cascada de `.autopilot` (issue #131):
/// cwd primero, luego walk-up acotado por la raíz del repo (.git),
/// y escritura que crea en cwd anunciando la ruta cuando no hay config.
final class ConfigResolutionTests: XCTestCase {

    private var root: String = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "config-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func mkdir(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func touch(_ path: String, _ content: String = "") throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - resolvedFilePath

    func testUsesConfigInStartDirectory() throws {
        let dir = try mkdir("repo")
        _ = try mkdir("repo/.git")
        try touch("\(dir)/.autopilot", "scheme=App\n")

        XCTAssertEqual(AutoPilotConfig.resolvedFilePath(startingAt: dir), "\(dir)/.autopilot")
    }

    func testWalksUpToRepoRoot() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let sub = try mkdir("repo/a/b")
        try touch("\(repo)/.autopilot", "scheme=App\n")

        XCTAssertEqual(AutoPilotConfig.resolvedFilePath(startingAt: sub), "\(repo)/.autopilot")
    }

    func testPrefersNearestConfigOverRepoRoot() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let mid = try mkdir("repo/a")
        let sub = try mkdir("repo/a/b")
        try touch("\(repo)/.autopilot", "scheme=Root\n")
        try touch("\(mid)/.autopilot", "scheme=Mid\n")

        XCTAssertEqual(AutoPilotConfig.resolvedFilePath(startingAt: sub), "\(mid)/.autopilot")
    }

    func testDoesNotEscapeRepoRoot() throws {
        // Un .autopilot POR ENCIMA de la raíz del repo no debe usarse.
        try touch("\(root)/.autopilot", "scheme=Ajeno\n")
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let sub = try mkdir("repo/a")

        XCTAssertNil(AutoPilotConfig.resolvedFilePath(startingAt: sub))
    }

    func testNoRepoOnlyChecksStartDirectory() throws {
        // Sin .git, el fallback de RepoRoot acota la búsqueda al propio start.
        try touch("\(root)/.autopilot", "scheme=Padre\n")
        let sub = try mkdir("sindotgit")

        XCTAssertNil(AutoPilotConfig.resolvedFilePath(startingAt: sub))
    }

    // MARK: - readAll resuelve rutas contra el dir del config

    func testReadAllResolvesRelativePathKeysAgainstConfigDir() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let sub = try mkdir("repo/a/b")
        try touch("\(repo)/.autopilot", "project=Demo/App.xcodeproj\nimage=img/foto.jpg\nscheme=App\n")

        let config = AutoPilotConfig.readAll(startingAt: sub)
        XCTAssertEqual(config["project"], "\(repo)/Demo/App.xcodeproj")
        XCTAssertEqual(config["image"], "\(repo)/img/foto.jpg")
        XCTAssertEqual(config["scheme"], "App", "las claves que no son rutas no se tocan")
    }

    func testReadAllLeavesAbsolutePathsUntouched() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        try touch("\(repo)/.autopilot", "project=/abs/App.xcodeproj\nimage=~/foto.jpg\n")

        let config = AutoPilotConfig.readAll(startingAt: repo)
        XCTAssertEqual(config["project"], "/abs/App.xcodeproj")
        XCTAssertEqual(config["image"], "~/foto.jpg")
    }

    // MARK: - set escribe en el config resuelto, no en el cwd

    func testSetWritesToExistingConfigFoundByCascade() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let sub = try mkdir("repo/a/b")
        try touch("\(repo)/.autopilot", "project=Demo/App.xcodeproj\n")

        AutoPilotConfig.set("device", value: "iPhone 17", startingAt: sub)

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sub)/.autopilot"),
                       "no debe crear un .autopilot nuevo en el cwd si ya hay uno en el repo")
        let content = try String(contentsOfFile: "\(repo)/.autopilot", encoding: .utf8)
        XCTAssertTrue(content.contains("device=iPhone 17"))
        XCTAssertTrue(content.contains("project=Demo/App.xcodeproj"),
                      "las rutas relativas deben quedar intactas en disco al reescribir")
    }

    func testSetCreatesConfigInStartWhenNoneExists() throws {
        let repo = try mkdir("repo")
        _ = try mkdir("repo/.git")
        let sub = try mkdir("repo/a")

        AutoPilotConfig.set("scheme", value: "App", startingAt: sub)

        let content = try String(contentsOfFile: "\(sub)/.autopilot", encoding: .utf8)
        XCTAssertTrue(content.contains("scheme=App"))
    }

    func testRemoveIsNoOpWithoutConfig() throws {
        let sub = try mkdir("vacio")
        AutoPilotConfig.remove("scheme", startingAt: sub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(sub)/.autopilot"))
    }
}
