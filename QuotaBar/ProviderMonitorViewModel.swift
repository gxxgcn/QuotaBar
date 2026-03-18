import AppKit
import Combine
import Foundation
import SwiftData

@MainActor
final class ProviderMonitorViewModel: ObservableObject {
    private static let backgroundRefreshInterval: Duration = .seconds(30 * 60)

    private let service: CodexAccountService
    private let sessionBackupService: CodexSessionBackupService

    @Published private(set) var accounts: [ProviderAccountRecord] = []
    @Published var snapshotsByAccountID: [UUID: CodexUsageSnapshot] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var backgroundRefreshStarted = false
    @Published private(set) var activeLoginURL: URL?
    @Published private(set) var addAccountErrorMessage: String?
    @Published private(set) var sessionExportDirectoryURL: URL?
    @Published private(set) var backupStatusMessage: String?
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
    private var loginContext: CodexAccountService.LoginStartContext?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var loginURLPollingTask: Task<Void, Never>?

    init(service: CodexAccountService, sessionBackupService: CodexSessionBackupService) {
        self.service = service
        self.sessionBackupService = sessionBackupService
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

    func setSessionExportDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        sessionBackupService.exportDirectoryURL = standardized
        sessionExportDirectoryURL = standardized
        backupErrorMessage = nil
    }

    func resetBackupTabState() {
        backupStatusMessage = nil
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
            backupErrorMessage = "Set an export directory before exporting."
            return
        }
        guard !selectedExportThreadIDs.isEmpty else {
            backupErrorMessage = "Choose at least one thread before exporting."
            return
        }
        guard !isExportingSession else { return }
        backupErrorMessage = nil
        backupStatusMessage = nil
        isExportingSession = true
        defer { isExportingSession = false }

        do {
            let archive = try sessionBackupService.exportBackup(
                threadIDs: Array(selectedExportThreadIDs),
                to: directoryURL
            )
            backupStatusMessage = "Exported \(archive.threadCount) thread(s) across \(archive.projectCount) project(s) to `\(archive.archiveURL.path)` (\(ByteCountFormatter.string(fromByteCount: Int64(archive.fileSizeBytes), countStyle: .file)))."
        } catch {
            backupErrorMessage = error.localizedDescription
        }
    }

    func prepareImportBackup(from archiveURL: URL) {
        backupErrorMessage = nil
        backupStatusMessage = nil
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
            backupErrorMessage = "Choose a backup file before importing."
            return
        }
        guard !isImportingSession else { return }
        guard canImportPreparedBackup else {
            backupErrorMessage = "Choose a destination workspace for each project before importing."
            return
        }
        backupErrorMessage = nil
        backupStatusMessage = nil
        isImportingSession = true
        defer { isImportingSession = false }

        do {
            let archive = try sessionBackupService.importBackupArchive(
                preview: importPreview,
                workspaceOverrides: importWorkspaceOverrides
            )
            backupStatusMessage = "Imported \(archive.threadCount) thread(s) from `\(archive.archiveURL.path)`."
            discardImportPreview()
        } catch {
            backupErrorMessage = error.localizedDescription
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
            reloadAccounts()
            await refreshAll(reason: "auth-import")
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
