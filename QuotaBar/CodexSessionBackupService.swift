import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CodexBackupThreadSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: Date
    let gitBranch: String?
    let firstUserMessage: String
}

struct CodexBackupWorkspaceGroup: Identifiable, Hashable, Sendable {
    let id: String
    let workspacePath: String
    let workspaceName: String
    let threads: [CodexBackupThreadSummary]
}

struct CodexBackupArchiveInfo: Sendable {
    let archiveURL: URL
    let fileSizeBytes: Int
    let threadCount: Int
    let projectCount: Int
}

struct CodexBackupProjectPreview: Identifiable, Hashable, Sendable {
    let id: String
    let sourceWorkspacePath: String
    let workspaceName: String
    let suggestedGitOriginURL: String?
    let suggestedGitBranch: String?
    let threads: [CodexBackupThreadSummary]
}

struct CodexBackupArchivePreview: Sendable {
    let archiveURL: URL
    let extractedRootURL: URL
    let exportedAt: Date?
    let projects: [CodexBackupProjectPreview]
    let threadCount: Int
}

final class CodexSessionBackupService {
    private enum DefaultsKey {
        static let exportDirectoryPath = "backup.exportDirectoryPath"
    }

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let codexHomeURL: URL

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        codexHomeURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.codexHomeURL = codexHomeURL ?? Self.resolveDefaultCodexHomeURL(fileManager: fileManager)
    }

    var exportDirectoryURL: URL? {
        get { url(forKey: DefaultsKey.exportDirectoryPath) }
        set { setURL(newValue, forKey: DefaultsKey.exportDirectoryPath) }
    }

    var codexDataDirectoryURL: URL { codexHomeURL }

    func listExportableWorkspaces() throws -> [CodexBackupWorkspaceGroup] {
        let stateDatabaseURL = codexHomeURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            throw CodexAppServerError.requestFailed(message: "Could not find Codex state database at `\(stateDatabaseURL.path)`.")
        }

        let database = try SQLiteDatabase(url: stateDatabaseURL)
        defer { database.close() }

        let sessionIndexEntries = try loadSessionIndexEntriesByID()
        let threads = try database.fetchThreads()
            .filter { thread in
                guard !thread.isArchivedForDisplay else { return false }
                return fileManager.fileExists(atPath: normalizedWorkspacePath(thread.cwd))
            }
            .compactMap { thread -> (ThreadRecord, String)? in
                guard let displayTitle = preferredIndexedDisplayTitle(for: thread, sessionIndexEntry: sessionIndexEntries[thread.id]) else {
                    return nil
                }
                return (thread, displayTitle)
            }
        if threads.isEmpty {
            throw CodexAppServerError.requestFailed(message: "No exportable Codex sessions were found after filtering archived and untitled threads.")
        }

        let grouped = Dictionary(grouping: threads) { thread in
            normalizedWorkspacePath(thread.0.cwd)
        }

        return grouped.keys.sorted().map { workspacePath in
            let sortedThreads = (grouped[workspacePath] ?? [])
                .sorted { $0.0.updatedAt > $1.0.updatedAt }
                .map { thread, displayTitle in
                    CodexBackupThreadSummary(
                        id: thread.id,
                        title: displayTitle,
                        cwd: thread.cwd,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
                        gitBranch: thread.gitBranch,
                        firstUserMessage: thread.firstUserMessage
                    )
                }
            return CodexBackupWorkspaceGroup(
                id: workspacePath,
                workspacePath: workspacePath,
                workspaceName: workspaceDisplayName(for: workspacePath),
                threads: sortedThreads
            )
        }
    }

    func exportBackup(threadIDs: [String], to directoryURL: URL) throws -> CodexBackupArchiveInfo {
        let uniqueThreadIDs = Array(Set(threadIDs)).sorted()
        guard !uniqueThreadIDs.isEmpty else {
            throw CodexAppServerError.requestFailed(message: "Choose at least one session thread to export.")
        }

        let stateDatabaseURL = codexHomeURL.appendingPathComponent("state_5.sqlite")
        let database = try SQLiteDatabase(url: stateDatabaseURL)
        defer { database.close() }
        let logsDatabaseURL = codexHomeURL.appendingPathComponent("logs_1.sqlite")
        let logsDatabase = fileManager.fileExists(atPath: logsDatabaseURL.path) ? try SQLiteLogsDatabase(url: logsDatabaseURL) : nil
        defer { logsDatabase?.close() }
        let sessionIndexEntries = try loadSessionIndexEntriesByID()

        let exportParentURL = fileManager.temporaryDirectory
            .appendingPathComponent("QuotaBarBackupExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRootURL = exportParentURL.appendingPathComponent("QuotaBarBackup", isDirectory: true)
        try fileManager.createDirectory(at: packageRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packageRootURL.appendingPathComponent("threads", isDirectory: true), withIntermediateDirectories: true)

        var threadManifests: [BackupThreadManifest] = []
        for threadID in uniqueThreadIDs {
            let thread = try database.fetchThread(id: threadID)
            let exportTitle = preferredIndexedDisplayTitle(for: thread, sessionIndexEntry: sessionIndexEntries[thread.id])
                ?? preferredDisplayTitle(for: thread, sessionIndexEntry: sessionIndexEntries[thread.id])
                ?? thread.title
            let dynamicTools = try database.fetchDynamicTools(threadID: threadID)
            let logs = try logsDatabase?.fetchLogs(threadID: threadID) ?? []
            let rolloutSourceURL = URL(fileURLWithPath: thread.rolloutPath)
            guard fileManager.fileExists(atPath: rolloutSourceURL.path) else {
                throw CodexAppServerError.requestFailed(message: "The selected session points to a missing rollout file: `\(rolloutSourceURL.path)`.")
            }

            let threadDirectoryURL = packageRootURL
                .appendingPathComponent("threads", isDirectory: true)
                .appendingPathComponent(thread.id, isDirectory: true)
            try fileManager.createDirectory(at: threadDirectoryURL, withIntermediateDirectories: true)

            let relativeRolloutPath = relativeRolloutPath(for: rolloutSourceURL)
            let threadManifest = BackupThreadManifest(
                threadID: thread.id,
                title: exportTitle,
                sourceCodexHome: codexHomeURL.path,
                sourceRolloutPath: rolloutSourceURL.path,
                rolloutRelativePath: relativeRolloutPath,
                sourceCwd: normalizedWorkspacePath(thread.cwd),
                suggestedImportCwdGitOriginURL: thread.gitOriginURL,
                suggestedImportCwdGitBranch: thread.gitBranch,
                packageRelativeDirectory: "threads/\(thread.id)"
            )
            threadManifests.append(threadManifest)

            let rolloutTargetURL = threadDirectoryURL.appendingPathComponent("rollout.jsonl")
            try fileManager.copyItem(at: rolloutSourceURL, to: rolloutTargetURL)

            try writeJSON(threadManifest, to: threadDirectoryURL.appendingPathComponent("manifest.json"))
            try writeJSON(thread, to: threadDirectoryURL.appendingPathComponent("thread.json"))
            try writeJSON(dynamicTools, to: threadDirectoryURL.appendingPathComponent("dynamic_tools.json"))
            if !logs.isEmpty {
                try writeJSON(logs, to: threadDirectoryURL.appendingPathComponent("logs.json"))
            }
            if let sessionIndexEntry = try loadSessionIndexEntry(threadID: thread.id) {
                try writeJSON(sessionIndexEntry, to: threadDirectoryURL.appendingPathComponent("session_index_entry.json"))
            }
        }

        let archiveManifest = BackupArchiveManifest(
            archiveVersion: 1,
            exportedAt: Self.exportDateFormatter.string(from: .now),
            sourceCodexHome: codexHomeURL.path,
            threads: threadManifests.sorted { lhs, rhs in
                lhs.sourceCwd == rhs.sourceCwd ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : lhs.sourceCwd.localizedCaseInsensitiveCompare(rhs.sourceCwd) == .orderedAscending
            }
        )
        try writeJSON(archiveManifest, to: packageRootURL.appendingPathComponent("manifest.json"))

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let archiveURL = directoryURL.appendingPathComponent(defaultArchiveName(exportedAt: .now))
        try? fileManager.removeItem(at: archiveURL)
        do {
            try zipItem(at: packageRootURL, to: archiveURL)
        } catch {
            try? fileManager.removeItem(at: exportParentURL)
            throw error
        }
        try? fileManager.removeItem(at: exportParentURL)

        let fileSize = try archiveFileSize(at: archiveURL)
        let projectCount = Set(threadManifests.map(\.sourceCwd)).count
        return CodexBackupArchiveInfo(
            archiveURL: archiveURL,
            fileSizeBytes: fileSize,
            threadCount: threadManifests.count,
            projectCount: projectCount
        )
    }

    func inspectBackupArchive(at archiveURL: URL) throws -> CodexBackupArchivePreview {
        let extractionRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("QuotaBarBackupImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: extractionRootURL, withIntermediateDirectories: true)

        do {
            try unzipItem(at: archiveURL, to: extractionRootURL)
        } catch {
            try? fileManager.removeItem(at: extractionRootURL)
            throw error
        }

        let packageRootURL: URL
        do {
            packageRootURL = try resolveExtractedPackageRoot(from: extractionRootURL)
        } catch {
            try? fileManager.removeItem(at: extractionRootURL)
            throw error
        }

        let manifest: BackupArchiveManifest
        do {
            manifest = try readJSON(from: packageRootURL.appendingPathComponent("manifest.json"))
        } catch {
            try? fileManager.removeItem(at: extractionRootURL)
            throw error
        }

        let projectGroups = Dictionary(grouping: manifest.threads) { $0.sourceCwd }
            .map { workspacePath, threadManifests in
                CodexBackupProjectPreview(
                    id: workspacePath,
                    sourceWorkspacePath: workspacePath,
                    workspaceName: workspaceDisplayName(for: workspacePath),
                    suggestedGitOriginURL: threadManifests.compactMap(\.suggestedImportCwdGitOriginURL).first,
                    suggestedGitBranch: threadManifests.compactMap(\.suggestedImportCwdGitBranch).first,
                    threads: threadManifests.map { manifest in
                        CodexBackupThreadSummary(
                            id: manifest.threadID,
                            title: manifest.title,
                            cwd: manifest.sourceCwd,
                            updatedAt: Date.distantPast,
                            gitBranch: manifest.suggestedImportCwdGitBranch,
                            firstUserMessage: ""
                        )
                    }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                )
            }
            .sorted { $0.workspaceName.localizedCaseInsensitiveCompare($1.workspaceName) == .orderedAscending }

        return CodexBackupArchivePreview(
            archiveURL: archiveURL,
            extractedRootURL: packageRootURL,
            exportedAt: Self.exportDateFormatter.date(from: manifest.exportedAt),
            projects: projectGroups,
            threadCount: manifest.threads.count
        )
    }

    func importBackupArchive(
        preview: CodexBackupArchivePreview,
        workspaceOverrides: [String: URL]
    ) throws -> CodexBackupArchiveInfo {
        let manifest: BackupArchiveManifest = try readJSON(from: preview.extractedRootURL.appendingPathComponent("manifest.json"))

        let stateDatabaseURL = codexHomeURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            throw CodexAppServerError.requestFailed(message: "Could not find Codex state database at `\(stateDatabaseURL.path)`.")
        }
        let database = try SQLiteDatabase(url: stateDatabaseURL)
        defer { database.close() }
        let logsDatabaseURL = codexHomeURL.appendingPathComponent("logs_1.sqlite")
        let logsDatabase = try SQLiteLogsDatabase(url: logsDatabaseURL)
        defer { logsDatabase.close() }

        for item in manifest.threads {
            let threadDirectoryURL = preview.extractedRootURL.appendingPathComponent(item.packageRelativeDirectory, isDirectory: true)
            var thread: ThreadRecord = try readJSON(from: threadDirectoryURL.appendingPathComponent("thread.json"))
            let dynamicTools: [DynamicToolRecord] = try readJSON(from: threadDirectoryURL.appendingPathComponent("dynamic_tools.json"))
            let sessionIndexEntryURL = threadDirectoryURL.appendingPathComponent("session_index_entry.json")
            let sessionIndexEntry: SessionIndexEntry? = fileManager.fileExists(atPath: sessionIndexEntryURL.path)
                ? try readJSON(from: sessionIndexEntryURL)
                : nil
            let logsURL = threadDirectoryURL.appendingPathComponent("logs.json")
            let logs: [LogRecord]? = fileManager.fileExists(atPath: logsURL.path)
                ? try readJSON(from: logsURL)
                : nil

            let rolloutSourceURL = threadDirectoryURL.appendingPathComponent("rollout.jsonl")
            guard fileManager.fileExists(atPath: rolloutSourceURL.path) else {
                throw CodexAppServerError.requestFailed(message: "Backup archive is missing `rollout.jsonl` for `\(item.title)`.")
            }

            let rolloutTargetURL = codexHomeURL.appendingPathComponent(item.rolloutRelativePath, isDirectory: false)
            try fileManager.createDirectory(at: rolloutTargetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: rolloutTargetURL.path) {
                try fileManager.removeItem(at: rolloutTargetURL)
            }
            let importedCWD = resolveImportedCWD(
                originalCWD: item.sourceCwd,
                override: workspaceOverrides[item.sourceCwd]
            )
            try rewriteImportedRollout(
                from: rolloutSourceURL,
                to: rolloutTargetURL,
                originalCWD: item.sourceCwd,
                importedCWD: importedCWD
            )

            thread.rolloutPath = rolloutTargetURL.path
            thread.cwd = importedCWD

            try database.upsert(thread: thread)
            try database.replaceDynamicTools(threadID: thread.id, tools: dynamicTools)
            if let logs, !logs.isEmpty {
                try logsDatabase.replaceLogs(threadID: thread.id, logs: logs)
            } else {
                try logsDatabase.insertSyntheticImportLog(threadID: thread.id, timestamp: thread.updatedAt)
            }

            let finalSessionIndexEntry = sessionIndexEntry ?? SessionIndexEntry(
                id: thread.id,
                threadName: thread.title,
                updatedAt: Self.sessionIndexDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)))
            )
            try updateSessionIndex(with: finalSessionIndexEntry)
        }

        let fileSize = try archiveFileSize(at: preview.archiveURL)
        return CodexBackupArchiveInfo(
            archiveURL: preview.archiveURL,
            fileSizeBytes: fileSize,
            threadCount: manifest.threads.count,
            projectCount: Set(manifest.threads.map(\.sourceCwd)).count
        )
    }

    func cleanupImportPreview(_ preview: CodexBackupArchivePreview?) {
        guard let preview else { return }
        let extractionContainer = preview.extractedRootURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: extractionContainer)
    }

    private func url(forKey key: String) -> URL? {
        guard let path = userDefaults.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func setURL(_ url: URL?, forKey key: String) {
        userDefaults.set(url?.path, forKey: key)
    }

    private func resolveArchiveURL(from directoryURL: URL) throws -> URL {
        if directoryURL.pathExtension.lowercased() == "zip" {
            return directoryURL
        }
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let archives = contents.filter { $0.pathExtension.lowercased() == "zip" }
        guard let latestArchive = archives.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            throw CodexAppServerError.requestFailed(message: "No importable backup archive was found in `\(directoryURL.path)`.")
        }
        return latestArchive
    }

    private func relativeRolloutPath(for rolloutURL: URL) -> String {
        let codexHomePath = codexHomeURL.standardizedFileURL.path
        let rolloutPath = rolloutURL.standardizedFileURL.path
        if rolloutPath.hasPrefix(codexHomePath + "/") {
            return String(rolloutPath.dropFirst(codexHomePath.count + 1))
        }
        return "sessions/\(rolloutURL.lastPathComponent)"
    }

    private func loadSessionIndexEntriesByID() throws -> [String: SessionIndexEntry] {
        let url = codexHomeURL.appendingPathComponent("session_index.jsonl")
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        var entries: [String: SessionIndexEntry] = [:]
        for entry in try parseSessionIndexEntries(from: url) {
            entries[entry.id] = entry
        }
        return entries
    }

    private func loadSessionIndexEntry(threadID: String) throws -> SessionIndexEntry? {
        try loadSessionIndexEntriesByID()[threadID]
    }

    private func preferredIndexedDisplayTitle(for thread: ThreadRecord, sessionIndexEntry: SessionIndexEntry?) -> String? {
        guard let sessionIndexEntry else { return nil }
        guard let normalized = normalizedDisplayTitle(sessionIndexEntry.threadName) else { return nil }
        guard isUserFacingThreadTitle(normalized) else { return nil }
        return normalized
    }

    private func preferredDisplayTitle(for thread: ThreadRecord, sessionIndexEntry: SessionIndexEntry?) -> String? {
        let candidates = [
            sessionIndexEntry?.threadName,
            thread.title,
        ]
        for candidate in candidates {
            guard let normalized = normalizedDisplayTitle(candidate) else { continue }
            guard isUserFacingThreadTitle(normalized) else { continue }
            return normalized
        }
        return nil
    }

    private func normalizedDisplayTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func isUserFacingThreadTitle(_ title: String) -> Bool {
        let blockedPrefixes = [
            "You are a helpful assistant.",
            "[$skill-installer]",
            "Install ",
        ]
        if blockedPrefixes.contains(where: { title.hasPrefix($0) }) {
            return false
        }
        if title.contains("The tasks typically have to do with coding-related tasks") {
            return false
        }
        if title.localizedCaseInsensitiveContains(" skill") {
            return false
        }
        if title.localizedCaseInsensitiveContains("provide prioritized findings") {
            return false
        }
        return true
    }

    private func updateSessionIndex(with entry: SessionIndexEntry) throws {
        let url = codexHomeURL.appendingPathComponent("session_index.jsonl")
        var entries = try fileManager.fileExists(atPath: url.path) ? parseSessionIndexEntries(from: url) : []
        entries.removeAll { $0.id == entry.id }

        entries.append(entry)
        entries.sort { $0.updatedAt < $1.updatedAt }
        let encodedLines = try entries.map { value in
            let data = try JSONEncoder.sessionIndexEncoder.encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                throw CodexAppServerError.requestFailed(message: "Could not encode session index entry.")
            }
            return string
        }
        try encodedLines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func parseSessionIndexEntries(from url: URL) throws -> [SessionIndexEntry] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [SessionIndexEntry] = []
        var buffer = ""

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if buffer.isEmpty && line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            if !buffer.isEmpty {
                buffer.append("\n")
            }
            buffer.append(line)

            guard let data = buffer.data(using: .utf8) else {
                throw CodexAppServerError.requestFailed(message: "Could not read session index data as UTF-8.")
            }

            if let entry = try? JSONDecoder().decode(SessionIndexEntry.self, from: data) {
                entries.append(entry)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CodexAppServerError.requestFailed(message: "The Codex session index file is malformed and could not be parsed.")
        }

        return entries
    }

    private func resolveImportedCWD(originalCWD: String, override: URL?) -> String {
        if let override {
            return override.standardizedFileURL.path
        }
        if fileManager.fileExists(atPath: originalCWD) {
            return URL(fileURLWithPath: originalCWD).standardizedFileURL.path
        }
        return originalCWD
    }

    private func rewriteImportedRollout(
        from sourceURL: URL,
        to destinationURL: URL,
        originalCWD: String,
        importedCWD: String
    ) throws {
        let originalPath = URL(fileURLWithPath: originalCWD).standardizedFileURL.path
        let importedPath = URL(fileURLWithPath: importedCWD).standardizedFileURL.path
        guard originalPath != importedPath else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return
        }

        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let rewrittenLines = try contents.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return line }
            guard var object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return line
            }
            rewriteCWDReferences(in: &object, originalCWD: originalPath, importedCWD: importedPath)
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            guard let rewritten = String(data: data, encoding: .utf8) else {
                throw CodexAppServerError.requestFailed(message: "Could not rewrite imported rollout as UTF-8.")
            }
            return rewritten
        }
        try rewrittenLines.joined(separator: "\n").write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func rewriteCWDReferences(in object: inout [String: Any], originalCWD: String, importedCWD: String) {
        if let payload = object["payload"] as? [String: Any] {
            var rewrittenPayload = payload
            rewriteNestedCWDReferences(in: &rewrittenPayload, originalCWD: originalCWD, importedCWD: importedCWD)
            object["payload"] = rewrittenPayload
        }
        rewriteNestedCWDReferences(in: &object, originalCWD: originalCWD, importedCWD: importedCWD)
    }

    private func rewriteNestedCWDReferences(in dictionary: inout [String: Any], originalCWD: String, importedCWD: String) {
        for key in dictionary.keys {
            switch dictionary[key] {
            case let value as String:
                if key == "cwd", value == originalCWD {
                    dictionary[key] = importedCWD
                } else if key == "text", value.contains("<cwd>\(originalCWD)</cwd>") {
                    dictionary[key] = value.replacingOccurrences(of: "<cwd>\(originalCWD)</cwd>", with: "<cwd>\(importedCWD)</cwd>")
                }
            case var value as [String: Any]:
                rewriteNestedCWDReferences(in: &value, originalCWD: originalCWD, importedCWD: importedCWD)
                dictionary[key] = value
            case var value as [[String: Any]]:
                for index in value.indices {
                    rewriteNestedCWDReferences(in: &value[index], originalCWD: originalCWD, importedCWD: importedCWD)
                }
                dictionary[key] = value
            default:
                continue
            }
        }
    }

    private func bundleDirectorySize(at url: URL) throws -> Int {
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        return try contents.reduce(into: 0) { total, item in
            total += try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
    }

    private func archiveFileSize(at url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func zipItem(at sourceURL: URL, to archiveURL: URL) throws {
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", sourceURL.path, archiveURL.path]
        )
    }

    private func unzipItem(at archiveURL: URL, to destinationURL: URL) throws {
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, destinationURL.path]
        )
    }

    private func runProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw CodexAppServerError.requestFailed(message: "Could not run `\(executableURL.lastPathComponent)`: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            var data = Data()
            data.append(stderr.fileHandleForReading.readDataToEndOfFile())
            data.append(stdout.fileHandleForReading.readDataToEndOfFile())
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output captured."
            throw CodexAppServerError.requestFailed(message: "`\(executableURL.lastPathComponent)` failed: \(output)")
        }
    }

    private func resolveExtractedPackageRoot(from extractionRootURL: URL) throws -> URL {
        let manifestAtRoot = extractionRootURL.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: manifestAtRoot.path) {
            return extractionRootURL
        }

        let childDirectories = try fileManager.contentsOfDirectory(
            at: extractionRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let packageDirectory = childDirectories.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }) {
            return packageDirectory
        }
        throw CodexAppServerError.requestFailed(message: "The selected backup archive does not contain a valid manifest.")
    }

    private func defaultArchiveName(exportedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "quotabar-codex-backup-\(formatter.string(from: exportedAt)).zip"
    }

    private func workspaceDisplayName(for workspacePath: String) -> String {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown Workspace" }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    private func normalizedWorkspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolveDefaultCodexHomeURL(fileManager: FileManager) -> URL {
        if let entry = getpwuid(getuid()), let homeDirectory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func sanitize(title: String) -> String {
        let sanitizedScalars = title.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(sanitizedScalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return String((collapsed.isEmpty ? "untitled" : collapsed).prefix(48))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.sessionBundleEncoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static let exportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sessionIndexDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension JSONEncoder {
    static let sessionBundleEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let sessionIndexEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

private struct BackupArchiveManifest: Codable {
    let archiveVersion: Int
    let exportedAt: String
    let sourceCodexHome: String
    let threads: [BackupThreadManifest]

    enum CodingKeys: String, CodingKey {
        case archiveVersion = "archive_version"
        case exportedAt = "exported_at"
        case sourceCodexHome = "source_codex_home"
        case threads
    }
}

private struct BackupThreadManifest: Codable {
    let threadID: String
    let title: String
    let sourceCodexHome: String
    let sourceRolloutPath: String
    let rolloutRelativePath: String
    let sourceCwd: String
    let suggestedImportCwdGitOriginURL: String?
    let suggestedImportCwdGitBranch: String?
    let packageRelativeDirectory: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case title
        case sourceCodexHome = "source_codex_home"
        case sourceRolloutPath = "source_rollout_path"
        case rolloutRelativePath = "rollout_relative_path"
        case sourceCwd = "source_cwd"
        case suggestedImportCwdGitOriginURL = "suggested_import_cwd_git_origin_url"
        case suggestedImportCwdGitBranch = "suggested_import_cwd_git_branch"
        case packageRelativeDirectory = "package_relative_directory"
    }
}

private struct ThreadRecord: Codable {
    var id: String
    var rolloutPath: String
    let createdAt: Int64
    let updatedAt: Int64
    let source: String
    let modelProvider: String
    var cwd: String
    var title: String
    let sandboxPolicy: String
    let approvalMode: String
    let tokensUsed: Int64
    let hasUserEvent: Int64
    let archived: Int64
    let archivedAt: Int64?
    let gitSha: String?
    let gitBranch: String?
    let gitOriginURL: String?
    let cliVersion: String
    let firstUserMessage: String
    let agentNickname: String?
    let agentRole: String?
    let memoryMode: String

    var isArchivedForDisplay: Bool {
        if archived != 0 {
            return true
        }
        return rolloutPath.contains("/archived_sessions/")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case rolloutPath = "rollout_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case source
        case modelProvider = "model_provider"
        case cwd
        case title
        case sandboxPolicy = "sandbox_policy"
        case approvalMode = "approval_mode"
        case tokensUsed = "tokens_used"
        case hasUserEvent = "has_user_event"
        case archived
        case archivedAt = "archived_at"
        case gitSha = "git_sha"
        case gitBranch = "git_branch"
        case gitOriginURL = "git_origin_url"
        case cliVersion = "cli_version"
        case firstUserMessage = "first_user_message"
        case agentNickname = "agent_nickname"
        case agentRole = "agent_role"
        case memoryMode = "memory_mode"
    }
}

private struct DynamicToolRecord: Codable {
    let position: Int64
    let name: String
    let description: String
    let inputSchema: String

    enum CodingKeys: String, CodingKey {
        case position
        case name
        case description
        case inputSchema = "input_schema"
    }
}

private struct LogRecord: Codable {
    let ts: Int64
    let tsNanos: Int64
    let level: String
    let target: String
    let message: String?
    let modulePath: String?
    let file: String?
    let line: Int64?
    let threadID: String?
    let processUUID: String?
    let estimatedBytes: Int64

    enum CodingKeys: String, CodingKey {
        case ts
        case tsNanos = "ts_nanos"
        case level
        case target
        case message
        case modulePath = "module_path"
        case file
        case line
        case threadID = "thread_id"
        case processUUID = "process_uuid"
        case estimatedBytes = "estimated_bytes"
    }
}

private struct SessionIndexEntry: Codable {
    let id: String
    let threadName: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case updatedAt = "updated_at"
    }
}

private final class SQLiteLogsDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            throw CodexAppServerError.requestFailed(message: "Could not open SQLite database at `\(url.path)`.")
        }
        handle = db
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func fetchLogs(threadID: String) throws -> [LogRecord] {
        let sql = """
        SELECT ts, ts_nanos, level, target, message, module_path, file, line, thread_id, process_uuid, estimated_bytes
        FROM logs
        WHERE thread_id = ?
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare logs lookup.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, threadID, -1, SQLITE_TRANSIENT)

        var logs: [LogRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            logs.append(
                LogRecord(
                    ts: sqlite3_column_int64(statement, 0),
                    tsNanos: sqlite3_column_int64(statement, 1),
                    level: string(statement, 2),
                    target: string(statement, 3),
                    message: optionalString(statement, 4),
                    modulePath: optionalString(statement, 5),
                    file: optionalString(statement, 6),
                    line: optionalInt64(statement, 7),
                    threadID: optionalString(statement, 8),
                    processUUID: optionalString(statement, 9),
                    estimatedBytes: sqlite3_column_int64(statement, 10)
                )
            )
        }
        return logs
    }

    func replaceLogs(threadID: String, logs: [LogRecord]) throws {
        try execute(sql: "DELETE FROM logs WHERE thread_id = ?", bind: { statement in
            self.bind(text: threadID, to: statement, index: 1)
        }, failureMessage: "Could not clear thread logs before import.")

        let sql = """
        INSERT INTO logs (
            ts, ts_nanos, level, target, message, module_path, file, line, thread_id, process_uuid, estimated_bytes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for log in logs {
            try execute(sql: sql, bind: { statement in
                sqlite3_bind_int64(statement, 1, log.ts)
                sqlite3_bind_int64(statement, 2, log.tsNanos)
                self.bind(text: log.level, to: statement, index: 3)
                self.bind(text: log.target, to: statement, index: 4)
                self.bind(optionalText: log.message, to: statement, index: 5)
                self.bind(optionalText: log.modulePath, to: statement, index: 6)
                self.bind(optionalText: log.file, to: statement, index: 7)
                self.bind(optionalInt64: log.line, to: statement, index: 8)
                self.bind(optionalText: log.threadID ?? threadID, to: statement, index: 9)
                self.bind(optionalText: log.processUUID, to: statement, index: 10)
                sqlite3_bind_int64(statement, 11, log.estimatedBytes)
            }, failureMessage: "Could not write imported thread logs.")
        }
    }

    func insertSyntheticImportLog(threadID: String, timestamp: Int64) throws {
        let message = "Imported by QuotaBar"
        let processUUID = "quotabar-import:\(UUID().uuidString)"
        let sql = """
        INSERT INTO logs (
            ts, ts_nanos, level, target, message, module_path, file, line, thread_id, process_uuid, estimated_bytes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try execute(sql: sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, timestamp)
            sqlite3_bind_int64(statement, 2, 0)
            self.bind(text: "INFO", to: statement, index: 3)
            self.bind(text: "quotabar.import", to: statement, index: 4)
            self.bind(optionalText: message, to: statement, index: 5)
            self.bind(optionalText: nil, to: statement, index: 6)
            self.bind(optionalText: nil, to: statement, index: 7)
            self.bind(optionalInt64: nil, to: statement, index: 8)
            self.bind(optionalText: threadID, to: statement, index: 9)
            self.bind(optionalText: processUUID, to: statement, index: 10)
            sqlite3_bind_int64(statement, 11, Int64(message.utf8.count))
        }, failureMessage: "Could not write synthetic import log entry.")
    }

    private func execute(sql: String, bind: (OpaquePointer?) throws -> Void, failureMessage: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: failureMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError(message: failureMessage)
        }
    }

    private func bind(text: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func bind(optionalText: String?, to statement: OpaquePointer?, index: Int32) {
        guard let optionalText else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(text: optionalText, to: statement, index: index)
    }

    private func bind(optionalInt64: Int64?, to statement: OpaquePointer?, index: Int32) {
        guard let optionalInt64 else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, optionalInt64)
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return string(statement, index)
    }

    private func optionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func currentError(message: String) -> CodexAppServerError {
        let details = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error."
        return .requestFailed(message: "\(message) \(details)")
    }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            throw CodexAppServerError.requestFailed(message: "Could not open SQLite database at `\(url.path)`.")
        }
        handle = db
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func fetchLatestThreadID() throws -> String? {
        try querySingleValue(
            sql: "SELECT id FROM threads ORDER BY updated_at DESC LIMIT 1"
        )
    }

    func fetchThreads() throws -> [ThreadRecord] {
        let sql = """
        SELECT id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
               sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
               git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
               agent_role, memory_mode
        FROM threads
        ORDER BY updated_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare thread list lookup.")
        }
        defer { sqlite3_finalize(statement) }

        var threads: [ThreadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            threads.append(
                ThreadRecord(
                    id: string(statement, 0),
                    rolloutPath: string(statement, 1),
                    createdAt: sqlite3_column_int64(statement, 2),
                    updatedAt: sqlite3_column_int64(statement, 3),
                    source: string(statement, 4),
                    modelProvider: string(statement, 5),
                    cwd: string(statement, 6),
                    title: string(statement, 7),
                    sandboxPolicy: string(statement, 8),
                    approvalMode: string(statement, 9),
                    tokensUsed: sqlite3_column_int64(statement, 10),
                    hasUserEvent: sqlite3_column_int64(statement, 11),
                    archived: sqlite3_column_int64(statement, 12),
                    archivedAt: optionalInt64(statement, 13),
                    gitSha: optionalString(statement, 14),
                    gitBranch: optionalString(statement, 15),
                    gitOriginURL: optionalString(statement, 16),
                    cliVersion: string(statement, 17),
                    firstUserMessage: string(statement, 18),
                    agentNickname: optionalString(statement, 19),
                    agentRole: optionalString(statement, 20),
                    memoryMode: string(statement, 21)
                )
            )
        }
        return threads
    }

    func fetchThread(id: String) throws -> ThreadRecord {
        let sql = """
        SELECT id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
               sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
               git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
               agent_role, memory_mode
        FROM threads
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare thread lookup.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CodexAppServerError.requestFailed(message: "Could not find session `\(id)`.")
        }

        return ThreadRecord(
            id: string(statement, 0),
            rolloutPath: string(statement, 1),
            createdAt: sqlite3_column_int64(statement, 2),
            updatedAt: sqlite3_column_int64(statement, 3),
            source: string(statement, 4),
            modelProvider: string(statement, 5),
            cwd: string(statement, 6),
            title: string(statement, 7),
            sandboxPolicy: string(statement, 8),
            approvalMode: string(statement, 9),
            tokensUsed: sqlite3_column_int64(statement, 10),
            hasUserEvent: sqlite3_column_int64(statement, 11),
            archived: sqlite3_column_int64(statement, 12),
            archivedAt: optionalInt64(statement, 13),
            gitSha: optionalString(statement, 14),
            gitBranch: optionalString(statement, 15),
            gitOriginURL: optionalString(statement, 16),
            cliVersion: string(statement, 17),
            firstUserMessage: string(statement, 18),
            agentNickname: optionalString(statement, 19),
            agentRole: optionalString(statement, 20),
            memoryMode: string(statement, 21)
        )
    }

    func fetchDynamicTools(threadID: String) throws -> [DynamicToolRecord] {
        let sql = """
        SELECT position, name, description, input_schema
        FROM thread_dynamic_tools
        WHERE thread_id = ?
        ORDER BY position ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare dynamic tools lookup.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, threadID, -1, SQLITE_TRANSIENT)

        var tools: [DynamicToolRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tools.append(
                DynamicToolRecord(
                    position: sqlite3_column_int64(statement, 0),
                    name: string(statement, 1),
                    description: string(statement, 2),
                    inputSchema: string(statement, 3)
                )
            )
        }
        return tools
    }

    func upsert(thread: ThreadRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
            git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
            agent_role, memory_mode
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare thread upsert.")
        }
        defer { sqlite3_finalize(statement) }

        bind(text: thread.id, to: statement, index: 1)
        bind(text: thread.rolloutPath, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, thread.createdAt)
        sqlite3_bind_int64(statement, 4, thread.updatedAt)
        bind(text: thread.source, to: statement, index: 5)
        bind(text: thread.modelProvider, to: statement, index: 6)
        bind(text: thread.cwd, to: statement, index: 7)
        bind(text: thread.title, to: statement, index: 8)
        bind(text: thread.sandboxPolicy, to: statement, index: 9)
        bind(text: thread.approvalMode, to: statement, index: 10)
        sqlite3_bind_int64(statement, 11, thread.tokensUsed)
        sqlite3_bind_int64(statement, 12, thread.hasUserEvent)
        sqlite3_bind_int64(statement, 13, thread.archived)
        bind(optionalInt64: thread.archivedAt, to: statement, index: 14)
        bind(optionalText: thread.gitSha, to: statement, index: 15)
        bind(optionalText: thread.gitBranch, to: statement, index: 16)
        bind(optionalText: thread.gitOriginURL, to: statement, index: 17)
        bind(text: thread.cliVersion, to: statement, index: 18)
        bind(text: thread.firstUserMessage, to: statement, index: 19)
        bind(optionalText: thread.agentNickname, to: statement, index: 20)
        bind(optionalText: thread.agentRole, to: statement, index: 21)
        bind(text: thread.memoryMode, to: statement, index: 22)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError(message: "Could not write imported session thread.")
        }
    }

    func replaceDynamicTools(threadID: String, tools: [DynamicToolRecord]) throws {
        try execute(sql: "DELETE FROM thread_dynamic_tools WHERE thread_id = ?", bind: { statement in
            self.bind(text: threadID, to: statement, index: 1)
        })

        let sql = """
        INSERT INTO thread_dynamic_tools (thread_id, position, name, description, input_schema)
        VALUES (?, ?, ?, ?, ?)
        """
        for tool in tools {
            try execute(sql: sql, bind: { statement in
                self.bind(text: threadID, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, tool.position)
                self.bind(text: tool.name, to: statement, index: 3)
                self.bind(text: tool.description, to: statement, index: 4)
                self.bind(text: tool.inputSchema, to: statement, index: 5)
            })
        }
    }

    private func querySingleValue(sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare query.")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalString(statement, 0)
    }

    private func execute(sql: String, bind: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError(message: "Could not prepare database write.")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError(message: "Could not complete database write.")
        }
    }

    private func bind(text: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func bind(optionalText: String?, to statement: OpaquePointer?, index: Int32) {
        if let optionalText {
            sqlite3_bind_text(statement, index, optionalText, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(optionalInt64: Int64?, to statement: OpaquePointer?, index: Int32) {
        if let optionalInt64 {
            sqlite3_bind_int64(statement, index, optionalInt64)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func currentError(message: String) -> Error {
        let detail = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error."
        return CodexAppServerError.requestFailed(message: "\(message) \(detail)")
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        optionalString(statement, index) ?? ""
    }

    private func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func optionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }
}
