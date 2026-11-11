import Foundation
import PDFKit

/// Extracts plain text from files the user attaches to a message.
enum AttachmentLoader {
    /// Roughly 15–20k tokens of Cyrillic text per file.
    static let maxCharactersPerFile = 60_000
    static let maxTotalCharacters = 120_000

    static let readableExtensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
        "rtf", "log", "yaml", "yml", "swift", "py", "js", "ts", "c", "h", "cpp", "sh"
    ]

    static func isReadable(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(url: URL, maxCharacters: Int) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let raw = try extractText(from: url)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw AttachmentError.empty(name)
        }

        let limit = max(1, maxCharacters)
        let truncated = trimmed.count > limit
        let text = truncated ? String(trimmed.prefix(limit)) : trimmed
        return ChatAttachment(name: name, text: text, truncated: truncated)
    }

    private static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw AttachmentError.unreadable(url.lastPathComponent)
            }
            return document.string ?? ""
        }

        if ext == "rtf" {
            if let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                return attributed.string
            }
        }

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .windowsCP1251) {
            return text
        }

        throw AttachmentError.unreadable(url.lastPathComponent)
    }
}

enum AttachmentError: LocalizedError {
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return L10n.t("«\(name)»: не удалось прочитать текст файла", "“\(name)”: could not read the file text")
        case .empty(let name):
            return L10n.t(
                "«\(name)»: текста не найдено (возможно, это скан или картинки)",
                "“\(name)”: no text found (maybe a scan or images)"
            )
        }
    }
}
