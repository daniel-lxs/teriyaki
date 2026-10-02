import SwiftUI
import WebKit

/// PlayStation Network sign-in, used once to look up the account ID that consoles ask for.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            SignInWebView { result in
                switch result {
                case .success(let accountID):
                    Prefs.shared.accountID = accountID
                    dismiss()
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
            Divider()
            HStack {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
    }
}

private enum PSN {
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let token = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    static var loginURL: URL {
        let device = "0000000700410080" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
            URLQueryItem(name: "duid", value: device),
        ]
        return components.url!
    }

    static var authorization: String {
        "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }

    static func accountID(code: String) async throws -> Data {
        var request = URLRequest(url: URL(string: token)!)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=authorization_code&code=\(code)&scope=\(scope)&redirect_uri=\(redirect)&".utf8)
        let (tokenData, _) = try await URLSession.shared.data(for: request)
        guard let tokenJSON = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let accessToken = tokenJSON["access_token"] as? String else { throw SignInError.unexpectedResponse }

        var info = URLRequest(url: URL(string: "\(token)/\(accessToken)")!)
        info.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (infoData, _) = try await URLSession.shared.data(for: info)
        guard let infoJSON = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let text = infoJSON["user_id"] as? String, let number = UInt64(text) else { throw SignInError.unexpectedResponse }
        return withUnsafeBytes(of: number.littleEndian) { Data($0) }
    }
}

enum SignInError: LocalizedError {
    case unexpectedResponse

    var errorDescription: String? { "PlayStation Network didn’t return an account. Try again." }
}

private struct SignInWebView: NSViewRepresentable {
    let completion: (Result<Data, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSN.loginURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let completion: (Result<Data, Error>) -> Void
        private var finished = false

        init(completion: @escaping (Result<Data, Error>) -> Void) {
            self.completion = completion
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.absoluteString.hasPrefix(PSN.redirect),
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
                  !finished else {
                decisionHandler(.allow)
                return
            }
            finished = true
            decisionHandler(.cancel)
            Task { @MainActor in
                do {
                    completion(.success(try await PSN.accountID(code: code)))
                } catch {
                    finished = false
                    completion(.failure(error))
                }
            }
        }
    }
}
