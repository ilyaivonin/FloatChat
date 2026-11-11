import Foundation

/// Finds or installs a `llama-server` binary.
///
/// Strategy:
/// 1. Look for an already installed binary (managed folder, Homebrew, common build paths).
/// 2. Download the latest official macOS build of llama.cpp from GitHub and unpack it
///    into `~/Library/Application Support/FloatChat/llama.cpp/current`.
/// 3. If GitHub is unavailable, fall back to `brew install llama.cpp` when Homebrew exists.
@MainActor
final class LlamaInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case verifying
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var lines: [String] = []
    @Published private(set) var lastMessage = ""

    /// Called on the main actor with the path of a usable `llama-server`.
    var onInstalled: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var lineLimit = 80
    private var targetCurrentDir = LlamaInstaller.currentDir

    private var targetServer: URL {
        targetCurrentDir.appendingPathComponent("llama-server")
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing, .verifying:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .checking:
            return L10n.t("Ищу llama-server…", "Looking for llama-server…")
        case .downloading:
            return progress.map { L10n.t("Скачивание llama.cpp — \(Int($0 * 100))%", "Downloading llama.cpp — \(Int($0 * 100))%") } ?? L10n.t("Скачивание llama.cpp…", "Downloading llama.cpp…")
        case .installing:
            return L10n.t("Установка llama.cpp…", "Installing llama.cpp…")
        case .verifying:
            return L10n.t("Проверяю, что llama-server запускается…", "Checking that llama-server starts…")
        case .done:
            return lastMessage.isEmpty ? L10n.t("Готово", "Done") : lastMessage
        case .failed(let message):
            return message
        }
    }

    // MARK: - Install locations

    nonisolated static var defaultParentDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("FloatChat", isDirectory: true)
    }

    nonisolated static var installRoot: URL {
        defaultParentDir.appendingPathComponent("llama.cpp", isDirectory: true)
    }

    nonisolated static var currentDir: URL {
        installRoot.appendingPathComponent("current", isDirectory: true)
    }

    nonisolated static var managedServer: URL {
        currentDir.appendingPathComponent("llama-server")
    }

    /// Checks well-known locations for an executable `llama-server`.
    nonisolated static func findInstalledServer() -> String? {
        for path in candidateServerPaths() where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated private static func candidateServerPaths() -> [String] {
        var paths = [managedServer.path]

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = envPath.split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/llama.cpp/bin",
            "/usr/local/opt/llama.cpp/bin"
        ]
        paths += directories.map {
            URL(fileURLWithPath: $0).appendingPathComponent("llama-server").path
        }

        paths += [
            "~/llama.cpp/build/bin/llama-server",
            "~/llama.cpp/build/bin/Release/llama-server",
            "~/llama.cpp-metal/build/bin/llama-server"
        ].map { NSString(string: $0).expandingTildeInPath }

        return paths
    }

    // MARK: - Public API

    func install() {
        start(forceDownload: false, destinationRoot: Self.installRoot, message: nil)
    }

    /// Downloads the latest build without looking at existing installations.
    /// The binary is placed into `<folder>/llama.cpp/current/llama-server`.
    func reinstall(into folder: URL) {
        let root = folder.appendingPathComponent("llama.cpp", isDirectory: true)
        start(forceDownload: true, destinationRoot: root, message: L10n.t("llama-server переустановлен", "llama-server reinstalled"))
    }

    private func start(forceDownload: Bool, destinationRoot: URL, message: String?) {
        guard task == nil else { return }

        targetCurrentDir = destinationRoot.appendingPathComponent("current", isDirectory: true)
        phase = .checking
        progress = nil
        lines.removeAll()
        lastMessage = ""

        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(
                forceDownload: forceDownload,
                destinationRoot: destinationRoot,
                successMessage: message
            )
            self.task = nil
        }
    }

    // MARK: - Workflow

    private func perform(forceDownload: Bool, destinationRoot: URL, successMessage: String?) async {
        if !forceDownload, let existing = Self.findInstalledServer() {
            log(L10n.t("llama-server уже установлен: \(existing)", "llama-server is already installed: \(existing)"))
            finish(with: existing, message: L10n.t("llama-server найден", "llama-server found"))
            return
        }

        do {
            let url = try await resolveLatestDownloadURL()
            log(L10n.t("Сборка: \(url.deletingLastPathComponent().lastPathComponent) (\(url.lastPathComponent))", "Build: \(url.deletingLastPathComponent().lastPathComponent) (\(url.lastPathComponent))"))

            phase = .downloading
            let archive = try await downloadArchive(from: url)

            phase = .installing
            try await unpack(archive: archive, root: destinationRoot)

            phase = .verifying
            let version = try await verifyInstallation()
            if !version.isEmpty {
                log(version)
            }

            finish(with: targetServer.path, message: successMessage ?? L10n.t("llama-server установлен", "llama-server installed"))
        } catch {
            log(L10n.t("Скачать официальную сборку не удалось: \(error.localizedDescription)", "Could not download the official build: \(error.localizedDescription)"))

            if forceDownload {
                let message = L10n.t("Не удалось переустановить llama-server: \(error.localizedDescription)", "Could not reinstall llama-server: \(error.localizedDescription)")
                log(message)
                phase = .failed(message)
                lastMessage = message
                return
            }

            do {
                let path = try await installWithHomebrew()
                finish(with: path, message: L10n.t("llama-server установлен через Homebrew", "llama-server installed via Homebrew"))
            } catch {
                let message = L10n.t("Не удалось установить llama-server: \(error.localizedDescription)", "Could not install llama-server: \(error.localizedDescription)")
                log(message)
                phase = .failed(message)
                lastMessage = message
            }
        }
    }

    private func finish(with path: String, message: String) {
        progress = nil
        lastMessage = message
        phase = .done
        onInstalled?(path)
    }

    private func log(_ line: String) {
        lines.append(line)
        if lines.count > lineLimit {
            lines.removeFirst(lines.count - lineLimit)
        }
    }

    // MARK: - GitHub download

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private func resolveLatestDownloadURL() async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FloatChat", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw InstallError.message(L10n.t("GitHub не ответил", "GitHub did not respond"))
        }
        guard http.statusCode == 200 else {
            throw InstallError.message(L10n.t("GitHub ответил кодом \(http.statusCode)", "GitHub returned code \(http.statusCode)"))
        }

        let releases: [Release]
        do {
            releases = try JSONDecoder().decode([Release].self, from: data)
        } catch {
            throw InstallError.message(L10n.t("Не удалось разобрать ответ GitHub", "Could not parse the GitHub response"))
        }

        let arch = Self.isAppleSilicon ? "arm64" : "x64"
        let suffix = "-bin-macos-\(arch).tar.gz"

        for release in releases {
            if let asset = release.assets.first(where: {
                $0.name.hasPrefix("llama-") && $0.name.hasSuffix(suffix)
            }) {
                log(L10n.t("Последняя сборка: \(release.tagName) (macOS \(arch))", "Latest build: \(release.tagName) (macOS \(arch))"))
                return asset.browserDownloadURL
            }
        }

        throw InstallError.message(L10n.t("Не нашёл сборку llama.cpp для macOS (\(arch))", "No llama.cpp build found for macOS (\(arch))"))
    }

    nonisolated private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private func downloadArchive(from url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatChat-\(UUID().uuidString)-\(url.lastPathComponent)")

        log(L10n.t("Скачиваю \(url.lastPathComponent)…", "Downloading \(url.lastPathComponent)…"))

        let delegate = DownloadDelegate(destination: destination) { [weak self] fraction in
            Task { @MainActor in
                self?.progress = fraction
            }
        }
        let archive = try await delegate.start(url: url)
        progress = nil

        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log(String(format: L10n.t("Скачано: %.1f МБ", "Downloaded: %.1f MB"), Double(size) / 1_048_576))
        return archive
    }

    private func unpack(archive: URL, root: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("FloatChat-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: archive)
        }

        let tar = try await Self.runProcess("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        guard tar.status == 0 else {
            throw InstallError.message(L10n.t("Не удалось распаковать архив: \(Self.tail(tar.output, 300))", "Could not unpack the archive: \(Self.tail(tar.output, 300))"))
        }

        guard let server = Self.findServerBinary(under: staging) else {
            throw InstallError.message(L10n.t("В архиве нет llama-server", "The archive does not contain llama-server"))
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: targetCurrentDir.path) {
            try fm.removeItem(at: targetCurrentDir)
        }
        try fm.moveItem(at: server.deletingLastPathComponent(), to: targetCurrentDir)

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetServer.path)
        _ = try? await Self.runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", targetCurrentDir.path])

        guard fm.isExecutableFile(atPath: targetServer.path) else {
            throw InstallError.message(L10n.t("llama-server не запускается: нет прав на выполнение", "llama-server is not executable"))
        }

        log(L10n.t("Установлено в \(targetCurrentDir.path)", "Installed to \(targetCurrentDir.path)"))
    }

    nonisolated private static func findServerBinary(under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == "llama-server" {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func verifyInstallation() async throws -> String {
        let result = try await Self.runProcess(
            targetServer.path,
            ["--version"],
            currentDirectory: targetCurrentDir,
            timeout: 30
        )

        guard result.status == 0 else {
            throw InstallError.message(L10n.t("llama-server завершился с ошибкой: \(Self.tail(result.output, 300))", "llama-server exited with an error: \(Self.tail(result.output, 300))"))
        }

        return result.output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.lowercased().hasPrefix("version") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    nonisolated private static func tail(_ text: String, _ count: Int) -> String {
        text.count > count ? String(text.suffix(count)) : text
    }

    // MARK: - Homebrew fallback

    private func installWithHomebrew() async throws -> String {
        guard let brew = Self.findBrew() else {
            throw InstallError.message(L10n.t("Homebrew не найден", "Homebrew not found"))
        }

        log(L10n.t("Пробую Homebrew: brew install llama.cpp (может занять несколько минут)…", "Trying Homebrew: brew install llama.cpp (may take a few minutes)…"))

        let environment = Self.environment(adding: URL(fileURLWithPath: brew).deletingLastPathComponent().path)
        let install = try await Self.runProcess(
            brew,
            ["install", "llama.cpp"],
            environment: environment,
            timeout: 900
        )
        guard install.status == 0 else {
            throw InstallError.message(L10n.t("brew install завершился с ошибкой: \(Self.tail(install.output, 500))", "brew install failed: \(Self.tail(install.output, 500))"))
        }

        let prefix = try await Self.runProcess(
            brew,
            ["--prefix", "llama.cpp"],
            environment: environment,
            timeout: 60
        )
        guard prefix.status == 0 else {
            throw InstallError.message(L10n.t("Не удалось определить путь llama.cpp в Homebrew", "Could not determine the llama.cpp path in Homebrew"))
        }

        let server = prefix.output.trimmingCharacters(in: .whitespacesAndNewlines) + "/bin/llama-server"
        guard FileManager.default.isExecutableFile(atPath: server) else {
            throw InstallError.message(L10n.t("Homebrew не поставил llama-server", "Homebrew did not install llama-server"))
        }

        log("Homebrew: \(server)")
        return server
    }

    nonisolated private static func findBrew() -> String? {
        let fixed = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let path = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in envPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("brew").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func environment(adding directory: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        path += ":\(directory)"
        path += ":/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = path
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    nonisolated private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment {
                    process.environment = environment
                }
                if let currentDirectory {
                    process.currentDirectoryURL = currentDirectory
                }

                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FloatChat-process-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: outputURL) else {
                    continuation.resume(throwing: InstallError.message(L10n.t("Не удалось создать временный файл", "Could not create a temporary file")))
                    return
                }

                process.standardOutput = handle
                process.standardError = handle

                defer {
                    try? FileManager.default.removeItem(at: outputURL)
                }

                var timeoutItem: DispatchWorkItem?

                do {
                    try process.run()

                    if let timeout {
                        let item = DispatchWorkItem {
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                        timeoutItem = item
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    }

                    process.waitUntilExit()
                    timeoutItem?.cancel()
                    try? handle.close()

                    let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                    continuation.resume(
                        returning: ProcessResult(status: process.terminationStatus, output: output)
                    )
                } catch {
                    timeoutItem?.cancel()
                    try? handle.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum InstallError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 900

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.setValue("FloatChat", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(InstallError.message(L10n.t("Сервер вернул код \(http.statusCode)", "Server returned code \(http.statusCode)"))))
            return
        }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        continuation.resume(with: result)
    }
}
