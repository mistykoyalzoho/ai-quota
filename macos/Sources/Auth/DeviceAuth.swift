import Foundation
import AppKit

enum DeviceAuth {
    struct DeviceCodeResponse: Codable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String?
        let expiresIn: Int
        let interval: Int?
    }

    struct TokenResponse: Codable {
        let accessToken: String
        let tokenType: String?
        let expiresIn: Int?
        let refreshToken: String?
        let idToken: String?
    }

    enum DeviceAuthError: LocalizedError {
        case requestFailed(String)
        case expired
        case accessDenied
        case pending

        var errorDescription: String? {
            switch self {
            case .requestFailed(let msg): return "Device auth request failed: \(msg)"
            case .expired: return "Authorization code expired. Please try again."
            case .accessDenied: return "Authorization was denied."
            case .pending: return "Authorization is pending."
            }
        }
    }

    private static let clientId = "xai-grok-app"
    private static let deviceEndpoint = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private static let tokenEndpoint  = URL(string: "https://auth.x.ai/oauth2/token")!

    static func requestDeviceCode() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: deviceEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientId)&scope=openid%20profile%20email%20offline_access"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw DeviceAuthError.requestFailed(msg)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DeviceCodeResponse.self, from: data)
    }

    static func pollForToken(deviceCode: String, interval: Int = 5, timeoutSeconds: Int = 300) async throws -> TokenResponse {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let waitInterval = max(interval, 3)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(waitInterval) * 1_000_000_000)

            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "client_id=\(clientId)&grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=\(deviceCode)"
            req.httpBody = body.data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { continue }

            if (200...299).contains(http.statusCode) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(TokenResponse.self, from: data)
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? String {
                switch err {
                case "authorization_pending": continue
                case "slow_down":
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                case "expired_token": throw DeviceAuthError.expired
                case "access_denied": throw DeviceAuthError.accessDenied
                default: throw DeviceAuthError.requestFailed(err)
                }
            }
        }

        throw DeviceAuthError.expired
    }
}
