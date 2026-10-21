import AuthenticationServices
import Combine
import Security
import SwiftUI

@MainActor
protocol SocialSignInProviding {
    func configurationIssue(for provider: String) -> String?
    func signInGoogle() async throws -> String
    func signInWeChat(state: String) async throws -> WeChatAuthorization
    func signOut()
}

extension SocialSignInCoordinator: SocialSignInProviding {}

/// Real accounts never fall back to demo data when configuration or the network fails.
struct BackendRootView: View {
    @StateObject private var account = BackendAccountController()
    @Environment(\.scenePhase) private var scenePhase
#if DEBUG
    @StateObject private var mockAccount = MockAccountSession()
#endif

    var body: some View {
        Group {
#if DEBUG
            if let environment = mockAccount.environment {
                AppRouter()
                    .appEnvironment(environment)
                    .environment(\.mockAccountSignOut, { mockAccount.signOut() })
            } else {
                accountContent
            }
#else
            accountContent
#endif
        }
#if DEBUG
        .safeAreaInset(edge: .bottom) {
            if account.environment == nil && mockAccount.environment == nil && !Self.usesDeveloperLogin {
                Button("Use demo") {
                    account.cancelPendingSignIn()
                    mockAccount.enterDemo()
                }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .accessibilityIdentifier("account.demo")
            }
        }
#endif
        .task { await account.start() }
        .onChange(of: scenePhase) { _, phase in
            account.setForeground(phase == .active)
        }
        .alert("Couldn't sign out", isPresented: Binding(
            get: { account.signOutIssue != nil },
            set: { if $0 == false { account.signOutIssue = nil } }
        )) {
            Button("OK", role: .cancel) { account.signOutIssue = nil }
        } message: {
            Text(account.signOutIssue ?? "")
        }
    }

