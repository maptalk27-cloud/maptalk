import Foundation
@preconcurrency import GoogleSignIn
@preconcurrency import MapTalkWeChatSDK
import UIKit

nonisolated struct WeChatAuthorization: Sendable {
    let code: String
    let state: String
}

nonisolated enum SocialSignInError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case let .message(message): return message }
    }
}

/// Native provider SDKs produce one-time codes; only our backend can create an
/// app session. No provider secrets, tokens or callback URLs are logged here.
@MainActor
final class SocialSignInCoordinator: NSObject, WXApiDelegate {
    static let shared = SocialSignInCoordinator()

    private var googleConfigured = false
    private var weChatRegistered = false
    private var googleAttempt: UUID?
    private var googleContinuation: CheckedContinuation<String, Error>?
    private var googleTimeout: Task<Void, Never>?
    private var weChatAttempt: UUID?
    private var weChatState: String?
    private var weChatContinuation: CheckedContinuation<WeChatAuthorization, Error>?
    private var weChatTimeout: Task<Void, Never>?

    private override init() { super.init() }

    func configurationIssue(for provider: String) -> String? {
        switch provider {
        case "google":
            guard let clientID = setting("GIDClientID"),
                  let serverID = setting("GIDServerClientID"),
                  clientID.hasSuffix(".apps.googleusercontent.com"),
                  serverID.hasSuffix(".apps.googleusercontent.com") else {
                return "Google sign-in needs this app's registered iOS and server client IDs."
            }
            let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
            guard callbackSchemes.contains(scheme) else {
                return "Google's callback URL scheme is missing from this build."
            }
            return nil
        case "wechat":
            guard let appID = setting("MapTalkWeChatAppID"),
                  appID.range(of: "^wx[a-zA-Z0-9]+$", options: .regularExpression) != nil,
                  let link = setting("MapTalkWeChatUniversalLink"),
                  let url = URL(string: link), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  link.hasSuffix("/") else {
                return "WeChat sign-in needs a registered App ID and an HTTPS Universal Link."
            }
            guard callbackSchemes.contains(appID) else {
                return "WeChat's callback URL scheme is missing from this build."
            }
            guard setting("MapTalkWeChatAssociatedDomain") == "applinks:\(url.host!)" else {
                return "WeChat's Associated Domain must match its Universal Link."
            }
            return nil
        default:
            return nil
        }
    }

