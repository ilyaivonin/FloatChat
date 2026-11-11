import Foundation

enum ServerStatus: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return L10n.t("выключен", "stopped")
        case .starting: return L10n.t("запуск модели…", "starting model…")
        case .ready: return L10n.t("онлайн", "online")
        case .failed: return L10n.t("ошибка", "error")
        }
    }
}

/// Parsed timing info from llama-server stderr (print_timing / n_gen lines).
struct TimingEvent {
    enum Phase { case prompt, generation }
    var phase: Phase
    /// 0–100 during prompt processing, nil during generation.
    var progress: Double?
    /// tokens per second, when available.
    var tokensPerSecond: Double?
}

enum LlamaRuntime {
    static let server = LlamaServer()
}

final class LlamaServer {
    private var process: Process?
    private let logLimit = 80_000
    private(set) var log = ""
    var onLog: ((String) -> Void)?
    /// Parsed timing events from llama-server stderr (prompt progress / generation t/s).
    var onTiming: ((TimingEvent) -> Void)?
    /// Called on the main queue when a process we started dies without stop()/stopAndWait().
    var onUnexpectedExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    /// Buffered partial lines from stderr so we can parse complete print_timing/n_gen lines.
    private var lineBuffer = ""

    static let promptRegex = try! NSRegularExpression(
        pattern: #"progress\s*=\s*([0-9.]+).*t\s*=\s*[0-9.]+\s*s\s*/\s*([0-9.]+)\s*tokens per second"#)
    static let genRegex = try! NSRegularExpression(
        pattern: #"tg_3s\s*=\s*([0-9.]+)"#)

    func isHealthy(_ settings: AppSettings) async -> Bool {
        await healthOK(settings.baseURL.appending(path: "health"))
    }

    func start(settings: AppSettings) throws {
        stop()

        let server = URL(fileURLWithPath: settings.serverPath)
        let model = URL(fileURLWithPath: settings.modelPath)

        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw LlamaError.missingBinary(server.path)
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw LlamaError.missingModel(model.path)
        }

        let process = Process()
        process.executableURL = server
        process.currentDirectoryURL = server.deletingLastPathComponent()
        process.arguments = [
            "-m", model.path,
            "-t", "\(settings.threads)",
            "-tb", "\(settings.threadsBatch)",
            "-c", "\(settings.contextSize)",
            "--host", settings.host,
            "--port", "\(settings.port)"
        ]
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendLog(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendLog("\n[llama-server exited \(proc.terminationStatus)]\n")
                // Ignore a late handler from a process we already replaced.
                guard self.process?.processIdentifier == proc.processIdentifier else { return }
                self.process = nil
                self.onUnexpectedExit?(proc.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        appendLog("started: \(server.lastPathComponent) -m \(model.lastPathComponent) -t \(settings.threads) -tb \(settings.threadsBatch) -c \(settings.contextSize) --host \(settings.host) --port \(settings.port)\n")
    }

    func waitUntilReady(settings: AppSettings, timeout: TimeInterval = 180) async throws {
        guard let running = process else {
            throw LlamaError.exited(L10n.t("llama-server не был запущен", "llama-server was not started"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        let health = settings.baseURL.appending(path: "health")

        while Date() < deadline {
            // Check the exact process we are waiting for: `self.process` can be
            // cleared by its termination handler, and nil must not look "alive".
            if !running.isRunning {
                throw LlamaError.exited(log.suffix(1200).description)
            }
            if await healthOK(health) {
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        throw LlamaError.timeout(log.suffix(1200).description)
    }

    func stop() {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        self.process = nil
    }

    /// Stops the server and waits until the process is really gone, freeing the port.
    func stopAndWait(timeout: TimeInterval = 5) async {
        guard let process else { return }
        process.terminationHandler = nil
        let pid = process.processIdentifier
        self.process = nil

        if process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }

        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func healthOK(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                return status == "ok" || status == "ready"
            }
            return true
        } catch {
            return false
        }
    }

    private func appendLog(_ chunk: String) {
        lineBuffer += chunk
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            lineBuffer = String(lineBuffer[lineBuffer.index(after: nl)...])
            if !line.isEmpty { processTimingLine(line) }
        }
        log += chunk
        if log.count > logLimit {
            log = String(log.suffix(logLimit))
        }
        onLog?(log)
    }

    /// Extracts prompt-progress and generation t/s from a single stderr line.
    private func processTimingLine(_ line: String) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        // Prompt processing:
        // print_timing: id  1 | task 26 | prompt processing, n_tokens = 2663, progress = 0.84, t = 104.25 s / 25.54 tokens per second
        if line.contains("prompt processing") {
            if let match = LlamaServer.promptRegex.firstMatch(in: line, range: range),
               match.numberOfRanges >= 3 {
                let p = (line as NSString).substring(with: match.range(at: 1))
                let t = (line as NSString).substring(with: match.range(at: 2))
                let event = TimingEvent(
                    phase: .prompt,
                    progress: (Double(p) ?? 0) * 100,
                    tokensPerSecond: Double(t)
                )
                DispatchQueue.main.async { [weak self] in self?.onTiming?(event) }
            }
            return
        }

        // Generation:
        // n_gen =   117, tg =   5.78 t/s, tg_3s =   5.51 t/s
        if line.contains("n_gen") && line.contains("tg_3s") {
            if let match = LlamaServer.genRegex.firstMatch(in: line, range: range),
               match.numberOfRanges >= 2 {
                let t = (line as NSString).substring(with: match.range(at: 1))
                let event = TimingEvent(
                    phase: .generation,
                    tokensPerSecond: Double(t)
                )
                DispatchQueue.main.async { [weak self] in self?.onTiming?(event) }
            }
        }
    }
}

enum LlamaError: LocalizedError {
    case missingBinary(String)
    case missingModel(String)
    case exited(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary(let path):
            return L10n.t("Не найден llama-server:\n\(path)", "llama-server not found:\n\(path)")
        case .missingModel(let path):
            return L10n.t("Не найдена модель:\n\(path)", "Model not found:\n\(path)")
        case .exited(let log):
            return L10n.t("llama-server завершился при старте.\n\(log)", "llama-server exited during startup.\n\(log)")
        case .timeout(let log):
            return L10n.t("Модель не поднялась за отведённое время.\n\(log)", "The model did not start in time.\n\(log)")
        }
    }
}
