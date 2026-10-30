import XCTest
@testable import MeshBarCore

/// How router auth results become messages. The real Pinnacle 2.2 answer to a
/// wrong header is `_ErrorUnauthorized` with the rejected header echoed back in
/// `error`, so these tests also check that echo never reaches the message.
final class AuthErrorTests: XCTestCase {
    private let endpoint = RouterEndpoint(rawHost: "192.168.1.1", useHTTPS: true)!

    private func client(_ transport: JNAPTransport, password: String = "example-password") -> JNAPClient {
        JNAPClient(
            configuration: .init(endpoint: endpoint, username: "admin", password: password, trustSelfSignedCertificate: false),
            transport: transport
        )
    }

    func testResultCodesMapToAuthErrors() {
        XCTAssertEqual(JNAPError.authError(forResult: "_ErrorUnauthorized"), .unauthorized(code: "_ErrorUnauthorized"))
        XCTAssertEqual(JNAPError.authError(forResult: "ErrorInvalidAdminPassword"), .unauthorized(code: "ErrorInvalidAdminPassword"))
        XCTAssertEqual(
            JNAPError.authError(forResult: "_ErrorAdminPasswordLockedOut"),
            .lockedOut(code: "_ErrorAdminPasswordLockedOut", retryAfterSeconds: nil)
        )
        XCTAssertEqual(
            JNAPError.authError(forResult: "_ErrorTooManyAttempts"),
            .lockedOut(code: "_ErrorTooManyAttempts", retryAfterSeconds: nil)
        )
        XCTAssertNil(JNAPError.authError(forResult: "_ErrorUnknownAction"))
        XCTAssertNil(JNAPError.authError(forResult: "_ErrorAbortedAction"))
    }

    func testMessagesIncludeTheRouterCode() {
        XCTAssertEqual(
            JNAPError.unauthorized(code: "_ErrorUnauthorized").localizedDescription,
            "The router rejected the username or password (_ErrorUnauthorized)."
        )
        XCTAssertTrue(JNAPError.lockedOut(code: "x", retryAfterSeconds: 290).localizedDescription.contains("about 5 minutes"))
        XCTAssertTrue(JNAPError.lockedOut(code: "x", retryAfterSeconds: nil).localizedDescription.contains("Wait about 5 minutes"))
        XCTAssertEqual(JNAPError.actionFailed(action: "a/B", result: "_ErrorUnauthorized").routerCode, "_ErrorUnauthorized")
    }

    func testRejectedHeaderEchoIsNotSurfaced() async {
        let echoed = Data(#"{"result":"_ErrorUnauthorized","error":"Invalid authorization credentials 'Basic ZXhhbXBsZQ=='"}"#.utf8)
        do {
            _ = try await client(ScriptedTransport(response: echoed)).perform(MeshCommands.checkAdminPassword())
            XCTFail("Expected a rejection")
        } catch {
            XCTAssertEqual(error as? JNAPError, .unauthorized(code: "_ErrorUnauthorized"))
            XCTAssertFalse(error.localizedDescription.contains("Basic"))
        }
    }

    func testLockoutResultFromTransaction() {
        let json = Data(#"{"result":"_ErrorAdminLoginLocked"}"#.utf8)
        XCTAssertThrowsError(try JNAPResponseDecoder.outputs(from: json, actions: ["a"])) { error in
            XCTAssertEqual(error as? JNAPError, .lockedOut(code: "_ErrorAdminLoginLocked", retryAfterSeconds: nil))
        }
    }

    func testCheckAdminPasswordSendsPasswordOnlyInHeader() async throws {
        let transport = ScriptedTransport(response: Data(#"{"result":"OK","output":{}}"#.utf8))
        _ = try await client(transport).perform(MeshCommands.checkAdminPassword())
        XCTAssertEqual(String(data: transport.lastBody ?? Data(), encoding: .utf8), "{}")
        XCTAssertEqual(
            transport.lastHeaders["X-JNAP-Authorization"],
            BasicAuthorization.headerValue(username: "admin", password: "example-password")
        )
    }

    func testAuthStatusIsSentWithoutCredentials() async throws {
        let transport = ScriptedTransport(response: Data(#"{"result":"OK","output":{"attemptsRemaining":5}}"#.utf8))
        let data = try await client(transport).perform(MeshCommands.adminAuthStatus())
        XCTAssertNil(transport.lastHeaders["X-JNAP-Authorization"])
        let status = MeshSnapshotParser.parseAdminAuthStatus(data)
        XCTAssertEqual(status, AdminAuthStatus(attemptsRemaining: 5, lockoutSecondsRemaining: nil))
        XCTAssertFalse(status.isLockedOut)
    }

    func testAuthStatusLockout() {
        let locked = MeshSnapshotParser.parseAdminAuthStatus(Data(#"{"attemptsRemaining":0,"delayTimeRemaining":240}"#.utf8))
        XCTAssertTrue(locked.isLockedOut)
        XCTAssertEqual(locked.lockoutSecondsRemaining, 240)
        XCTAssertTrue(MeshSnapshotParser.parseAdminAuthStatus(Data(#"{"attemptsRemaining":0}"#.utf8)).isLockedOut)
    }

    func testPasswordTrimming() {
        XCTAssertEqual(PasswordInput.normalize("example pass\n").value, "example pass")
        XCTAssertTrue(PasswordInput.normalize(" example\t").trimmed)
        XCTAssertFalse(PasswordInput.normalize("example").trimmed)
        XCTAssertEqual(PasswordInput.normalize("in side").value, "in side")
    }

    func testHTTP401KeepsItsCode() {
        XCTAssertEqual(JNAPError.unauthorized(code: "HTTP 401").routerCode, "HTTP 401")
    }
}
