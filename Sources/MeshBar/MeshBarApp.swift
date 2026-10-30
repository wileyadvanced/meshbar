import AppKit
import MeshBarCore
import SwiftUI

@main
struct MeshBarApp: App {
    @NSApplicationDelegateAdaptor(MeshBarAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarIcon(glyph: model.statusGlyph)
                .id(model.statusGlyph)
                .background(LaunchDashboardOpener(model: model))
        }
        .menuBarExtraStyle(.window)

        Window("MeshBar", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)

        Window("Connect to Router", id: "connect") {
            ConnectView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuButton(model: model)
            }
        }
    }
}

/// The menu-bar glyph. A template image, like Apple's own status items, so
/// macOS draws it for light, dark, tinted and highlighted menu bars. Health
/// shows in the shape, never as colour: bars follow the signal of the node
/// this Mac is on, `wifi.exclamationmark` means a node needs attention,
/// `wifi.slash` means the internet is down.
struct MenuBarIcon: View {
    var glyph: StatusGlyph

    var body: some View {
        Image(nsImage: StatusIcon.image(for: glyph))
            .accessibilityLabel(glyph.accessibilityLabel)
    }
}

struct StatusGlyph: Hashable {
    var symbol: String
    var level: Double?
    var accessibilityLabel: String
}

enum StatusIcon {
    static func image(for glyph: StatusGlyph) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
        let base: NSImage?
        if let level = glyph.level {
            base = NSImage(systemSymbolName: glyph.symbol, variableValue: level, accessibilityDescription: glyph.accessibilityLabel)
        } else {
            base = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: glyph.accessibilityLabel)
        }
        guard let image = base?.withSymbolConfiguration(config) else { return NSImage() }
        image.isTemplate = true
        return image
    }
}

private struct SettingsMenuButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            model.activate { openWindow(id: "settings") }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// `open MeshBar.app --args --dashboard` opens the dashboard at launch.
/// `--open-window connect` or `--open-window settings` opens that window too.
private struct LaunchDashboardOpener: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var done = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard !Self.done else { return }
                Self.done = true
                let arguments = CommandLine.arguments
                var windows: [String] = []
                if arguments.contains("--dashboard") { windows.append("dashboard") }
                for (index, argument) in arguments.enumerated()
                where argument == "--open-window" && index + 1 < arguments.count {
                    let id = arguments[index + 1]
                    if ["connect", "settings", "dashboard"].contains(id), !windows.contains(id) { windows.append(id) }
                }
                if arguments.contains("--open-menu") {
                    // Clicks MeshBar's own status item once, so the dropdown
                    // can be screenshotted without touching the mouse.
                    try? await Task.sleep(for: .seconds(4))
                    for window in NSApp.windows where window.className.contains("StatusBar") {
                        if let button = window.contentView?.firstSubview(of: NSStatusBarButton.self) {
                            button.performClick(nil)
                            break
                        }
                    }
                }
                guard !windows.isEmpty else { return }
                model.activate { windows.forEach { openWindow(id: $0) } }
            }
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
