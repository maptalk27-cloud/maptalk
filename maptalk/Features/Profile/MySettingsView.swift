import SwiftUI

struct MySettingsView: View {
    @Environment(\.appEnv) private var environment

    private let user = PreviewData.currentUser
    @State private var isPrivateMap = false
    @State private var notificationsEnabled = true
    @State private var autoPlayReels = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Open profile home if needed
                    } label: {
                        HStack(spacing: 12) {
                            ProfileAvatarView(user: user, size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("@\(user.handle)")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                Text("Profile and account")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.gray.opacity(0.6))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    SettingRow(icon: "person.crop.circle", title: "Account & Security")
                    SettingRow(icon: "qrcode.viewfinder", title: "My QR Code")
                    SettingRow(icon: "creditcard.fill", title: "Payments")
                }

                Section {
                    SettingToggleRow(
                        icon: "location",
                        title: "Map privacy",
                        isOn: $isPrivateMap
                    )
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
                }

                Section {
                    SettingRow(icon: "questionmark.circle", title: "Help & Feedback")
                    SettingRow(icon: "info.circle", title: "About MapTalk", detail: buildLabel)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("My")
        }
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
