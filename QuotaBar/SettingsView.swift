import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("QuotaBar")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text("Manage Codex accounts without touching your default `~/.codex`.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    statsPanel

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Provider")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Image(systemName: "terminal.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Codex")
                                    .font(.headline)
                                Text("Isolated token monitoring")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        viewModel.presentAddAccountSheet()
                    } label: {
                        Label("Add Codex Account", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
                .padding(24)
                .frame(width: 250)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(
                    LinearGradient(
                        colors: [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Codex Accounts")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Text("\(viewModel.accounts.count) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.accounts.isEmpty {
                            emptyAccountsState
                        } else {
                            ForEach(viewModel.accounts) { account in
                                accountCard(account)
                            }
                        }

                        if let error = viewModel.addAccountErrorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("QuotaBar Settings")
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(
            isPresented: Binding(
                get: { viewModel.isPresentingAddAccountSheet },
                set: { _ in viewModel.dismissAddAccountSheet() }
            )
        ) {
            AddCodexAccountSheet(viewModel: viewModel)
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statRow(title: "Accounts", value: "\(viewModel.summary.accountCount)")
            statRow(title: "Healthy", value: "\(max(viewModel.summary.accountCount - viewModel.summary.unhealthyCount, 0))")
            statRow(title: "Alerts", value: "\(viewModel.summary.unhealthyCount)")
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
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
}

private struct AddCodexAccountSheet: View {
    @ObservedObject var viewModel: ProviderMonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Codex Account")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text("Use browser login for a new account, or import an existing isolated `auth.json` file. Both paths keep QuotaBar separate from the default Codex CLI directory.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Browser Login")
                        .font(.headline)
                    Spacer()
                    if viewModel.isStartingLogin {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("Start an isolated `codex login`. The CLI should open the browser for you; after it succeeds, come back here and confirm.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
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
                }

                if let url = viewModel.activeLoginURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the browser did not open, copy this link and open it manually:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Text(url.absoluteString)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
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
                    Text("If your browser did not open automatically, wait for the login link to appear here and copy it manually. If no link appears, run `codex login` in Terminal and import the resulting isolated `auth.json`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.thinMaterial, in: .rect(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Import Existing Auth")
                    .font(.headline)

                Text("Choose an `auth.json` exported from another isolated Codex login directory.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        if let url = selectAuthFileURL(), await viewModel.importAuthFile(from: url) {
                            dismiss()
                        }
                    }
                } label: {
                    Label("Import auth.json", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.thinMaterial, in: .rect(cornerRadius: 16))

            if let error = viewModel.addAccountErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
            }

            HStack {
                Spacer()

                Button("Close") {
                    viewModel.dismissAddAccountSheet()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task {
                        if await viewModel.finishCodexLogin() {
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isFinishingLogin {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("I've Finished Login")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.loginHasStarted || viewModel.isFinishingLogin)
            }
        }
        .padding(22)
        .frame(width: 580)
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
