import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol JNAPTransport {
    func post(url: URL, headers: [String: String], body: Data) async throws -> Data
}

public enum JNAPError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case transport(String)
    case badJSON
    /// The router refused the credentials. `code` is the router's own result
    /// string, for example `_ErrorUnauthorized`, or `HTTP 401`.
    case unauthorized(code: String)
    /// The router has paused admin logins after too many wrong passwords.
    case lockedOut(code: String, retryAfterSeconds: Int?)
    case actionFailed(action: String, result: String)
    case emptyTransaction
    /// HTTPS failed because the router's certificate is self-signed.
    case untrustedCertificate
    /// The router aborted a `core/Transaction` because the children at these
    /// indices failed. The other children were not run.
    case transactionRejected(failedIndices: [Int])
    /// Like `transactionRejected`, but at least one child said
    /// `_ErrorUnauthorized`. Pinnacle 2.2 answers this way both for a wrong
    /// password and for a single action the admin account may not call, so
    /// the client checks the password before deciding which it is.
    case transactionChildUnauthorized(failedIndices: [Int], codes: [String])

    /// The router's own result code, when the error came from the router.
    public var routerCode: String? {
        switch self {
        case let .unauthorized(code), let .lockedOut(code, _): return code
        case let .actionFailed(_, result): return result
        default: return nil
        }
    }

    /// Maps a non-OK JNAP result string to an auth error, or nil if the result
    /// is not about credentials. Lockout codes are checked first because some
    /// firmware names them `...Password...` as well.
    public static func authError(forResult result: String) -> JNAPError? {
        let lowered = result.lowercased()
        let lockoutWords = ["lock", "toomany", "too_many", "attemptsexceeded", "throttl", "ratelimit", "delay"]
        if lockoutWords.contains(where: lowered.contains) {
            return .lockedOut(code: result, retryAfterSeconds: nil)
        }
        if lowered.contains("password") || lowered.contains("unauthorized") || lowered.contains("authorization") {
            return .unauthorized(code: result)
        }
        return nil
    }

    static func waitAdvice(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else {
            return "Wait about 5 minutes, then try once."
        }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return minutes <= 1 ? "Try again in about a minute." : "Try again in about \(minutes) minutes."
    }

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The router host is not a valid hostname or IP address."
        case let .transport(message):
            return message
        case .badJSON:
            return "The router returned something that was not JNAP JSON."
        case let .unauthorized(code):
            return "The router rejected the username or password (\(code))."
        case let .lockedOut(code, seconds):
            return "The router has paused admin logins after too many wrong passwords (\(code)). "
                + JNAPError.waitAdvice(seconds)
        case let .actionFailed(action, result):
            let short = action.split(separator: "/").last.map(String.init) ?? "Request"
            if let auth = JNAPError.authError(forResult: result) {
                return auth.errorDescription
            }
            return "\(short) failed (\(result))."
        case .emptyTransaction:
            return "Nothing to ask the router."
        case .untrustedCertificate:
            return "The router's HTTPS certificate is self-signed. Turn on \"Trust this host's certificate\" in Settings."
        case .transactionRejected:
            return "The router rejected part of the status request."
        case let .transactionChildUnauthorized(_, codes):
            return "The router refused part of the status request (\(codes.first ?? "_ErrorUnauthorized"))."
        }
    }
}

struct JNAPEnvelope: Decodable {
    var result: String?
    var response: String?
    var output: JSONValue?
    var responses: [JNAPEnvelope]?

