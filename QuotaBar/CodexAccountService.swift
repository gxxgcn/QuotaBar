import Darwin
import Foundation
import SwiftData

struct LocalCodexAccountStatus: Sendable {
    let matchedAccountID: UUID?
    let hasAuthFile: Bool
    let authFileURL: URL
}

struct LocalCodexSwitchResult: Sendable {
    let authFileURL: URL
    let backupURL: URL?
}

@MainActor
final class CodexAccountService {
    private static let refreshTimeout: Duration = .seconds(15)
    private static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    struct LoginStartContext {
        let authURL: URL?
        let session: LoginSession
    }

    final class LoginSession {
        private let outputQueue = DispatchQueue(label: "QuotaBar.CodexLoginSession")
        let homeURL: URL
        let process: Process
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        private var mergedOutput = ""
        private var discoveredAuthURL: URL?

        init(homeURL: URL, process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
            self.homeURL = homeURL
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        nonisolated func appendOutput(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            outputQueue.sync {
                mergedOutput.append(text)
                if discoveredAuthURL == nil {
                    discoveredAuthURL = Self.extractURL(from: mergedOutput)
                }
            }
        }

        nonisolated func authURL() -> URL? {
            outputQueue.sync { discoveredAuthURL }
        }

        nonisolated func combinedOutput() -> String {
            outputQueue.sync {
                String(mergedOutput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            }
        }

        private static func extractURL(from text: String) -> URL? {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = detector.matches(in: text, options: [], range: range)
            let urls = matches.compactMap(\.url)

            if let preferred = urls.first(where: isPreferredLoginURL) {
                return preferred
            }

            return urls.first(where: isFallbackLoginURL)
        }

        private static func isPreferredLoginURL(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https" else { return false }
            guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
            guard !isLocalHost(host) else { return false }

            return host.contains("openai.com")
                || host.contains("chatgpt.com")
                || host.contains("auth.openai")
        }

        private static func isFallbackLoginURL(_ url: URL) -> Bool {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
            guard let host = url.host?.lowercased(), !host.isEmpty else { return true }
            return !isLocalHost(host)
        }

        private static func isLocalHost(_ host: String) -> Bool {
            host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
    }

    private let modelContext: ModelContext
    private let credentialStore: CredentialStore
    private let fileManager: FileManager
    private let localCodexHomeURL: URL

    init(
        modelContext: ModelContext,
        credentialStore: CredentialStore,
        fileManager: FileManager = .default,
        localCodexHomeURL: URL? = nil
    ) {
        self.modelContext = modelContext
        self.credentialStore = credentialStore
        self.fileManager = fileManager
        self.localCodexHomeURL = localCodexHomeURL ?? Self.resolveDefaultCodexHomeURL(fileManager: fileManager)
    }

    func fetchAccounts(providerKind: ProviderKind = .codex) throws -> [ProviderAccountRecord] {
        let descriptor = FetchDescriptor<ProviderAccountRecord>(
            predicate: #Predicate { $0.providerKindRawValue == providerKind.rawValue },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt),
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    func beginLogin() async throws -> LoginStartContext {
        let homeURL = try createIsolatedCodexHome()
        let session = try startLoginProcess(in: homeURL)
        let authURL = try await awaitLoginURL(in: session)
        return LoginStartContext(authURL: authURL, session: session)
    }

    func completeLogin(using context: LoginStartContext) async throws -> ProviderAccountRecord {
        defer { cleanup(loginSession: context.session) }

        if fileManager.fileExists(atPath: context.session.homeURL.appendingPathComponent("auth.json").path) {
            let authData = try loadAuthData(from: context.session.homeURL)
            return try await upsertAccount(from: authData, authData: authData)
        }

        if context.session.process.isRunning {
            throw CodexAppServerError.requestFailed(
                message: "Codex login is still running. Finish it in the browser, then click \"I've Finished Login\" again."
            )
        }

        let output = readCombinedOutput(from: context.session)
        let status = context.session.process.terminationStatus
        if status == 0 {
            throw CodexAppServerError.loginDidNotProduceAuth
        }

        let detail = output.isEmpty ? "No output captured." : output
        throw CodexAppServerError.requestFailed(
            message: "Codex login exited with status \(status). \(detail)"
        )
    }

    func refreshAccount(_ account: ProviderAccountRecord) async throws -> CodexUsageSnapshot {
        let authData = try await credentialStore.loadAuthData(for: account.id)
        account.syncStatus = .refreshing
        try modelContext.save()

        do {
            let token = try CodexAuthParser.bearerToken(from: authData)
            let usageResponse = try await withTimeout(Self.refreshTimeout) {
                try await self.fetchUsage(token: token)
            }

            if let planType = usageResponse.planType, !planType.isEmpty {
                account.planType = planType
            }
            account.lastSyncedAt = .now
            account.syncStatus = .healthy
            try modelContext.save()

            return makeSnapshot(account: account, response: usageResponse, error: nil)
        } catch {
            account.lastSyncedAt = .now
            account.syncStatus = syncStatus(for: error)
            try modelContext.save()

            return CodexUsageSnapshot(
                accountID: account.id,
                email: account.email,
                planType: account.planType,
                rateLimitsByLimitID: [:],
                primaryLimit: nil,
                secondaryLimit: nil,
                lastError: error.localizedDescription,
                fetchedAt: .now
            )
        }
    }

    func importAccount(from authData: Data) async throws -> ProviderAccountRecord {
        try await upsertAccount(from: authData, authData: authData)
    }

    func renameAccount(id: UUID, to newName: String) throws {
        guard let record = try fetchAccounts().first(where: { $0.id == id }) else { return }
        record.displayName = newName.isEmpty ? defaultDisplayName(for: record.email) : newName
        try modelContext.save()
    }

    func setAccountEnabled(id: UUID, isEnabled: Bool) throws {
        guard let record = try fetchAccounts().first(where: { $0.id == id }) else { return }
        record.isEnabled = isEnabled
        record.syncStatus = isEnabled ? .idle : .disabled
        try modelContext.save()
    }

    func deleteAccount(id: UUID) async throws {
        guard let record = try fetchAccounts().first(where: { $0.id == id }) else { return }
        modelContext.delete(record)
        try modelContext.save()
        try await credentialStore.deleteAuthData(for: id)
    }

    func localCodexAccountStatus() async throws -> LocalCodexAccountStatus {
        let authFileURL = localAuthFileURL()
        guard fileManager.fileExists(atPath: authFileURL.path) else {
            return LocalCodexAccountStatus(matchedAccountID: nil, hasAuthFile: false, authFileURL: authFileURL)
        }

        let authData: Data
        do {
            authData = try Data(contentsOf: authFileURL)
        } catch {
            throw CodexAppServerError.requestFailed(message: "Could not read local auth from `\(authFileURL.path)`. \(error.localizedDescription)")
        }

        let identity = try localIdentity(from: authData)
        let matchedAccountID = try fetchAccounts()
            .first(where: { $0.providerKind == .codex && $0.remoteAccountID == identity.accountID })?
            .id

        return LocalCodexAccountStatus(
            matchedAccountID: matchedAccountID,
            hasAuthFile: true,
            authFileURL: authFileURL
        )
    }

    func switchLocalCodexAccount(to account: ProviderAccountRecord) async throws -> LocalCodexSwitchResult {
        let authData = try await credentialStore.loadAuthData(for: account.id)
        _ = try CodexAuthParser.identity(from: authData)

        let authFileURL = localAuthFileURL()
        let homeURL = authFileURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        } catch {
            throw CodexAppServerError.requestFailed(message: "Could not create local Codex home at `\(homeURL.path)`. \(error.localizedDescription)")
        }

        let backupURL = try backupExistingLocalAuthIfNeeded(at: authFileURL)
        do {
            try atomicallyWriteLocalAuth(authData, to: authFileURL)
        } catch let appError as CodexAppServerError {
            throw appError
        } catch {
            throw CodexAppServerError.localAuthWriteFailed(path: authFileURL.path, underlying: error.localizedDescription)
        }

        return LocalCodexSwitchResult(authFileURL: authFileURL, backupURL: backupURL)
    }

    private func upsertAccount(
        from authData: Data,
        authData persistedAuthData: Data
    ) async throws -> ProviderAccountRecord {
        let identity = try CodexAuthParser.identity(from: authData)
        let remoteAccountID = identity.accountID
        let existing = try fetchAccounts().first(where: {
            $0.remoteAccountID == remoteAccountID && $0.providerKind == .codex
        })

        let record = existing ?? ProviderAccountRecord(
            providerKind: .codex,
            displayName: defaultDisplayName(for: identity.email),
            email: identity.email,
            remoteAccountID: remoteAccountID,
            planType: identity.planType,
            sortOrder: (try? fetchAccounts().count) ?? 0
        )

        record.email = identity.email
        record.planType = identity.planType
        if record.displayName.isEmpty {
            record.displayName = defaultDisplayName(for: identity.email)
        }
        record.remoteAccountID = remoteAccountID
        record.syncStatus = .idle

        if existing == nil {
            modelContext.insert(record)
        }

        try modelContext.save()
        try await credentialStore.save(authData: persistedAuthData, for: record.id)
        return record
    }

    private func makeSnapshot(
        account: ProviderAccountRecord,
        response: UsageResponse,
        error: String?
    ) -> CodexUsageSnapshot {
        let limit = RateLimitSnapshotData(
            limitID: "codex",
            limitName: "Codex",
            planType: response.planType ?? account.planType,
            primary: mapWindow(response.primaryWindow),
            secondary: mapWindow(response.secondaryWindow)
        )
        let mappedRateLimitsByID = ["codex": limit]

        return CodexUsageSnapshot(
            accountID: account.id,
            email: account.email,
            planType: response.planType ?? account.planType,
            rateLimitsByLimitID: mappedRateLimitsByID,
            primaryLimit: limit,
            secondaryLimit: limit.secondary == nil ? nil : limit,
            lastError: error,
            fetchedAt: .now
        )
    }

    private func mapWindow(_ payload: UsageWindowPayload?) -> RateLimitWindowSnapshot? {
        guard let payload else { return nil }
        return RateLimitWindowSnapshot(
            usedPercent: payload.usedPercent,
            resetsAt: payload.resetAt.map { Date(timeIntervalSince1970: $0) },
            resetDescription: nil,
            windowDurationMins: payload.limitWindowSeconds.map { Int(($0 / 60.0).rounded()) }
        )
    }

    private func syncStatus(for error: Error) -> AccountSyncStatus {
        let message = error.localizedDescription.lowercased()
        if message.contains("unauthorized") || message.contains("http 401") || message.contains("http 403") {
            return .unauthorized
        }
        return .failed
    }

    private func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexAppServerError.requestFailed(message: "Usage request returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = body.map { $0.isEmpty ? "" : " - \($0)" } ?? ""
            throw CodexAppServerError.requestFailed(
                message: "Usage request failed: HTTP \(httpResponse.statusCode)\(suffix)"
            )
        }

        return try UsageResponse(data: data)
    }

    private func loadAuthData(from homeURL: URL) throws -> Data {
        let authURL = homeURL.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexAppServerError.loginDidNotProduceAuth
        }
        return try Data(contentsOf: authURL)
    }

    private func cleanup(loginSession: LoginSession) {
        loginSession.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        loginSession.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if loginSession.process.isRunning {
            loginSession.process.terminate()
        }
        try? fileManager.removeItem(at: loginSession.homeURL)
    }

    func cancelLogin(using context: LoginStartContext) {
        cleanup(loginSession: context.session)
    }

    private func createIsolatedCodexHome() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("QuotaBar")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CodexAppServerError.requestFailed(
                    message: "Timed out waiting for Codex CLI. Check that `codex` works in Terminal and that the account auth is still valid."
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func startLoginProcess(in homeURL: URL) throws -> LoginSession {
        guard let codexBinary = CodexBinaryLocator.resolve() else {
            try? fileManager.removeItem(at: homeURL)
            throw CodexAppServerError.requestFailed(
                message: "Could not find the Codex CLI. Install it and ensure QuotaBar can see the binary."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexBinary, "login"]
        process.environment = environment(with: homeURL)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = LoginSession(homeURL: homeURL, process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            session.appendOutput(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            session.appendOutput(data)
        }

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: homeURL)
            throw CodexAppServerError.requestFailed(
                message: "Could not start `codex login`. Make sure the Codex CLI is installed and available in PATH. \(error.localizedDescription)"
            )
        }

        return session
    }

    private func environment(with homeURL: URL) -> [String: String] {
        CodexBinaryLocator.environment(codexHome: homeURL)
    }

    private func readCombinedOutput(from session: LoginSession) -> String {
        session.combinedOutput()
    }

    func currentLoginURL(using context: LoginStartContext) -> URL? {
        context.session.authURL()
    }

    private func awaitLoginURL(in session: LoginSession) async throws -> URL? {
        for _ in 0..<20 {
            if let url = session.authURL() {
                return url
            }
            if !session.process.isRunning {
                return session.authURL()
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return session.authURL()
    }

    private func defaultDisplayName(for email: String) -> String {
        if let localPart = email.split(separator: "@").first, !localPart.isEmpty {
            return String(localPart)
        }
        return "Codex Account"
    }

    private func localAuthFileURL() -> URL {
        localCodexHomeURL.appendingPathComponent("auth.json")
    }

    private func localIdentity(from authData: Data) throws -> CodexAccountIdentity {
        do {
            return try CodexAuthParser.identity(from: authData)
        } catch {
            throw CodexAppServerError.malformedLocalAuthData
        }
    }

    private func backupExistingLocalAuthIfNeeded(at authFileURL: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: authFileURL.path) else {
            return nil
        }

        let existingData: Data
        do {
            existingData = try Data(contentsOf: authFileURL)
        } catch {
            throw CodexAppServerError.requestFailed(message: "Could not read existing local auth from `\(authFileURL.path)`. \(error.localizedDescription)")
        }

        _ = try localIdentity(from: existingData)

        let backupDirectoryURL = localCodexHomeURL.appendingPathComponent("quotabar-backups", isDirectory: true)
        do {
            try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw CodexAppServerError.localAuthBackupFailed(path: backupDirectoryURL.path, underlying: error.localizedDescription)
        }

        let backupURL = backupDirectoryURL.appendingPathComponent("auth-\(Self.backupTimestampString(from: .now)).json")
        do {
            try existingData.write(to: backupURL, options: .withoutOverwriting)
        } catch {
            throw CodexAppServerError.localAuthBackupFailed(path: backupURL.path, underlying: error.localizedDescription)
        }
        return backupURL
    }

    private func atomicallyWriteLocalAuth(_ authData: Data, to authFileURL: URL) throws {
        let tempURL = authFileURL.deletingLastPathComponent()
            .appendingPathComponent(".auth.\(UUID().uuidString).tmp")

        do {
            try authData.write(to: tempURL, options: .withoutOverwriting)
            if fileManager.fileExists(atPath: authFileURL.path) {
                _ = try fileManager.replaceItemAt(authFileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: authFileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw CodexAppServerError.localAuthWriteFailed(path: authFileURL.path, underlying: error.localizedDescription)
        }
    }

    private static func resolveDefaultCodexHomeURL(fileManager: FileManager) -> URL {
        if let entry = getpwuid(getuid()), let homeDirectory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func backupTimestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct UsageResponse: Sendable {
    let planType: String?
    let primaryWindow: UsageWindowPayload?
    let secondaryWindow: UsageWindowPayload?

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw CodexAppServerError.requestFailed(message: "Usage response was not a JSON object.")
        }

        planType = root["plan_type"] as? String
        primaryWindow = UsageResponse.lookupWindow(in: root, keys: ["rate_limit", "primary_window"])
        secondaryWindow = UsageResponse.lookupWindow(in: root, keys: ["rate_limit", "secondary_window"])
    }

    private static func lookupWindow(in root: [String: Any], keys: [String]) -> UsageWindowPayload? {
        guard let object = lookupObject(in: root, keys: keys) else { return nil }
        return UsageWindowPayload(
            usedPercent: clampPercent(object["used_percent"]),
            resetAt: unixTimestamp(object["reset_at"]),
            limitWindowSeconds: doubleValue(object["limit_window_seconds"])
        )
    }

    private static func lookupObject(in root: [String: Any], keys: [String]) -> [String: Any]? {
        var current: Any = root
        for key in keys {
            guard let object = current as? [String: Any], let next = object[key] else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Float:
            return Double(number)
        case let number as Int:
            return Double(number)
        case let number as Int64:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    private static func unixTimestamp(_ value: Any?) -> TimeInterval? {
        doubleValue(value)
    }

    private static func clampPercent(_ value: Any?) -> Int {
        guard let number = doubleValue(value) else { return 0 }
        return min(100, max(0, Int(number.rounded())))
    }
}

private struct UsageWindowPayload: Sendable {
    let usedPercent: Int
    let resetAt: TimeInterval?
    let limitWindowSeconds: Double?
}
