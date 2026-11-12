import Foundation

/// A downloadable GGUF model shown in the "Download model" sheet.
struct CatalogModel: Identifiable {
    let id: String
    let name: String
    let size: String
    let textRU: String
    let textEN: String?
    let downloadURL: URL
    let pageURL: URL?

    /// Localized description (falls back to the Russian text when no English one is given).
    var summary: String {
        if L10n.current == .en, let textEN, !textEN.isEmpty { return textEN }
        return textRU
    }

    /// Suggested file name for the downloaded .gguf.
    var fileName: String {
        let name = downloadURL.lastPathComponent
        return name.isEmpty ? "model.gguf" : name
    }
}

/// The model list lives in `models.json` in the project root, so anyone who
/// builds the app from the repository can use the bundled catalog or replace
/// it with their own. The packaged app carries a copy in `Contents/Resources`;
/// `swift run` reads it from the working directory. The Documents folder is
/// used only for logs and chat history.
enum ModelCatalog {
    static let fileName = "models.json"

    /// Lookup order: app bundle resources → working directory → executable folder.
    static var searchURLs: [URL] {
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent(fileName))
        }
        urls.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(fileName)
        )
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            urls.append(executable.deletingLastPathComponent().appendingPathComponent(fileName))
        }
        return urls
    }

    /// First existing models.json, or nil when none was found.
    static func locateFile() -> URL? {
        searchURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Models used when models.json is missing or cannot be read.
    static let builtIn: [CatalogEntry] = [
        CatalogEntry(
            id: "gemma-3-1b-it-qat",
            name: "Gemma 3 1B IT — QAT Q4_0",
            size: "0.7 GB",
            text: "Самая лёгкая модель: быстрый ответ даже на слабом Mac, минимум памяти. Подходит для простых задач. Скачивается с официального зеркала ggml-org — репозиторий Google требует принятия лицензии.",
            textEN: "The lightest model: fast answers even on a slow Mac, minimal memory. Good for simple tasks. Downloaded from the official ggml-org mirror — Google's repository requires accepting a license.",
            url: "https://huggingface.co/ggml-org/gemma-3-1b-it-qat-GGUF/resolve/main/gemma-3-1b-it-qat-Q4_0.gguf?download=true",
            page: "https://huggingface.co/google/gemma-3-1b-it-qat-q4_0-gguf"
        ),
        CatalogEntry(
            id: "qwen38-2b-q4km",
            name: "Qwen3.8-2B — Q4_K_M",
            size: "1.3 GB",
            text: "Компактная и быстрая. Хороший выбор для слабых машин и быстрых ответов.",
            textEN: "Compact and fast. A good choice for slower machines and quick answers.",
            url: "https://huggingface.co/empero-ai/Qwen3.8-2B-Distill-GGUF/resolve/main/Qwen3.8-2B-Q4_K_M.gguf?download=true",
            page: "https://huggingface.co/empero-ai/Qwen3.8-2B-Distill-GGUF"
        ),
        CatalogEntry(
            id: "qwen38-4b-q4km",
            name: "Qwen3.8-4B — Q4_K_M",
            size: "2.8 GB",
            text: "Баланс качества и скорости. Разумные требования к памяти — подходит большинству.",
            textEN: "A balance of quality and speed. Reasonable memory needs — a good fit for most people.",
            url: "https://huggingface.co/empero-ai/Qwen3.8-4B-Distill-GGUF/resolve/main/Qwen3.8-4B-Q4_K_M.gguf?download=true",
            page: "https://huggingface.co/empero-ai/Qwen3.8-4B-Distill-GGUF"
        ),
        CatalogEntry(
            id: "qwen38-9b-q4km",
            name: "Qwen3.8-9B — Q4_K_M",
            size: "5.8 GB",
            text: "Заметно качественнее, но требует больше памяти и времени на ответ.",
            textEN: "Noticeably better quality, but needs more memory and takes longer to answer.",
            url: "https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF/resolve/main/Qwen3.8-9B-Q4_K_M.gguf?download=true",
            page: "https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF"
        ),
        CatalogEntry(
            id: "qwen38-14b-turbo-q4km",
            name: "Qwen3.8-14B Instruct Turbo — Q4_K_M",
            size: "9.2 GB",
            text: "Лучшее качество в списке. Нужен мощный Mac и много свободной памяти.",
            textEN: "The best quality in the list. Needs a powerful Mac and plenty of free memory.",
            url: "https://huggingface.co/mradermacher/Qwen3.8-14B-Instruct-Turbo-GGUF/resolve/main/Qwen3.8-14B-Instruct-Turbo.Q4_K_M.gguf?download=true",
            page: "https://huggingface.co/mradermacher/Qwen3.8-14B-Instruct-Turbo-GGUF"
        )
    ]

    static func defaultModels() -> [CatalogModel] {
        builtIn.compactMap(makeModel)
    }

    /// Reads models.json. On any problem the built-in list is returned together
    /// with a message.
    static func load() -> (models: [CatalogModel], error: String?) {
        guard let url = locateFile() else {
            return (defaultModels(), L10n.t(
                "models.json не найден — показан встроенный список.",
                "models.json was not found — showing the built-in list."
            ))
        }

        guard let data = try? Data(contentsOf: url) else {
            return (defaultModels(), L10n.t(
                "Не удалось открыть models.json — показан встроенный список.",
                "Could not open models.json — showing the built-in list."
            ))
        }

        do {
            let file = try JSONDecoder().decode(CatalogFile.self, from: data)
            let models = file.models.compactMap(makeModel)
            guard !models.isEmpty else {
                return (defaultModels(), L10n.t(
                    "В models.json нет моделей — показан встроенный список.",
                    "models.json has no models — showing the built-in list."
                ))
            }
            return (models, nil)
        } catch {
            return (defaultModels(), L10n.t(
                "Ошибка в models.json — показан встроенный список.",
                "models.json contains an error — showing the built-in list."
            ))
        }
    }

    private static func makeModel(_ entry: CatalogEntry) -> CatalogModel? {
        guard let url = URL(string: entry.url),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }

        return CatalogModel(
            id: entry.id ?? entry.url,
            name: entry.name,
            size: entry.size ?? "",
            textRU: entry.text ?? "",
            textEN: entry.textEN,
            downloadURL: url,
            pageURL: entry.page.flatMap { URL(string: $0) }
        )
    }
}

/// Shape of models.json.
struct CatalogFile: Codable {
    var models: [CatalogEntry]
}

/// One record in models.json. Only `name` and `url` are required.
struct CatalogEntry: Codable {
    var id: String?
    var name: String
    var size: String?
    var text: String?
    var textEN: String?
    var url: String
    var page: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, text, url, page
        case textEN = "text_en"
    }

    init(
        id: String? = nil,
        name: String,
        size: String? = nil,
        text: String? = nil,
        textEN: String? = nil,
        url: String,
        page: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.text = text
        self.textEN = textEN
        self.url = url
        self.page = page
    }
}
