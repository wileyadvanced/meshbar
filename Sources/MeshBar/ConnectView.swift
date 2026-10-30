import AppKit
import MeshBarCore
import SwiftUI

/// The small window behind "Connect…" and "Disconnect / change router…".
/// Router address, username and password live here, not in Settings.
struct ConnectView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var working = false
    @State private var message: String?
    @State private var succeeded = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.router")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isConnected ? "Change router" : "Connect to your router")
                        .font(.title3.weight(.semibold))
                    Text("Use the admin password you sign in with at https://\(host.isEmpty ? "192.168.1.1" : host). It is not your Wi-Fi password or Linksys cloud account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Router").gridColumnAlignment(.trailing)
                    TextField("Router", text: $host, prompt: Text("192.168.1.1"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                }
                GridRow {
                    Text("Username")
                    TextField("Username", text: $username, prompt: Text("admin"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .textContentType(nil)
                }
                GridRow {
                    Text("Password")
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password, prompt: Text("Router admin password"))
                            } else {
                                SecureField("Password", text: $password, prompt: Text("Router admin password"))
                            }
                        }
                        .labelsHidden()
                        .textContentType(nil)
                        .autocorrectionDisabled()
                        .focused($passwordFocused)
                        .onSubmit(connect)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showPassword ? "Hide password" : "Show password")
                        Button {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                password = PasswordInput.normalize(pasted).value
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        .help("Paste the password")
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(passwordHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message {
                Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(succeeded ? Color.green : Color.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isConnected {
                    Button("Disconnect", role: .destructive) {
                        model.disconnect()
                        password = ""
                        succeeded = false
                        message = "Disconnected. The saved password was removed from the Keychain."
                    }
                    .help("Forget the saved password for \(model.settings.routerHost)")
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismissWindow(id: "connect") }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || password.isEmpty || host.isEmpty || username.isEmpty)
            }
            Text("MeshBar checks the password once, then saves it in your Keychain. It only reads from the router.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            host = model.settings.routerHost.isEmpty ? "192.168.1.1" : model.settings.routerHost
            username = model.settings.username.isEmpty ? "admin" : model.settings.username
            password = ""
            message = model.authFailed ? model.lastError : nil
            succeeded = false
            passwordFocused = true
        }
    }

    private var isConnected: Bool {
        !model.routerPassword.isEmpty && !model.authFailed
    }

    private var passwordHint: String {
        if password.isEmpty {
            if let saved = model.passwordSavedAt, !model.routerPassword.isEmpty {
                return "A password was saved \(saved.formatted(date: .abbreviated, time: .shortened)). Type it again to change it."
            }
            return "Spaces or line breaks around a pasted password are removed."
        }
        let count = password.count
        return count == 1 ? "1 character" : "\(count) characters"
    }

    private func connect() {
        guard !working, !password.isEmpty else { return }
        working = true
        message = nil
        Task {
            let outcome = await model.connect(host: host, username: username, password: password)
            working = false
            succeeded = outcome.success
            message = outcome.message
            if outcome.success {
                password = ""
                try? await Task.sleep(for: .seconds(2.5))
                if succeeded { dismissWindow(id: "connect") }
            }
        }
    }
}
