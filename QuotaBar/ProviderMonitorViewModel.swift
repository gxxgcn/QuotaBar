import AppKit
import Combine
import Foundation
import SwiftData

@MainActor
final class ProviderMonitorViewModel: ObservableObject, ContentViewDataSource {
    private static let backgroundRefreshInterval: Duration = .seconds(30 * 60)
    private enum DefaultsKey {
        static let suppressRestartReminder = "localCodex.suppressRestartReminder"
    }
    #if DEBUG
    private static let authShowcaseAccountID = UUID(uuidString: "F0D95444-1D6E-4A39-9A0B-2D6D5F0F0A11")!
    #endif

    private let service: CodexAccountService
    private let sessionBackupService: CodexSessionBackupService
    private let userDefaults: UserDefaults

    @Published private(set) var accounts: [ProviderAccountRecord] = []
    @Published var snapshotsByAccountID: [UUID: CodexUsageSnapshot] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var backgroundRefreshStarted = false
    @Published private(set) var activeLoginURL: URL?
    @Published private(set) var addAccountErrorMessage: String?
    @Published private(set) var sessionExportDirectoryURL: URL?
    @Published private(set) var backupErrorMessage: String?
    @Published private(set) var isExportingSession = false
    @Published private(set) var isImportingSession = false
    @Published private(set) var exportableWorkspaces: [CodexBackupWorkspaceGroup] = []
    @Published var selectedExportThreadIDs: Set<String> = []
    @Published private(set) var selectedImportArchiveURL: URL?
    @Published private(set) var importPreview: CodexBackupArchivePreview?
    @Published private(set) var importWorkspaceOverrides: [String: URL] = [:]
    @Published private(set) var isStartingLogin = false
    @Published private(set) var isFinishingLogin = false
    @Published private(set) var loginHasStarted = false
    @Published private(set) var localCodexAccountID: UUID?
    @Published private(set) var localCodexHasAuthFile = false
    @Published private(set) var localCodexAuthFileURL: URL?
    @Published private(set) var localCodexErrorMessage: String?
    @Published private(set) var switchingLocalAccountID: UUID?
    private var loginContext: CodexAccountService.LoginStartContext?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var loginURLPollingTask: Task<Void, Never>?

    init(
        service: CodexAccountService,
        sessionBackupService: CodexSessionBackupService,
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.sessionBackupService = sessionBackupService
        self.userDefaults = userDefaults
        self.sessionExportDirectoryURL = sessionBackupService.exportDirectoryURL
        reloadAccounts()
    }

