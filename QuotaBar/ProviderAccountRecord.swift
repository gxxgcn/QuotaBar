import Foundation
import SwiftData

@Model
final class ProviderAccountRecord {
    @Attribute(.unique) var id: UUID
    var providerKindRawValue: String
    var displayName: String
    var email: String
    var remoteAccountID: String
    var planType: String
    var isEnabled: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    var lastKnownStatus: String
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        providerKind: ProviderKind,
        displayName: String,
        email: String,
        remoteAccountID: String,
        planType: String,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        lastSyncedAt: Date? = nil,
        lastKnownStatus: String = AccountSyncStatus.idle.rawValue,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.providerKindRawValue = providerKind.rawValue
        self.displayName = displayName
        self.email = email
        self.remoteAccountID = remoteAccountID
        self.planType = planType
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
        self.lastKnownStatus = lastKnownStatus
        self.sortOrder = sortOrder
    }

    var providerKind: ProviderKind {
        get { ProviderKind(rawValue: providerKindRawValue) ?? .codex }
        set { providerKindRawValue = newValue.rawValue }
    }

    var syncStatus: AccountSyncStatus {
        get { AccountSyncStatus(rawValue: lastKnownStatus) ?? .idle }
        set { lastKnownStatus = newValue.rawValue }
    }
}

enum AccountSyncStatus: String, Codable, Sendable {
    case idle
    case refreshing
    case healthy
    case degraded
    case unauthorized
    case disabled
    case failed
}
