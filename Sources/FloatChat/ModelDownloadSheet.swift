import AppKit
import SwiftUI

/// Popup with the model catalog: direct download buttons with descriptions.
/// Button titles and links come from `models.json` in the project root, so a
/// custom catalog can be shipped by replacing that file before building.
struct ModelDownloadSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var downloader: ModelDownloader

    var onClose: () -> Void

    @State private var models: [CatalogModel] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("Скачать модель", "Download a model"))
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(L10n.t("Закрыть", "Close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(L10n.t(
                "Кнопки и ссылки берутся из models.json в корне проекта — при сборке можно заменить его своим. Файл .gguf сохраняется в папку «Загрузки/FloatChat» и сразу выбирается как модель.",
                "Buttons and links come from models.json in the project root — replace it with your own before building. The .gguf file is saved to “Downloads/FloatChat” and selected as the model right away."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(models) { model in
                        modelCard(model)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 420)

            if let loadError {
                Text(loadError)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            downloadStatus

            Divider().opacity(0.25)

            HStack(spacing: 10) {
                Button {
                    openModelsFolder()
                } label: {
                    Label(L10n.t("Перейти в папку с моделями", "Show models folder"), systemImage: "folder")
                }
                .help(L10n.t("Открыть папку с файлами .gguf", "Open the folder with .gguf files"))

                Button(L10n.t("Обновить список", "Reload list")) { reloadModels() }

                Spacer()

                Button(L10n.t("Готово", "Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 620)
        .background(Palette.header)
        .onAppear(perform: reloadModels)
    }

    // MARK: - One download button + its description

    private func modelCard(_ model: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            downloadButton(model)

            if !model.summary.isEmpty {
                Text(model.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            if let page = model.pageURL {
                Link(L10n.t("Страница модели", "Model page"), destination: page)
                    .font(.system(size: 10))
                    .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ model: CatalogModel) -> some View {
        switch downloader.phase {
        case .downloading(let modelID) where modelID == model.id:
            buttonShell {
                ProgressView()
                    .controlSize(.small)
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(percentText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }

        case .finished(let modelID, _) where modelID == model.id:
            buttonShell {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.online)
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(L10n.t("Скачано", "Downloaded"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.online)
            }

        default:
            Button {
                download(model)
            } label: {
                buttonShell {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Palette.text)
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    if !model.size.isEmpty {
                        Text(model.size)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(downloader.isDownloading)
            .help(L10n.t("Скачать \(model.fileName)", "Download \(model.fileName)"))
        }
    }

    private func buttonShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.input.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.muted.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Global status

    @ViewBuilder
    private var downloadStatus: some View {
        switch downloader.phase {
        case .downloading(let modelID):
            let name = models.first { $0.id == modelID }?.name ?? ""
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.t("Скачивание: \(name)", "Downloading: \(name)"))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Text(percentText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Button(L10n.t("Отменить", "Cancel")) { downloader.cancel() }
                        .font(.system(size: 10))
                }
                ProgressView(value: downloader.progress ?? 0)
                    .progressViewStyle(.linear)
            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)

        case .finished(_, let fileName):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.online)
                Text(L10n.t(
                    "\(fileName) скачано в «Загрузки/FloatChat» и выбрано как модель. Нажмите «Применить и перезапустить» в настройках.",
                    "\(fileName) was downloaded to “Downloads/FloatChat” and selected as the model. Press “Apply and restart” in settings."
                ))
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let url = downloader.downloadedURL {
                    Button(L10n.t("Показать", "Show")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .font(.system(size: 10))
                }
            }

        case .idle:
            EmptyView()
        }
    }

    private var percentText: String {
        guard let progress = downloader.progress else { return "…" }
        return "\(Int((progress * 100).rounded()))%"
    }

    private func download(_ model: CatalogModel) {
        downloader.onFinished = { [weak state] url in
            state?.selectModel(at: url)
        }
        downloader.download(model)
    }

    /// Shows the selected model in Finder, or opens the folder the app
    /// downloads models into when nothing is selected yet.
    private func openModelsFolder() {
        ModelDownloader.revealModelsFolder(selectedPath: state.settings.modelPath)
    }

    private func reloadModels() {
        let result = ModelCatalog.load()
        models = result.models
        loadError = result.error
    }
}
