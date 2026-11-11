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
    @Published var log = ""
    @Published var errorText: String?
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var attachmentError: String?
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

    init() {
        settings = SettingsStore.load()
        lightMode = UserDefaults.standard.bool(forKey: WindowSupport.lightModeKey)
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: L10n.key) ?? "ru") ?? .ru
        server.onLog = { [weak self] text in
            Task { @MainActor in
                self?.log = text
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
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    func closeSettings() {
        settingsWindow?.close()
    }

    func startServer() {
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
        let content = text.isEmpty ? L10n.t("Посмотри вложенные файлы.", "Look at the attached files.") : text
        messages.append(ChatMessage(role: .user, content: content, attachments: attachments))
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
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    if self.messages[index].content.isEmpty {
                        self.messages[index].content = "⚠️ \(error.localizedDescription)"
                    }
                }
            }
            self.isGenerating = false
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

    func clearChat() {
        stopGeneration()
        messages.removeAll()
    }
}
