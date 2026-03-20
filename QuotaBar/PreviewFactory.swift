import Foundation
import SwiftData

enum PreviewFactory {
  enum Scenario {
    case empty
    case mixed
    case loginInProgress
  }

  @MainActor
  static func makeViewModel(scenario: Scenario = .mixed) -> ProviderMonitorViewModel {
    let schema = Schema([
      ProviderAccountRecord.self
    ])
    let container = try! ModelContainer(
      for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let service = CodexAccountService(
      modelContext: container.mainContext,
      credentialStore: PreviewCredentialStore()
    )
    let viewModel = ProviderMonitorViewModel(
      service: service,
      sessionBackupService: CodexSessionBackupService()
    )

    switch scenario {
    case .empty, .loginInProgress:
      break
    case .mixed:
      let accounts = makeSampleAccounts()
      for account in accounts {
        container.mainContext.insert(account)
      }
      try? container.mainContext.save()
      viewModel.reloadAccounts()

      for account in accounts {
        if let snapshot = makeSnapshot(for: account) {
          viewModel.snapshotsByAccountID[account.id] = snapshot
        }
      }
    }

    return viewModel
  }

  static func makeSampleAccounts() -> [ProviderAccountRecord] {
    [
      ProviderAccountRecord(
        providerKind: .codex,
        displayName: "aidan-main",
        email: "aidan93.cn@gmail.com",
        remoteAccountID: "preview-local",
        planType: "plus",
        lastSyncedAt: .now.addingTimeInterval(-420),
        lastKnownStatus: AccountSyncStatus.healthy.rawValue,
        sortOrder: 0,
        subscriptionExpiresAt: Calendar.current.date(
          from: DateComponents(year: 2026, month: 3, day: 23))
      ),
      ProviderAccountRecord(
        providerKind: .codex,
        displayName: "team-alpha",
        email: "team-alpha@example.com",
        remoteAccountID: "preview-team-alpha",
        planType: "team",
        lastSyncedAt: .now.addingTimeInterval(-900),
        lastKnownStatus: AccountSyncStatus.healthy.rawValue,
        sortOrder: 1,
        subscriptionExpiresAt: Calendar.current.date(
          from: DateComponents(year: 2026, month: 4, day: 15))
      ),
      ProviderAccountRecord(
        providerKind: .codex,
        displayName: "ops-prod",
        email: "ops-prod@example.com",
        remoteAccountID: "preview-ops-prod",
        planType: "pro",
        lastSyncedAt: .now.addingTimeInterval(-150),
        lastKnownStatus: AccountSyncStatus.refreshing.rawValue,
        sortOrder: 2,
        subscriptionExpiresAt: Calendar.current.date(
          from: DateComponents(year: 2026, month: 5, day: 10))
      ),
      ProviderAccountRecord(
        providerKind: .codex,
        displayName: "design-lab",
        email: "design-lab@example.com",
        remoteAccountID: "preview-design-lab",
        planType: "plus",
        lastKnownStatus: AccountSyncStatus.unauthorized.rawValue,
        sortOrder: 3,
        subscriptionExpiresAt: nil
      ),
      ProviderAccountRecord(
        providerKind: .codex,
        displayName: "frontend-dev",
        email: "frontend-dev@example.com",
        remoteAccountID: "preview-frontend-dev",
        planType: "enterprise",
        lastSyncedAt: .now.addingTimeInterval(-1_800),
        lastKnownStatus: AccountSyncStatus.failed.rawValue,
        sortOrder: 4,
        subscriptionExpiresAt: Calendar.current.date(
          from: DateComponents(year: 2026, month: 6, day: 30))
      ),
    ]
  }

  static func makeSnapshot(for account: ProviderAccountRecord) -> CodexUsageSnapshot? {
    switch account.displayName {
    case "aidan-main":
      return snapshot(
        account: account,
        primaryUsedPercent: 42,
        secondaryUsedPercent: 18,
        primaryReset: .now.addingTimeInterval(3_600),
        secondaryReset: .now.addingTimeInterval(86_400)
      )
    case "team-alpha":
      return snapshot(
        account: account,
        primaryUsedPercent: 26,
        secondaryUsedPercent: 33,
        primaryReset: .now.addingTimeInterval(5_400),
        secondaryReset: .now.addingTimeInterval(172_800)
      )
    case "ops-prod":
      return snapshot(
        account: account,
        primaryUsedPercent: 67,
        secondaryUsedPercent: 39,
        primaryReset: .now.addingTimeInterval(7_200),
        secondaryReset: .now.addingTimeInterval(259_200)
      )
    case "design-lab":
      return snapshot(
        account: account,
        primaryUsedPercent: 79,
        secondaryUsedPercent: 51,
        primaryReset: .now.addingTimeInterval(10_800),
        secondaryReset: .now.addingTimeInterval(259_200),
        lastError: "Session expired. Use Quick Login to re-authenticate."
      )
    case "frontend-dev":
      return snapshot(
        account: account,
        primaryUsedPercent: 85,
        secondaryUsedPercent: 62,
        primaryReset: .now.addingTimeInterval(14_400),
        secondaryReset: .now.addingTimeInterval(345_600),
        lastError: "Usage data is stale. Partial data from last refresh."
      )
    default:
      return nil
    }
  }

  private static func snapshot(
    account: ProviderAccountRecord,
    primaryUsedPercent: Int,
    secondaryUsedPercent: Int,
    primaryReset: Date,
    secondaryReset: Date,
    lastError: String? = nil
  ) -> CodexUsageSnapshot {
    CodexUsageSnapshot(
      accountID: account.id,
      email: account.email,
      planType: account.planType,
      rateLimitsByLimitID: [
        "codex": RateLimitSnapshotData(
          limitID: "codex",
          limitName: "Codex",
          planType: account.planType,
          primary: RateLimitWindowSnapshot(
            usedPercent: primaryUsedPercent,
            resetsAt: primaryReset,
            windowDurationMins: 300
          ),
          secondary: RateLimitWindowSnapshot(
            usedPercent: secondaryUsedPercent,
            resetsAt: secondaryReset,
            windowDurationMins: 10_080
          )
        )
      ],
      primaryLimit: nil,
      secondaryLimit: nil,
      lastError: lastError,
      fetchedAt: .now
    )
  }
}

private struct PreviewCredentialStore: CredentialStore {
  func save(authData: Data, for accountID: UUID) async throws {}
  func loadAuthData(for accountID: UUID) async throws -> Data { Data() }
  func deleteAuthData(for accountID: UUID) async throws {}
}
