import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @State private var stickToBottom = true
    @State private var isDropTargeted = false
    @State private var showHowto = false

    private static let bottomAnchorID = "transcript-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            transcript
            Divider().opacity(0.25)
            composer
        }
        .background(Palette.bg.ignoresSafeArea())
        .background(WindowConfigurator(alwaysOnTop: state.alwaysOnTop, title: state.displayName, opacity: state.opacity))
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .sheet(isPresented: $showHowto) {
            HowtoView()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            acceptDroppedFiles(providers)
        }
        .onAppear {
            WindowSupport.applyAlwaysOnTop(state.alwaysOnTop)
            if !UserDefaults.standard.bool(forKey: "floatchat.howtoShown") {
                showHowto = true
            }
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.accent.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .overlay(alignment: .bottom) {
                Label(
                    L10n.t("Отпустите файл, чтобы прикрепить", "Drop files to attach"),
                    systemImage: "paperclip"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.input, in: Capsule())
                .padding(.bottom, 14)
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.enumerated().filter {
            $0.element.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        var urls: [Int: URL] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, provider) in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = nil
                }
                if let url {
                    lock.lock()
                    urls[index] = url.standardizedFileURL
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            let ordered = fileProviders.compactMap { urls[$0.offset] }
            let files = ordered.filter { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return !isDirectory && AttachmentLoader.isReadable(url)
            }
            Task { @MainActor in
                guard !files.isEmpty else {
                    state.attachmentError = L10n.t(
                        "Можно перетащить только текстовые файлы (PDF, TXT, RTF, JSON, HTML…)",
                        "Only text files can be dropped (PDF, TXT, RTF, JSON, HTML…)"
                    )
                    return
                }
                state.addAttachments(files)
            }
        }

        return true
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(state.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(statusCaption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Text(speedCaption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Text(contextCaption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer()
            if case .failed = state.status {
                headerButton(system: "arrow.clockwise", help: L10n.t("Перезапустить llama-server", "Restart llama-server")) {
                    state.restartServer()
                }
            }
            headerButton(
                system: state.lightMode ? "lightbulb.fill" : "lightbulb",
                help: state.lightMode ? L10n.t("Тёмная тема", "Dark theme") : L10n.t("Светлая тема", "Light theme")
            ) {
                state.lightMode.toggle()
            }
            headerButton(system: state.alwaysOnTop ? "pin.fill" : "pin", help: L10n.t("Поверх всех окон", "Always on top")) {
                state.alwaysOnTop.toggle()
            }
            headerButton(system: "gearshape", help: L10n.t("Настройки llama.cpp", "llama.cpp settings")) {
                state.openSettings()
            }
            headerButton(system: "trash.fill", help: L10n.t("Очистить чат", "Clear chat")) {
                state.clearChat()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Palette.header)
    }

    private var statusCaption: String {
        switch state.status {
        case .failed(let message):
            return message.replacingOccurrences(of: "\n", with: " ")
        default:
            return state.status.label
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .shadow(color: statusColor.opacity(0.8), radius: state.status == .ready ? 4 : 0)
            .padding(.trailing, 2)
    }

    private var statusColor: Color {
        switch state.status {
        case .ready: return Palette.online
        case .starting: return Palette.warn
        case .failed: return Palette.danger
        case .stopped: return Palette.muted
        }
    }

    /// Context usage: estimated tokens used / context window size.
    private var contextCaption: String {
        let total = state.settings.contextSize
        let used = state.contextUsed
        return "\(L10n.contextUsed(used, total))"
    }

    /// Real-time speed / progress from llama-server stderr (print_timing / n_gen).
    private var speedCaption: String {
        if let progress = state.promptProgress {
            let tps = state.tokensPerSecond.map { String(format: "%.0f", $0) } ?? "—"
            return L10n.t(
                "запрос \(Int(progress))% • \(tps) t/s",
                "prompt \(Int(progress))% • \(tps) t/s"
            )
        }
        if let tps = state.tokensPerSecond {
            return String(format: "%.0f t/s", tps)
        }
        if state.isGenerating {
            return L10n.t("считаю скорость…", "measuring…")
        }
        return "— t/s"
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if state.messages.isEmpty {
                            emptyState
                        }
                        ForEach(state.messages) { message in
                            MessageBubble(message: message, pulsing: state.isGenerating && message.id == state.messages.last?.id)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        ScrollPositionObserver { nearBottom in
                            // While a reply streams in, the content grows under the
                            // scroll view; ignore those transient "not at bottom"
                            // readings so the transcript keeps following the model.
                            guard !state.isGenerating else { return }
                            if nearBottom != stickToBottom {
                                stickToBottom = nearBottom
                            }
                        }
                    )
                }
                .scrollIndicators(.visible)

                if !stickToBottom && !state.messages.isEmpty {
                    Button {
                        stickToBottom = true
                        scrollToBottom(proxy, animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.text)
                            .frame(width: 26, height: 26)
                            .background(Palette.input, in: Circle())
                            .overlay(Circle().stroke(Palette.muted.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .help(L10n.t("Прокрутить вниз", "Scroll to bottom"))
                }
            }
            .onChange(of: state.messages.last?.content) { _, _ in
                if state.isGenerating {
                    stickToBottom = true
                }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: state.messages.last?.reasoning) { _, _ in
                // "Thinking" text grows before the answer starts; follow it too.
                if state.isGenerating {
                    stickToBottom = true
                }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: state.messages.count) { _, _ in
                stickToBottom = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: state.isGenerating) { _, isGenerating in
                if isGenerating {
                    stickToBottom = true
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L10n.t("ICQ, только с моделью", "ICQ, but with a model"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(L10n.t("Напиши сообщение — llama-server уже крутится локально.", "Type a message — llama-server is already running locally."))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.pendingAttachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if let error = state.attachmentError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    chooseAttachments()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.status == .ready ? Palette.text : Palette.muted)
                        .frame(width: 28, height: 28)
                        .background(Palette.input, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(state.status != .ready)
                .help(L10n.t("Прикрепить файл: PDF, текст, RTF, JSON…", "Attach a file: PDF, text, RTF, JSON…"))

                MessageEditor(
                    text: $state.draft,
                    isEnabled: state.status == .ready,
                    placeholder: L10n.t("Сообщение", "Message"),
                    onSend: state.send
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if state.isGenerating {
                        state.stopGeneration()
                    } else {
                        state.send()
                    }
                } label: {
                    Image(systemName: state.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 28, height: 28)
                        .background(state.status == .ready ? Palette.accent : Palette.muted, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(state.status != .ready || (!state.isGenerating && state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.pendingAttachments.isEmpty))
                .help(state.isGenerating ? L10n.t("Остановить", "Stop") : L10n.t("Отправить", "Send"))
            }
        }
        .padding(10)
        .background(Palette.header)
    }

    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
            Text(attachment.caption)
                .font(.system(size: 10))
                .lineLimit(1)
            Button {
                state.removeAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Palette.input, in: Capsule())
        .help(L10n.t("\(attachment.name) — \(attachment.text.count) символов текста", "\(attachment.name) — \(attachment.text.count) characters of text"))
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .plainText, .text, .rtf, .json, .html, .xml, .commaSeparatedText]
        panel.allowsOtherFileTypes = true
        panel.message = L10n.t("Прикрепить файлы: PDF, текст, RTF, JSON…", "Attach files: PDF, text, RTF, JSON…")
        panel.prompt = L10n.t("Прикрепить", "Attach")

        if panel.runModal() == .OK {
            state.addAttachments(panel.urls)
        }
    }

    private func headerButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 24, height: 24)
                .background(Palette.input, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard stickToBottom || animated else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

/// Tracks whether the transcript is scrolled to the bottom, so streaming
/// does not yank the view away while the user is reading older messages.
private struct ScrollPositionObserver: NSViewRepresentable {
    var onNearBottomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onNearBottomChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        DispatchQueue.main.async {
            context.coordinator.attach()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onNearBottomChange
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var onChange: (Bool) -> Void

        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastNearBottom = true

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        func attach() {
            guard scrollView == nil, let scrollView = hostView?.enclosingScrollView else { return }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.evaluate()
            }
            evaluate()
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            scrollView = nil
        }

        private func evaluate() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let distance = document.frame.height - (visible.origin.y + visible.height)
            let nearBottom = distance <= 32 || document.frame.height <= visible.height
            guard nearBottom != lastNearBottom else { return }
            lastNearBottom = nearBottom
            onChange(nearBottom)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var pulsing: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 36) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                Text(attachment.caption)
                                    .lineLimit(1)
                                Text(L10n.t("· \(attachment.text.count) симв.", "· \(attachment.text.count) chars"))
                                    .foregroundStyle(Palette.muted)
                            }
                            .font(.system(size: 10))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Palette.header.opacity(0.75), in: Capsule())
                        }
                    }
                }
                if !message.reasoning.isEmpty {
                    Text(message.reasoning)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .italic()
                        .textSelection(.enabled)
                }
                if message.content.isEmpty && pulsing {
                    TypingDots()
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(message.role == .user ? Palette.userBubble : Palette.assistantBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 36) }
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.28)) { timeline in
            let current = Int(timeline.date.timeIntervalSinceReferenceDate * 3.6) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 5, height: 5)
                        .opacity(current == index ? 1 : 0.35)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var installer: LlamaInstaller
    var onClose: () -> Void

    @StateObject private var modelDownloader = ModelDownloader()
    @State private var showDownloader = false
    @State private var showInfo = false
    @State private var showAdvanced = false

    private var serverExists: Bool {
        FileManager.default.isExecutableFile(atPath: state.settings.serverPath)
    }

    private var modelExists: Bool {
        !state.settings.modelPath.isEmpty
            && FileManager.default.fileExists(atPath: state.settings.modelPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                appHeader
                field(L10n.t("Название приложения", "Application name"), text: Binding(
                    get: { state.appName },
                    set: { state.appName = $0 }
                ))
                HStack(spacing: 12) {
                    Button(L10n.dialogHistory) {
                        // Reveal ChatHistory.log (falls back to its folder if it
                        // does not exist yet).
                        if FileManager.default.fileExists(atPath: state.chatHistoryFileURL.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([state.chatHistoryFileURL])
                        } else {
                            NSWorkspace.shared.open(state.chatHistoryFileURL.deletingLastPathComponent())
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Открыть файл истории переписки", "Open the conversation history file"))
                    Button(L10n.openLogsFolder) {
                        NSWorkspace.shared.open(state.logFileURL.deletingLastPathComponent())
                    }
                    .buttonStyle(.link)
                    .help(L10n.t("Открыть папку с логами", "Open the logs folder"))
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L10n.t("Прозрачность окна", "Window opacity"))
                            .foregroundStyle(Palette.text)
                        Spacer()
                        Text("\(Int((state.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }

                    Slider(
                        value: Binding(
                            get: { state.opacity },
                            set: { state.opacity = $0 }
                        ),
                        in: 0.3...1.0,
                        step: 0.01
                    )

                    HStack {
                        Text("30%")
                        Spacer()
                        Text("100%")
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }

                Divider().opacity(0.25)

                HStack(spacing: 8) {
                    Text("llama.cpp")
                        .font(.headline)
                        .foregroundStyle(Palette.text)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: serverExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(serverExists ? Palette.online : Palette.warn)
                        Text(serverExists ? L10n.t("llama-server найден", "llama-server found") : L10n.t("llama-server не найден", "llama-server not found"))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                        if !serverExists {
                            Button {
                                installer.install()
                            } label: {
                                Text(installer.isBusy ? L10n.t("Установка…", "Installing…") : L10n.t("Установить автоматически", "Install automatically"))
                                    .font(.system(size: 11))
                            }
                            .disabled(installer.isBusy)
                            .buttonStyle(.plain)
                            .help(L10n.t("Скачать официальную сборку llama.cpp с GitHub и прописать путь автоматически", "Download the official llama.cpp build from GitHub and set the path automatically"))
                        }
                        Button(L10n.t("Переустановить…", "Reinstall…")) {
                            chooseInstallFolder()
                        }
                        .disabled(installer.isBusy)
                        .buttonStyle(.plain)
                        .help(L10n.t("Скачать свежую сборку llama.cpp в выбранную папку (существующая установка не проверяется)", "Download a fresh llama.cpp build into the selected folder (an existing installation is not checked)"))
                    }
                }
                pathField("llama-server", text: $state.settings.serverPath, prompt: L10n.t("Выбрать llama-server", "Choose llama-server"))
                installProgress
                pathField(L10n.t("Модель .gguf", "Model .gguf"), text: $state.settings.modelPath, prompt: L10n.t("Выбрать модель .gguf", "Choose a .gguf model"))
                HStack(spacing: 5) {
                    Image(systemName: modelExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(modelExists ? Palette.online : Palette.warn)
                    Text(modelExists ? L10n.t("модель найдена", "model found") : L10n.t("модель не выбрана", "no model selected"))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                }
                Text(L10n.t("Новая модель, контекст и порт применятся после «Применить и перезапустить» — llama-server перезапустится полностью.", "A new model, context and port are applied after “Apply and restart” — llama-server restarts completely."))
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        showDownloader = true
                    } label: {
                        Label(L10n.t("Скачать модель…", "Download model…"), systemImage: "arrow.down.circle")
                    }
                    .help(L10n.t("Открыть список моделей с прямыми ссылками", "Open the model list with direct links"))

                    Button {
                        ModelDownloader.revealModelsFolder(selectedPath: state.settings.modelPath)
                    } label: {
                        Label(L10n.t("Папка с моделями", "Models folder"), systemImage: "folder")
                    }
                    .help(L10n.t("Открыть папку с файлами .gguf", "Open the folder with .gguf files"))
                }

                if modelDownloader.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView(value: modelDownloader.progress ?? 0)
                            .progressViewStyle(.linear)
                        Text(downloadPercentText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                        Button(L10n.t("Отменить", "Cancel")) { modelDownloader.cancel() }
                            .font(.system(size: 10))
                    }
                }
                DisclosureGroup(L10n.t("Тонкие настройки", "Advanced settings"), isExpanded: $showAdvanced) {
                    HStack {
                        stepper("threads -t", value: $state.settings.threads, range: 1...32)
                        stepper("batch -tb", value: $state.settings.threadsBatch, range: 1...32)
                    }
                    HStack {
                        stepper("ctx -c", value: $state.settings.contextSize, range: 512...64000, step: 512)
                        stepper("port", value: $state.settings.port, range: 1024...65535)
                    }
                }
                NumberSlider(
                    title: L10n.t("Максимум токенов ответа", "Max response tokens"),
                    value: $state.settings.maxTokens,
                    range: 256...32000,
                    step: 256
                )

                NumberSlider(
                    title: L10n.t("Бюджет рассуждений", "Reasoning budget"),
                    value: $state.settings.reasoningBudget,
                    range: 0...8192,
                    step: 64
                )
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { state.alwaysOnTop },
                        set: { state.alwaysOnTop = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Text(L10n.t("Поверх всех окон", "Always on top"))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Button(L10n.t("Сбросить настройки", "Reset settings")) {
                        resetSettings()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                }
                HStack {
                    Button(L10n.t("Очистить чат", "Clear chat")) { state.clearChat() }
                    Spacer()
                    Button(L10n.t("Закрыть", "Close")) { onClose() }
                    Button(L10n.t("Применить и перезапустить", "Apply and restart")) {
                        state.restartServer()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if !state.log.isEmpty {
                    ScrollView {
                        Text(state.log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(Palette.bg, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 620)
        .background(Palette.header)
        .sheet(isPresented: $showDownloader) {
            ModelDownloadSheet(downloader: modelDownloader) {
                showDownloader = false
            }
            .environmentObject(state)
        }
        .onAppear {
            modelDownloader.onFinished = { [weak state] url in
                state?.selectModel(at: url)
            }
        }
    }

    private var downloadPercentText: String {
        guard let progress = modelDownloader.progress else { return "…" }
        return "\(Int((progress * 100).rounded()))%"
    }

    private var appHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("Приложение", "Application"))
                .font(.headline)
                .foregroundStyle(Palette.text)

            Spacer()

            Picker("", selection: $state.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.shortTitle).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 88)
            .help(L10n.t("Язык интерфейса", "Interface language"))

            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 24, height: 24)
                    .background(Palette.input, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L10n.t("Информация", "Information"))
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                infoPopover
            }
        }
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("О приложении", "About"))
                .font(.headline)
                .foregroundStyle(Palette.text)

            Link(destination: URL(string: AppInfo.github)!) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("GitHub · ilyaivonin")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.input, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(AppInfo.github)

            infoRow(L10n.t("Автор", "Author"), AppInfo.author)
            infoRow(L10n.t("Компания", "Company"), AppInfo.company)
            infoRow(L10n.t("Донаты", "Donations"), AppInfo.donate)

            if let url = URL(string: AppInfo.donate),
               url.scheme == "http" || url.scheme == "https" {
                Link(L10n.t("Открыть страницу донатов", "Open donation page"), destination: url)
                    .font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(Palette.bg)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.muted)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if installer.isBusy {
                if let progress = installer.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
                Text(installer.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            } else {
                if !installer.lines.isEmpty {
                    ScrollView {
                        Text(installer.lines.suffix(6).joined(separator: "\n"))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 54)
                }
                if !installer.statusText.isEmpty {
                    Text(installer.statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(installerFailed ? Palette.danger : Palette.muted)
                }
            }
        }
    }

    private func chooseInstallFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("Установить", "Install")
        panel.message = L10n.t("В выбранной папке будет создана папка llama.cpp", "A llama.cpp folder will be created in the selected folder")

        try? FileManager.default.createDirectory(
            at: LlamaInstaller.defaultParentDir,
            withIntermediateDirectories: true
        )
        panel.directoryURL = LlamaInstaller.defaultParentDir

        if panel.runModal() == .OK, let folder = panel.url {
            installer.reinstall(into: folder)
        }
    }

    private var installerFailed: Bool {
        if case .failed = installer.phase { return true }
        return false
    }

    private func pathField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.t("Обзор…", "Browse…")) {
                    browseFile(prompt: prompt, into: text)
                }
            }
        }
    }

    private func browseFile(prompt: String, into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = prompt

        let current = URL(fileURLWithPath: binding.wrappedValue)
        var directory = current.hasDirectoryPath ? current : current.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            directory = FileManager.default.homeDirectoryForCurrentUser
        }
        panel.directoryURL = directory

        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            HStack {
                TextField(title, value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func resetSettings() {
        state.settings = AppSettings.default
        SettingsStore.save(state.settings)
    }
}

/// Slider with a numeric input field, used for token limits.
private struct NumberSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(Palette.text)
                Spacer()
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($editing)
                    .frame(width: 64)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Palette.input, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onSubmit(commit)
                    .onChange(of: editing) { _, focused in
                        if !focused { commit() }
                    }
                    .onChange(of: text) { _, newText in
                        // Apply valid numbers while typing, so a manual value is
                        // not lost if the user clicks "Применить" without pressing Enter.
                        liveUpdate(newText)
                    }
            }

            Slider(
                value: Binding(
                    get: { Double(clamped(value)) },
                    set: { value = clamp(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )

            HStack {
                Text("\(range.lowerBound)")
                Spacer()
                Text("\(range.upperBound)")
            }
            .font(.caption2)
            .foregroundStyle(Palette.muted)
        }
        .onAppear { text = String(clamped(value)) }
        .onChange(of: value) { _, newValue in
            if !editing {
                text = String(clamped(newValue))
            }
        }
    }

    private func clamped(_ raw: Int) -> Int {
        clamp(raw)
    }

    private func clamp(_ raw: Int) -> Int {
        min(max(raw, range.lowerBound), range.upperBound)
    }

    /// Accepts "16000", "16 000", "16,000" and clamps out-of-range values.
    private func commit() {
        let digits = text.filter(\.isNumber)
        guard let parsed = Int(digits) else {
            text = String(clamped(value))
            return
        }
        let result = clamp(parsed)
        if value != result {
            value = result
        }
        text = String(result)
    }

    /// Applies a partially typed number once it is already inside the range.
    private func liveUpdate(_ raw: String) {
        let digits = raw.filter(\.isNumber)
        guard let parsed = Int(digits), range.contains(parsed) else { return }
        if value != parsed {
            value = parsed
        }
    }
}

