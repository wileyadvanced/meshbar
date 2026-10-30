import MeshBarCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRouterRestart = false
    @AppStorage("meshbar.showInspector") private var showInspector = true
    /// Clients / History / Speed test panel. Collapsed by default so the
    /// topology gets the room; expanded state and height persist.
    @AppStorage("meshbar.bottomPanel.expanded") private var bottomExpanded = false
    @AppStorage("meshbar.bottomPanel.height") private var bottomHeight: Double = 300
    @State private var dragStartHeight: Double?
    /// Ticks once a second so "updated 12s ago" stays live.
    @State private var now = Date()
    @State private var toast: RefreshToast?
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.demoMode || model.snapshot?.isDemo == true {
                Text("Demo mode — sample mesh with made-up names and addresses, not your network")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.18))
            }
            if let error = model.lastError, !model.needsConnect, model.refreshFailure == nil {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                Divider()
            }
            if let snapshot = model.snapshot {
                HStack(spacing: 0) {
                    GeometryReader { geo in
                        let maxPanel: Double = max(BottomPanel.minHeight, Double(geo.size.height) - 552)
                        VStack(spacing: bottomExpanded ? 0 : 10) {
                            statStrip(snapshot)
                                .padding(.bottom, bottomExpanded ? 14 : 4)
                            Group {
                                switch model.mainView {
                                case .topology:
                                    TopologyView(model: model, snapshot: snapshot)
                                case .spectrum:
                                    SpectrumView(model: model, snapshot: snapshot)
                                }
                            }
                            .frame(minHeight: 330, maxHeight: .infinity)
                            if bottomExpanded {
                                resizeHandle(maxPanel: maxPanel)
                                bottom(snapshot)
                                    .frame(height: min(max(bottomHeight, BottomPanel.minHeight), maxPanel))
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                collapsedBar(snapshot)
                                    .transition(.opacity)
                            }
                        }
                        .padding(16)
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector, let node = model.selectedNode {
                        Divider()
                        NodeDetailView(model: model, node: node, snapshot: snapshot)
                            .id(node.id)
                            .frame(width: 330)
                            .transition(.move(edge: .trailing))
                    }
                }
                .background(DashboardStyle.canvasBackground)
            } else {
                ContentUnavailableView {
                    Label(
                        model.needsConnect ? "Connect to your router" : (model.isRefreshing ? "Reading the mesh" : "No mesh yet"),
                        systemImage: model.needsConnect ? "wifi.router" : "wifi"
                    )
                } description: {
                    Text(model.needsConnect
                         ? (model.authFailed ? (model.lastError ?? "The router rejected the saved password.") : "Sign in with the router's admin password to see your mesh. Or turn on Demo mode in Settings.")
                         : (model.lastError ?? "Waiting for the first reading."))
                } actions: {
                    if model.needsConnect {
                        Button("Connect…") {
                            model.activate { openWindow(id: "connect") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button("Refresh") { model.requestRefresh(source: "empty state") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.snapshot?.identity?.modelNumber ?? "MeshBar")
        .navigationSubtitle(headerSubtitle)
        .overlay(alignment: .top) {
            if let toast {
                RefreshToastView(toast: toast) {
                    self.toast = nil
                    model.requestRefresh(source: "toast retry")
                } dismiss: {
                    withAnimation { self.toast = nil }
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $model.detailClient) { request in
            ClientDetailView(model: model, clientID: request.id)
        }
        .onAppear { model.presentLaunchDetailIfNeeded() }
        .onChange(of: model.lastRefresh) { _, _ in model.presentLaunchDetailIfNeeded() }
        .onReceive(ticker) { now = $0 }
        .onChange(of: model.dataLandedAt) { _, landed in
            guard let landed, !model.settings.demoMode else { return }
            show(.updated(landed))
        }
        .onChange(of: model.refreshFailedAt) { _, failedAt in
            if failedAt != nil, let failure = model.refreshFailure { show(.failed(failure)) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.snapshot != nil {
                    Picker("View", selection: $model.mainView) {
                        ForEach(AppModel.MainView.allCases) { view in
                            Label(view.title, systemImage: view.symbol).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleOnly)
                    .help("Topology shows how nodes connect. Spectrum shows the channels around them.")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.requestRefresh(source: "toolbar")
                } label: {
                    if model.isRefreshing && !model.settings.demoMode {
                        Label {
                            Text("Refreshing")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(refreshHelp)
                // A click during an automatic poll queues a fresh one right
                // after it; only a manual poll in flight (or queued) disables.
                .disabled(model.manualRefreshInFlight || model.manualRefreshQueued)
                Button {
                    toggleBottom()
                } label: {
                    Label(bottomExpanded ? "Hide Clients Panel" : "Show Clients Panel", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .help(bottomExpanded ? "Hide Clients, History and Speed test (⇧⌘C)" : "Show Clients, History and Speed test (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide the node inspector" : "Show the node inspector")
                .keyboardShortcut("i", modifiers: [.command, .option])
                Menu {
                    if !model.needsConnect && !model.settings.demoMode {
                        Button("Disconnect / Change Router…") {
                            model.activate { openWindow(id: "connect") }
                        }
                        Divider()
                    }
                    Button("Restart Entire Router…", role: .destructive) {
                        confirmRouterRestart = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Router actions. Restarting one node is on the node panel.")
            }
        }
        .confirmationDialog(
            "Restart the entire router?",
            isPresented: $confirmRouterRestart,
            titleVisibility: .visible
        ) {
            Button("Restart entire router", role: .destructive) {
                Task { await model.restartEntireRouter() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends core/Reboot and restarts the whole router, not one node. Every node drops offline for a few minutes. The per-node button uses core/Reboot2 instead.")
        }
    }

    private func statStrip(_ snapshot: MeshSnapshot) -> some View {
        let thresholds = model.settings.thresholds
        let online = snapshot.nodes.filter(\.isOnline).count
        let clientsOnline = snapshot.clients.filter(\.isOnline).count
        let score = MeshSummary.score(snapshot, thresholds: thresholds)
        let weakest = MeshSummary.weakestLink(snapshot)
        let weakestQuality = weakest.map { HealthEvaluator.linkQuality($0, thresholds: thresholds) } ?? .healthy
        let wan = snapshot.wan
        let wanUp = wan?.isConnected ?? false
        let routerUptime = snapshot.nodes.first(where: \.isPrimary)?.uptimeSeconds
        return HStack(spacing: 12) {
            StatCard(
                title: "Internet",
                value: wan == nil ? "—" : (wanUp ? "Online" : "Down"),
                detail: [wan?.wanType, routerUptime.map { "up \(MeshFormat.uptime($0))" }].compactMap { $0 }.joined(separator: " · "),
                systemName: wanUp ? "globe" : "exclamationmark.icloud",
                tint: wan == nil ? .gray : (wanUp ? .blue : MeshPalette.color(.offline))
            )
            StatCard(
                title: "Nodes online",
                value: "\(online)/\(snapshot.nodes.count)",
                detail: online == snapshot.nodes.count ? "All nodes reachable" : "\(snapshot.nodes.count - online) offline",
                systemName: "wifi.router",
                tint: online == snapshot.nodes.count ? .teal : MeshPalette.color(.degraded)
            )
            StatCard(
                title: "Clients",
                value: "\(clientsOnline)",
                detail: "\(snapshot.clients.count - clientsOnline) offline known",
                systemName: "laptopcomputer.and.iphone",
                tint: .indigo
            )
            StatCard(
                title: "Weakest link",
                value: MeshSummary.speedText(weakest?.backhaul) ?? (weakest == nil ? "None" : "—"),
                detail: weakest.map { node in
                    [node.name, node.backhaul?.rssiDbm.map(MeshSummary.dBm)].compactMap { $0 }.joined(separator: " · ")
                } ?? "No wireless backhaul",
                systemName: "antenna.radiowaves.left.and.right",
                tint: weakest == nil ? .gray : MeshPalette.color(weakestQuality)
            )
            StatCard(
                title: "Mesh health",
                value: model.health.label,
                detail: healthDetail(snapshot),
                systemName: healthSymbol,
                tint: MeshSummary.scoreColor(score),
                accessory: AnyView(HealthRing(fraction: Double(score) / 100, tint: MeshSummary.scoreColor(score), lineWidth: 4, size: 36, label: "\(score)"))
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func healthDetail(_ snapshot: MeshSnapshot) -> String {
        let weak = snapshot.nodes.filter { !$0.isPrimary && HealthEvaluator.linkQuality($0, thresholds: model.settings.thresholds) == .degraded }.count
        if snapshot.wan?.isConnected == false { return "Internet is down" }
        if weak > 0 { return "\(weak) weak backhaul\(weak == 1 ? "" : "s")" }
        return "Score out of 100"
    }

    private var healthSymbol: String {
        switch model.health {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .offline: return "xmark.octagon.fill"
        case .partial: return "circle.lefthalf.filled"
        case .unknown: return "questionmark.circle"
        }
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if let firmware = model.snapshot?.identity?.firmwareVersion {
            parts.append("firmware \(firmware)")
        }
        if model.manualRefreshInFlight || model.manualRefreshQueued {
            parts.append("refreshing…")
        } else if let lastRefresh = model.lastRefresh {
            parts.append("updated \(RefreshClock.ago(lastRefresh, now: now))")
        }
        if model.refreshFailure != nil {
            parts.append("last refresh failed")
        }
        return parts.joined(separator: " · ")
    }

    private var refreshHelp: String {
        if model.manualRefreshQueued { return "A refresh will run as soon as the current reading finishes" }
        if model.manualRefreshInFlight { return "Re-measuring links and reading the mesh…" }
        if model.isRefreshing { return "Refresh again after the current reading (⌘R)" }
        return "Re-measure links and read the mesh now (⌘R)"
    }

    private func show(_ next: RefreshToast) {
        withAnimation(.spring(duration: 0.3)) { toast = next }
        guard case .updated = next else { return }
        let shown = next
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if toast == shown { withAnimation(.easeOut(duration: 0.4)) { toast = nil } }
        }
    }

    // MARK: Bottom panel

    private enum BottomPanel {
        static let minHeight: Double = 170
    }

    private func toggleBottom() {
        withAnimation(.snappy(duration: 0.25)) { bottomExpanded.toggle() }
    }

    /// Segmented control shown in the expanded panel's header.
    private var tabPicker: some View {
        Picker("Section", selection: $model.bottomTab) {
            ForEach(AppModel.BottomTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
    }

    private func toggleButton() -> some View {
        Button(action: toggleBottom) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(bottomExpanded ? 180 : 0))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(bottomExpanded ? "Hide panel (⇧⌘C)" : "Show panel (⇧⌘C)")
        .accessibilityLabel(bottomExpanded ? "Hide Clients panel" : "Show Clients panel")
    }

    private func panelSummary(_ snapshot: MeshSnapshot) -> String {
        let online = snapshot.clients.filter(\.isOnline).count
        var parts = ["\(online) client\(online == 1 ? "" : "s") online"]
        if let result = model.speedTest ?? snapshot.speedTest, result.downloadMbps != nil || result.uploadMbps != nil {
            let down = result.downloadMbps.map(MeshSummary.speed) ?? "—"
            let up = result.uploadMbps.map(MeshSummary.speed) ?? "—"
            parts.append("last speed test ↓\(down) ↑\(up)")
        } else {
            parts.append("last speed test —")
        }
        return parts.joined(separator: " · ")
    }

    /// Slim bar shown when the panel is collapsed, like Xcode's debug bar.
    private func collapsedBar(_ snapshot: MeshSnapshot) -> some View {
        HStack(spacing: 10) {
            toggleButton()
            // Momentary segments: nothing looks selected while collapsed,
            // and any click opens the panel on that tab.
            ControlGroup {
                ForEach(AppModel.BottomTab.allCases) { tab in
                    Button(tab.title) {
                        model.bottomTab = tab
                        withAnimation(.snappy(duration: 0.25)) { bottomExpanded = true }
                    }
                    .help("Show \(tab.title)")
                }
            }
            .controlSize(.small)
            .frame(width: 240)
            Text(panelSummary(snapshot))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleBottom)
    }

    /// Drag to resize the expanded panel; double-click to collapse.
    private func resizeHandle(maxPanel: Double) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 4)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? min(max(bottomHeight, BottomPanel.minHeight), maxPanel)
                    if dragStartHeight == nil { dragStartHeight = start }
                    bottomHeight = min(max(start - value.translation.height, BottomPanel.minHeight), maxPanel)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .onTapGesture(count: 2, perform: toggleBottom)
        .help("Drag to resize. Double-click to hide.")
        .accessibilityHidden(true)
    }

    private func bottom(_ snapshot: MeshSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                toggleButton()
                tabPicker
                Spacer()
                if let message = model.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
            Group {
                switch model.bottomTab {
                case .clients:
                    ClientsView(model: model, snapshot: snapshot)
                case .history:
                    HistoryChartsView(model: model, snapshot: snapshot)
                case .speed:
                    SpeedTestView(model: model, snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashboardStyle.cardBackground, in: RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DashboardStyle.cardRadius, style: .continuous)
                .strokeBorder(DashboardStyle.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}
