import AppKit
import CryptoKit
import Foundation
import Network

/// "Connect Google Calendar" OAuth, so scheduled meetings can start recording
/// automatically. Same PKCE authorization-code flow as `ChatGPTOAuth`, but
/// against Google's endpoints and with a desktop-client id/secret the user
/// supplies in Settings (this repo is public, so nothing is compiled in).
/// Tokens live in `~/.config/macwhisper/google-oauth.json` (owner-only); the
/// refresh token keeps the connection alive for months, so the user signs in
/// once. Read-only calendar scope.
final class GoogleOAuth {
    static let shared = GoogleOAuth()

    private static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let redirectURI = "http://localhost:1456/oauth/callback"
    // openid+email so we can show which account is connected; calendar.readonly
    // to list events. No write scope.
    private static let scope = "openid email https://www.googleapis.com/auth/calendar.readonly"
    private static let callbackPort: NWEndpoint.Port = 1456

    private var clientID: String { Settings.shared.googleClientID }
    private var clientSecret: String { Settings.shared.googleClientSecret }

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Credentials: Codable {
        var access: String
        var refresh: String
        /// Epoch seconds when the access token expires.
        var expiresAt: TimeInterval
        var email: String
    }

    private static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/google-oauth.json")
    }

    private var listener: NWListener?
    private var pendingVerifier: String?
    private var pendingState: String?
    private var signInCompletion: ((Result<Void, Error>) -> Void)?

    var isSignedIn: Bool { loadCredentials() != nil }
    /// The connected account's email, for the settings status line.
    var signedInEmail: String? { loadCredentials()?.email }

    // MARK: - Sign in / out

    /// Starts the browser OAuth flow. The completion fires on an arbitrary queue
    /// after the callback is received and tokens are stored (or on failure).
    func signIn(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            completion(.failure(AuthError(message: "먼저 Google 클라이언트 ID와 secret을 입력하세요")))
            return
        }
        // A previous unfinished attempt holds the port; tear it down first.
        stopCallbackServer()

        let verifier = Self.randomURLSafeString(bytes: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(bytes: 16)
        pendingVerifier = verifier
        pendingState = state
        signInCompletion = completion

        do {
            try startCallbackServer()
        } catch {
            finishSignIn(.failure(AuthError(message: "콜백 포트 1456을 열 수 없습니다: \(error.localizedDescription)")))
            return
        }

        var comps = URLComponents(string: Self.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Required to receive a refresh token from Google: offline access,
            // and force the consent screen so a refresh token is issued even on
            // a re-connect.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        // Give up after 5 minutes so the port isn't held forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.signInCompletion != nil else { return }
            self.finishSignIn(.failure(AuthError(message: "로그인 시간 초과")))
        }
    }

    func signOut() {
        try? FileManager.default.removeItem(at: Self.credentialsURL)
    }

    /// Runs `completion` with a valid access token, refreshing it first when it
    /// is expired or about to expire. Google does not reissue the refresh token
    /// on a refresh grant, so the stored one is carried forward.
    func withFreshToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard let creds = loadCredentials() else {
            completion(.failure(AuthError(message: "Google 캘린더가 연동되지 않았습니다")))
            return
        }
        if creds.expiresAt - Date().timeIntervalSince1970 > 300 {
            completion(.success(creds.access))
            return
        }
        requestToken(params: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
        ], carryOver: creds) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let new):
                self?.storeCredentials(new)
                completion(.success(new.access))
            }
        }
    }

    // MARK: - Callback server (localhost:1456)

    private func startCallbackServer() throws {
        // Bind to loopback only: the default binds to all interfaces, which
        // would expose the OAuth callback server to the local network.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.callbackPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.handleHTTPRequest(request, on: connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func stopCallbackServer() {
        listener?.cancel()
        listener = nil
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        // "GET /oauth/callback?code=…&state=… HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: String(parts[1])),
              comps.path == "/oauth/callback" else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        let code = comps.queryItems?.first { $0.name == "code" }?.value
        let state = comps.queryItems?.first { $0.name == "state" }?.value

        guard let code, state == pendingState else {
            respond(connection, status: "400 Bad Request",
                    body: "<h2>연동 실패</h2><p>코드 누락 또는 state 불일치. Mac Transcribe로 돌아가 다시 시도하세요.</p>")
            finishSignIn(.failure(AuthError(message: "OAuth callback missing code or state mismatch")))
            return
        }
        respond(connection, status: "200 OK",
                body: "<h2>Google 캘린더 연동 완료</h2><p>이 창을 닫고 앱으로 돌아가세요.</p>")

        let verifier = pendingVerifier ?? ""
        requestToken(params: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Self.redirectURI,
        ], carryOver: nil) { [weak self] result in
            switch result {
            case .failure(let error):
                self?.finishSignIn(.failure(error))
            case .success(let creds):
                self?.storeCredentials(creds)
                self?.finishSignIn(.success(()))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:80px\">\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finishSignIn(_ result: Result<Void, Error>) {
        stopCallbackServer()
        pendingVerifier = nil
        pendingState = nil
        let completion = signInCompletion
        signInCompletion = nil
        completion?(result)
    }

    // MARK: - Token endpoint

    /// `carryOver` supplies the previous credentials on a refresh grant, where
    /// Google omits the refresh token (and may omit the id_token) — those
    /// fields are then carried forward instead of failing.
    private func requestToken(params: [String: String], carryOver: Credentials?,
                              completion: @escaping (Result<Credentials, Error>) -> Void) {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(AuthError(message: "토큰 요청 실패 (HTTP \(status)): \(detail)")))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                completion(.failure(AuthError(message: "토큰 응답 필드 누락")))
                return
            }
            // Google returns a refresh token only on the initial consent, not on
            // refresh; carry the previous one forward.
            let refresh = (json["refresh_token"] as? String) ?? carryOver?.refresh ?? ""
            guard !refresh.isEmpty else {
                completion(.failure(AuthError(message: "refresh token을 받지 못했습니다 — 다시 연동하세요")))
                return
            }
            let email = (json["id_token"] as? String).flatMap { Self.email(fromJWT: $0) }
                ?? carryOver?.email ?? ""
            completion(.success(Credentials(
                access: access,
                refresh: refresh,
                expiresAt: Date().timeIntervalSince1970 + expiresIn,
                email: email
            )))
        }.resume()
    }

    /// The connected account's email lives in the id_token's `email` claim.
    private static func email(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    // MARK: - Credential storage

    private func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: Self.credentialsURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private func storeCredentials(_ creds: Credentials) {
        let url = Self.credentialsURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: url, options: .atomic)
        // The refresh token grants calendar access: owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Encoding helpers

    private static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