    func signInGoogle() async throws -> String {
        if let issue = configurationIssue(for: "google") { throw SocialSignInError.message(issue) }
        guard googleContinuation == nil, weChatContinuation == nil else {
            throw SocialSignInError.message("Finish the current sign-in first.")
        }
        guard let presenter = presentingController() else {
            throw SocialSignInError.message("Open MapTalk before signing in.")
        }
        try Task.checkCancellation()
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: setting("GIDClientID")!, serverClientID: setting("GIDServerClientID")!
        )
        googleConfigured = true
        let attempt = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                googleAttempt = attempt
                googleContinuation = continuation
                googleTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(240)) } catch { return }
                    self?.finishGoogle(.failure(SocialSignInError.message("Sign-in timed out. Please try again.")), attempt: attempt)
                }
                GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                    // SDK documents completion on main; Task also isolates state
                    // and safely ignores a callback from an earlier attempt.
                    let code = result?.serverAuthCode
                    let failure = error as NSError?
                    Task { @MainActor in
                        guard self.googleAttempt == attempt else { return }
                        if let failure {
                            if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue {
                                self.finishGoogle(.failure(CancellationError()), attempt: attempt)
                            } else {
                                self.finishGoogle(.failure(SocialSignInError.message("Google couldn't complete sign-in. Please try again.")), attempt: attempt)
                            }
                        } else if let code, !code.isEmpty {
                            self.finishGoogle(.success(code), attempt: attempt)
                        } else {
                            self.finishGoogle(.failure(SocialSignInError.message("Google didn't return a server authorization code. Check the server client ID.")), attempt: attempt)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishGoogle(.failure(CancellationError()), attempt: attempt) }
        }
    }

    func signInWeChat(state: String) async throws -> WeChatAuthorization {
        if let issue = configurationIssue(for: "wechat") { throw SocialSignInError.message(issue) }
        guard googleContinuation == nil, weChatContinuation == nil else {
            throw SocialSignInError.message("Finish the current sign-in first.")
        }
        guard !state.isEmpty, state.utf8.count <= 1024 else {
            throw SocialSignInError.message("Start a new WeChat sign-in attempt.")
        }
        guard WXApi.isWXAppInstalled() else {
            throw SocialSignInError.message("Install WeChat on this iPhone, then try again. You can also use Apple or Google.")
        }
        guard WXApi.isWXAppSupport() else {
            throw SocialSignInError.message("Update WeChat on this iPhone, then try again.")
        }
        guard let presenter = presentingController(), registerWeChat() else {
            throw SocialSignInError.message("WeChat couldn't start. Check this build's App ID and Universal Link.")
        }
        try Task.checkCancellation()
        let attempt = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                weChatAttempt = attempt
                weChatState = state
                weChatContinuation = continuation
                weChatTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(240)) } catch { return }
                    self?.finishWeChat(.failure(SocialSignInError.message("WeChat sign-in timed out. Please try again.")), attempt: attempt)
                }
                let request = SendAuthReq()
                request.scope = "snsapi_userinfo"
                request.state = state
                WXApi.sendAuthReq(request, viewController: presenter, delegate: self) { sent in
                    Task { @MainActor in
                        guard !sent else { return }
                        self.finishWeChat(.failure(SocialSignInError.message("Couldn't open WeChat. Check the app registration and try again.")), attempt: attempt)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWeChat(.failure(CancellationError()), attempt: attempt) }
        }
    }

    func handleURL(_ url: URL) -> Bool {
        if let clientID = setting("GIDClientID"),
           configurationIssue(for: "google") == nil,
           url.scheme == clientID.split(separator: ".").reversed().joined(separator: ".") {
            return GIDSignIn.sharedInstance.handle(url)
        }
        guard url.scheme == setting("MapTalkWeChatAppID"), registerWeChat() else { return false }
        return WXApi.handleOpen(url, delegate: self)
    }

    func handleUniversalLink(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let incoming = activity.webpageURL,
              let expected = setting("MapTalkWeChatUniversalLink").flatMap(URL.init(string:)),
              incoming.scheme == expected.scheme, incoming.host == expected.host,
              incoming.port == expected.port,
              incoming.path == expected.path || incoming.path.hasPrefix(
                expected.path.hasSuffix("/") ? expected.path : expected.path + "/"
              ),
              registerWeChat() else { return false }
        return WXApi.handleOpenUniversalLink(activity, delegate: self)
    }

    nonisolated func onResp(_ response: BaseResp) {
        guard let auth = response as? SendAuthResp else { return }
        let code = auth.code
        let state = auth.state
        let errorCode = auth.errCode
        Task { @MainActor [weak self] in
            guard let self, let attempt = self.weChatAttempt else { return }
            // Cancellation / SDK failures can omit state. Never accept a
            // mismatched response, and successful auth still requires the
            // exact backend challenge state before returning any code.
            guard state == nil || state == self.weChatState else { return }
            if errorCode == -2 || errorCode == -4 {
                self.finishWeChat(.failure(CancellationError()), attempt: attempt)
            } else if errorCode == 0, let code, !code.isEmpty,
                      let state, state == self.weChatState {
                self.finishWeChat(.success(.init(code: code, state: state)), attempt: attempt)
            } else {
                self.finishWeChat(.failure(SocialSignInError.message("WeChat couldn't authorize sign-in. Please try again.")), attempt: attempt)
            }
        }
    }

    func signOut() {
        if let attempt = googleAttempt { finishGoogle(.failure(CancellationError()), attempt: attempt) }
        if let attempt = weChatAttempt { finishWeChat(.failure(CancellationError()), attempt: attempt) }
        // A restored MapTalk session can be signed out before this process has
        // invoked Google. Clear the SDK's persisted account in that case too.
        if googleConfigured || configurationIssue(for: "google") == nil {
            GIDSignIn.sharedInstance.signOut()
        }
    }

    private func finishGoogle(_ result: Result<String, Error>, attempt: UUID) {
        guard googleAttempt == attempt, let continuation = googleContinuation else { return }
        googleAttempt = nil
        googleContinuation = nil
        googleTimeout?.cancel()
        googleTimeout = nil
        continuation.resume(with: result)
    }

    private func finishWeChat(_ result: Result<WeChatAuthorization, Error>, attempt: UUID) {
        guard weChatAttempt == attempt, let continuation = weChatContinuation else { return }
        weChatAttempt = nil
        weChatContinuation = nil
        weChatState = nil
        weChatTimeout?.cancel()
        weChatTimeout = nil
        continuation.resume(with: result)
    }

    private func registerWeChat() -> Bool {
        if weChatRegistered { return true }
        guard configurationIssue(for: "wechat") == nil,
              let appID = setting("MapTalkWeChatAppID"),
              let universalLink = setting("MapTalkWeChatUniversalLink") else { return false }
        weChatRegistered = WXApi.registerApp(appID, universalLink: universalLink)
        return weChatRegistered
    }

    private func setting(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("YOUR_") else { return nil }
        return trimmed
    }

    private var callbackSchemes: [String] {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    private func presentingController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow),
              var controller = window.rootViewController else { return nil }
        while true {
            if let presented = controller.presentedViewController { controller = presented }
            else if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { controller = visible }
            else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { controller = selected }
            else { return controller }
        }
    }
}
