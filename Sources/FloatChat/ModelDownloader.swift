import AppKit
import Foundation

/// Downloads a catalog model straight to ~/Downloads and reports progress.
/// One download at a time; a second call cancels the previous one.
final class ModelDownloader: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(modelID: String)
        case finished(modelID: String, fileName: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var downloadedURL: URL?

    /// Called on the main queue after a successful download.
    var onFinished: ((URL) -> Void)?

    private struct ActiveDownload {
        var taskID: Int
        var modelID: String
        var fileName: String
    }

    private let lock = NSLock()
    private var active: ActiveDownload?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func download(_ model: CatalogModel) {
        cancel()

        DispatchQueue.main.async {
            self.phase = .downloading(modelID: model.id)
            self.progress = nil
            self.downloadedURL = nil
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // Models can be several gigabytes.
        configuration.timeoutIntervalForResource = 60 * 60 * 8
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: model.downloadURL)
        request.setValue("FloatChat", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        setActive(ActiveDownload(
            taskID: task.taskIdentifier,
            modelID: model.id,
            fileName: model.fileName
        ))
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        clearActive()
        DispatchQueue.main.async {
            if case .downloading = self.phase { self.phase = .idle }
            self.progress = nil
        }
    }

    // MARK: - Active download bookkeeping

    private func setActive(_ value: ActiveDownload?) {
        lock.lock()
        active = value
        lock.unlock()
    }

    private func activeDownload(for taskID: Int) -> ActiveDownload? {
        lock.lock()
        defer { lock.unlock() }
        guard active?.taskID == taskID else { return nil }
        return active
    }

    private func clearActive() {
        setActive(nil)
    }

    // MARK: - Destination

    /// Folder where downloaded models are stored: ~/Downloads/FloatChat.
    static var modelsDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("FloatChat", isDirectory: true)
    }

    /// Reveals the selected model in Finder, or opens the download folder when
    /// no model is selected yet.
    static func revealModelsFolder(selectedPath: String) {
        if !selectedPath.isEmpty, FileManager.default.fileExists(atPath: selectedPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedPath)])
            return
        }
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(modelsDirectory)
    }

    private func destinationURL(for fileName: String) -> URL {
        let folder = Self.modelsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let safeName = fileName.isEmpty ? "model.gguf" : fileName
        var url = folder.appendingPathComponent(safeName)

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            url = folder.appendingPathComponent(name)
            index += 1
        }
        return url
    }

    private func finishFailure(_ message: String) {
        clearActive()
        DispatchQueue.main.async {
            self.phase = .failed(message)
            self.progress = nil
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard activeDownload(for: downloadTask.taskIdentifier) != nil,
              totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = value }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let info = activeDownload(for: downloadTask.taskIdentifier) else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finishFailure(L10n.t("Сервер вернул код \(http.statusCode)", "Server returned code \(http.statusCode)"))
            return
        }

        let destination = destinationURL(for: info.fileName)
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            clearActive()
            DispatchQueue.main.async {
                self.phase = .finished(modelID: info.modelID, fileName: destination.lastPathComponent)
                self.progress = nil
                self.downloadedURL = destination
                self.onFinished?(destination)
            }
        } catch {
            finishFailure(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error,
           (error as NSError).code != NSURLErrorCancelled,
           activeDownload(for: task.taskIdentifier) != nil {
            finishFailure(error.localizedDescription)
        }

        session.finishTasksAndInvalidate()
        DispatchQueue.main.async {
            if self.session === session {
                self.session = nil
                self.task = nil
            }
        }
    }
}
