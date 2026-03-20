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
    case .requestFailed(let message):
      return message
    case .loginCancelled:
      return "Login was cancelled."
    case .loginDidNotProduceAuth:
      return "Login completed without auth data."
    case .malformedAuthData:
      return "Stored auth data is malformed."
    case .malformedLocalAuthData:
      return "Local auth file is malformed."
    case .localCodexHomeUnavailable:
      return "Could not resolve local `~/.codex` directory."
    case .localAuthBackupFailed(let path, let underlying):
      return "Backup failed: \(underlying)"
    case .localAuthWriteFailed(let path, let underlying):
      return "Auth write failed: \(underlying)"
    }
  }
}