    var status: String {
        (result ?? response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isOK: Bool {
        status.caseInsensitiveCompare("OK") == .orderedSame
    }

    func outputData() throws -> Data {
        try (output ?? .object([:])).encodedData()
    }
}

/// Splits a `core/Transaction` body into per-action output JSON.
/// Child actions that are not `OK` are skipped so one rejected call cannot
/// throw away the rest of the poll.
public enum JNAPResponseDecoder {
    public static func outputs(from data: Data, actions: [String]) throws -> ParsedActions {
        let envelope = try decodeEnvelope(data)
        guard envelope.isOK else {
            let status = envelope.status.isEmpty ? "error" : envelope.status
            if let auth = JNAPError.authError(forResult: status) {
                throw auth
            }
            // Pinnacle 2.2 firmware answers a batch with one failing child as
            // `result: "Error"`, the failing child's own error, and
            // `_ErrorAbortedAction` for every other child. Report which children
            // really failed so the caller can drop them and retry.
            let children = envelope.responses ?? []
            let failed = children.enumerated().compactMap { index, child -> Int? in
                if child.isOK || child.status == "_ErrorAbortedAction" { return nil }
                return index
            }
            let authFailures = failed.compactMap { JNAPError.authError(forResult: children[$0].status) }
            if let lockout = authFailures.first(where: { if case .lockedOut = $0 { return true } else { return false } }) {
                throw lockout
            }
            if !authFailures.isEmpty {
                // Do not decide here whether the password is wrong. The client
                // checks it once and then drops only the refused actions.
                throw JNAPError.transactionChildUnauthorized(
                    failedIndices: failed,
                    codes: failed.map { children[$0].status }
                )
            }
            if !failed.isEmpty, failed.count < children.count {
                throw JNAPError.transactionRejected(failedIndices: failed)
            }
            throw JNAPError.actionFailed(action: JNAPAction.transaction, result: status)
        }
        if envelope.responses == nil {
            MeshLog.shape("Transaction response had no responses array")
        }
        let responses = envelope.responses ?? []
        var parsed = ParsedActions()
        for (index, response) in responses.enumerated() {
            let action = index < actions.count ? actions[index] : "response-\(index)"
            guard response.isOK else {
                let status = response.status.isEmpty ? "error" : response.status
                MeshLog.shape("Skipped \(action) because the router returned \(status)")
                continue
            }
            parsed.store(action: action, output: try response.outputData())
        }
        return parsed
    }

    static func isAuthFailure(_ status: String) -> Bool {
        JNAPError.authError(forResult: status) != nil
    }

    static func decodeEnvelope(_ data: Data) throws -> JNAPEnvelope {
        do {
            return try JSONDecoder().decode(JNAPEnvelope.self, from: data)
        } catch {
            throw JNAPError.badJSON
        }
    }
}

/// Talks to the master router only. Extenders are often unreachable on the LAN;
/// the master answers JNAP for the whole mesh.
public final class JNAPClient {
    public struct Configuration: Equatable {
        public var endpoint: RouterEndpoint
        public var username: String
        public var password: String
        public var trustSelfSignedCertificate: Bool
        public var timeout: TimeInterval

        public init(
            endpoint: RouterEndpoint,
            username: String,
            password: String,
            trustSelfSignedCertificate: Bool,
            timeout: TimeInterval = 20
        ) {
            self.endpoint = endpoint
            self.username = username
            self.password = password
            self.trustSelfSignedCertificate = trustSelfSignedCertificate
            self.timeout = timeout
        }
    }

    public var configuration: Configuration
    private let transport: JNAPTransport
    #if os(macOS)
    /// URLSession does not retain its delegate.
    private let trustDelegate: HostPinnedTrustDelegate?
    #endif
    private let ownedSession: URLSession?

    public init(configuration: Configuration, transport: JNAPTransport) {
        self.configuration = configuration
        self.transport = transport
        self.ownedSession = nil
        #if os(macOS)
        self.trustDelegate = nil
        #endif
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        #if os(macOS)
        let delegate = HostPinnedTrustDelegate(
            host: configuration.endpoint.host,
            trustSelfSigned: configuration.trustSelfSignedCertificate
        )
        self.trustDelegate = delegate
        let session = URLSession(
            configuration: JNAPClient.sessionConfiguration(timeout: configuration.timeout),
            delegate: delegate,
            delegateQueue: nil
        )
        #else
        let session = URLSession(configuration: JNAPClient.sessionConfiguration(timeout: configuration.timeout))
        #endif
        self.ownedSession = session
        self.transport = URLSessionJNAPTransport(session: session)
    }

    public func perform(_ call: JNAPCall) async throws -> Data {
        let data = try await send(
            action: call.action,
            body: try call.request.encodedData(),
            authenticated: !JNAPAction.unauthenticated.contains(call.action)
        )
        let envelope = try JNAPResponseDecoder.decodeEnvelope(data)
        guard envelope.isOK else {
            let status = envelope.status.isEmpty ? "error" : envelope.status
            if let auth = JNAPError.authError(forResult: status) {
                throw auth
            }
            throw JNAPError.actionFailed(action: call.action, result: status)
        }
        let output = try envelope.outputData()
        if call.action == JNAPAction.checkAdminPassword, !MeshSnapshotParser.passwordAccepted(output) {
            throw JNAPError.unauthorized(code: "isPasswordValid=false")
        }
        return output
    }

    public func transaction(_ calls: [JNAPCall]) async throws -> ParsedActions {
        try await transaction(calls, refused: [:], credentialsChecked: false)
    }

    private func transaction(
        _ calls: [JNAPCall],
        refused: [String: String],
        credentialsChecked: Bool
    ) async throws -> ParsedActions {
        guard !calls.isEmpty else { throw JNAPError.emptyTransaction }
        let body = JSONValue.array(calls.map { call in
            .object([
                "action": .string(call.action),
                "request": call.request,
            ])
        })
        let data = try await send(action: JNAPAction.transaction, body: try body.encodedData())
        do {
            var parsed = try JNAPResponseDecoder.outputs(from: data, actions: calls.map(\.action))
            parsed.refused.merge(refused) { current, _ in current }
            return parsed
        } catch let JNAPError.transactionRejected(failedIndices) {
            // One unsupported action aborts the whole batch on Pinnacle firmware.
            // Drop the actions the router refused and ask once more for the rest.
            return try await retry(calls, dropping: failedIndices, code: "refused", refused: refused, credentialsChecked: credentialsChecked)
        } catch let JNAPError.transactionChildUnauthorized(failedIndices, codes) {
            // A wrong password and one admin-only action look the same in a
            // batch. Check the password once. If it is wrong, stop here.
            if !credentialsChecked {
                _ = try await perform(MeshCommands.checkAdminPassword())
            }
            // The password is right. Pinnacle 2.2 still refuses some
            // actions inside a batch that it answers on their own, so ask
            // for each one separately and keep whatever it shares.
            let names = zip(failedIndices, codes)
                .map { index, code in "\(index < calls.count ? calls[index].action : "#\(index)") (\(code))" }
                .joined(separator: ", ")
            MeshLog.debug("Batch refused \(names) with a valid password; asking one action at a time")
            var parsed = try await individually(calls)
            parsed.refused.merge(refused) { current, _ in current }
            return parsed
        }
    }

    /// Sends each call on its own. Actions the router refuses are recorded in
    /// `refused` with the router's code. A wrong password still throws.
    public func individually(_ calls: [JNAPCall]) async throws -> ParsedActions {
        guard !calls.isEmpty else { throw JNAPError.emptyTransaction }
        var parsed = ParsedActions()
        parsed.usedSingleCalls = true
        var lastError: Error?
        for call in calls {
            do {
                parsed.store(action: call.action, output: try await perform(call))
            } catch let error as JNAPError {
                if case .lockedOut = error { throw error }
                let code: String
                switch error {
                case let .unauthorized(routerCode): code = routerCode
                case let .actionFailed(_, result): code = result
                default: code = error.routerCode ?? "error"
                }
                parsed.refused[call.action] = code
                lastError = error
                MeshLog.debug("\(call.action) returned \(code)")
            }
        }
        if parsed.refused.count == calls.count, let lastError {
            throw lastError
        }
        return parsed
    }

    private func retry(
        _ calls: [JNAPCall],
        dropping failedIndices: [Int],
        code: String,
        refused: [String: String],
        credentialsChecked: Bool
    ) async throws -> ParsedActions {
        let dropped = Set(failedIndices)
        var refused = refused
        for index in failedIndices where index < calls.count {
            refused[calls[index].action] = code
            MeshLog.debug("Dropped \(calls[index].action) from the poll because the router returned \(code)")
        }
        let remaining = calls.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        guard !remaining.isEmpty, remaining.count < calls.count else {
            throw JNAPError.actionFailed(action: JNAPAction.transaction, result: code == "refused" ? "Error" : code)
        }
        return try await transaction(remaining, refused: refused, credentialsChecked: credentialsChecked)
    }

    /// GET a page on the router with HTTP Basic auth, e.g. `sysinfo.cgi`.
    /// The returned text can contain secrets; callers parse what they need
    /// and drop the rest. Never log or persist it.
    public func fetchPage(path: String) async throws -> String {
        // sysinfo.cgi runs a radio scan before answering, which takes far
        // longer than a JNAP call, so it gets its own session with a long timeout.
        let pageConfiguration = JNAPClient.sessionConfiguration(timeout: 90)
        #if os(macOS)
        let session = URLSession(configuration: pageConfiguration, delegate: trustDelegate, delegateQueue: nil)
        #else
        let session = URLSession(configuration: pageConfiguration)
        #endif
        defer { session.finishTasksAndInvalidate() }
        guard let base = configuration.endpoint.url,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw JNAPError.invalidEndpoint
        }
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else { throw JNAPError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue(BasicAuthorization.headerValue(username: configuration.username, password: configuration.password), forHTTPHeaderField: "Authorization")
        request.setValue("MeshBar/0.1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where URLSessionJNAPTransport.certificateCodes.contains(error.code) {
            throw JNAPError.untrustedCertificate
        } catch {
            throw JNAPError.transport("Could not reach the router. Check the host and that this Mac is on its LAN.")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw JNAPError.unauthorized(code: "HTTP \(http.statusCode)") }
            throw JNAPError.transport("The router returned HTTP \(http.statusCode).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func send(action: String, body: Data, authenticated: Bool = true) async throws -> Data {
        guard let url = configuration.endpoint.url else { throw JNAPError.invalidEndpoint }
        // The password lives only in X-JNAP-Authorization. Do not log this dictionary.
        // Pinnacle firmware echoes a rejected header back in the JSON `error`
        // field, so that field is never decoded or shown either.
        var headers = [
            "X-JNAP-Action": action,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "MeshBar/0.1",
        ]
        if authenticated {
            headers["X-JNAP-Authorization"] = BasicAuthorization.headerValue(
                username: configuration.username,
                password: configuration.password
            )
        }
        return try await transport.post(url: url, headers: headers, body: body)
    }

    private static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

struct URLSessionJNAPTransport: JNAPTransport {
    let session: URLSession

    static let certificateCodes: Set<URLError.Code> = [
        .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot,
        .serverCertificateHasBadDate,
        .serverCertificateNotYetValid,
        .secureConnectionFailed,
    ]

    func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw JNAPError.unauthorized(code: "HTTP \(http.statusCode)")
                }
                throw JNAPError.transport("The router returned HTTP \(http.statusCode).")
            }
            return data
        } catch let error as JNAPError {
            throw error
        } catch let error as URLError where URLSessionJNAPTransport.certificateCodes.contains(error.code) {
            // Linksys routers serve a self-signed certificate, so this is the
            // usual first-run failure. Say so instead of "could not reach".
            throw JNAPError.untrustedCertificate
        } catch {
            throw JNAPError.transport("Could not reach the router. Check the host and that this Mac is on its LAN.")
        }
    }
}

#if os(macOS)
/// Accepts the router certificate for one configured host when the user opts in.
/// Every other host keeps normal trust evaluation. Nothing here is global.
final class HostPinnedTrustDelegate: NSObject, URLSessionDelegate {
    var host: String
    var trustSelfSigned: Bool

    init(host: String, trustSelfSigned: Bool) {
        self.host = host
        self.trustSelfSigned = trustSelfSigned
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let decision = ServerTrustPolicy.decision(
            trustSelfSigned: trustSelfSigned,
            challengedHost: challenge.protectionSpace.host,
            configuredHost: host,
            isServerTrustChallenge: method == NSURLAuthenticationMethodServerTrust
        )
        switch decision {
        case .defaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .cancel:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .acceptPinnedHost:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
#endif
