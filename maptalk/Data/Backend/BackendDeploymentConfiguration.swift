import Foundation

/// The release app never falls back to demo data or a developer's loopback API.
nonisolated enum BackendDeploymentConfiguration {
    static func validatedURL(_ text: String, allowLocal: Bool) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard (url.scheme == "https" && !local) || (allowLocal && url.scheme == "http" && local) else { return nil }
        return url
    }

    static var configuredURL: URL? {
#if DEBUG
        if let address = ProcessInfo.processInfo.environment["MAPTALK_BACKEND_URL"] {
            return validatedURL(address, allowLocal: true)
        }
#endif
        if let address = Bundle.main.object(forInfoDictionaryKey: "MapTalkBackendURL") as? String,
           !address.isEmpty, !address.contains("$(") {
            return validatedURL(address, allowLocal: false)
        }
#if DEBUG
        return URL(string: "http://127.0.0.1:8787")
#else
        return nil
#endif
    }

    static var isHosted: Bool { configuredURL?.scheme == "https" }

    static var sessionNamespace: String {
        guard let url = configuredURL, url.scheme == "https" else { return "local-backend" }
        return "backend.\(url.host ?? "").\(url.port ?? 443)"
    }

    static func publicURL(for key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
