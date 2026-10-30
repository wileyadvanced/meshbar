import AppKit
import SwiftUI

/// Brief confirmation that fresh data landed, or a note that it did not.
enum RefreshToast: Equatable {
    case updated(Date)
    case failed(String)
}

struct RefreshToastView: View {
    let toast: RefreshToast
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch toast {
            case let .updated(date):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Refresh failed").font(.callout.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: 360, alignment: .leading)
                Button("Retry", action: retry).controlSize(.small)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Handles meshbar:// URLs, all read-only:
/// - `meshbar://refresh` asks for one poll, which the refresh gate coalesces.
/// - `meshbar://spectrum` shows the Spectrum view.
/// - `meshbar://scan-airwaves` runs one router site survey (at most once a minute).
@MainActor
enum URLCommandRouter {
    weak static var model: AppModel?

    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "meshbar" else { return }
        switch url.host?.lowercased() {
        case "refresh":
            model?.requestRefresh(source: "meshbar://refresh")
        case "scan-airwaves":
            // One on-demand router site survey; throttled inside the model.
            model?.mainView = .spectrum
            Task { await model?.scanRouterAirwaves(source: "meshbar://scan-airwaves") }
        case "spectrum":
            model?.mainView = .spectrum
        default:
            break
        }
    }
}

/// Registers for URL events before SwiftUI does, so a meshbar:// open does
/// not spawn a window and goes straight to the router above.
final class MeshBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        MainActor.assumeIsolated { URLCommandRouter.handle(url) }
    }
}
