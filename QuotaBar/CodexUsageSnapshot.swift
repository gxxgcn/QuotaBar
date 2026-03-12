import Foundation

struct RateLimitWindowSnapshot: Codable, Hashable, Sendable {
    var usedPercent: Int
    var resetsAt: Date?
    var resetDescription: String?
    var windowDurationMins: Int?

    var percentLeft: Int {
        max(0, 100 - usedPercent)
    }
}

struct RateLimitSnapshotData: Codable, Hashable, Sendable {
    var limitID: String?
    var limitName: String?
    var planType: String?
    var primary: RateLimitWindowSnapshot?
    var secondary: RateLimitWindowSnapshot?

    var dominantWindow: RateLimitWindowSnapshot? {
        primary ?? secondary
    }
}

struct CodexUsageSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID { accountID }
    let accountID: UUID
    let email: String
    let planType: String
    let rateLimitsByLimitID: [String: RateLimitSnapshotData]
    let primaryLimit: RateLimitSnapshotData?
    let secondaryLimit: RateLimitSnapshotData?
    let lastError: String?
    let fetchedAt: Date

    var preferredRateLimit: RateLimitSnapshotData? {
        rateLimitsByLimitID["codex"] ?? primaryLimit ?? rateLimitsByLimitID.values.sorted {
            ($0.limitName ?? "") < ($1.limitName ?? "")
        }.first
    }

    var highestUsagePercent: Int {
        let candidates = [
            preferredRateLimit?.primary?.usedPercent,
            preferredRateLimit?.secondary?.usedPercent,
            primaryLimit?.primary?.usedPercent,
            secondaryLimit?.primary?.usedPercent,
        ]
        return candidates.compactMap { $0 }.max() ?? 0
    }
}
