import Foundation

enum CodexBinaryLocator {
    nonisolated static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = environment["CODEX_CLI_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        if let path = environment["PATH"],
           let hit = findInPATH(path, fileManager: fileManager) {
            return hit
        }

        if let shellHit = lookupFromLoginShell(shell: environment["SHELL"], fileManager: fileManager) {
            return shellHit
        }

        for candidate in commonCandidates(fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    nonisolated static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL
    ) -> [String: String] {
        var environment = base
        environment["CODEX_HOME"] = codexHome.path
        environment["TERM"] = "xterm-256color"

        if let binary = resolve(environment: base) {
            let binaryDirectory = URL(fileURLWithPath: binary).deletingLastPathComponent().path
            let currentPath = base["PATH"] ?? ""
            let merged = ([binaryDirectory] + currentPath.split(separator: ":").map(String.init))
                .filter { !$0.isEmpty }
            environment["PATH"] = dedupe(merged).joined(separator: ":")
        }

        return environment
    }

    nonisolated private static func findInPATH(_ path: String, fileManager: FileManager) -> String? {
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func lookupFromLoginShell(shell: String?, fileManager: FileManager) -> String? {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "command -v codex"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let text, text.hasPrefix("/"), fileManager.isExecutableFile(atPath: text) else {
            return nil
        }
        return text
    }

    nonisolated private static func commonCandidates(fileManager: FileManager) -> [String] {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]

        let home = fileManager.homeDirectoryForCurrentUser
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) {
            let sorted = versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            candidates.append(contentsOf: sorted.map { $0.appendingPathComponent("bin/codex").path })
        }

        return candidates
    }

    nonisolated private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard seen.insert(item).inserted else { return nil }
            return item
        }
    }
}
