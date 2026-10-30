import AppKit
import MeshBarCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Router") {
                LabeledContent("Router", value: model.routerPassword.isEmpty ? "Not connected" : "\(model.settings.username)@\(model.settings.routerHost)")
                Button(model.routerPassword.isEmpty ? "Connect…" : "Disconnect / change router…") {
                    model.activate { openWindow(id: "connect") }
                }
                Text("The router address, username and password are set in the Connect window. The password is stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Polling and history") {
                Stepper(value: intBinding(\.pollIntervalSeconds), in: 15...3600, step: 15) {
                    Text("Poll every \(model.settings.pollIntervalSeconds) seconds")
                }
                Stepper(value: intBinding(\.retentionDays), in: 1...365) {
                    Text("Keep history \(model.settings.retentionDays) days")
                }
                Text("Samples live in ~/Library/Application Support/MeshBar. Demo and live history are separate files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Health") {
                Stepper(value: doubleBinding(\.minimumBackhaulMbps), in: 10.0...2000.0, step: 10.0) {
                    Text("Amber under \(Int(model.settings.minimumBackhaulMbps)) Mbps")
                }
                Stepper(value: intBinding(\.minimumRSSI), in: -100 ... -30) {
                    Text("Amber under \(model.settings.minimumRSSI) dBm")
                }
                Text("WAN down turns the menu icon red. An offline node or a weak backhaul turns it amber. Wired links ignore RSSI. A missing reading is not treated as a failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Launch at login uses SMAppService and only works for MeshBar.app from scripts/bundle.sh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Demo mode", isOn: Binding(
                    get: { model.settings.demoMode },
                    set: { model.setDemoMode($0) }
                ))
                Text("Demo mode shows a made-up router and three extenders in a daisy chain. It never contacts a router. Turn it off before entering a real password if you want the next poll to use the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Toggle("HTTPS", isOn: boolBinding(\.useHTTPS))
                Toggle("Trust this host's certificate", isOn: boolBinding(\.trustSelfSignedCertificate))
                Text("Connect turns on trust by itself when the router's certificate is self-signed. It applies only to \(model.settings.routerHost); other servers keep normal checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}