/// First-launch "how to use" popup. Text is loaded from howto.md in the app
/// bundle (or the working directory when running via `swift run`).
private struct HowtoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Как пользоваться", "How to use"))
                .font(.headline)
                .foregroundStyle(Palette.text)

            ScrollView {
                Text(howtoText)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 300)

            HStack {
                Toggle(L10n.t("Не показывать снова", "Don't show again"), isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button(L10n.t("Закрыть", "Close")) {
                    if dontShowAgain {
                        UserDefaults.standard.set(true, forKey: "floatchat.howtoShown")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 460)
        .background(Palette.bg)
    }

    private var howtoText: String {
        if let url = howtoURL(),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return L10n.t(
            """
            1. Установите llama-server через кнопку «Установить» рядом с заголовком llama.cpp.
            2. Скачайте модель .gguf через «Скачать модель…» или укажите свой файл в настройках.
            3. Нажмите «Применить и перезапустить».
            4. Напишите сообщение в чат — модель ответит локально на вашем Mac.

            Используйте метлу в заголовке чата, чтобы очистить историю сообщений.
            """,
            """
            1. Install llama-server via the Install button next to the llama.cpp header.
            2. Download a .gguf model via Download model… or specify your own file in settings.
            3. Press Apply and restart.
            4. Type a message in the chat — the model will reply locally on your Mac.

            Use the broom icon in the chat header to clear the message history.
            """
        )
    }

    private func howtoURL() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent("howto.md")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("howto.md")
        if FileManager.default.fileExists(atPath: cwd.path) {
            return cwd
        }
        return nil
    }
}