    deinit {
        backgroundRefreshTask?.cancel()
        loginURLPollingTask?.cancel()
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

    var latestRefreshDate: Date? {
        let accountDates = accounts.compactMap(\.lastSyncedAt)
        let snapshotDates = snapshotsByAccountID.values.map(\.fetchedAt)
        return (accountDates + snapshotDates).max()
    }

    func bootstrap() async {
        guard !backgroundRefreshStarted else { return }
        backgroundRefreshStarted = true
        await refreshAll(reason: "startup")
        await refreshLocalCodexAccount()
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundRefreshInterval)
                await self?.refreshAll(reason: "background")
            }
        }
    }

    func panelDidOpen() {
        reloadAccounts()
        Task { await refreshLocalCodexAccount() }
    }

    func reloadAccounts() {
        do {
            let fetchedAccounts = try service.fetchAccounts()
            accounts = presentingAccounts(from: fetchedAccounts)
            synchronizeShowcaseSnapshot()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func refreshLocalCodexAccount() async {
        do {
            let status = try await service.localCodexAccountStatus()
            localCodexAccountID = status.matchedAccountID
            localCodexHasAuthFile = status.hasAuthFile
            localCodexAuthFileURL = status.authFileURL
            localCodexErrorMessage = nil
        } catch {
            localCodexAccountID = nil
            localCodexHasAuthFile = false
            localCodexAuthFileURL = nil
            localCodexErrorMessage = error.localizedDescription
        }
    }

    func refreshAll(reason: String) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        reloadAccounts()
        let enabledAccounts = accounts.filter(\.isEnabled).filter { !isDebugShowcaseAccount($0) }

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

    func setSessionExportDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        sessionBackupService.exportDirectoryURL = standardized
        sessionExportDirectoryURL = standardized
        backupErrorMessage = nil
    }

    func resetBackupTabState() {
        backupErrorMessage = nil
        exportableWorkspaces = []
        selectedExportThreadIDs = []
        selectedImportArchiveURL = nil
        importWorkspaceOverrides = [:]
        sessionBackupService.cleanupImportPreview(importPreview)
        importPreview = nil
    }

    func prepareExportSelection() {
        do {
            exportableWorkspaces = try sessionBackupService.listExportableWorkspaces()
            selectedExportThreadIDs = []
            backupErrorMessage = nil
        } catch {
            exportableWorkspaces = []
            selectedExportThreadIDs = []
            backupErrorMessage = error.localizedDescription
        }
    }

    func toggleExportSelection(for threadID: String) {
        if selectedExportThreadIDs.contains(threadID) {
            selectedExportThreadIDs.remove(threadID)
        } else {
            selectedExportThreadIDs.insert(threadID)
        }
    }

    func setWorkspaceSelection(_ isSelected: Bool, workspaceID: String) {
        guard let workspace = exportableWorkspaces.first(where: { $0.id == workspaceID }) else { return }
        let threadIDs = workspace.threads.map(\.id)
        if isSelected {
            selectedExportThreadIDs.formUnion(threadIDs)
        } else {
            selectedExportThreadIDs.subtract(threadIDs)
        }
    }

    func selectedThreadCount(for workspaceID: String) -> Int {
        guard let workspace = exportableWorkspaces.first(where: { $0.id == workspaceID }) else { return 0 }
        return workspace.threads.reduce(into: 0) { count, thread in
            if selectedExportThreadIDs.contains(thread.id) {
                count += 1
            }
        }
    }

    func exportSelectedThreads() async {
        guard let directoryURL = sessionExportDirectoryURL else {
            backupErrorMessage = "Choose an export folder first."
            return
        }
        guard !selectedExportThreadIDs.isEmpty else {
            backupErrorMessage = "Choose at least one thread."
            return
        }
        guard !isExportingSession else { return }
        backupErrorMessage = nil
        isExportingSession = true
        defer { isExportingSession = false }

        do {
            let archive = try sessionBackupService.exportBackup(
                threadIDs: Array(selectedExportThreadIDs),
                to: directoryURL
            )
            await presentSystemAlert(LocalCodexAlert(
                title: "Export Complete",
                message: archive.threadCount == 1 ? "1 thread exported." : "\(archive.threadCount) threads exported."
            ))
        } catch {
            backupErrorMessage = error.localizedDescription
            await presentSystemAlert(exportFailureAlert())
        }
    }

    func prepareImportBackup(from archiveURL: URL) {
        backupErrorMessage = nil
        sessionBackupService.cleanupImportPreview(importPreview)
        do {
            let preview = try sessionBackupService.inspectBackupArchive(at: archiveURL)
            selectedImportArchiveURL = archiveURL
            importPreview = preview
            importWorkspaceOverrides = Dictionary(uniqueKeysWithValues: preview.projects.compactMap { project in
                let url = URL(fileURLWithPath: project.sourceWorkspacePath, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    return (project.sourceWorkspacePath, url)
                }
                return nil
            })
        } catch {
            selectedImportArchiveURL = nil
            importPreview = nil
            importWorkspaceOverrides = [:]
            backupErrorMessage = error.localizedDescription
        }
    }

    func setImportWorkspace(_ url: URL, for sourceWorkspacePath: String) {
        importWorkspaceOverrides[sourceWorkspacePath] = url.standardizedFileURL
        backupErrorMessage = nil
    }

    func clearImportWorkspace(for sourceWorkspacePath: String) {
        importWorkspaceOverrides.removeValue(forKey: sourceWorkspacePath)
        backupErrorMessage = nil
    }

    func discardImportPreview() {
        sessionBackupService.cleanupImportPreview(importPreview)
        importPreview = nil
        selectedImportArchiveURL = nil
        importWorkspaceOverrides = [:]
    }

    var canImportPreparedBackup: Bool {
        guard let importPreview else { return false }
        return importPreview.projects.allSatisfy { importWorkspaceOverrides[$0.sourceWorkspacePath] != nil }
    }

    func importPreparedBackup() async {
        guard let importPreview else {
            backupErrorMessage = "Choose a backup file first."
            return
        }
        guard !isImportingSession else { return }
        guard canImportPreparedBackup else {
            backupErrorMessage = "Choose a destination workspace for each project."
            return
        }
        backupErrorMessage = nil
        isImportingSession = true
        defer { isImportingSession = false }

        do {
            let archive = try sessionBackupService.importBackupArchive(
                preview: importPreview,
                workspaceOverrides: importWorkspaceOverrides
            )
            discardImportPreview()
            await presentSystemAlert(LocalCodexAlert(
                title: "Import Complete",
                message: archive.threadCount == 1 ? "1 thread imported." : "\(archive.threadCount) threads imported."
            ))
        } catch {
            backupErrorMessage = error.localizedDescription
            await presentSystemAlert(importFailureAlert())
        }
    }

    private func resetLoginFlow(cancelProcess: Bool) {
        loginURLPollingTask?.cancel()
        if cancelProcess, let loginContext {
            service.cancelLogin(using: loginContext)
        }
        activeLoginURL = nil
        addAccountErrorMessage = nil
        isStartingLogin = false
        isFinishingLogin = false
        loginHasStarted = false
        loginContext = nil
    }

    func prepareLoginGuide() {
        resetLoginFlow(cancelProcess: true)
    }

    func cancelCodexLogin() {
        resetLoginFlow(cancelProcess: true)
    }

    func beginCodexLogin() async {
        guard !isStartingLogin else { return }
        if loginContext != nil {
            resetLoginFlow(cancelProcess: true)
        }
        addAccountErrorMessage = nil
        isStartingLogin = true
        defer { isStartingLogin = false }
        do {
            let context = try await service.beginLogin()
            loginContext = context
            activeLoginURL = context.authURL
            loginHasStarted = true
            startPollingLoginURL(using: context)
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
            loginURLPollingTask?.cancel()
            self.loginContext = nil
            activeLoginURL = nil
            loginHasStarted = false
            reloadAccounts()
            await refreshAll(reason: "account-added")
            await refreshLocalCodexAccount()
            return true
        } catch {
            addAccountErrorMessage = error.localizedDescription
            return false
        }
    }

    func importAuthFile(from url: URL) async -> Bool {
        addAccountErrorMessage = nil
        do {
            let authData = try Data(contentsOf: url)
            _ = try await service.importAccount(from: authData)
            loginURLPollingTask?.cancel()
            loginContext = nil
            reloadAccounts()
            await refreshAll(reason: "auth-import")
            loginHasStarted = false
            activeLoginURL = nil
            await refreshLocalCodexAccount()
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

    private func startPollingLoginURL(using context: CodexAccountService.LoginStartContext) {
        loginURLPollingTask?.cancel()
        loginURLPollingTask = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if let url = self.service.currentLoginURL(using: context) {
                    if self.activeLoginURL != url {
                        self.activeLoginURL = url
                    }
                    return
                }
                if !context.session.process.isRunning {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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
            await refreshLocalCodexAccount()
        } catch {
            addAccountErrorMessage = error.localizedDescription
        }
    }

    func switchLocalCodexAccount(to account: ProviderAccountRecord) async {
        guard !isDebugShowcaseAccount(account) else { return }
        guard switchingLocalAccountID == nil else { return }
        switchingLocalAccountID = account.id
        localCodexErrorMessage = nil
        defer { switchingLocalAccountID = nil }

        do {
            let result = try await service.switchLocalCodexAccount(to: account)
            await refreshLocalCodexAccount()
            await presentSystemAlert(makeSwitchSuccessAlert(for: account, result: result))
        } catch {
            localCodexErrorMessage = error.localizedDescription
            await presentSystemAlert(switchFailureAlert())
        }
    }

    func isLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool {
        localCodexAccountID == account.id
    }

    func isSwitchingLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool {
        switchingLocalAccountID == account.id
    }

    private func makeSwitchSuccessAlert(
        for account: ProviderAccountRecord,
        result _: LocalCodexSwitchResult
    ) -> LocalCodexAlert {
        return LocalCodexAlert(
            title: "Account Updated",
            message: "Now using \(account.displayName). Restart Codex if it is open.",
            suppressionPreferenceKey: DefaultsKey.suppressRestartReminder,
            suppressionButtonTitle: "Don't remind me again"
        )
    }

    private func switchFailureAlert() -> LocalCodexAlert {
        LocalCodexAlert(
            title: "Switch Failed",
            message: "We couldn't switch the local Codex account."
        )
    }

    private func exportFailureAlert() -> LocalCodexAlert {
        LocalCodexAlert(
            title: "Export Failed",
            message: "We couldn't export the selected threads."
        )
    }

    private func importFailureAlert() -> LocalCodexAlert {
        LocalCodexAlert(
            title: "Import Failed",
            message: "We couldn't import this backup."
        )
    }

    private func presentSystemAlert(_ alert: LocalCodexAlert) async {
        if let preferenceKey = alert.suppressionPreferenceKey,
           userDefaults.bool(forKey: preferenceKey) {
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let nsAlert = NSAlert()
        nsAlert.alertStyle = .informational
        nsAlert.messageText = alert.title
        nsAlert.informativeText = alert.message
        if let preferenceKey = alert.suppressionPreferenceKey {
            nsAlert.showsSuppressionButton = true
            nsAlert.suppressionButton?.title = alert.suppressionButtonTitle ?? "Don't show this again"
            nsAlert.suppressionButton?.state = userDefaults.bool(forKey: preferenceKey) ? .on : .off
        }
        nsAlert.addButton(withTitle: "OK")
        _ = nsAlert.runModal()

        if let preferenceKey = alert.suppressionPreferenceKey {
            let shouldSuppress = nsAlert.suppressionButton?.state == .on
            userDefaults.set(shouldSuppress, forKey: preferenceKey)
        }
    }

    private func presentingAccounts(from fetchedAccounts: [ProviderAccountRecord]) -> [ProviderAccountRecord] {
        #if DEBUG
        if fetchedAccounts.contains(where: { $0.syncStatus == .unauthorized }) {
            return fetchedAccounts
        }
        return fetchedAccounts + [makeDebugAuthShowcaseAccount(sortOrder: fetchedAccounts.count)]
        #else
        return fetchedAccounts
        #endif
    }

    private func synchronizeShowcaseSnapshot() {
        #if DEBUG
        if let showcaseAccount = accounts.first(where: isDebugShowcaseAccount) {
            snapshotsByAccountID[showcaseAccount.id] = makeDebugAuthShowcaseSnapshot(for: showcaseAccount)
        } else {
            snapshotsByAccountID.removeValue(forKey: Self.authShowcaseAccountID)
        }
        #endif
    }

    private func isDebugShowcaseAccount(_ account: ProviderAccountRecord) -> Bool {
        #if DEBUG
        account.id == Self.authShowcaseAccountID
        #else
        false
        #endif
    }

    #if DEBUG
    private func makeDebugAuthShowcaseAccount(sortOrder: Int) -> ProviderAccountRecord {
        ProviderAccountRecord(
            id: Self.authShowcaseAccountID,
            providerKind: .codex,
            displayName: "auth-required",
            email: "auth-required@example.com",
            remoteAccountID: "debug-auth-required",
            planType: "plus",
            isEnabled: true,
            createdAt: .now,
            lastSyncedAt: nil,
            lastKnownStatus: AccountSyncStatus.unauthorized.rawValue,
            sortOrder: sortOrder,
            subscriptionExpiresAt: nil
        )
    }

    private func makeDebugAuthShowcaseSnapshot(for account: ProviderAccountRecord) -> CodexUsageSnapshot {
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
                        usedPercent: 72,
                        resetsAt: .now.addingTimeInterval(4_200),
                        windowDurationMins: 300
                    ),
                    secondary: RateLimitWindowSnapshot(
                        usedPercent: 41,
                        resetsAt: .now.addingTimeInterval(172_800),
                        windowDurationMins: 10_080
                    )
                )
            ],
            primaryLimit: nil,
            secondaryLimit: nil,
            lastError: "Authentication required. Use Quick Login to reconnect this account.",
            fetchedAt: .now
        )
    }
    #endif

}

struct LocalCodexAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suppressionPreferenceKey: String?
    let suppressionButtonTitle: String?

    init(
        title: String,
        message: String,
        suppressionPreferenceKey: String? = nil,
        suppressionButtonTitle: String? = nil
    ) {
        self.title = title
        self.message = message
        self.suppressionPreferenceKey = suppressionPreferenceKey
        self.suppressionButtonTitle = suppressionButtonTitle
    }
}

struct ProviderSummary {
    let accountCount: Int
    let syncedCount: Int
    let unhealthyCount: Int
    let hottestAccountName: String?
    let hottestUsagePercent: Int
}
