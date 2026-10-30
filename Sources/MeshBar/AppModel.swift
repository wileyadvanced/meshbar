import AppKit
import Foundation
import MeshBarCore
import os
import SwiftUI

/// Owns polling, the menu-bar snapshot, history, and the few JNAP writes.
///
/// Extenders are never dialed directly. Every request goes to the master.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var routerPassword: String
    /// When the Keychain item was last written, read from the item itself.
    @Published var passwordSavedAt: Date?
    /// Shown under the password field, e.g. after trimming a pasted newline.
    @Published var passwordNote: String?
    /// The last poll failed on credentials. Shows the Connect button.
    @Published var authFailed = false
    @Published var snapshot: MeshSnapshot?
    @Published var health: MeshHealth = .unknown
    @Published var samples: [HistorySample] = []
    @Published var chartRange: ChartRange = .day
    @Published var selectedNodeID: String?
    /// Client whose connection history sheet is open.
    @Published var detailClient: ClientDetailRequest?
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    /// The running poll was asked for by the user (button, ⌘R, URL).
    @Published var manualRefreshInFlight = false
    /// A user refresh is waiting for the running poll to finish.
    @Published var manualRefreshQueued = false
    /// Set when the last poll failed; cleared by the next good one.
    @Published var refreshFailure: String?
    /// When fresh data last landed. Drives the brief "Updated" highlight.
    @Published var dataLandedAt: Date?
    /// Bumped when a failure should be shown: every failed manual refresh,
    /// and the first failed automatic one (not one per minute while offline).
    @Published var refreshFailedAt: Date?
    @Published var isActing = false
    @Published var speedTest: SpeedTestResult?
    @Published var speedTestRunning = false
    @Published var localIdentity = LocalIdentity(macAddresses: [], ipAddresses: [])
    @Published var bottomTab: BottomTab = .clients
    /// `--view spectrum` starts the dashboard on Spectrum (handy for screenshots).
    @Published var mainView: MainView = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--view"), index + 1 < arguments.count,
           let view = MainView(rawValue: arguments[index + 1]) {
            return view
        }
        return .topology
    }()
    /// Channels per node (GetSelectedChannels) and DFS state.
    @Published var channelPlan: ChannelPlan?
    /// Router site survey, parsed in memory. The raw page is never kept.
    @Published var routerScan: AirwavesScan?
    @Published var macScan: AirwavesScan?
    @Published var routerScanRunning = false
    @Published var macScanRunning = false
    @Published var airwavesNote: String?
    var lastChannelRead: Date?
    var lastRouterScanStart: Date?

    private var store: HistoryStoring?
    private var pollTask: Task<Void, Never>?
    private var lastBackhaulRefresh: Date?
    /// Poll actions this router refused with the current credentials. They are
    /// left out of later polls until the credentials change.
    private var refusedActions: [String: String] = [:]
    /// Set when this router refuses parts of a batch it answers one by one.
    private var singleCalls = false
    private var gate = RefreshGate()
    private var demoNames: [String: String] = [:]
    /// `--client-detail <name>` opens that client's history once it is seen.
    private var pendingLaunchDetailID: String?
    /// `--select-node <name>` selects that node in the inspector at launch.
    private var launchSelectNodeMatch: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--select-node"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()
    private var launchClientDetailMatch: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--client-detail"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()
    private let alerts = AlertEngine(debounce: 120)
    private let log = Logger(subsystem: "com.meshbar.app", category: "jnap")

    enum MainView: String, CaseIterable, Identifiable {
        case topology
        case spectrum

        var id: String { rawValue }
        var title: String { self == .topology ? "Topology" : "Spectrum" }
        var symbol: String { self == .topology ? "point.3.connected.trianglepath.dotted" : "waveform" }
    }

    enum BottomTab: String, CaseIterable, Identifiable {
        case clients
        case history
        case speed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clients: return "Clients"
            case .history: return "History"
            case .speed: return "Speed test"
            }
        }
    }

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        routerPassword = KeychainStore.load(
            account: KeychainStore.account(username: loaded.username, host: loaded.routerHost)
        ) ?? ""
        passwordSavedAt = KeychainStore.modificationDate(
            account: KeychainStore.account(username: loaded.username, host: loaded.routerHost)
        )
        settings.launchAtLogin = LaunchAtLogin.isEnabled
        URLCommandRouter.model = self
        MeshLog.handler = { [log] message in
            log.notice("\(message, privacy: .public)")
        }
        reopenStore()
        if settings.demoMode {
            seedDemoIfNeeded()
        }
        startPolling()
        MeshNotifier.requestAuthorization()
    }

    /// True when there is no saved password or the router refused it.
    var needsConnect: Bool {
        !settings.demoMode && (routerPassword.isEmpty || authFailed)
    }

    var menuHealth: MeshHealth {
        if snapshot == nil && lastError != nil { return .unknown }
        return health
    }

    var statusGlyph: StatusGlyph {
        if needsConnect {
            return StatusGlyph(symbol: "wifi", level: 0, accessibilityLabel: "MeshBar, not connected")
        }
        switch menuHealth {
        case .offline:
            return StatusGlyph(symbol: "wifi.slash", level: nil, accessibilityLabel: "MeshBar, internet down")
        case .degraded:
            return StatusGlyph(symbol: "wifi.exclamationmark", level: nil, accessibilityLabel: "MeshBar, needs attention")
        case .unknown:
            return StatusGlyph(symbol: lastError == nil ? "wifi" : "wifi.exclamationmark", level: lastError == nil ? 0 : nil, accessibilityLabel: "MeshBar, no data")
        case .healthy, .partial:
            var level = 1.0
            if let snapshot {
                let client = NodeLocator.client(matching: localIdentity, in: snapshot)
                let node = thisMacNodeID.flatMap { snapshot.node(id: $0) }
                level = SignalLevel.forThisMac(client: client, node: node)
            }
            return StatusGlyph(symbol: "wifi", level: level, accessibilityLabel: "MeshBar, \(menuHealth.label)")
        }
    }

    var thisMacNodeID: String? {
        guard let snapshot else { return nil }
        return NodeLocator.node(hosting: localIdentity, in: snapshot)?.id
    }

    var selectedNode: MeshNode? {
        guard let snapshot, let selectedNodeID else { return snapshot?.treeOrder.first }
        return snapshot.node(id: selectedNodeID)
    }

    func activate(_ body: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        body()
        NSApp.activate()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.settings.pollIntervalClamped ?? 60
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        let previous = account
        body(&settings)
        settings.pollIntervalSeconds = settings.pollIntervalClamped
        settings.retentionDays = settings.retentionClamped
        settings.minimumBackhaulMbps = max(0, settings.minimumBackhaulMbps)
        if settings.minimumRSSI >= 0 { settings.minimumRSSI = -70 }
        SettingsStore.save(settings)
        if account != previous {
            routerPassword = KeychainStore.load(account: account) ?? ""
            passwordSavedAt = KeychainStore.modificationDate(account: account)
        }
        if let snapshot {
            health = HealthEvaluator.evaluate(snapshot, thresholds: settings.thresholds)
        }
    }

    /// Saves the password to the Keychain and returns the value actually
    /// stored, which may be trimmed.
    @discardableResult
    func updatePassword(_ rawValue: String) -> String {
        let (newValue, trimmed) = PasswordInput.normalize(rawValue)
        if trimmed {
            passwordNote = "Removed spaces or a line break from the start or end of the password."
        }
        guard newValue != routerPassword || KeychainStore.load(account: account) != newValue else {
            return newValue
        }
        routerPassword = newValue
        do {
            if newValue.isEmpty {
                try KeychainStore.delete(account: account)
                passwordSavedAt = nil
            } else {
                try KeychainStore.save(account: account, password: newValue)
                // Read it back so a Keychain problem cannot look like a wrong password.
                guard KeychainStore.load(account: account) == newValue else {
                    passwordNote = "The Keychain did not return the password that was just saved. Try again, or check Keychain Access for \(KeychainStore.service)."
                    return newValue
                }
                passwordSavedAt = KeychainStore.modificationDate(account: account) ?? Date()
                authFailed = false
                refusedActions = [:]
                singleCalls = false
            }
        } catch {
            passwordNote = "Could not save the password to the Keychain (\(error.localizedDescription))."
        }
        return newValue
    }

    func setDemoMode(_ enabled: Bool) {
        settings.demoMode = enabled
        SettingsStore.save(settings)
        reopenStore()
        clearAirwaves()
        if enabled {
            seedDemoIfNeeded()
        }
        Task { await refresh() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLogin = LaunchAtLogin.isEnabled
            SettingsStore.save(settings)
            if enabled && !LaunchAtLogin.isEnabled {
                lastError = "macOS still needs approval for launch at login. This only works for a bundled MeshBar.app."
            }
        } catch {
            settings.launchAtLogin = LaunchAtLogin.isEnabled
            lastError = "Launch at login needs the bundled app from scripts/bundle.sh. \(error.localizedDescription)"
        }
    }

    func setChartRange(_ range: ChartRange) {
        chartRange = range
        try? reloadSamples()
    }

    /// Refresh button, ⌘R and meshbar://refresh. Always results in a fresh
    /// poll: now if idle, otherwise straight after the one in flight. Asks
    /// the master to re-measure backhaul first so link speeds are current.
    func requestRefresh(source: String) {
        log.notice("Refresh requested from \(source, privacy: .public); poll in flight: \(self.gate.inFlight, privacy: .public)")
        if gate.inFlight && !settings.demoMode {
            manualRefreshQueued = true
        }
        Task { await refresh(forceBackhaul: true, userInitiated: true) }
    }

    func refresh(forceBackhaul: Bool = false, userInitiated: Bool = false) async {
        if settings.demoMode {
            localIdentity = DemoMesh.thisMac
            apply(currentDemoSnapshot(), clearingError: true)
            if channelPlan == nil || routerScan?.source != .demo {
                channelPlan = DemoMesh.channelPlan()
                routerScan = DemoMesh.airwavesScan(at: Date())
                macScan = nil
            }
            refreshFailure = nil
            dataLandedAt = Date()
            return
        }
        guard case let .start(force, manual) = gate.request(forceBackhaul: forceBackhaul, userInitiated: userInitiated) else {
            // Credentials may have changed, or the user asked mid-poll. The
            // gate runs exactly one more poll when this one ends.
            log.notice("Refresh queued behind the poll in flight")
            return
        }
        var next: (force: Bool, manual: Bool)? = (force, manual)
        isRefreshing = true
        while let run = next {
            manualRefreshInFlight = run.manual
            if run.manual { manualRefreshQueued = false }
            await poll(forceBackhaul: run.force, userInitiated: run.manual)
            if case let .start(f, m)? = gate.finish() {
                log.notice("Running the queued refresh")
                next = (f, m)
            } else {
                next = nil
            }
        }
        isRefreshing = false
        manualRefreshInFlight = false
        manualRefreshQueued = false
    }

    private func poll(forceBackhaul: Bool, userInitiated: Bool) async {
        // Built per refresh from the current settings and Keychain value, so a
        // saved password is used on the next call. Nothing is cached.
        guard let client = makeClient() else {
            if snapshot == nil { health = .unknown }
            return
        }
        let started = Date()
        log.notice("Poll started (\(userInitiated ? "manual" : "automatic", privacy: .public), re-measure backhaul: \(RefreshGate.shouldRefreshBackhaul(force: forceBackhaul, last: self.lastBackhaulRefresh), privacy: .public))")
        localIdentity = LocalNetworkIdentity.current()
        do {
            if RefreshGate.shouldRefreshBackhaul(force: forceBackhaul, last: lastBackhaulRefresh) {
                // A failed refresh must not fail the poll. Extender backhaul data
                // is filled in by the master, and it can take a cycle to update.
                if (try? await client.perform(MeshCommands.refreshBackhaul())) != nil, userInitiated {
                    // Give the master a moment to re-measure before reading.
                    try? await Task.sleep(for: .seconds(2))
                }
                lastBackhaulRefresh = Date()
            }
            let calls = MeshCommands.statusPoll().filter { refusedActions[$0.action] == nil }
            let pieces = singleCalls
                ? try await client.individually(calls)
                : try await client.transaction(calls)
            if pieces.usedSingleCalls { singleCalls = true }
            // The user may have switched to demo mode while this request was in flight.
            guard !settings.demoMode else { return }
            refusedActions.merge(pieces.refused) { current, _ in current }
            authFailed = false
            apply(MeshSnapshotParser.parse(pieces, at: Date(), isDemo: false), clearingError: true)
            refreshFailure = nil
            dataLandedAt = Date()
            log.notice("Poll finished in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s")
            await readChannelPlan(client, force: userInitiated)
            if !refusedActions.isEmpty {
                let names = refusedActions
                    .map { action, code in "\(action.split(separator: "/").last.map(String.init) ?? action) (\(code))" }
                    .sorted()
                    .joined(separator: ", ")
                statusMessage = "The router did not share: \(names). The rest is shown."
            }
        } catch {
            if case .unauthorized = error as? JNAPError { authFailed = true }
            if case .lockedOut = error as? JNAPError { authFailed = true }
            lastError = error.localizedDescription
            if userInitiated || refreshFailure == nil { refreshFailedAt = Date() }
            refreshFailure = error.localizedDescription
            if snapshot == nil { health = .unknown }
            log.notice("Poll failed after \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s: \(Self.failureKind(error), privacy: .public)")
        }
    }

    /// A log-safe label for a poll failure. Never includes router payloads.
    private static func failureKind(_ error: Error) -> String {
        guard let jnap = error as? JNAPError else { return "other" }
        switch jnap {
        case .transport: return "transport (router unreachable or HTTP error)"
        case .unauthorized: return "unauthorized"
        case .lockedOut: return "locked out"
        case .untrustedCertificate: return "untrusted certificate"
        case .badJSON: return "bad JSON"
        default: return "router refused (\(jnap.routerCode ?? "no code"))"
        }
    }

    struct ConnectOutcome {
        var success: Bool
        var message: String
    }

    /// Tests a login and, if it works, saves it and starts polling with it.
    /// Turns on certificate trust for this host only if the router's HTTPS
    /// certificate is self-signed.
    func connect(host rawHost: String, username rawUsername: String, password rawPassword: String) async -> ConnectOutcome {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let (password, trimmed) = PasswordInput.normalize(rawPassword)
        guard let endpoint = RouterEndpoint(rawHost: host, useHTTPS: settings.useHTTPS) else {
            return ConnectOutcome(success: false, message: "Enter the router's address, for example 192.168.1.1.")
        }
        guard !username.isEmpty, !password.isEmpty else {
            return ConnectOutcome(success: false, message: "Enter the admin username and password.")
        }
        func client(trust: Bool) -> JNAPClient {
            JNAPClient(configuration: .init(endpoint: endpoint, username: username, password: password, trustSelfSignedCertificate: trust))
        }
        var trust = settings.trustSelfSignedCertificate && endpoint.host.caseInsensitiveCompare(settings.routerHost) == .orderedSame
        var notes: [String] = []
        if trimmed { notes.append("Removed spaces or a line break around the password.") }

        // 1. Reach the router without credentials. This also finds a self-signed certificate.
        var info: Data
        do {
            info = try await client(trust: trust).perform(MeshCommands.deviceInfo())
        } catch JNAPError.untrustedCertificate where settings.useHTTPS && !trust {
            trust = true
            notes.append("The router uses a self-signed HTTPS certificate, as Linksys routers do, so MeshBar now trusts it for \(endpoint.host) only.")
            do {
                info = try await client(trust: true).perform(MeshCommands.deviceInfo())
            } catch {
                return ConnectOutcome(success: false, message: error.localizedDescription)
            }
        } catch {
            return ConnectOutcome(success: false, message: error.localizedDescription)
        }
        let candidate = client(trust: trust)

        // 2. Do not try a password while the router has paused logins.
        if let status = await adminAuthStatus(candidate), status.isLockedOut {
            return ConnectOutcome(
                success: false,
                message: JNAPError.lockedOut(code: "attemptsRemaining=0", retryAfterSeconds: status.lockoutSecondsRemaining).localizedDescription
            )
        }

        // 3. One login check.
        do {
            _ = try await candidate.perform(MeshCommands.checkAdminPassword())
        } catch let error as JNAPError {
            var parts = [error.localizedDescription]
            if case .unauthorized = error {
                parts.append("Sent \(password.count) characters as \"\(username)\".")
                if let left = await adminAuthStatus(candidate)?.attemptsRemaining {
                    parts.append("Router lockout counter: \(left) attempts left.")
                }
                parts.append("Check it by signing in at https://\(endpoint.host).")
            }
            return ConnectOutcome(success: false, message: parts.joined(separator: " "))
        } catch {
            return ConnectOutcome(success: false, message: error.localizedDescription)
        }

        // 4. Save and poll with the new login right away.
        updateSettings {
            $0.routerHost = endpoint.host
            $0.username = username
            $0.trustSelfSignedCertificate = trust
        }
        routerPassword = ""
        updatePassword(password)
        passwordNote = nil
        authFailed = false
        refusedActions = [:]
        singleCalls = false
        lastError = nil
        lastBackhaulRefresh = nil
        snapshot = nil
        await refresh()
        let identity = MeshSnapshotParser.parseIdentityData(info)
        let model = identity?.modelNumber ?? "the router"
        let firmware = identity?.firmwareVersion.map { ", firmware \($0)" } ?? ""
        notes.insert("Connected to \(model)\(firmware).", at: 0)
        return ConnectOutcome(success: true, message: notes.joined(separator: " "))
    }

    /// Forgets the saved password for the current router.
    func disconnect() {
        try? KeychainStore.delete(account: account)
        routerPassword = ""
        passwordSavedAt = nil
        authFailed = false
        refusedActions = [:]
        singleCalls = false
        snapshot = nil
        health = .unknown
        lastRefresh = nil
        lastError = nil
        statusMessage = nil
        clearAirwaves()
    }

    func testConnection() async -> String {
        if settings.demoMode {
            return "Demo mode is on, so MeshBar is not talking to a router."
        }
        guard let client = makeClient() else {
            return lastError ?? "Check the host and password."
        }
        // Ask first, without credentials, whether the router has paused logins.
        // A test during a lockout would only extend it.
        let before = await adminAuthStatus(client)
        if let before, before.isLockedOut {
            return JNAPError.lockedOut(
                code: "attemptsRemaining=\(before.attemptsRemaining.map(String.init) ?? "?")",
                retryAfterSeconds: before.lockoutSecondsRemaining
            ).localizedDescription
        }
        do {
            _ = try await client.perform(MeshCommands.checkAdminPassword())
            let info = try await client.perform(MeshCommands.deviceInfo())
            let identity = MeshSnapshotParser.parseIdentityData(info)
            let model = identity?.modelNumber ?? "router"
            let firmware = identity?.firmwareVersion ?? "unknown firmware"
            // The login works, so poll with it now instead of on the next tick.
            authFailed = false
            refusedActions = [:]
            singleCalls = false
            Task { await refresh() }
            return "Connected to \(model), firmware \(firmware)."
        } catch let error as JNAPError {
            if case .unauthorized = error {
                var parts = [error.localizedDescription]
                parts.append("Sent \(routerPassword.count) characters as user \"\(settings.username)\".")
                if let after = await adminAuthStatus(client) {
                    if after.isLockedOut {
                        return JNAPError.lockedOut(code: "attemptsRemaining=0", retryAfterSeconds: after.lockoutSecondsRemaining).localizedDescription
                    }
                    if let left = after.attemptsRemaining {
                        parts.append("Router lockout counter: \(left) attempts left.")
                    }
                }
                parts.append("Check it by signing in at https://\(settings.routerHost).")
                return parts.joined(separator: " ")
            }
            return error.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    private func adminAuthStatus(_ client: JNAPClient) async -> AdminAuthStatus? {
        guard let data = try? await client.perform(MeshCommands.adminAuthStatus()) else { return nil }
        return MeshSnapshotParser.parseAdminAuthStatus(data)
    }

    /// Restarts one node via `core/Reboot2`. Never `core/Reboot`.
    func restartNode(_ node: MeshNode) async {
        let call = MeshCommands.rebootNode(deviceUUID: node.id)
        precondition(call.action == JNAPAction.rebootNode, "Per-node restart must use core/Reboot2")
        if settings.demoMode {
            statusMessage = "Demo mode does not restart \(node.name)."
            return
        }
        await invoke(call, success: "Restarting \(node.name). Other nodes stay up.")
    }

    /// Restarts the whole router via `core/Reboot`. This is not the per-node button.
    func restartEntireRouter() async {
        let call = MeshCommands.rebootEntireRouter()
        precondition(call.action == JNAPAction.rebootRouter, "Whole-router restart must use core/Reboot")
        if settings.demoMode {
            statusMessage = "Demo mode does not restart the router."
            return
        }
        await invoke(call, success: "The router is restarting. The whole mesh will drop off for a few minutes.")
    }

    func blink(_ node: MeshNode) async {
        if settings.demoMode {
            statusMessage = "Demo mode would blink the LED on \(node.name)."
            return
        }
        await invoke(MeshCommands.blink(deviceID: node.id), success: "\(node.name) should be blinking.")
    }

    func stopBlinking() async {
        if settings.demoMode {
            statusMessage = "Demo mode would stop the LED blink."
            return
        }
        await invoke(MeshCommands.stopBlinking(), success: "Stopped the LED blink.")
    }

    func rename(id: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else {
            lastError = "Use a name between 1 and 32 characters."
            return
        }
        if settings.demoMode {
            demoNames[id] = trimmed
            apply(currentDemoSnapshot(), clearingError: true)
            statusMessage = "Renamed in the demo snapshot."
            return
        }
        await invoke(MeshCommands.rename(deviceID: id, name: trimmed), success: "Rename sent.")
        await refresh()
    }

    func runSpeedTest() async {
        if settings.demoMode {
            speedTestRunning = true
            try? await Task.sleep(for: .seconds(1))
            speedTest = DemoMesh.speedTest
            speedTestRunning = false
            statusMessage = "Demo speed test finished. No router was contacted."
            return
        }
        guard let client = makeClient() else { return }
        speedTestRunning = true
        defer { speedTestRunning = false }
        do {
            _ = try await client.perform(MeshCommands.runSpeedTest())
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                let status = try await client.perform(MeshCommands.healthStatus())
                if let partial = MeshSnapshotParser.parseSpeedTest(status: status, results: nil) {
                    speedTest = partial
                    if partial.isComplete {
                        statusMessage = "Speed test finished."
                        return
                    }
                }
            }
            let results = try await client.perform(MeshCommands.healthResults())
            speedTest = MeshSnapshotParser.parseSpeedTest(status: nil, results: results) ?? speedTest
            statusMessage = "Speed test finished."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var account: String {
        KeychainStore.account(username: settings.username, host: settings.routerHost)
    }

    func makeClient() -> JNAPClient? {
        guard let endpoint = RouterEndpoint(rawHost: settings.routerHost, useHTTPS: settings.useHTTPS) else {
            lastError = "The router host is not a valid hostname or IP address."
            return nil
        }
        guard !routerPassword.isEmpty else {
            lastError = nil
            return nil
        }
        return JNAPClient(
            configuration: JNAPClient.Configuration(
                endpoint: endpoint,
                username: settings.username,
                password: routerPassword,
                trustSelfSignedCertificate: settings.trustSelfSignedCertificate
            )
        )
    }

    private func invoke(_ call: JNAPCall, success: String) async {
        guard let client = makeClient() else { return }
        isActing = true
        defer { isActing = false }
        do {
            _ = try await client.perform(call)
            statusMessage = success
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ newSnapshot: MeshSnapshot, clearingError: Bool) {
        let previous = snapshot
        snapshot = newSnapshot
        health = HealthEvaluator.evaluate(newSnapshot, thresholds: settings.thresholds)
        lastRefresh = newSnapshot.capturedAt
        if clearingError { lastError = nil }
        if let match = launchSelectNodeMatch,
           let node = newSnapshot.treeOrder.first(where: { $0.name.localizedCaseInsensitiveContains(match) }) {
            launchSelectNodeMatch = nil
            selectedNodeID = node.id
        }
        if selectedNodeID == nil || newSnapshot.node(id: selectedNodeID ?? "") == nil {
            selectedNodeID = newSnapshot.treeOrder.first?.id
        }
        if speedTest == nil {
            speedTest = newSnapshot.speedTest
        }
        if let match = launchClientDetailMatch,
           let client = newSnapshot.clients.first(where: { $0.name.localizedCaseInsensitiveContains(match) }) {
            launchClientDetailMatch = nil
            pendingLaunchDetailID = client.id
        }
        do {
            try store?.append(newSnapshot.makeHistorySamples())
            try store?.appendClients(newSnapshot.makeClientSamples())
            let cutoff = Date().addingTimeInterval(-Double(settings.retentionClamped) * 86_400)
            try store?.purge(olderThan: cutoff)
            try reloadSamples()
        } catch {
            lastError = "History could not be saved."
        }
        let fired = alerts.evaluate(
            previous: previous,
            current: newSnapshot,
            thresholds: settings.thresholds
        )
        for alert in fired {
            MeshNotifier.post(alert)
        }
    }

    private func currentDemoSnapshot() -> MeshSnapshot {
        var snapshot = DemoMesh.snapshot(at: Date())
        snapshot.nodes = snapshot.nodes.map { node in
            guard let name = demoNames[node.id] else { return node }
            var copy = node
            copy.name = name
            return copy
        }
        snapshot.clients = snapshot.clients.map { client in
            guard let name = demoNames[client.id] else { return client }
            var copy = client
            copy.name = name
            return copy
        }
        return snapshot
    }

    private func historyDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MeshBar", isDirectory: true)
            .appendingPathComponent(settings.demoMode ? "Demo" : "Live", isDirectory: true)
    }

    private func reopenStore() {
        do {
            store = try HistoryStoreFactory.open(directory: historyDirectory())
            try reloadSamples()
        } catch {
            store = nil
            lastError = "Could not open the history database."
        }
    }

    private func seedDemoIfNeeded() {
        guard let store else { return }
        let existing = (try? store.samples(since: .distantPast, nodeID: nil)) ?? []
        guard existing.isEmpty else { return }
        try? store.append(DemoMesh.seededHistory())
        try? store.appendClients(DemoMesh.seededClientHistory())
        try? reloadSamples()
    }

    /// Called by the dashboard once it is on screen, so the sheet has a window.
    func presentLaunchDetailIfNeeded() {
        runLaunchScanIfNeeded()
        guard let id = pendingLaunchDetailID else { return }
        pendingLaunchDetailID = nil
        detailClient = ClientDetailRequest(id: id)
    }

    /// `--scan router` or `--scan mac`: run one Spectrum scan once the first
    /// snapshot is in (used to take screenshots). The router scan is the same
    /// read-only site survey as the Scan button.
    private var launchScan: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    private func runLaunchScanIfNeeded() {
        guard snapshot != nil, let scan = launchScan else { return }
        launchScan = nil
        Task {
            switch scan {
            case "router": await scanRouterAirwaves(source: "launch")
            case "mac": await scanFromThisMac()
            default: break
            }
        }
    }

    func showClientDetail(_ clientID: String) {
        detailClient = ClientDetailRequest(id: clientID)
    }

    /// Recorded samples for one client, oldest first.
    func clientHistory(clientID: String, since: Date) -> [ClientSample] {
        (try? store?.clientSamples(clientID: clientID, since: since)) ?? []
    }

    private func reloadSamples() throws {
        let since = Date().addingTimeInterval(-chartRange.seconds)
        samples = try store?.samples(since: since, nodeID: nil) ?? []
    }
}