    private var accountContent: some View {
        Group {
            if let environment = account.environment {
                AppRouter()
                    .appEnvironment(environment)
                    .environment(\.backendDeleteAccount, { try await account.deleteAccount() })
                    .id(environment.currentUser.id)
            } else if let access = account.betaAccess, !access.isActive {
                BetaInvitationView(account: account, access: access)
            } else if account.isRestoring {
                VStack(spacing: 18) {
                    Text("MapTalk").font(.system(size: 32, weight: .semibold))
                    ProgressView().tint(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else if account.restoreFailed {
                VStack(spacing: 20) {
                    Text("Let's reconnect")
                        .font(.system(size: 28, weight: .semibold))
                    Text(account.issue ?? "MapTalk isn't available right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Your account is still saved on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await account.restore() }
                    }
                    .buttonStyle(AccountPrimaryButtonStyle())
                    .accessibilityIdentifier("account.retry")
                    Button("Sign out on this device") { account.signOut() }
                        .font(.subheadline)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("account.signout")
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                if Self.usesDeveloperLogin {
                    BackendAccountForm(account: account)
                } else {
                    SocialAccountView(account: account)
                }
            }
        }
    }

    private static var usesDeveloperLogin: Bool {
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--developer-login")
#else
        return false
#endif
    }
}

private struct SocialAccountView: View {
    @ObservedObject var account: BackendAccountController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("MapTalk")
                .font(.system(size: 40, weight: .semibold))
            Text("Your places, together.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Spacer()
            VStack(spacing: 16) {
                if account.showsProvider("apple") {
                SignInWithAppleButton(.continue,
                    onRequest: account.configureAppleRequest,
                    onCompletion: { result in Task { await account.completeAppleSignIn(result) } })
                    .signInWithAppleButtonStyle(.white)
                    .modifier(SocialSignInButtonSurface())
                    .disabled(!account.appleSignInReady || account.isSubmitting)
                    .accessibilityIdentifier("account.apple")
                }

                if account.showsProvider("google") {
                Button {
                    Task { await account.signInWithSocial(provider: "google") }
                } label: {
                    HStack(spacing: 12) {
                        // Official Google Identity branding asset, kept in full color.
                        // https://developers.google.com/identity/branding-guidelines
                        Image("GoogleSignInMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        Text("Continue with Google")
                    }
                    .font(.system(size: 20, weight: .medium))
                    .modifier(SocialSignInButtonSurface())
                }
                .buttonStyle(.plain)
                .disabled(account.isSubmitting)
                .accessibilityIdentifier("account.google")
                }

                if account.showsProvider("wechat") {
                Button {
                    Task { await account.signInWithSocial(provider: "wechat") }
                } label: {
                    HStack(spacing: 12) {
                        // Official WeChat wordless mark from wechat.com.
                        Image("WeChatSignInMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        Text("Continue with WeChat")
                    }
                    .font(.system(size: 20, weight: .medium))
                    .modifier(SocialSignInButtonSurface())
                }
                .buttonStyle(.plain)
                .disabled(account.isSubmitting)
                .accessibilityIdentifier("account.wechat")
                }

                if account.isSubmitting || account.isPreparingApple {
                    ProgressView().tint(.black)
                        .accessibilityLabel(account.isSubmitting ? "Signing in" : "Preparing sign-in")
                }
                if account.isSubmitting {
                    Button("Cancel sign-in") { account.cancelPendingSignIn() }
                        .font(.footnote)
                        .accessibilityIdentifier("account.signin.cancel")
                }
                if let issue = account.issue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !account.isSubmitting && !account.isPreparingApple {
                        Button("Try again") { Task { await account.retrySignIn() } }
                            .font(.subheadline.weight(.medium))
                            .accessibilityIdentifier("account.signin.retry")
                    }
                } else if !account.isPreparingApple && !account.isSubmitting {
                    Text("Your map starts here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .foregroundStyle(.black)
        .task { await account.prepareSignIn() }
        .task(id: account.appleChallenge?.challengeId) {
            await account.refreshAppleChallengeBeforeExpiry()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await account.prepareSignIn() } }
        }
    }
}

/// Shared geometry for all providers, including Apple's native authorization button.
private struct SocialSignInButtonSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 0.455, green: 0.467, blue: 0.459), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct BackendAccountForm: View {
    @ObservedObject var account: BackendAccountController
    @State private var handle = ""
    @State private var password = ""
    @State private var isRegistering = false
    @FocusState private var focusedField: Field?
    private enum Field { case handle, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MapTalk")
                        .font(.system(size: 36, weight: .semibold))
                    Text(isRegistering ? "Make room for your places." : "Your places, together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 70)
                .padding(.bottom, 12)

                VStack(spacing: 12) {
                    TextField("Username", text: $handle)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .handle)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("account.handle")
                    SecureField("Password", text: $password)
                        // This is a loopback-only test account, not an iCloud
                        // credential. Avoid offering a generated saved password.
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit(submit)
                        .privacySensitive()
                        .accessibilityIdentifier("account.password")
                }
                .textFieldStyle(AccountTextFieldStyle())
                .disabled(account.isSubmitting)

                if isRegistering {
                    Text("Username: 3–32 letters, numbers or _.\nPassword: at least 12 characters.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let issue = account.issue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let notice = account.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(action: submit) {
                    Group {
                        if account.isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text(isRegistering ? "Create account" : "Sign in")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccountPrimaryButtonStyle())
                .disabled(canSubmit == false)
                .opacity(canSubmit || account.isSubmitting ? 1 : 0.4)
                .accessibilityIdentifier("account.submit")

                Button(isRegistering ? "Already have an account? Sign in" : "New here? Create an account") {
                    isRegistering.toggle()
                    account.issue = nil
                    password = ""
                }
                .font(.subheadline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .disabled(account.isSubmitting)
                .accessibilityIdentifier("account.mode")

                Text("Local test · This Mac only\nUse a test password, not one from another account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.white)
        .foregroundStyle(.black)
    }

    private var canSubmit: Bool {
        account.isSubmitting == false
            && handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && password.isEmpty == false
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await account.authenticate(
                handle: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                register: isRegistering
            )
            if account.environment != nil || account.restoreFailed { password = "" }
        }
    }
}

private struct AccountTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 16))
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AccountPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

@MainActor
final class BackendAccountController: ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    @Published private(set) var isRestoring = true
    @Published private(set) var isSubmitting = false
    @Published private(set) var restoreFailed = false
    @Published var issue: String?
    @Published private(set) var notice: String?
    @Published var signOutIssue: String?
    @Published private(set) var isPreparingApple = false
    @Published private(set) var appleChallenge: BackendAppleChallenge?
    @Published private(set) var betaAccess: BackendBetaAccess?
    @Published private(set) var enabledProviders: Set<String> = []
    private var signedInUser: User?
    private var pendingAppleChallenge: BackendAppleChallenge?
    private var appleOperation: UUID?
    private var lastSignInProvider = "apple"

    private var api: BackendAPI
    private let social: any SocialSignInProviding
    private let sessions: BackendSessionPersistence
    private var pendingStore: BackendStore?
    private var connectionTask: Task<Void, Never>?
    private var connectionRetryRequested = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var isForeground = true
    private var didStart = false
    private var operationID = UUID()

    init(api: BackendAPI? = nil, social: (any SocialSignInProviding)? = nil,
         sessions: BackendSessionPersistence? = nil) {
        self.api = api ?? Self.makeAPI()
        self.social = social ?? SocialSignInCoordinator.shared
        self.sessions = sessions ?? .keychain
        installAccessHandler()
    }

    private func installAccessHandler() {
        let observedAPI = api
        api.onUnauthorized = { [weak self, weak observedAPI] in
            guard let self, self.api === observedAPI else { return }
            self.operationID = UUID()
            self.clearExpiredSession()
        }
        api.onAccessDenied = { [weak self, weak observedAPI] status in
            guard let self, self.api === observedAPI else { return }
            self.operationID = UUID()
            self.connectionTask?.cancel()
            self.connectionTask = nil
            self.connectionRetryRequested = false
            self.cancelRecovery()
            self.environment?.backend?.clearLocalMedia()
            self.pendingStore?.clearLocalMedia()
            self.pendingStore = nil
            self.environment = nil
            self.betaAccess = BackendBetaAccess(required: true, status: status)
            self.restoreFailed = false
            self.isRestoring = false
            self.isSubmitting = false
        }
    }

    func showsProvider(_ provider: String) -> Bool {
        api.baseURL.scheme != "https" || enabledProviders.contains(provider)
    }

    func prepareSignIn() async {
        guard environment == nil, betaAccess == nil, !isSubmitting else { return }
        if api.baseURL.scheme == "https" {
            do {
                let available = try await api.authProviders()
                enabledProviders = Set(available.providers.filter { $0.available && ($0.id == "apple" || social.configurationIssue(for: $0.id) == nil) }.map(\.id))
                guard !enabledProviders.isEmpty else {
                    issue = "Sign-in isn't configured for this build yet. Contact the person who invited you."
                    return
                }
                if !enabledProviders.contains("apple") { issue = nil; return }
            } catch { issue = error.localizedDescription; return }
        }
        await prepareAppleSignIn()
    }

    func redeemInvite(_ code: String) async {
        guard !isSubmitting, let user = signedInUser else { return }
        isSubmitting = true
        issue = nil
        let operation = operationID
        defer { if operation == operationID { isSubmitting = false } }
        do {
            try await api.redeemInvite(code.trimmingCharacters(in: .whitespacesAndNewlines))
            guard operation == operationID else { return }
            try await connect(user: user, operation: operation)
        } catch {
            guard operation == operationID else { return }
            restoreFailed = betaAccess == nil
            issue = error.localizedDescription
        }
    }

    func deleteAccount() async throws {
        guard !isSubmitting else { throw BackendClientError.message("Please wait for the current action to finish.") }
        let operation = operationID
        let deletingUser = signedInUser
        let deletingAPI = api
        isSubmitting = true
        defer { if operationID == operation { isSubmitting = false } }
        try await deletingAPI.deleteAccount()
        if let user = deletingUser {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BackendAccounts/\(user.id.uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        guard operationID == operation else { return }
        signOut(sessionAlreadyRevoked: true)
    }

    func signInWithSocial(provider: String) async {
        guard ["google", "wechat"].contains(provider), !isSubmitting, environment == nil else { return }
        let operation = UUID()
        operationID = operation
        lastSignInProvider = provider
        isSubmitting = true
        issue = nil
        var savedSession = false
        defer { if operationID == operation { isSubmitting = false } }
        do {
            if let reason = social.configurationIssue(for: provider) {
                throw BackendClientError.message(reason)
            }
            let configuration = try await api.authProviders()
            guard operationID == operation else { return }
            guard let status = configuration.providers.first(where: { $0.id == provider }), status.available else {
                let reason = configuration.providers.first(where: { $0.id == provider })?.reason
                throw BackendClientError.message(reason ?? "This sign-in provider is not configured on the server yet.")
            }
            let challenge = try await api.socialChallenge(provider: provider)
            guard operationID == operation else { return }
            guard challenge.expiresAt.timeIntervalSinceNow > 30 else {
                throw BackendClientError.message("This sign-in attempt expired. Please try again.")
            }
            let code: String
            var returnedState: String?
            if provider == "google" {
                code = try await social.signInGoogle()
            } else {
                guard let state = challenge.state, !state.isEmpty else {
                    throw BackendClientError.message("The server returned an invalid WeChat sign-in request.")
                }
                let authorization = try await social.signInWeChat(state: state)
                guard authorization.state == state else {
                    throw BackendClientError.message("WeChat couldn't verify this sign-in attempt. Please try again.")
                }
                code = authorization.code
                returnedState = authorization.state
            }
            guard operationID == operation else { return }
            guard !code.isEmpty, challenge.expiresAt > .now else {
                throw BackendClientError.message("This sign-in attempt expired. Please try again.")
            }
            let auth = try await api.authenticateWithSocial(provider: provider, challengeID: challenge.challengeId,
                                                            code: code, state: returnedState)
            guard operationID == operation else { return }
            try await saveSession(auth)
            savedSession = true
            try await connect(user: auth.user.user, operation: operation, profile: auth.user)
        } catch is CancellationError {
            // Closing a provider's authorization sheet is not a failed login.
        } catch {
            guard operationID == operation else { return }
            restoreFailed = savedSession
            issue = error.localizedDescription
        }
    }

    func retrySignIn() async {
        if enabledProviders.isEmpty && api.baseURL.scheme == "https" { await prepareSignIn() }
        else if lastSignInProvider == "apple" { await prepareAppleSignIn(force: true) }
        else { await signInWithSocial(provider: lastSignInProvider) }
    }

    func cancelPendingSignIn() {
        guard isSubmitting, environment == nil else { return }
        if pendingStore != nil {
            // Authorization has already saved a session but its initial read
            // is still loading. Cancel this newly signed-in session normally.
            signOut()
            return
        }
        operationID = UUID()
        appleOperation = nil
        pendingAppleChallenge = nil
        social.signOut()
        pendingStore?.clearLocalMedia()
        pendingStore = nil
        isSubmitting = false
        issue = nil
    }

    var appleSignInReady: Bool {
        appleChallenge.map { $0.expiresAt.timeIntervalSinceNow > 30 } ?? false
    }

    func refreshAppleChallengeBeforeExpiry() async {
        guard let challenge = appleChallenge else { return }
        do {
            try await Task.sleep(for: .seconds(max(0, challenge.expiresAt.timeIntervalSinceNow - 60)))
            try Task.checkCancellation()
            guard appleChallenge?.challengeId == challenge.challengeId else { return }
            await prepareAppleSignIn(force: true)
        } catch { /* A dismissed screen or started sign-in cancels this timer. */ }
    }

    func prepareAppleSignIn(force: Bool = false) async {
        guard !isPreparingApple, !isSubmitting, environment == nil else { return }
        if !force, let challenge = appleChallenge, challenge.expiresAt.timeIntervalSinceNow > 30 { return }
        let operation = operationID
        isPreparingApple = true
        defer { isPreparingApple = false }
        do {
            let challenge = try await api.appleChallenge()
            guard operationID == operation else { return }
            guard challenge.expiresAt.timeIntervalSinceNow > 30 else {
                throw BackendClientError.message("This sign-in attempt expired. Please try again.")
            }
            appleChallenge = challenge
            if lastSignInProvider == "apple" { issue = nil }
        } catch {
            guard operationID == operation else { return }
            appleChallenge = nil
            if lastSignInProvider == "apple" { issue = error.localizedDescription }
        }
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard let challenge = appleChallenge, appleSignInReady, !isSubmitting else {
            // A stale system callback must never send an unbound authorization.
            request.nonce = UUID().uuidString
            request.state = UUID().uuidString
            issue = "Preparing Apple sign-in. Please try again."
            Task { await prepareAppleSignIn(force: true) }
            return
        }
        let operation = UUID()
        operationID = operation
        lastSignInProvider = "apple"
        appleOperation = operation
        pendingAppleChallenge = challenge
        appleChallenge = nil
        isSubmitting = true
        issue = nil
        request.nonce = challenge.nonce
        request.state = challenge.challengeId.uuidString
        // No email, password or contact access needed for a MapTalk account.
        request.requestedScopes = []
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard let operation = appleOperation, operationID == operation,
              let challenge = pendingAppleChallenge else { return }
        appleOperation = nil
        pendingAppleChallenge = nil
        var savedSession = false
        defer { if operationID == operation { isSubmitting = false } }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == challenge.challengeId.uuidString,
                  let bytes = credential.identityToken,
                  let identityToken = String(data: bytes, encoding: .utf8) else {
                throw BackendClientError.message("Apple couldn't complete sign-in. Please try again.")
            }
            let auth = try await api.authenticateWithApple(challengeID: challenge.challengeId, identityToken: identityToken,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) })
            guard operationID == operation else { return }
            try await saveSession(auth)
            savedSession = true
            try await connect(user: auth.user.user, operation: operation, profile: auth.user)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // Dismissing Apple's sheet is not an error or an account change.
        } catch {
            guard operationID == operation else { return }
            restoreFailed = savedSession
            issue = error.localizedDescription
        }
        guard operationID == operation else { return }
        isSubmitting = false
        if environment == nil && betaAccess == nil && !restoreFailed {
            // Always use a fresh challenge after cancellation or failure.
            let previousIssue = issue
            await prepareAppleSignIn()
            if issue == nil { issue = previousIssue }
        }
    }

    private func saveSession(_ auth: BackendAuth) async throws {
        api.token = auth.token
        do { try sessions.save(auth) }
        catch {
            try? await api.logout()
            api.token = nil
            throw error
        }
    }

    func start() async {
        guard didStart == false else { return }
        didStart = true
        await restore()
    }

    func restore() async {
        let operation = UUID()
        operationID = operation
        connectionTask?.cancel()
        connectionTask = nil
        connectionRetryRequested = false
        cancelRecovery()
        isRestoring = true
        restoreFailed = false
        issue = nil
        defer { if operationID == operation { isRestoring = false } }
        do {
            guard let saved = try sessions.load() else {
                api.token = nil
                return
            }
            guard saved.expiresAt > Date() else { throw BackendClientError.unauthorized }
            api.token = saved.token
            let cachedStore = BackendStore(user: saved.user.user, api: api)
            if await cachedStore.restoreCachedState() {
                guard operationID == operation else { return }
                signedInUser = cachedStore.user
                attach(cachedStore)
                verifyCachedConnection(saved, store: cachedStore, operation: operation)
                return
            }
            let verifiedUser = try await api.me()
            guard operationID == operation else { return }
            try sessions.save(.init(user: verifiedUser, token: saved.token, expiresAt: saved.expiresAt))
            try await connect(user: verifiedUser.user, operation: operation, profile: verifiedUser)
        } catch BackendClientError.unauthorized {
            guard operationID == operation else { return }
            clearExpiredSession()
        } catch {
            guard operationID == operation else { return }
            restoreFailed = true
            issue = error.localizedDescription
        }
    }

    func authenticate(handle: String, password: String, register: Bool) async {
        guard isSubmitting == false else { return }
        let operation = UUID()
        operationID = operation
        isSubmitting = true
        issue = nil
        notice = nil
        var savedSession = false
        defer { if operationID == operation { isSubmitting = false } }
        do {
            let auth = try await api.authenticate(handle: handle, password: password, register: register)
            guard operationID == operation else { return }
            try await saveSession(auth)
            savedSession = true
            try await connect(user: auth.user.user, operation: operation, profile: auth.user)
        } catch BackendClientError.unauthorized {
            guard operationID == operation else { return }
            clearExpiredSession()
        } catch {
            guard operationID == operation else { return }
            restoreFailed = savedSession
            issue = error.localizedDescription
        }
    }

    private func connect(user: User, operation: UUID, profile: BackendUser? = nil) async throws {
        signedInUser = user
        if api.baseURL.scheme == "https" {
            let access = try await api.betaAccess()
            guard operationID == operation else { return }
            betaAccess = access.isActive ? nil : access
            if !access.isActive {
                restoreFailed = false
                issue = nil
                return
            }
        }
        pendingStore?.clearLocalMedia()
        let store = BackendStore(user: user, api: api)
        pendingStore = store
        // A prior expired token may have left this account's unsent memories
        // safely on disk. Restore them only after this fresh authorization.
        _ = await store.restoreCachedState()
        guard operationID == operation else { return }
        // Authentication and beta access succeeded. Persist that identity and
        // enter now; neither a slow feed nor one photo should gate the app.
        try await store.cacheVerifiedIdentity(profile: profile)
        guard operationID == operation else { return }
        attach(store)
        refreshConnection(store, operation: operation)
    }

    private func attach(_ store: BackendStore) {
        store.onSignOut = { [weak self] in self?.signOut() }
        store.onConnectionAvailable = { [weak self, weak store] in
            guard let self, self.environment?.backend === store else { return }
            self.cancelRecovery()
            self.resume()
        }
        environment = AppEnvironment.connected(to: store)
        pendingStore = nil
        restoreFailed = false
        issue = nil
    }

    private func verifyCachedConnection(_ saved: BackendAuth, store: BackendStore, operation: UUID) {
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { finishConnectionAttempt(operation: operation) }
            do {
                let verifiedUser = try await api.me()
                guard operationID == operation, store.isActive else { return }
                guard verifiedUser.id == saved.user.id else { throw BackendClientError.unauthorized }
                if api.baseURL.scheme == "https" {
                    let access = try await api.betaAccess()
                    guard operationID == operation, store.isActive else { return }
                    if !access.isActive {
                        store.clearLocalMedia()
                        environment = nil
                        betaAccess = access
                        restoreFailed = false
                        return
                    }
                }
                try sessions.save(.init(user: verifiedUser, token: saved.token, expiresAt: saved.expiresAt))
                store.resumeVerifiedConnection()
                try await store.refresh()
                guard operationID == operation, store.isActive else { return }
                cancelRecovery()
            } catch BackendClientError.unauthorized {
                guard operationID == operation else { return }
                clearExpiredSession()
            } catch {
                guard operationID == operation, store.isActive, !(error is CancellationError) else { return }
                // A connection failure is not a sign-out. Cached memories and
                // the durable outbox stay accessible until verification works.
                store.issue = "Couldn't refresh. Your saved memories are still available."
                scheduleRecovery(store, operation: operation)
            }
        }
    }

    private func refreshConnection(_ store: BackendStore, operation: UUID) {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { finishConnectionAttempt(operation: operation) }
            do {
                store.resumeVerifiedConnection()
                try await store.refresh()
                guard operationID == operation, store.isActive else { return }
                cancelRecovery()
            } catch BackendClientError.unauthorized {
                guard operationID == operation else { return }
                clearExpiredSession()
            } catch {
                guard operationID == operation, store.isActive, !(error is CancellationError) else { return }
                store.issue = "Couldn't refresh. Your saved memories are still available."
                scheduleRecovery(store, operation: operation)
            }
        }
    }

    /// Revalidate a cached session on foreground/connection recovery without
    /// taking the person out of the map while the server is unreachable.
    func resume() {
        guard didStart, isForeground, !isRestoring,
              let store = environment?.backend, store.isActive else { return }
        guard connectionTask == nil else {
            // A network recovery can arrive before the old failed request
            // returns. Remember it instead of waiting for another path change.
            connectionRetryRequested = true
            return
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        do {
            guard let saved = try sessions.load(), saved.user.id == store.user.id,
                  saved.expiresAt > Date() else {
                clearExpiredSession()
                return
            }
            verifyCachedConnection(saved, store: store, operation: operationID)
        } catch {
            store.issue = error.localizedDescription
        }
    }

    private func finishConnectionAttempt(operation: UUID) {
        guard operationID == operation else { return }
        connectionTask = nil
        if connectionRetryRequested {
            connectionRetryRequested = false
            resume()
        }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        cancelRecovery()
        if active { resume() }
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
    }

    private func scheduleRecovery(_ store: BackendStore, operation: UUID) {
        guard isForeground, recoveryTask == nil, recoveryAttempts < 3 else { return }
        recoveryAttempts += 1
        recoveryTask = Task { [weak self, weak store] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard let self, let store, operationID == operation, store.isActive,
                  environment?.backend === store, isForeground else { return }
            recoveryTask = nil
            resume()
        }
    }

    func signOut(sessionAlreadyRevoked: Bool = false) {
        if !sessionAlreadyRevoked,
           environment?.backend?.hasPendingSyncWork == true || pendingStore?.hasPendingSyncWork == true {
            let store = environment?.backend ?? pendingStore
            signOutIssue = store?.pendingPublications.isEmpty == true
                ? "A deletion is waiting to sync. Connect to the internet before signing out."
                : "Some memories are waiting to upload. Upload them or delete them from MyMap before signing out."
            return
        }
        do {
            try sessions.delete()
        } catch {
            if !sessionAlreadyRevoked {
                signOutIssue = error.localizedDescription
                return
            }
        }
        let operation = UUID()
        operationID = operation
        connectionTask?.cancel()
        connectionTask = nil
        connectionRetryRequested = false
        cancelRecovery()
        appleChallenge = nil
        lastSignInProvider = "apple"
        pendingAppleChallenge = nil
        appleOperation = nil
        let previousAPI = api
        social.signOut()
        environment?.backend?.clearLocalMedia()
        pendingStore?.clearLocalMedia()
        pendingStore = nil
        environment = nil
        betaAccess = nil
        signedInUser = nil
        api = Self.makeAPI()
        installAccessHandler()
        isRestoring = false
        isSubmitting = false
        restoreFailed = false
        issue = nil
        notice = "Signed out on this device."
        if sessionAlreadyRevoked {
            previousAPI.token = nil
            notice = "Account deleted."
            return
        }
        Task {
            defer { previousAPI.token = nil }
            do { try await previousAPI.logout() }
            catch {
                guard operationID == operation else { return }
                notice = "Signed out on this device. The server couldn't confirm sign-out; its session expires automatically within 7 days."
            }
        }
    }

    private func clearExpiredSession() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionRetryRequested = false
        cancelRecovery()
        environment?.backend?.clearLocalMedia(preservePendingPublications: true)
        environment = nil
        api.token = nil
        betaAccess = nil
        signedInUser = nil
        pendingStore?.clearLocalMedia(preservePendingPublications: true)
        pendingStore = nil
        isRestoring = false
        isSubmitting = false
        do {
            try sessions.delete()
            restoreFailed = false
            issue = "Your session has expired. Please sign in again."
        } catch {
            restoreFailed = true
            issue = error.localizedDescription
        }
    }

    private static func makeAPI() -> BackendAPI {
        // BackendRootView is only constructed after validating configuration.
        BackendAPI(baseURL: BackendDeploymentConfiguration.configuredURL!)
    }
}

/// Defaults to Keychain; tests inject isolated storage without changing a real
/// signed-in account on the device running the test bundle.
@MainActor
struct BackendSessionPersistence {
    let load: @MainActor () throws -> BackendAuth?
    let save: @MainActor (BackendAuth) throws -> Void
    let delete: @MainActor () throws -> Void

    static var keychain: Self {
        .init(load: BackendSessionStorage.load, save: BackendSessionStorage.save,
              delete: BackendSessionStorage.delete)
    }
}

@MainActor
private enum BackendSessionStorage {
    private static var service: String {
        var value = "\(Bundle.main.bundleIdentifier ?? "maptalk").\(BackendDeploymentConfiguration.sessionNamespace)"
#if DEBUG
        if let namespace = ProcessInfo.processInfo.environment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] {
            value += ".\(namespace)"
        }
#endif
        return value
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "session-v1"]
    }

    static func load() throws -> BackendAuth? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BackendClientError.message("Couldn't read your saved session securely. Unlock this device and retry.")
        }
        return try BackendAPI.decoder.decode(BackendAuth.self, from: data)
    }

    static func save(_ auth: BackendAuth) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(auth)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw BackendClientError.message("Couldn't save your session securely. Please retry.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw BackendClientError.message("Couldn't save your session securely. Please retry.")
        }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackendClientError.message("Couldn't clear your saved session. Unlock this device and try signing out again.")
        }
    }
}
