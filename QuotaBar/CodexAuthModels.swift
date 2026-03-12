import Foundation

struct CodexAuthPayload: Codable, Sendable {
    struct Tokens: Codable, Sendable {
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountID = "account_id"
        }
    }

    var authMode: String?
    var openAIAPIKey: String?
    var tokens: Tokens?
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct CodexAccountIdentity: Sendable {
    let email: String
    let accountID: String
    let planType: String
}

enum CodexAuthParser {
    static func identity(from authData: Data) throws -> CodexAccountIdentity {
        let decoder = JSONDecoder()
        let payload = try decoder.decode(CodexAuthPayload.self, from: authData)

        if let idToken = payload.tokens?.idToken,
           let identity = identity(fromJWT: idToken, fallbackAccountID: payload.tokens?.accountID) {
            return identity
        }

        if let accessToken = payload.tokens?.accessToken,
           let identity = identity(fromJWT: accessToken, fallbackAccountID: payload.tokens?.accountID) {
            return identity
        }

        throw CodexAppServerError.malformedAuthData
    }

    static func bearerToken(from authData: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: authData)
        guard let root = object as? [String: Any] else {
            throw CodexAppServerError.malformedAuthData
        }

        if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CodexAppServerError.requestFailed(
                message: "This account appears to use OPENAI_API_KEY. Usage monitoring needs a ChatGPT/Codex bearer token."
            )
        }

        if let token = searchBearerToken(in: root["tokens"]) ?? searchBearerToken(in: root) {
            return token
        }

        throw CodexAppServerError.requestFailed(
            message: "Could not find a usable bearer token in auth.json."
        )
    }

    private static func identity(fromJWT token: String, fallbackAccountID: String?) -> CodexAccountIdentity? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payloadData = decodeBase64URL(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        let email = object["email"] as? String
            ?? ((object["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)

        let authClaims = object["https://api.openai.com/auth"] as? [String: Any]
        let accountID = fallbackAccountID
            ?? authClaims?["chatgpt_account_id"] as? String
            ?? authClaims?["chatgpt_account_user_id"] as? String
        let planType = authClaims?["chatgpt_plan_type"] as? String
            ?? authClaims?["chatgpt_subscription_plan_type"] as? String
            ?? "unknown"

        guard let email, let accountID else { return nil }
        return CodexAccountIdentity(email: email, accountID: accountID, planType: planType)
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }

    private static func searchBearerToken(in value: Any?) -> String? {
        switch value {
        case let object as [String: Any]:
            let preferredKeys = [
                "access_token",
                "accessToken",
                "token",
                "id_token",
                "idToken",
                "chatgpt_access_token",
            ]

            for key in preferredKeys {
                if let token = normalizedToken(from: object[key]) {
                    return token
                }
            }

            for (key, child) in object where shouldInspectTokenField(key) {
                if let token = searchBearerToken(in: child) {
                    return token
                }
            }
            return nil
        case let array as [Any]:
            for item in array {
                if let token = searchBearerToken(in: item) {
                    return token
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func shouldInspectTokenField(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return !lowered.contains("refresh") && !lowered.contains("secret") && !lowered.contains("api_key") && !lowered.contains("api-key")
    }

    private static func normalizedToken(from value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = token.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.count >= 20, !token.contains(" ") else { return nil }
        return token
    }
}

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
