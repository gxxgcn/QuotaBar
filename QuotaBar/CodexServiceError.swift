import Foundation

enum CodexAppServerError: LocalizedError {
    case requestFailed(message: String)
    case loginCancelled
    case loginDidNotProduceAuth
    case malformedAuthData

    var errorDescription: String? {
        switch self {
        case let .requestFailed(message):
            return message
        case .loginCancelled:
            return "Login was cancelled."
        case .loginDidNotProduceAuth:
            return "Login finished but did not produce auth data."
        case .malformedAuthData:
            return "Stored auth data is malformed."
        }
    }
}
