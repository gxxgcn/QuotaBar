import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case backup = "Backup"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .accounts:
                return "person.2"
            case .backup:
                return "externaldrive.badge.icloud"
            }
        }

        var title: String { rawValue }
    }

    @ObservedObject var viewModel: ProviderMonitorViewModel
    @State private var selectedTab: SettingsTab = .accounts
    @State private var isPresentingLoginSheet = false
    @State private var isPresentingExportSheet = false
    @State private var isPresentingImportSheet = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("QuotaBar")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text("Manage Codex accounts and move single-session backups between devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    statsPanel

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sections")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(SettingsTab.allCases) { tab in
                                sidebarTabButton(tab)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(24)
                .frame(width: 250)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(.clear)

                Divider()

                ScrollView {
                    currentTabView
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("QuotaBar Settings")
        }
        .frame(minWidth: 840, minHeight: 560)
        .sheet(isPresented: $isPresentingLoginSheet) {
            LoginGuideSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isPresentingExportSheet) {
            BackupExportSheet(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { isPresentingImportSheet && viewModel.importPreview != nil },
                set: { newValue in
                    if !newValue {
                        isPresentingImportSheet = false
                        viewModel.discardImportPreview()
                    }
                }
            )
        ) {
            if let preview = viewModel.importPreview {
                BackupImportSheet(viewModel: viewModel, preview: preview)
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            guard newTab == .backup else { return }
            isPresentingExportSheet = false
            isPresentingImportSheet = false
            viewModel.resetBackupTabState()
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statRow(title: "Accounts", value: "\(viewModel.summary.accountCount)")
            statRow(title: "Healthy", value: "\(max(viewModel.summary.accountCount - viewModel.summary.unhealthyCount, 0))")
            statRow(title: "Alerts", value: "\(viewModel.summary.unhealthyCount)")
        }
        .padding(16)
        .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.08))
        }
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    @ViewBuilder
    private var currentTabView: some View {
        switch selectedTab {
        case .accounts:
            accountsTab
        case .backup:
            backupTab
        }
    }

    private func sidebarTabButton(_ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(
                title: "Account Management",
                subtitle: "Use the login guide to add accounts, then review and manage them here."
            )

            loginEntryPanel

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Accounts")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(viewModel.accounts.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.accounts.isEmpty {
                    emptyAccountsState
                } else {
                    LazyVGrid(columns: accountColumns, alignment: .leading, spacing: 16) {
                        ForEach(viewModel.accounts) { account in
                            accountCard(account)
                        }
                    }
                }
            }
        }
    }

    private var accountColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 280), spacing: 16, alignment: .top),
            GridItem(.flexible(minimum: 280), spacing: 16, alignment: .top),
        ]
    }

    private var loginEntryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Or Import Account")
                        .font(.headline)
                    Text("Open the login guide to start an isolated browser login, copy the login link manually if needed, or import an existing `auth.json`.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isPresentingLoginSheet = true
                } label: {
                    Label("Open Login Guide", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = viewModel.addAccountErrorMessage, !viewModel.loginHasStarted {
                inlineError(error)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
    }

    private var emptyAccountsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts added yet")
                .font(.headline)
            Text("Start a browser login or import an isolated `auth.json` file.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var backupTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(
                title: "Backup Settings",
                subtitle: "Export selected threads into a compressed backup archive, then map each imported project onto a local workspace."
            )

            VStack(alignment: .leading, spacing: 14) {
                backupDirectoryRow(
                    title: "Export Folder",
                    description: "QuotaBar writes compressed backup archives into this folder.",
                    selectedURL: viewModel.sessionExportDirectoryURL,
                    chooseTitle: "Choose Export Folder"
                ) {
                    if let url = selectDirectoryURL(message: "Choose a folder for exported Codex session bundles") {
                        viewModel.setSessionExportDirectory(url)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Export")
                        .font(.headline)
                    Text("Pick one or more threads grouped by workspace, then export them into a single compressed backup file.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.prepareExportSelection()
                        if !viewModel.exportableWorkspaces.isEmpty {
                            isPresentingExportSheet = true
                        }
                    } label: {
                        Label("Select Threads To Export", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Import")
                        .font(.headline)
                    Text("Choose a backup archive, review the projects inside it, then assign a destination workspace for each project before importing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        if let archiveURL = selectBackupArchiveURL() {
                            viewModel.prepareImportBackup(from: archiveURL)
                            if viewModel.importPreview != nil {
                                isPresentingImportSheet = true
                            }
                        }
                    } label: {
                        Label("Choose Backup File", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                if let error = viewModel.backupErrorMessage {
                    inlineError(error)
                }
            }
            .padding(18)
            .background(.thinMaterial, in: .rect(cornerRadius: 18))
        }
    }

    private func backupDirectoryRow(
        title: String,
        description: String,
        selectedURL: URL?,
        chooseTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(chooseTitle, action: action)
                    .buttonStyle(.bordered)
            }

            Text(selectedURL?.path ?? "Not set")
                .font(.footnote.monospaced())
                .foregroundStyle(selectedURL == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
            .textSelection(.enabled)
    }

    private func accountCard(_ account: ProviderAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "Display Name",
                        text: Binding(
                            get: { account.displayName },
                            set: { viewModel.renameAccount(account, to: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)

                    Text(account.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if viewModel.isLocalCodexAccount(account) {
                        SettingsLocalBadge()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 10) {
                    compactStatusBadge(for: account.syncStatus)

                    HStack(spacing: 8) {
                        Text("Enabled")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { account.isEnabled },
                                set: { viewModel.setAccountEnabled(account, isEnabled: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .fixedSize()
            }

            HStack(spacing: 10) {
                detailPill(title: "Plan", value: account.planType.capitalized)
                detailPill(title: "Synced", value: syncText(account.lastSyncedAt))
                Spacer(minLength: 0)

                Button {
                    Task { await viewModel.switchLocalCodexAccount(to: account) }
                } label: {
                    if viewModel.isSwitchingLocalCodexAccount(account) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(viewModel.isLocalCodexAccount(account) ? "Using Locally" : "Switch To Local Codex")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLocalCodexAccount(account) || viewModel.isSwitchingLocalCodexAccount(account))

                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteAccount(account) }
                }
                .buttonStyle(.borderless)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
    }

    private func detailPill(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
        .fixedSize()
    }

    private func compactStatusBadge(for status: AccountSyncStatus) -> some View {
        Text(statusText(for: status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(for: status))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor(for: status).opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private func statusText(for status: AccountSyncStatus) -> String {
        switch status {
        case .healthy:
            return "Healthy"
        case .unauthorized:
            return "Auth"
        case .failed, .degraded:
            return "Error"
        case .disabled:
            return "Disabled"
        case .refreshing:
            return "Refreshing"
        case .idle:
            return "Idle"
        }
    }

    private func statusColor(for status: AccountSyncStatus) -> Color {
        switch status {
        case .healthy:
            return .green
        case .unauthorized:
            return .orange
        case .failed, .degraded:
            return .red
        case .disabled, .idle:
            return .secondary
        case .refreshing:
            return .blue
        }
    }

    private func syncText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func selectDirectoryURL(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func selectAuthFileURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a Codex auth.json file"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func selectBackupArchiveURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a QuotaBar backup archive"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct SettingsLocalBadge: View {
    var body: some View {
        Text("Local Codex")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.12), in: Capsule())
    }
}

private struct LoginGuideSheet: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Login Guide")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text("Start an isolated Codex login here. If the browser does not open automatically, copy the login link and open it manually, or import an existing `auth.json`.")
                .foregroundStyle(.secondary)

            SettingsViewLoginPanel(viewModel: viewModel)

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640)
    }
}

private struct SettingsViewLoginPanel: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browser Login")
                    .font(.headline)

                Text("Start an isolated `codex login` for a new account, or import an existing isolated `auth.json` file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.beginCodexLogin() }
                    } label: {
                        Label(viewModel.loginHasStarted ? "Restart Login" : "Start Login", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isStartingLogin || viewModel.isFinishingLogin)

                    if viewModel.activeLoginURL != nil {
                        Button("Open Again") {
                            viewModel.reopenLoginURL()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        Task {
                            if let url = selectAuthFileURL() {
                                _ = await viewModel.importAuthFile(from: url)
                            }
                        }
                    } label: {
                        Label("Import auth.json", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                if let url = viewModel.activeLoginURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Login Link")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Text(url.absoluteString)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
                    }
                } else if viewModel.loginHasStarted {
                    Text("Waiting for the Codex CLI to print the login link. If it does not appear, import an `auth.json` from a terminal login instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { _ = await viewModel.finishCodexLogin() }
                } label: {
                    if viewModel.isFinishingLogin {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("I've Finished Login")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.loginHasStarted || viewModel.isFinishingLogin)
            }

            if let error = viewModel.addAccountErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
    }

    private func selectAuthFileURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a Codex auth.json file"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct BackupExportSheet: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Backup")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text("Choose which workspace threads to include in this backup archive. You can mix threads from multiple projects.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(viewModel.exportableWorkspaces) { workspace in
                        workspaceSection(workspace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280)

            if let error = viewModel.backupErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
                    .textSelection(.enabled)
            }

            HStack {
                Text("\(viewModel.selectedExportThreadIDs.count) thread(s) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        await viewModel.exportSelectedThreads()
                        if viewModel.backupErrorMessage == nil {
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isExportingSession {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Export Backup")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedExportThreadIDs.isEmpty || viewModel.isExportingSession)
            }
        }
        .padding(22)
        .frame(width: 760, height: 640)
        .onAppear {
            viewModel.prepareExportSelection()
        }
    }

    private func workspaceSection(_ workspace: CodexBackupWorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.selectedThreadCount(for: workspace.id) == workspace.threads.count && !workspace.threads.isEmpty },
                        set: { viewModel.setWorkspaceSelection($0, workspaceID: workspace.id) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.workspaceName)
                        .font(.headline)
                    Text(workspace.workspacePath)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("\(viewModel.selectedThreadCount(for: workspace.id))/\(workspace.threads.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(workspace.threads) { thread in
                Toggle(
                    isOn: Binding(
                        get: { viewModel.selectedExportThreadIDs.contains(thread.id) },
                        set: { _ in viewModel.toggleExportSelection(for: thread.id) }
                    )
                ) {
                    Text(thread.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 28)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }
}

private struct BackupImportSheet: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel
    let preview: CodexBackupArchivePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Backup")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text("Assign a destination workspace for each imported project before restoring its threads into your local Codex data.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(preview.archiveURL.path)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("\(preview.threadCount) thread(s) across \(preview.projects.count) project(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(preview.projects) { project in
                        importProjectSection(project)
                    }
                }
            }
            .frame(minHeight: 280)

            if let error = viewModel.backupErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        await viewModel.importPreparedBackup()
                        if viewModel.importPreview == nil {
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isImportingSession {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Import Backup")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canImportPreparedBackup || viewModel.isImportingSession)
            }
        }
        .padding(22)
        .frame(width: 760, height: 640)
    }

    private func importProjectSection(_ project: CodexBackupProjectPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project.workspaceName)
                .font(.headline)
            Text(project.sourceWorkspacePath)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let gitOrigin = project.suggestedGitOriginURL {
                Text(gitOrigin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Text(viewModel.importWorkspaceOverrides[project.sourceWorkspacePath]?.path ?? "Workspace not selected")
                    .font(.footnote.monospaced())
                    .foregroundStyle(viewModel.importWorkspaceOverrides[project.sourceWorkspacePath] == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose Workspace") {
                    if let url = selectDirectoryURL(message: "Choose the destination workspace for \(project.workspaceName)") {
                        viewModel.setImportWorkspace(url, for: project.sourceWorkspacePath)
                    }
                }
                .buttonStyle(.bordered)

                if viewModel.importWorkspaceOverrides[project.sourceWorkspacePath] != nil {
                    Button("Clear") {
                        viewModel.clearImportWorkspace(for: project.sourceWorkspacePath)
                    }
                    .buttonStyle(.bordered)
                }
            }

            ForEach(project.threads) { thread in
                Text(thread.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private func selectDirectoryURL(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
