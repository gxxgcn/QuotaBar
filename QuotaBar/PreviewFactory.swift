import Foundation
import SwiftData

enum PreviewFactory {
    @MainActor
    static func makeViewModel() -> ProviderMonitorViewModel {
        let schema = Schema([
            ProviderAccountRecord.self,
        ])
        let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let service = CodexAccountService(
            modelContext: container.mainContext,
            credentialStore: PreviewCredentialStore()
        )
        let viewModel = ProviderMonitorViewModel(
            service: service,
            sessionBackupService: CodexSessionBackupService()
        )

        if (try? service.fetchAccounts().isEmpty) == true {
            let account = ProviderAccountRecord(
                providerKind: .codex,
                displayName: "aidan93",
                email: "aidan93.cn@gmail.com",
                remoteAccountID: "preview-account",
                planType: "plus"
            )
            container.mainContext.insert(account)
            try? container.mainContext.save()
            viewModel.reloadAccounts()
            viewModel.snapshotsByAccountID[account.id] = CodexUsageSnapshot(
                accountID: account.id,
                email: account.email,
                planType: account.planType,
                rateLimitsByLimitID: [
                    "codex": RateLimitSnapshotData(
                        limitID: "codex",
                        limitName: "Codex",
                        planType: "plus",
                        primary: RateLimitWindowSnapshot(
                            usedPercent: 42,
                            resetsAt: .now.addingTimeInterval(3_600),
                            windowDurationMins: 300
                        ),
                        secondary: RateLimitWindowSnapshot(
                            usedPercent: 18,
                            resetsAt: .now.addingTimeInterval(86_400),
                            windowDurationMins: 10_080
                        )
                    )
                ],
                primaryLimit: nil,
                secondaryLimit: nil,
                lastError: nil,
                fetchedAt: .now
            )
        }

        return viewModel
    }
}

private struct PreviewCredentialStore: CredentialStore {
    func save(authData: Data, for accountID: UUID) async throws {}
    func loadAuthData(for accountID: UUID) async throws -> Data { Data() }
    func deleteAuthData(for accountID: UUID) async throws {}
}
