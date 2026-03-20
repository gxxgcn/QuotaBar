import Foundation

@MainActor
protocol ContentViewDataSource: ObservableObject {
    var accounts: [ProviderAccountRecord] { get }
    var snapshotsByAccountID: [UUID: CodexUsageSnapshot] { get }
    var isRefreshingAll: Bool { get }
    var isStartingLogin: Bool { get }
    var isFinishingLogin: Bool { get }
    var loginHasStarted: Bool { get }
    var activeLoginURL: URL? { get }
    var addAccountErrorMessage: String? { get }

    func isLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool
    func isSwitchingLocalCodexAccount(_ account: ProviderAccountRecord) -> Bool
    func switchLocalCodexAccount(to account: ProviderAccountRecord) async
    func refreshAll(reason: String) async
    func beginCodexLogin() async
    func finishCodexLogin() async -> Bool
    func cancelCodexLogin()
    func reopenLoginURL()
    func panelDidOpen()
}
