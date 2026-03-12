import AppKit
import Combine
import Foundation
import SwiftData

@MainActor
final class ProviderMonitorViewModel: ObservableObject {
    private static let backgroundRefreshInterval: Duration = .seconds(30 * 60)

    private let service: CodexAccountService

    @Published private(set) var accounts: [ProviderAccountRecord] = []
    @Published var snapshotsByAccountID: [UUID: CodexUsageSnapshot] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var backgroundRefreshStarted = false
    @Published private(set) var isPresentingAddAccountSheet = false
    @Published private(set) var activeLoginURL: URL?
    @Published private(set) var addAccountErrorMessage: String?
    @Published private(set) var isStartingLogin = false
    @Published private(set) var isFinishingLogin = false
    @Published private(set) var loginHasStarted = false
    private var loginContext: CodexAccountService.LoginStartContext?
    private var backgroundRefreshTask: Task<Void, Never>?
    init(service: CodexAccountService) {
        self.service = service
        reloadAccounts()
    }

    deinit {
        backgroundRefreshTask?.cancel()
    }

    var summary: ProviderSummary {
        let enabledAccounts = accounts.filter(\.isEnabled)
        let syncedCount = enabledAccounts.filter { snapshotsByAccountID[$0.id] != nil || $0.lastSyncedAt != nil }.count
        let unhealthyCount = enabledAccounts.filter {
            guard let snapshot = snapshotsByAccountID[$0.id] else {
                return $0.syncStatus == .failed || $0.syncStatus == .unauthorized || $0.syncStatus == .degraded
            }
            return snapshot.lastError != nil
        }.count

        let hottestAccount = enabledAccounts.max {
            (snapshotsByAccountID[$0.id]?.highestUsagePercent ?? 0) < (snapshotsByAccountID[$1.id]?.highestUsagePercent ?? 0)
        }

        return ProviderSummary(
            accountCount: enabledAccounts.count,
            syncedCount: syncedCount,
            unhealthyCount: unhealthyCount,
            hottestAccountName: hottestAccount?.displayName,
            hottestUsagePercent: hottestAccount.flatMap { snapshotsByAccountID[$0.id]?.highestUsagePercent } ?? 0
        )
    }

    var statusBarIconName: String {
        if isRefreshingAll {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        if summary.unhealthyCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return "gauge.with.dots.needle.33percent"
    }

    func bootstrap() async {
        guard !backgroundRefreshStarted else { return }
        backgroundRefreshStarted = true
        await refreshAll(reason: "startup")
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundRefreshInterval)
                await self?.refreshAll(reason: "background")
            }
        }
    }

    func panelDidOpen() {
        reloadAccounts()
    }

    func reloadAccounts() {
        do {
            accounts = try service.fetchAccounts()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func refreshAll(reason: String) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        reloadAccounts()
        let enabledAccounts = accounts.filter(\.isEnabled)

        await withTaskGroup(of: CodexUsageSnapshot?.self) { group in
            for account in enabledAccounts {
                group.addTask { [service] in
                    try? await service.refreshAccount(account)
                }
            }

            for await snapshot in group {
                if let snapshot {
                    snapshotsByAccountID[snapshot.accountID] = snapshot
                }
            }
        }
        reloadAccounts()
    }

    func presentAddAccountSheet() {
        addAccountErrorMessage = nil
        isPresentingAddAccountSheet = true
    }

    func dismissAddAccountSheet() {
        if let loginContext {
            service.cancelLogin(using: loginContext)
        }
        isPresentingAddAccountSheet = false
        activeLoginURL = nil
        addAccountErrorMessage = nil
        isStartingLogin = false
        isFinishingLogin = false
        loginHasStarted = false
        loginContext = nil
    }

    func beginCodexLogin() async {
        guard !isStartingLogin else { return }
        addAccountErrorMessage = nil
        isStartingLogin = true
        defer { isStartingLogin = false }
        do {
            let context = try await service.beginLogin()
            loginContext = context
            activeLoginURL = context.authURL
            loginHasStarted = true
            if let authURL = context.authURL {
                NSWorkspace.shared.open(authURL)
            }
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func finishCodexLogin() async -> Bool {
        guard let loginContext else { return false }
        guard !isFinishingLogin else { return false }
        isFinishingLogin = true
        defer { isFinishingLogin = false }
        do {
            _ = try await service.completeLogin(using: loginContext)
            self.loginContext = nil
            activeLoginURL = nil
            loginHasStarted = false
            isPresentingAddAccountSheet = false
            reloadAccounts()
            await refreshAll(reason: "account-added")
            return true
        } catch {
            addAccountErrorMessage = error.localizedDescription
            if !isPresentingAddAccountSheet {
                self.loginContext = nil
            }
            return false
        }
    }

    func importAuthFile(from url: URL) async -> Bool {
        addAccountErrorMessage = nil
        do {
            let authData = try Data(contentsOf: url)
            _ = try await service.importAccount(from: authData)
            reloadAccounts()
            await refreshAll(reason: "auth-import")
            isPresentingAddAccountSheet = false
            loginHasStarted = false
            activeLoginURL = nil
            return true
        } catch {
            addAccountErrorMessage = error.localizedDescription
            return false
        }
    }

    func reopenLoginURL() {
        guard let activeLoginURL else { return }
        NSWorkspace.shared.open(activeLoginURL)
    }

    func renameAccount(_ account: ProviderAccountRecord, to name: String) {
        do {
            try service.renameAccount(id: account.id, to: name)
            reloadAccounts()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func setAccountEnabled(_ account: ProviderAccountRecord, isEnabled: Bool) {
        do {
            try service.setAccountEnabled(id: account.id, isEnabled: isEnabled)
            reloadAccounts()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func deleteAccount(_ account: ProviderAccountRecord) async {
        do {
            try await service.deleteAccount(id: account.id)
            snapshotsByAccountID.removeValue(forKey: account.id)
            reloadAccounts()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }
}

struct ProviderSummary {
    let accountCount: Int
    let syncedCount: Int
    let unhealthyCount: Int
    let hottestAccountName: String?
    let hottestUsagePercent: Int
}
