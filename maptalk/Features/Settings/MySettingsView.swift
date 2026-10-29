import SwiftUI

struct MySettingsView: View {
    @Environment(\.appEnv) private var environment
    @Environment(\.backendDeleteAccount) private var deleteAccount
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var deletionIssue: String?
#if DEBUG
    @Environment(\.mockAccountSignOut) private var mockAccountSignOut
#endif

    @State private var isPrivateMap = false
    @State private var notificationsEnabled = true
    @State private var autoPlayReels = true

    var body: some View {
        List {
            if environment.backend == nil {
                Section {
                    SettingRow(icon: "person.crop.circle", title: "Account & Security")
                    SettingRow(icon: "qrcode.viewfinder", title: "My QR Code")
                    SettingRow(icon: "creditcard.fill", title: "Payments")
                }
            }

            Section {
                if environment.backend == nil {
                SettingToggleRow(
                    icon: "location",
                    title: "Map privacy",
                    isOn: $isPrivateMap
                )
                .disabled(environment.backend != nil)
                SettingToggleRow(
                    icon: "sparkles",
                    title: "Auto-play Reels",
                    isOn: $autoPlayReels
                )
                SettingToggleRow(
                    icon: "bell.badge.fill",
                    title: "Notifications",
                    isOn: $notificationsEnabled
                )
                } else {
                    Text("Public posts are shared with invited test members. Private memories are only visible to you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } footer: {
                if environment.backend != nil {
                    Text("Deleting a memory from MyMap also removes its public post. Deleting a place removes only your visits, not other people's. Collections are stored only on this device.")
                }
            }

            Section {
                if let url = BackendDeploymentConfiguration.publicURL(for: "MapTalkSupportURL") {
                    Link("Help & Feedback", destination: url)
                } else if environment.backend == nil {
                    SettingRow(icon: "questionmark.circle", title: "Help & Feedback")
                }
                if let url = BackendDeploymentConfiguration.publicURL(for: "MapTalkPrivacyURL") {
                    Link("Privacy policy", destination: url)
                }
                SettingRow(icon: "info.circle", title: "About MapTalk", detail: buildLabel)
            }

            if let backend = environment.backend {
                Section {
                    Button("Sign out", role: .destructive) {
                        backend.onSignOut?()
                    }
                    .accessibilityIdentifier("account.signout")
                    if deleteAccount != nil {
                        Button(isDeleting ? "Deleting…" : "Delete account", role: .destructive) { confirmsDeletion = true }
                            .disabled(isDeleting)
                            .accessibilityIdentifier("account.delete")
                    }
                }
            }
#if DEBUG
            if let mockAccountSignOut {
                Section {
                    Button("Exit demo", role: .destructive, action: mockAccountSignOut)
                        .accessibilityIdentifier("account.demo.signout")
                } footer: {
                    Text("Demo · Sample data only")
                }
            }
#endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("Permanently delete your account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete account and posts", role: .destructive) {
                guard let deleteAccount else { return }
                isDeleting = true
                Task {
                    defer { isDeleting = false }
                    do { try await deleteAccount() }
                    catch { deletionIssue = error.localizedDescription }
                }
            }
        } message: {
            Text("Your posts, photos and account will be deleted. This cannot be undone.")
        }
        .alert("Couldn't delete account", isPresented: Binding(get: { deletionIssue != nil }, set: { if !$0 { deletionIssue = nil } })) {
            Button("OK", role: .cancel) { deletionIssue = nil }
        } message: { Text(deletionIssue ?? "") }
    }

    private var buildLabel: String {
        switch environment.build.configuration {
        case .debug: return "Debug"
        case .release: return "Release"
        }
    }
}

private struct SettingRow: View {
    let icon: String
    let title: String
    var detail: String?
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.black)
                    .frame(width: 24)
                Text(title)
                    .foregroundColor(.black)
                Spacer()
                if let detail {
                    Text(detail)
                        .foregroundColor(.gray)
                        .font(.subheadline)
                }
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray.opacity(0.6))
            }
            .padding(.vertical, 6)
        }
    }
}

private struct SettingToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.black)
                .frame(width: 24)
            Text(title)
                .foregroundColor(.black)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.vertical, 6)
    }
}