enum Palette {
    /// Colors resolve against the window appearance, so one palette serves both themes.
    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    static let bg = adaptive(light: (0.95, 0.96, 0.98), dark: (0.10, 0.12, 0.16))
    static let header = adaptive(light: (0.90, 0.92, 0.95), dark: (0.13, 0.15, 0.21))
    static let input = adaptive(light: (1.00, 1.00, 1.00), dark: (0.16, 0.18, 0.25))
    static let userBubble = adaptive(light: (0.80, 0.93, 0.82), dark: (0.16, 0.42, 0.20))
    static let assistantBubble = adaptive(light: (0.90, 0.92, 0.96), dark: (0.18, 0.20, 0.28))
    static let accent = adaptive(light: (0.55, 0.70, 0.10), dark: (0.78, 0.90, 0.28))
    static let onAccent = adaptive(light: (1.00, 1.00, 1.00), dark: (0.10, 0.12, 0.16))
    static let online = adaptive(light: (0.10, 0.60, 0.20), dark: (0.38, 0.92, 0.32))
    static let warn = adaptive(light: (0.85, 0.55, 0.05), dark: (0.95, 0.74, 0.22))
    static let danger = adaptive(light: (0.78, 0.16, 0.14), dark: (0.90, 0.32, 0.28))
    static let text = adaptive(light: (0.10, 0.12, 0.16), dark: (0.93, 0.94, 0.96))
    static let muted = adaptive(light: (0.36, 0.40, 0.48), dark: (0.62, 0.66, 0.74))
}
