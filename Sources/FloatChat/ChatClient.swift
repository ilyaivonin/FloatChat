import Foundation

struct ChatAttachment: Identifiable, Equatable {
    let id: UUID
    var name: String
    var text: String
    var truncated: Bool

    init(id: UUID = UUID(), name: String, text: String, truncated: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.truncated = truncated
    }

    var caption: String {
        truncated ? name + L10n.t(" (обрезано)", " (truncated)") : name
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var content: String
    var reasoning: String
    var attachments: [ChatAttachment]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String = "",
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.attachments = attachments
    }
}

final class ChatClient {
    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    func stream(
        settings: AppSettings,
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String, String, Double?) -> Void
    ) async throws {
        let url = settings.baseURL.appending(path: "v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "stream": true,
            "stream_options": ["include_usage": true],
            "cache_prompt": true,
            "max_tokens": settings.maxTokens,
            "thinking_budget_tokens": settings.reasoningBudget,
            "messages": history.map { message in
                [
                    "role": message.role.rawValue,
                    "content": Self.payloadContent(for: message)
                ]
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let generationStartedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatError.http(http.statusCode)
        }

        var debugChunkCount = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

            debugChunkCount += 1
            if debugChunkCount <= 3 || dataLine.contains("usage") || dataLine.contains("timings") {
                print("SSE DEBUG [\(debugChunkCount)]: \(dataLine.prefix(600))")
            }

            if dataLine == "[DONE]" { break }
            guard let data = dataLine.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }

            if let speed = chunk.timings?.predictedPerSecond, speed > 0 {
                await onDelta("", "", speed)
            } else if let count = chunk.usage?.completionTokens, count > 0 {
                let elapsed = max(Date().timeIntervalSince(generationStartedAt), 0.001)
                await onDelta("", "", Double(count) / elapsed)
            }

            guard let delta = chunk.choices?.first?.delta else { continue }
            let content = delta.content ?? ""
            let reasoning = delta.reasoningContent ?? ""
            if !content.isEmpty || !reasoning.isEmpty {
                await onDelta(content, reasoning, nil)
            }
        }
    }

    /// Inlines attachment text so the model can read PDFs and plain-text files.
    static func payloadContent(for message: ChatMessage) -> String {
        guard !message.attachments.isEmpty else { return message.content }

        var parts: [String] = []
        let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }
        for attachment in message.attachments {
            parts.append(
                """
                --- Файл: \(attachment.name) ---
                \(attachment.text)
                --- Конец файла: \(attachment.name) ---
                """
            )
        }
        return parts.joined(separator: "\n\n")
    }
}

enum ChatError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return L10n.t("Сервер ответил \(code)", "Server responded \(code)")
        }
    }
}

private struct StreamChunk: Decodable {
    struct Timings: Decodable {
        let predictedPerSecond: Double?

        enum CodingKeys: String, CodingKey {
            case predictedPerSecond = "predicted_per_second"
        }
    }

    let timings: Timings?

    struct Usage: Decodable {
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case completionTokens = "completion_tokens"
        }
    }

    let choices: [Choice]?
    let usage: Usage?

    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        let delta: Delta?
    }
}
