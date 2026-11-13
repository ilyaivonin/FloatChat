import Foundation

struct AppSettings: Equatable {
    var appName: String
    var opacity: Double
    var serverPath: String
    var modelPath: String
    var threads: Int
    var threadsBatch: Int
    var contextSize: Int
    var host: String
    var port: Int
    var alwaysOnTop: Bool
    var maxTokens: Int
    var reasoningBudget: Int

    static let `default` = AppSettings(
        appName: "AngryHamsterGPT",
        opacity: 1.0,
        serverPath: LlamaInstaller.managedServer.path,
        modelPath: "",
        threads: 4,
        threadsBatch: 4,
        contextSize: 8192,
        host: "127.0.0.1",
        port: 4096,
        alwaysOnTop: true,
        maxTokens: 2048,
        reasoningBudget: 192
    )

    var displayName: String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "FloatChat" : trimmed
    }

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}

enum SettingsStore {
    private static let key = "floatchat.settings.v1"

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(CodableSettings.self, from: data)
        else {
            return .default
        }
        var settings = decoded.asSettings

        // Older builds allowed higher limits; keep the stored value inside the current range.
        let clampedMaxTokens = min(max(settings.maxTokens, 256), 32_000)
        let clampedReasoning = min(max(settings.reasoningBudget, 0), 8_192)
        if clampedMaxTokens != settings.maxTokens || clampedReasoning != settings.reasoningBudget {
            settings.maxTokens = clampedMaxTokens
            settings.reasoningBudget = clampedReasoning
            save(settings)
        }

        return settings
    }

    static func save(_ settings: AppSettings) {
        let data = try? JSONEncoder().encode(CodableSettings(settings))
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct CodableSettings: Codable {
    var appName: String
    var opacity: Double
    var serverPath: String
    var modelPath: String
    var threads: Int
    var threadsBatch: Int
    var contextSize: Int
    var host: String
    var port: Int
    var alwaysOnTop: Bool
    var maxTokens: Int
    var reasoningBudget: Int

    init(_ settings: AppSettings) {
        appName = settings.appName
        opacity = settings.opacity
        serverPath = settings.serverPath
        modelPath = settings.modelPath
        threads = settings.threads
        threadsBatch = settings.threadsBatch
        contextSize = settings.contextSize
        host = settings.host
        port = settings.port
        alwaysOnTop = settings.alwaysOnTop
        maxTokens = settings.maxTokens
        reasoningBudget = settings.reasoningBudget
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? "AngryHamsterGPT"
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        serverPath = try c.decode(String.self, forKey: .serverPath)
        modelPath = try c.decode(String.self, forKey: .modelPath)
        threads = try c.decode(Int.self, forKey: .threads)
        threadsBatch = try c.decode(Int.self, forKey: .threadsBatch)
        contextSize = try c.decodeIfPresent(Int.self, forKey: .contextSize) ?? 4096
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        alwaysOnTop = try c.decode(Bool.self, forKey: .alwaysOnTop)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
        reasoningBudget = try c.decodeIfPresent(Int.self, forKey: .reasoningBudget) ?? 192
    }

    var asSettings: AppSettings {
        AppSettings(
            appName: appName,
            opacity: opacity,
            serverPath: serverPath,
            modelPath: modelPath,
            threads: threads,
            threadsBatch: threadsBatch,
            contextSize: contextSize,
            host: host,
            port: port,
            alwaysOnTop: alwaysOnTop,
            maxTokens: maxTokens,
            reasoningBudget: reasoningBudget
        )
    }
}
