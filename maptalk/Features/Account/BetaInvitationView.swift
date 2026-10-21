import SwiftUI

private struct BackendDeleteAccountKey: EnvironmentKey {
    static let defaultValue: (@MainActor () async throws -> Void)? = nil
}

extension EnvironmentValues {
    var backendDeleteAccount: (@MainActor () async throws -> Void)? {
        get { self[BackendDeleteAccountKey.self] }
        set { self[BackendDeleteAccountKey.self] = newValue }
    }
}

struct BetaInvitationView: View {
    @ObservedObject var account: BackendAccountController
    let access: BackendBetaAccess
    @State private var code = ""
    @State private var confirmsDeletion = false
    @State private var deletionIssue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text(access.status == "revoked" ? "Your invitation has ended" : "You're invited")
                .font(.system(size: 30, weight: .semibold))
            Text(access.status == "revoked"
                ? "Contact the person who invited you to rejoin the private test."
                : "Enter your invitation code to join the private MapTalk test.")
                .foregroundStyle(.secondary)
            if access.status != "revoked" {
                TextField("Invitation code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(16)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("account.invite.code")
                Button { Task { await account.redeemInvite(code) } } label: {
                    Text(account.isSubmitting ? "Joining…" : "Join MapTalk")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.black, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isSubmitting)
                .accessibilityIdentifier("account.invite.redeem")
                Text("Public posts are visible to invited test members, not just your friends. Private memories are only visible to you.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let issue = account.issue ?? deletionIssue {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account.invite.error")
            }
            Spacer()
            Button("Sign out") { account.signOut() }
                .accessibilityIdentifier("account.signout")
            Button("Delete account", role: .destructive) { confirmsDeletion = true }
                .font(.footnote)
        }
        .padding(32)
        .tint(.black)
        .confirmationDialog("Permanently delete your account and its posts?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task {
                    do { try await account.deleteAccount() }
                    catch { deletionIssue = error.localizedDescription }
                }
            }
        }
    }
}
