import Foundation

/// JNAP action URIs this version actually calls.
///
/// The router advertises a much larger catalog (see `docs/jnap-actions.md`).
/// Keeping the called set small and named is deliberate: `core/Reboot` and
/// `core/Reboot2` are easy to mix up, and mixing them up reboots every node.
public enum JNAPAction {
    public static let prefix = "http://linksys.com/jnap/"

    public static let transaction = prefix + "core/Transaction"
    public static let checkAdminPassword = prefix + "core/CheckAdminPassword"
    public static let getDeviceInfo = prefix + "core/GetDeviceInfo"
    /// Unauthenticated. Reports `attemptsRemaining` before the router locks
    /// admin logins. Failed `X-JNAP-Authorization` headers on Pinnacle 2.2 do
    /// not count down; only this counter tells you if a lockout is near.
    public static let getAdminPasswordAuthStatus = prefix + "core/GetAdminPasswordAuthStatus"

    /// Actions sent without the Authorization header, so a wrong password
    /// cannot affect them.
    public static let unauthenticated: Set<String> = [getAdminPasswordAuthStatus]
    /// Reboots the whole router. Never wire this to a per-node button.
    public static let rebootRouter = prefix + "core/Reboot"
    /// Reboots the single node identified by `deviceUUID`.
    public static let rebootNode = prefix + "core/Reboot2"

    public static let getDevices = prefix + "devicelist/GetDevices3"
    public static let setDeviceProperties = prefix + "devicelist/SetDeviceProperties"

    public static let getSystemStats = prefix + "diagnostics/GetSystemStats2"

    public static let getHealthCheckResults = prefix + "healthcheck/GetHealthCheckResults"
    public static let getHealthCheckStatus = prefix + "healthcheck/GetHealthCheckStatus"
    public static let runHealthCheck = prefix + "healthcheck/RunHealthCheck"

    public static let getBackhaul = prefix + "nodes/diagnostics/GetBackhaulInfo2"
    public static let refreshBackhaul = prefix + "nodes/diagnostics/RefreshSlaveBackhaulData"
    public static let getWirelessConnections = prefix + "nodes/networkconnections/GetNodesWirelessNetworkConnections2"

    public static let startBlinking = prefix + "nodes/setup/StartBlinkingNodeLed"
    public static let stopBlinking = prefix + "nodes/setup/StopBlinkingNodeLed"

    public static let getTopologyOptimization = prefix + "nodes/topologyoptimization/GetTopologyOptimizationSettings2"

    public static let getWANStatus = prefix + "router/GetWANStatus3"
    public static let getRadioInfo = prefix + "wirelessap/GetRadioInfo3"
    public static let getDFSSettings = prefix + "wirelessap/GetDFSSettings"
    /// Channels each node is on right now (read-only; StartAutoChannelSelection is never called).
    public static let getSelectedChannels = prefix + "nodes/setup/GetSelectedChannels"

    /// Accept either a full JNAP URI or `service/Action` and return the URI.
    public static func normalize(_ action: String) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return prefix + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// One action inside a call or a `core/Transaction` batch.
public struct JNAPCall: Equatable {
    public var action: String
    public var request: JSONValue

    public init(action: String, request: JSONValue = .object([:])) {
        self.action = JNAPAction.normalize(action)
        self.request = request
    }
}

/// Requests MeshBar knows how to send.
///
/// Payloads follow the Pinnacle 2.2 M62CF-EU (firmware 1.2.4) shapes checked
/// against the router, with field names also seen in uvjim/pyvelop. There is
/// no request here that pins a node's parent. The router does not advertise one.
public enum MeshCommands {
    /// The router checks the password in `X-JNAP-Authorization`, so the body
    /// stays empty and the password is not sent twice.
    public static func checkAdminPassword() -> JNAPCall {
        JNAPCall(action: JNAPAction.checkAdminPassword)
    }

    public static func adminAuthStatus() -> JNAPCall {
        JNAPCall(action: JNAPAction.getAdminPasswordAuthStatus)
    }

    public static func deviceInfo() -> JNAPCall {
        JNAPCall(action: JNAPAction.getDeviceInfo)
    }

    /// Restart one node. The body key is `deviceUUID` on the tested firmware.
    /// This must stay on `core/Reboot2`. `core/Reboot` reboots the entire router.
    public static func rebootNode(deviceUUID: String) -> JNAPCall {
        JNAPCall(
            action: JNAPAction.rebootNode,
            request: .object(["deviceUUID": .string(deviceUUID)])
        )
    }

