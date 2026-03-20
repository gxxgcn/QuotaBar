import Foundation
import Combine

@MainActor
final class PreviewDataSource: ContentViewDataSource {
    @Published var accounts: [ProviderAccountRecord] = []
    @Published var snapshotsByAccountID: [UUID: CodexUsageSnapshot] = [:]
    @Published var isRefreshingAll = false
    @Published var isStartingLogin = false
    @Published var isFinishingLogin = false
    @Published var loginHasStarted = false
    @Published var activeLoginURL: URL?
    @Published var addAccountErrorMessage: String?

    let objectWillChange = ObservableObjectPublisher()

    private let scenario: PreviewFactory.Scenario

    init(scenario: PreviewFactory.Scenario = .mixed) {
        self.scenario = scenario
        loadData()
    }

    private func loadData() {
        switch scenario {
        case .empty, .loginInProgress:
            break
        case .mixed:
            let sampleAccounts = PreviewFactory.makeSampleAccounts()
            accounts = sampleAccounts
            for account in sampleAccounts {
                if let snapshot = PreviewFactory.makeSnapshot(for: account) {
                    snapshotsByAccountID[account.id] = snapshot
                }
            }
        }
    }

    func isLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool {
        account.remoteAccountID == "preview-local"
    }

    func isSwitchingLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool {
        false
    }

    func switchLocalCodexAccount(to account: ProviderAccountRecord) async {
        // Preview - no action needed
    }

    func refreshAll(reason: String) async {
        isRefreshingAll = true
        try? await Task.sleep(for: .seconds(1))
        isRefreshingAll = false
    }

    func beginCodexLogin() async {
        isStartingLogin = true
        addAccountErrorMessage = nil
        activeLoginURL = nil
        try? await Task.sleep(for: .seconds(1))
        isStartingLogin = false
        loginHasStarted = true
        activeLoginURL = URL(string: "https://chatgpt.com/auth/codex/device-preview")
    }

    func finishCodexLogin() async -> Bool {
        guard loginHasStarted else { return false }
        isFinishingLogin = true
        try? await Task.sleep(for: .seconds(1))
        isFinishingLogin = false
        loginHasStarted = false
        activeLoginURL = nil
        return true
    }

    func cancelCodexLogin() {
        loginHasStarted = false
        activeLoginURL = nil
        addAccountErrorMessage = nil
        isStartingLogin = false
        isFinishingLogin = false
    }

    func reopenLoginURL() {
        // Preview - no action needed
    }

    func panelDidOpen() {
        // Preview - no action needed
    }
}
