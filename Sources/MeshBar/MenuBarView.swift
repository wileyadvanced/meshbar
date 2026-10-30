import AppKit
import MeshBarCore
import SwiftUI

/// The dropdown, laid out like the macOS Wi-Fi and Control Center menus:
/// a bold header, small secondary section titles, rows with a round symbol
/// badge and Wi-Fi bars, hover highlights, and a plain-text footer.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.needsConnect {
                MenuSeparator()
                connectSection
            } else {
                if let error = model.lastError {
                    MenuSeparator()
                    MessageRow(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                } else if let message = model.statusMessage {
                    MenuSeparator()
                    MessageRow(text: message, systemImage: "info.circle", tint: .secondary)
                }
                if let snapshot = model.snapshot {
                    MenuSeparator()
                    MenuSectionHeader("Internet")
                    wanRow(snapshot)
                    MenuSeparator()
                    MenuSectionHeader("Mesh Nodes")
                    ForEach(snapshot.treeOrder) { node in
                        nodeRow(node, in: snapshot)
                    }
                } else {
                    MenuSeparator()
                    HStack(spacing: 8) {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        Text(model.isRefreshing ? "Reading the mesh…" : "No reading yet")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            MenuSeparator()
            if !model.needsConnect {
                MenuItem(model.manualRefreshInFlight ? "Refreshing…" : "Refresh", shortcut: "⌘R") { model.requestRefresh(source: "menu bar") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.manualRefreshInFlight || model.manualRefreshQueued)
            }
            MenuItem("Dashboard…") { model.activate { openWindow(id: "dashboard") } }
            if !model.needsConnect && !model.settings.demoMode {
                MenuItem("Disconnect / Change Router…") { model.activate { openWindow(id: "connect") } }
            }
            MenuSeparator()
            MenuItem("MeshBar Settings…", shortcut: "⌘,") { model.activate { openWindow(id: "settings") } }
                .keyboardShortcut(",", modifiers: .command)
            MenuItem("Quit MeshBar", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(5)
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mesh")
                .font(.system(size: 13, weight: .bold))
            if model.settings.demoMode { DemoBadge() }
            Spacer()
            Text(headerStatus)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var headerStatus: String {
        if model.needsConnect { return "Not Connected" }
        if model.isRefreshing && model.snapshot == nil { return "Connecting…" }
        guard let lastRefresh = model.lastRefresh else { return model.health.label }
        return "\(model.health.label) · \(MeshFormat.relative(lastRefresh))"
    }

    // MARK: Connect

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.authFailed {
                MessageRow(text: model.lastError ?? "The router rejected the saved password.", systemImage: "lock.trianglebadge.exclamationmark", tint: .orange)
                    .padding(.horizontal, -10)
            } else {
                Text("Connect MeshBar to your Linksys router to see the mesh.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.activate { openWindow(id: "connect") }
            } label: {
                Text("Connect…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Rows

    private func wanRow(_ snapshot: MeshSnapshot) -> some View {
        let up = snapshot.wan?.isConnected
        return MenuRow(action: { model.activate { openWindow(id: "dashboard") } }) {
            SymbolBadge(systemImage: up == false ? "globe.badge.chevron.backward" : "globe", filled: up == true)
            VStack(alignment: .leading, spacing: 0) {
                Text(up == true ? "Connected" : (up == nil ? "Unknown" : "Not Connected"))
                    .font(.system(size: 13))
                Text(wanDetail(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if up == false { StatusDot(color: .red) }
        }
    }

    private func wanDetail(_ snapshot: MeshSnapshot) -> String {
        var parts: [String] = []
        if let type = snapshot.wan?.wanType { parts.append(type) }
        if let ip = snapshot.wan?.ipAddress { parts.append(ip) }
        return parts.isEmpty ? "No address reported" : parts.joined(separator: " · ")
    }

    private func nodeRow(_ node: MeshNode, in snapshot: MeshSnapshot) -> some View {
        let quality = HealthEvaluator.linkQuality(node, thresholds: model.settings.thresholds)
        let isThisMac = model.thisMacNodeID == node.id
        return MenuRow(action: {
            model.selectedNodeID = node.id
            model.activate { openWindow(id: "dashboard") }
        }) {
            SymbolBadge(systemImage: node.isPrimary ? "wifi.router.fill" : "wifi.router", filled: isThisMac)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(node.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isThisMac {
                        // A tag on the name line, so the subtitle keeps room
                        // for the link speed and client count.
                        Text("This Mac")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .fixedSize()
                    }
                }
                Text(subtitle(node, in: snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle(node, in: snapshot))
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if quality == .offline {
                StatusDot(color: .red)
            } else if quality == .degraded {
                StatusDot(color: .orange)
            }
            linkGlyph(node)
        }
        .help(detailHelp(node))
    }

    private func subtitle(_ node: MeshNode, in snapshot: MeshSnapshot) -> String {
        var parts: [String] = []
        if !node.isOnline {
            parts.append("Offline")
        } else if node.isPrimary {
            parts.append("Router")
        } else if let parent = snapshot.parentName(of: node) {
            parts.append("via \(parent)")
        }
        if node.isOnline, !node.isPrimary, let speed = node.backhaul?.speedMbps {
            parts.append(MeshFormat.mbps(speed))
        } else if node.isOnline, !node.isPrimary, node.backhaul?.isAwaitingSpeed == true {
            parts.append("Measuring…")
        }
        parts.append("\(node.clientCount) client\(node.clientCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private func detailHelp(_ node: MeshNode) -> String {
        guard let link = node.backhaul else { return node.name }
        var parts = [node.name, link.medium.label]
        if let rssi = link.rssiDbm, link.medium != .wired { parts.append(MeshFormat.rssi(rssi)) }
        if let speed = link.speedMbps { parts.append(MeshFormat.mbps(speed)) } else if link.isAwaitingSpeed { parts.append("speed measuring…") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func linkGlyph(_ node: MeshNode) -> some View {
        if !node.isOnline {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        } else if node.isPrimary {
            EmptyView()
        } else if node.backhaul?.medium == .wired {
            Image(systemName: "cable.connector.horizontal").foregroundStyle(.secondary)
        } else {
            Image(systemName: "wifi", variableValue: SignalLevel.fraction(rssi: node.backhaul?.rssiDbm))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Menu building blocks

/// A full-width row with the rounded hover highlight macOS menus use.
struct MenuRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A plain-text menu command with an optional shortcut on the right.
struct MenuItem: View {
    var title: String
    var shortcut: String?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSectionHeader: View {
    var title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct MenuSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// The round symbol badge from the Wi-Fi menu: accent-filled for the item
/// you are on, grey otherwise.
struct SymbolBadge: View {
    var systemImage: String
    var filled: Bool

    var body: some View {
        ZStack {
            Circle().fill(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filled ? Color.white : Color.primary)
        }
        .frame(width: 26, height: 26)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

struct MessageRow: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.25), in: Capsule())
            .foregroundStyle(.orange)
    }
}
