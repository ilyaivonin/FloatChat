import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings
    @Published var status: ServerStatus = .stopped
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isGenerating = false
    @Published var tokensPerSecond: Double?
    /// Prompt-processing progress (0–100) from llama-server print_timing lines.
    @Published var promptProgress: Double?

    /// Estimated tokens used in the current context (rough: 1 token ≈ 4 chars).
    var contextUsed: Int {
        messages.reduce(0) { $0 + max(1, ($1.content.count + $1.reasoning.count) / 4) }
    }
    @Published var log = ""
    @Published var errorText: String?
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var attachmentError: String?

    /// Folder for logs and chat history: ~/Documents/FloatChat/
    static let logsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("FloatChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Server-side logs (llama-server output, startup/restart events).
    let logFileURL: URL = AppState.logsDir.appendingPathComponent("FloatChat.log")

    /// Conversation history: user / ApplicationName lines.
    let chatHistoryFileURL: URL = AppState.logsDir.appendingPathComponent("ChatHistory.log")

    /// llama-server warns "srv stop: cancel task" when a client aborts a task;
    /// it is harmless and should not show up in the UI or the log file.
    private static func isCancelTaskNoise(_ line: String) -> Bool {
        line.contains("stop: cancel task")
    }

    private static func withoutCancelTaskNoise(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !isCancelTaskNoise($0) }
            .joined(separator: "\n")
    }

    private func appendLog(_ text: String) {
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(text)\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                return
            }
        }
        try? data.write(to: logFileURL)
    }

    @Published var lightMode: Bool {
        didSet {
            UserDefaults.standard.set(lightMode, forKey: WindowSupport.lightModeKey)
            WindowSupport.applyAppearance(lightMode: lightMode)
        }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.key)
            AppMenu.install(appName: displayName, language: language)
            settingsWindow?.title = L10n.t("Настройки — ", "Settings — ") + displayName
        }
    }

    let installer = LlamaInstaller()

    private let server = LlamaRuntime.server
    private let client = ChatClient()
    private var generateTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var settingsHideObserver: NSObjectProtocol?

    init() {
        settings = SettingsStore.load()
        lightMode = UserDefaults.standard.bool(forKey: WindowSupport.lightModeKey)
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: L10n.key) ?? "ru") ?? .ru
        server.onLog = { [weak self] text in
            Task { @MainActor in
                self?.log = AppState.withoutCancelTaskNoise(text)
            }
        }
        server.onLogLine = { [weak self] line in
            Task { @MainActor in
                guard !AppState.isCancelTaskNoise(line) else { return }
                let trimmed = line.hasSuffix("\n") ? String(line.dropLast()) : line
                self?.appendLog(trimmed)
            }
        }
        server.onTiming = { [weak self] event in
            Task { @MainActor in
                switch event.phase {
                case .prompt:
                    self?.promptProgress = event.progress
                    if let tps = event.tokensPerSecond {
                        self?.tokensPerSecond = tps
                    }
                case .generation:
                    self?.promptProgress = nil
                    self?.tokensPerSecond = event.tokensPerSecond
                }
            }
        }
        installer.onInstalled = { [weak self] path in
            self?.adoptInstalledServer(path)
        }
        server.onUnexpectedExit = { [weak self] code in
            Task { @MainActor in
                self?.handleUnexpectedExit(code)
            }
        }
        detectServerIfNeeded()
    }

    private func handleUnexpectedExit(_ code: Int32) {
        guard status == .ready || status == .starting else { return }
        let message = L10n.t(
            "llama-server остановлен (код \(code))",
            "llama-server stopped (code \(code))"
        )
        status = .failed(message)
        errorText = message
    }

    /// If the configured path is gone, pick up a llama-server found in a known location.
    func detectServerIfNeeded() {
        guard !FileManager.default.isExecutableFile(atPath: settings.serverPath) else { return }
        guard let found = LlamaInstaller.findInstalledServer() else { return }
        adoptInstalledServer(found)
    }

    func adoptInstalledServer(_ path: String) {
        guard settings.serverPath != path else { return }
        var next = settings
        next.serverPath = path
        settings = next
        SettingsStore.save(next)
    }

    var displayName: String { settings.displayName }

    /// Selects a downloaded model and persists the choice right away.
    func selectModel(at url: URL) {
        var next = settings
        next.modelPath = url.path
        settings = next
        SettingsStore.save(next)
    }

    var alwaysOnTop: Bool {
        get { settings.alwaysOnTop }
        set {
            var next = settings
            next.alwaysOnTop = newValue
            settings = next
            SettingsStore.save(next)
            WindowSupport.applyAlwaysOnTop(newValue)
        }
    }

    var opacity: Double {
        get { settings.opacity }
        set {
            var next = settings
            next.opacity = min(max(newValue, 0.3), 1.0)
            settings = next
            SettingsStore.save(next)
            WindowSupport.applyOpacity(next.opacity)
        }
    }

    var appName: String {
        get { settings.appName }
        set {
            var next = settings
            next.appName = newValue
            settings = next
            SettingsStore.save(next)
            WindowSupport.applyTitle(next.displayName)
            settingsWindow?.title = L10n.t("Настройки — ", "Settings — ") + next.displayName
            AppMenu.updateAppName(next.displayName)
        }
    }

    func openSettings() {
        if let window = settingsWindow {
            WindowSupport.applyOpacity(settings.opacity, window: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(onClose: { [weak self] in self?.closeSettings() })
            .environmentObject(self)
            .environmentObject(installer)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = WindowSupport.settingsWindowID
        window.title = L10n.t("Настройки — ", "Settings — ") + displayName
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: 520)
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = false
        window.level = settings.alwaysOnTop ? .floating : .normal
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        WindowSupport.applyOpacity(settings.opacity, window: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
        settingsHideObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            // A file picker or a sheet keeps the settings window on screen.
            guard NSApp.modalWindow == nil, window.attachedSheet == nil else { return }
            guard window.isVisible, !window.isMiniaturized else { return }
            window.orderOut(nil)
        }
    }

    func closeSettings() {
        settingsWindow?.close()
    }

    func startServer() {
        appendLog(L10n.t("Запуск сервера…", "Starting server…"))
        startTask?.cancel()
        guard !settings.modelPath.isEmpty else {
            let missingModel = L10n.t("Выберите модель .gguf в настройках", "Choose a .gguf model in settings")
            status = .failed(missingModel)
            errorText = missingModel
            return
        }
        status = .starting
        errorText = nil
        startTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do {
                if await self.server.isHealthy(self.settings) {
                    guard !Task.isCancelled else { return }
                    self.status = .ready
                    WindowSupport.applyAlwaysOnTop(self.settings.alwaysOnTop)
                    return
                }
                guard !Task.isCancelled else { return }
                try self.server.start(settings: self.settings)
                try await self.server.waitUntilReady(settings: self.settings)
                guard !Task.isCancelled else { return }
                self.status = .ready
                WindowSupport.applyAlwaysOnTop(self.settings.alwaysOnTop)
            } catch is CancellationError {
                return
            } catch {
                self.failStart(with: error)
            }
        }
    }

    private func failStart(with error: Error) {
        let detailed = friendlyError(error)
        errorText = detailed
        let firstLine = detailed.split(separator: "\n").first.map(String.init) ?? detailed
        status = .failed(firstLine.count > 120 ? String(firstLine.prefix(117)) + "…" : firstLine)
    }

    /// Turns llama-server's English stderr tail into an actionable message.
    private func friendlyError(_ error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()

        if lower.contains("address already in use")
            || lower.contains("couldn't bind")
            || lower.contains("failed to bind")
            || lower.contains("bind:") {
            return L10n.t(
                "Порт \(settings.port) занят другим процессом. Закройте его или укажите другой порт.",
                "Port \(settings.port) is busy. Close the other process or choose another port."
            )
        }
        if lower.contains("error loading model")
            || lower.contains("failed to load model")
            || lower.contains("invalid model") {
            return L10n.t(
                "Не удалось загрузить модель:\n\(settings.modelPath)\n\n\(text)",
                "Failed to load the model:\n\(settings.modelPath)\n\n\(text)"
            )
        }
        return text
    }

    /// Full restart: the old llama-server process is stopped and a new one is started,
    /// so a changed model / context / port is actually applied.
    func restartServer() {
        appendLog(L10n.t("Перезапуск сервера…", "Restarting server…"))
        generateTask?.cancel()
        generateTask = nil
        startTask?.cancel()
        isGenerating = false
        tokensPerSecond = nil
        SettingsStore.save(settings)
        guard !settings.modelPath.isEmpty else {
            let missingModel = L10n.t("Выберите модель .gguf в настройках", "Choose a .gguf model in settings")
            status = .failed(missingModel)
            errorText = missingModel
            return
        }
        status = .starting
        errorText = nil
        log = ""

        startTask = Task { [weak self] in
            guard let self else { return }
            await self.server.stopAndWait()
            guard !Task.isCancelled else { return }
            do {
                try self.server.start(settings: self.settings)
                try await self.server.waitUntilReady(settings: self.settings)
                guard !Task.isCancelled else { return }
                self.status = .ready
                self.errorText = nil
                WindowSupport.applyAlwaysOnTop(self.settings.alwaysOnTop)
            } catch is CancellationError {
                return
            } catch {
                self.failStart(with: error)
            }
        }
    }

    func stopServer() {
        generateTask?.cancel()
        startTask?.cancel()
        server.stop()
        status = .stopped
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, status == .ready, !isGenerating else { return }
        draft = ""
        pendingAttachments = []
        attachmentError = nil
        tokensPerSecond = nil
        promptProgress = nil
        let content = text.isEmpty ? L10n.t("Посмотри вложенные файлы.", "Look at the attached files.") : text
        messages.append(ChatMessage(role: .user, content: content, attachments: attachments))
        appendConversation(role: "user", text: content)
        messages.append(ChatMessage(role: .assistant, content: "", reasoning: ""))
        isGenerating = true
        tokensPerSecond = nil

        let history = messages.dropLast()
        let assistantID = messages.last!.id

        generateTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.stream(settings: self.settings, history: Array(history)) { content, reasoning, speed in
                    if let speed {
                        self.tokensPerSecond = speed
                    }
                    guard !content.isEmpty || !reasoning.isEmpty else { return }
                    guard let index = self.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                    self.messages[index].content += content
                    self.messages[index].reasoning += reasoning
                }
            } catch is CancellationError {
                // keep partial reply
            } catch {
                if case ChatError.http(400) = error {
                    self.clearChat()
                    self.restartServer()
                    return
                }
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    if self.messages[index].content.isEmpty {
                        self.messages[index].content = "⚠️ \(error.localizedDescription)"
                    }
                }
            }
            self.isGenerating = false
            if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                let assistantText = self.messages[index].content
                if !assistantText.isEmpty {
                    self.appendConversation(role: self.displayName, text: assistantText)
                }
            }
            if let last = self.messages.last, last.role == .assistant, last.content.isEmpty, last.reasoning.isEmpty {
                self.messages.removeLast()
            }
        }
    }

    func stopGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
    }

    // MARK: - Attachments

    func addAttachments(_ urls: [URL]) {
        attachmentError = nil
        var budget = AttachmentLoader.maxTotalCharacters
            - pendingAttachments.reduce(0) { $0 + $1.text.count }

        for url in urls {
            guard budget > 0 else {
                attachmentError = L10n.t(
                    "Достигнут лимит текста вложений (\(AttachmentLoader.maxTotalCharacters) символов)",
                    "Attachment text limit reached (\(AttachmentLoader.maxTotalCharacters) characters)"
                )
                break
            }
            do {
                let limit = min(budget, AttachmentLoader.maxCharactersPerFile)
                let attachment = try AttachmentLoader.load(url: url, maxCharacters: limit)
                pendingAttachments.append(attachment)
                budget -= attachment.text.count
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        attachmentError = nil
    }

    /// Appends one line to the conversation history log.
    private func appendConversation(role: String, text: String) {
        let line = "\(role) - \(text)\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        if FileManager.default.fileExists(atPath: chatHistoryFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: chatHistoryFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                return
            }
        }
        try? data.write(to: chatHistoryFileURL)
    }

    func clearChat() {
        stopGeneration()
        messages.removeAll()
    }
}
