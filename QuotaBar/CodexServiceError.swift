import Foundation

enum CodexAppServerError: LocalizedError {
    case requestFailed(message: String)
    case loginCancelled
    case loginDidNotProduceAuth
    case malformedAuthData
    case malformedLocalAuthData
    case localCodexHomeUnavailable
    case localAuthBackupFailed(path: String, underlying: String)
    case localAuthWriteFailed(path: String, underlying: String)

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
        case .malformedLocalAuthData:
            return "The local `~/.codex/auth.json` file is malformed."
        case .localCodexHomeUnavailable:
            return "Could not resolve the local `~/.codex` directory."
        case let .localAuthBackupFailed(path, underlying):
            return "Could not back up local auth to `\(path)`. \(underlying)"
        case let .localAuthWriteFailed(path, underlying):
            return "Could not write local auth at `\(path)`. \(underlying)"
        }
    }
}