    /// Restart the whole router. Callers have to confirm this separately from
    /// the per-node action above.
    public static func rebootEntireRouter() -> JNAPCall {
        JNAPCall(action: JNAPAction.rebootRouter, request: .object([:]))
    }

    public static func blink(deviceID: String) -> JNAPCall {
        JNAPCall(
            action: JNAPAction.startBlinking,
            request: .object(["deviceID": .string(deviceID)])
        )
    }

    /// The tested firmware takes an empty object and stops the blink.
    /// It does not take a device id.
    public static func stopBlinking() -> JNAPCall {
        JNAPCall(action: JNAPAction.stopBlinking, request: .object([:]))
    }

    public static func rename(deviceID: String, name: String) -> JNAPCall {
        JNAPCall(
            action: JNAPAction.setDeviceProperties,
            request: .object([
                "deviceID": .string(deviceID),
                "propertiesToModify": .array([
                    .object([
                        "name": .string("userDeviceName"),
                        "value": .string(name),
                    ]),
                ]),
            ])
        )
    }

    public static func refreshBackhaul() -> JNAPCall {
        JNAPCall(action: JNAPAction.refreshBackhaul)
    }

    /// `runHealthCheckModule` is the field the Linksys health-check service expects.
    /// Confirmed via the action list (`healthcheck/RunHealthCheck`) and pyvelop.
    public static func runSpeedTest() -> JNAPCall {
        JNAPCall(
            action: JNAPAction.runHealthCheck,
            request: .object(["runHealthCheckModule": .string("SpeedTest")])
        )
    }

    public static func healthStatus() -> JNAPCall {
        JNAPCall(action: JNAPAction.getHealthCheckStatus)
    }

    public static func healthResults(last: Int = 5) -> JNAPCall {
        JNAPCall(
            action: JNAPAction.getHealthCheckResults,
            request: .object([
                "healthCheckModule": .string("SpeedTest"),
                "includeModuleResults": .bool(true),
                "lastNumberOfResults": .number(Double(max(1, last))),
            ])
        )
    }

    /// Read-only poll. Extenders are not contacted directly; every action goes
    /// to the master router, which answers for the mesh.
    ///
    /// `sinceRevision: 0` asks GetDevices3 for the full device table.
    public static func statusPoll() -> [JNAPCall] {
        [
            deviceInfo(),
            JNAPCall(
                action: JNAPAction.getDevices,
                request: .object(["sinceRevision": .number(0)])
            ),
            JNAPCall(action: JNAPAction.getBackhaul),
            JNAPCall(action: JNAPAction.getWirelessConnections),
            JNAPCall(action: JNAPAction.getWANStatus),
            JNAPCall(action: JNAPAction.getRadioInfo),
            JNAPCall(action: JNAPAction.getSystemStats),
            healthStatus(),
            healthResults(last: 1),
            JNAPCall(action: JNAPAction.getTopologyOptimization),
        ]
    }
}

/// Basic auth header value. The password never goes in the URL.
public enum BasicAuthorization {
    public static func headerValue(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        let token = Data(raw.utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

/// Host (and optional port) of the master router. User paste of a full URL is
/// accepted and reduced to a host so a password in a URL cannot be sent.
public struct RouterEndpoint: Equatable {
    public var host: String
    public var port: Int?
    public var useHTTPS: Bool

    public init?(rawHost: String, useHTTPS: Bool) {
        guard let parsed = RouterEndpoint.parse(rawHost) else { return nil }
        self.host = parsed.host
        self.port = parsed.port
        self.useHTTPS = useHTTPS
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = useHTTPS ? "https" : "http"
        components.host = host
        if let port {
            components.port = port
        }
        components.path = "/JNAP/"
        return components.url
    }

    private static func parse(_ raw: String) -> (host: String, port: Int?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let query = text.firstIndex(of: "?") {
            text = String(text[..<query])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let host: String
        let port: Int?
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<end])
            let rest = text[text.index(after: end)...]
            if rest.isEmpty {
                port = nil
            } else if rest.hasPrefix(":"), let value = Int(rest.dropFirst()), (1...65535).contains(value) {
                port = value
            } else {
                return nil
            }
        } else if text.filter({ $0 == ":" }).count == 1, !text.contains("::") {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = Int(parts[1]), (1...65535).contains(value) else {
                return nil
            }
            host = parts[0]
            port = value
        } else {
            host = text
            port = nil
        }

        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableHost(cleaned) else { return nil }
        return (cleaned, port)
    }

    private static func isAcceptableHost(_ host: String) -> Bool {
        guard host.count <= 253, !host.contains(" "), !host.contains("@") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) } && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
}
