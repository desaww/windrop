import SwiftUI
import AppKit

/// Settings in tabs, the way macOS apps usually do it.
///
/// About the window height: every form gets fixedSize on the vertical axis.
/// That way it reports its real content height instead of stretching
/// greedily - otherwise the window opens far too tall and leaves an empty
/// area at the bottom.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            sending
                .tabItem { Label("Sending", systemImage: "paperplane") }
            connection
                .tabItem { Label("Connection", systemImage: "wifi") }
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Start WinDrop at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    hint(error, red: true)
                }
            }

            Section("Notifications") {
                Toggle("When something goes wrong", isOn: $settings.notifyOnFailure)
                Toggle("For every delivered file", isOn: $settings.notifyOnSuccess)
            }

            Section {
                Text("WinDrop \(WinDropInfo.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Sending

    private var sending: some View {
        Form {
            Section {
                Toggle("Send several files as one ZIP archive",
                       isOn: $settings.bundleAsZip)
                hint("One archive is one download. Without bundling, the browser "
                     + "asks for permission once on the second download.")
            }

            Section {
                hint("Folders are always packed, they cannot be transferred any "
                     + "other way. The share menu cannot do it, use the drop "
                     + "window for those.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Connection

    private var connection: some View {
        Form {
            Section("Address for the Windows laptop") {
                Text(state.addressByName)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Copy address") { state.copyAddress() }
                    Button("Copy IP address") { state.copyIPAddress() }
                }
                .controlSize(.small)
            }

            Section {
                HStack {
                    Button("New access token") { state.regenerateToken() }
                    Spacer()
                    Button("Restart server") { state.restartServer() }
                }
                .controlSize(.small)
                hint("A new token invalidates the old address. The tab on the "
                     + "Windows laptop has to be opened once more.")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    Text("\(WinDropInfo.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                hint("Fixed in code, because the share extension cannot read the "
                     + "app's settings from inside its sandbox.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(red ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
