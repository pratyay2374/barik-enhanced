import AppKit
import CryptoKit
import Foundation

/// Barik's own OAuth (PKCE) client for Anthropic / Claude.
///
/// This lets the Claude Usage widget authenticate with a token it obtained
/// itself, instead of borrowing Claude Code's `Claude Code-credentials`
/// keychain item. The tokens we get here are stored in a keychain item Barik
/// OWNS (see `ClaudeUsageManager`), so reading them never triggers the macOS
/// cross-app authorization dialog, and no other app resets their ACL.
///
/// The flow is the standard Claude Code OAuth authorization-code + PKCE grant
/// with the "paste the code" (out-of-band) redirect, so no local web server or
/// custom URL scheme is required.
enum ClaudeOAuth {
    /// Public client id used by the Claude Code OAuth application.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    /// Out-of-band redirect: the page shows the user a code to paste back.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    /// One PKCE session — created when the user starts sign-in, consumed when
    /// they paste the resulting code.
    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    enum OAuthError: Error {
        case badCode
        case network
        case server(String)
        case decode
    }

    /// Generates a fresh PKCE verifier/challenge and anti-forgery `state`.
    static func makePKCE() -> PKCE {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafeString(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    /// The URL the user opens in their browser to authorize Barik.
    static func authorizationURL(pkce: PKCE) -> URL? {
        var components = URLComponents(string: authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components?.url
    }

    /// Exchanges the code the user pasted for access/refresh tokens. The pasted
    /// value is `"<code>#<state>"` — claude.ai appends the state after a `#`.
    static func exchange(pastedCode raw: String, pkce: PKCE) async -> Result<TokenResponse, OAuthError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.badCode) }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? trimmed
        let state = parts.count > 1 ? parts[1] : pkce.state

        return await postToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
    }

    /// Silently mints a fresh access token from a refresh token (no browser).
    static func refresh(refreshToken: String) async -> Result<TokenResponse, OAuthError> {
        return await postToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    // MARK: - Token endpoint

    private static func postToken(body: [String: Any]) async -> Result<TokenResponse, OAuthError> {
        guard let url = URL(string: tokenURL),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.decode)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.network) }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                return .failure(.server(msg))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                return .failure(.decode)
            }
            let refreshToken = json["refresh_token"] as? String
            let expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            return .success(TokenResponse(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt))
        } catch {
            return .failure(.network)
        }
    }

    // MARK: - Helpers

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
