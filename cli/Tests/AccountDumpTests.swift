import XCTest
@testable import AutoCore

/// Tests del parser de `dumpsys account` (issue #86).
///
/// El fixture `emptyDump` es output real de un emulador API 35
/// (sdk_gphone64_arm64, build `user`) sin cuentas. `dumpWithAccounts` es el
/// mismo dump con la sección `Accounts:` poblada con el formato de
/// `Account.toString()` de AOSP (`Account {name=..., type=...}`).
final class AccountDumpTests: XCTestCase {

    // Capturado con `adb shell dumpsys account` en un emulador API 35.
    private let emptyDump = """
    User UserInfo{0:Owner:4c13}:
      Accounts: 0

      AccountId, Action_Type, timestamp, UID, TableName, Key
      Accounts History

      Active Sessions: 0

      RegisteredServicesCache: 4 services
        ServiceInfo: AuthenticatorDescription {type=com.google.android.gm.pop3}, ComponentInfo{com.google.android.gm/com.android.email.service.Pop3AuthenticatorService}, uid 10167
        ServiceInfo: AuthenticatorDescription {type=com.google}, ComponentInfo{com.google.android.gms/com.google.android.gms.auth.account.authenticator.GoogleAccountAuthenticatorService}, uid 10144
        ServiceInfo: AuthenticatorDescription {type=com.google.android.gm.exchange}, ComponentInfo{com.google.android.gm/com.android.email.service.EasAuthenticatorService}, uid 10167
        ServiceInfo: AuthenticatorDescription {type=com.google.android.gm.legacyimap}, ComponentInfo{com.google.android.gm/com.android.email.service.LegacyImapAuthenticatorService}, uid 10167

      Account visibility:
    """

    private let dumpWithAccounts = """
    User UserInfo{0:Owner:4c13}:
      Accounts: 2
        Account {name=tester@gmail.com, type=com.google}
        Account {name=otro@empresa.com, type=com.facebook.auth.login}

      Active Sessions: 0

      RegisteredServicesCache: 2 services
        ServiceInfo: AuthenticatorDescription {type=com.google}, ComponentInfo{com.google.android.gms/com.google.android.gms.auth.account.authenticator.GoogleAccountAuthenticatorService}, uid 10144
        ServiceInfo: AuthenticatorDescription {type=com.facebook.auth.login}, ComponentInfo{com.facebook.katana/com.facebook.account.FacebookAuthenticatorService}, uid 10201

      Account visibility:
    """

    // MARK: - Accounts

    func testParsesEmptyDump() {
        let parsed = AccountDump.parse(emptyDump)
        XCTAssertTrue(parsed.accounts.isEmpty)
    }

    func testParsesAccounts() {
        let parsed = AccountDump.parse(dumpWithAccounts)
        XCTAssertEqual(parsed.accounts.count, 2)
        XCTAssertEqual(parsed.accounts[0], AccountDump.Account(name: "tester@gmail.com", type: "com.google"))
        XCTAssertEqual(parsed.accounts[1], AccountDump.Account(name: "otro@empresa.com", type: "com.facebook.auth.login"))
    }

    func testDeduplicatesRepeatedAccounts() {
        // Dumps multi-usuario o con secciones repetidas listan la misma
        // cuenta más de una vez — debe aparecer una sola.
        let dump = dumpWithAccounts + "\n" + dumpWithAccounts
        let parsed = AccountDump.parse(dump)
        XCTAssertEqual(parsed.accounts.count, 2)
    }

    func testIgnoresMalformedAccountLines() {
        let parsed = AccountDump.parse("""
          Accounts: 2
            Account {name=sin-tipo}
            Account sin llaves
        """)
        XCTAssertTrue(parsed.accounts.isEmpty)
    }

    // MARK: - Authenticators (type → package)

    func testResolvesAuthenticatorPackages() {
        let parsed = AccountDump.parse(emptyDump)
        XCTAssertEqual(parsed.authenticators["com.google"], "com.google.android.gms")
        XCTAssertEqual(parsed.authenticators["com.google.android.gm.pop3"], "com.google.android.gm")
        XCTAssertEqual(parsed.authenticators.count, 4)
    }

    func testResolvesThirdPartyAuthenticator() {
        let parsed = AccountDump.parse(dumpWithAccounts)
        XCTAssertEqual(parsed.authenticators["com.facebook.auth.login"], "com.facebook.katana")
    }

    func testUnknownTypeHasNoAuthenticator() {
        let parsed = AccountDump.parse(emptyDump)
        XCTAssertNil(parsed.authenticators["com.desconocido"])
    }
}
