import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        }
    }
}
