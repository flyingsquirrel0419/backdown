import Foundation
import Network

/// 시스템 background URLSession으로 다운로드한다. 앱이 백그라운드로 가거나 종료돼도
/// nsurlsessiond가 계속 받고, 끊기면 resumeData로 이어받는다.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "com.flyingsquirrel.backdown") + ".background"

    @Published private(set) var items: [DownloadItem] = []
    /// bytes/sec
    @Published private(set) var speeds: [UUID: Double] = [:]

    var backgroundCompletionHandler: (() -> Void)?

    let downloadsDirectory: URL
    private let supportDirectory: URL
    private let resumeDirectory: URL
    private var stateFile: URL { supportDirectory.appendingPathComponent("downloads.json") }

    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// 사용자가 일시정지/삭제해서 취소된 task. didCompleteWithError에서 실패로 처리하지 않는다.
    private var userCancelled: Set<UUID> = []
    private var speedSamples: [UUID: (date: Date, bytes: Int64)] = [:]
    private var lastUIUpdate: [UUID: Date] = [:]
    private var lastSave = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    private let maxAutoRetries = 10
    private let fm = FileManager.default

    private override init() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackDown", isDirectory: true)
        downloadsDirectory = docs.appendingPathComponent("Downloads", isDirectory: true)
        supportDirectory = support
        resumeDirectory = support.appendingPathComponent("resume", isDirectory: true)
        super.init()

        for dir in [downloadsDirectory, supportDirectory, resumeDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        reattach()
        startNetworkMonitor()
    }

    // MARK: - Public API

    func enqueue(request: URLRequest, suggestedFileName: String?) {
        guard let url = request.url else { return }
        let serverName = suggestedFileName.flatMap(Self.sanitize)
        let item = DownloadItem(
            id: UUID(),
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            fileName: serverName ?? Self.fallbackName(for: url),
            nameFromServer: serverName != nil,
            state: .queued
        )
        items.insert(item, at: 0)
        startTask(for: item.id)
    }

    func pause(_ id: UUID) {
        guard let idx = index(of: id), !items[idx].isForeground else { return }
        items[idx].state = .paused
        speeds[id] = nil
        if let task = tasks[id] {
            userCancelled.insert(id)
            task.cancel(byProducingResumeData: { [weak self] data in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let data { try? data.write(to: self.resumeURL(id)) }
                    self.save(force: true)
                }
            })
        }
        save(force: true)
        refreshKeepAlive()
    }

    func resume(_ id: UUID) {
        guard let idx = index(of: id), !items[idx].isForeground else { return }
        items[idx].retryCount = 0
        if let task = tasks[id] {
            task.resume()
            items[idx].state = .downloading
        } else {
            startTask(for: id)
        }
    }

    /// 처음부터 다시 받기 (이어받기 데이터 폐기)
    func restart(_ id: UUID) {
        guard let idx = index(of: id), !items[idx].isForeground else { return }
        if let task = tasks[id] {
            userCancelled.insert(id)
            task.cancel()
            tasks[id] = nil
        }
        try? fm.removeItem(at: resumeURL(id))
        items[idx].retryCount = 0
        startTask(for: id)
    }

    func remove(_ id: UUID, deleteFile: Bool) {
        if let task = tasks[id] {
            userCancelled.insert(id)
            task.cancel()
        }
        tasks[id] = nil
        speeds[id] = nil
        try? fm.removeItem(at: resumeURL(id))
        if deleteFile, let item = items.first(where: { $0.id == id }), item.state == .completed || item.isForeground {
            try? fm.removeItem(at: fileURL(for: item))
        }
        items.removeAll { $0.id == id }
        save(force: true)
        refreshKeepAlive()
    }

    func clearCompleted() {
        items.removeAll { $0.state == .completed }
        save(force: true)
    }

    func fileURL(for item: DownloadItem) -> URL {
        downloadsDirectory.appendingPathComponent(item.fileName)
    }

    /// 겹치지 않는 저장 경로. `name.ext` → `name (1).ext`
    func uniqueDestination(for rawName: String) -> URL {
        let name = Self.sanitize(rawName) ?? "download"
        var candidate = downloadsDirectory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = downloadsDirectory.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    // MARK: - Foreground (WKDownload) items

    func addForegroundItem(fileName: String, url: URL?, totalBytes: Int64) -> UUID {
        let item = DownloadItem(
            id: UUID(),
            url: url ?? URL(string: "about:blank")!,
            headers: [:],
            fileName: fileName,
            nameFromServer: true,
            state: .downloading,
            totalBytes: totalBytes,
            isForeground: true
        )
        items.insert(item, at: 0)
        save(force: true)
        refreshKeepAlive()
        return item.id
    }

    func updateForegroundItem(_ id: UUID, received: Int64, total: Int64) {
        guard let idx = index(of: id) else { return }
        items[idx].receivedBytes = received
        if total > 0 { items[idx].totalBytes = total }
        updateSpeed(id, bytes: received)
    }

    func finishForegroundItem(_ id: UUID, fileURL: URL) {
        guard let idx = index(of: id) else { return }
        markCompleted(idx, fileURL: fileURL)
    }

    func failForegroundItem(_ id: UUID, message: String) {
        guard let idx = index(of: id) else { return }
        items[idx].state = .failed
        items[idx].errorMessage = message
        speeds[id] = nil
        Notifier.post(title: "다운로드 실패", body: items[idx].fileName)
        save(force: true)
        refreshKeepAlive()
    }

    // MARK: - Internals

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func itemID(for task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func resumeURL(_ id: UUID) -> URL {
        resumeDirectory.appendingPathComponent("\(id.uuidString).resume")
    }

    private func startTask(for id: UUID) {
        guard let idx = index(of: id) else { return }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL(id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: items[idx].url)
            for (key, value) in items[idx].headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            task = session.downloadTask(with: request)
            items[idx].receivedBytes = 0
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        task.resume()
        save(force: true)
        refreshKeepAlive()
    }

    /// 앱 재실행 시 시스템에 살아 있는 task를 다시 연결하고, 끊긴 항목은 이어받기를 시도한다.
    private func reattach() {
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in all {
                    guard let download = task as? URLSessionDownloadTask,
                          let id = self.itemID(for: task),
                          let idx = self.index(of: id) else {
                        task.cancel()
                        continue
                    }
                    self.tasks[id] = download
                    if self.items[idx].state != .paused {
                        self.items[idx].state = .downloading
                    }
                }
                for item in self.items where self.tasks[item.id] == nil {
                    if item.isForeground && item.state == .downloading {
                        if let idx = self.index(of: item.id) {
                            self.items[idx].state = .failed
                            self.items[idx].errorMessage = "앱이 종료되어 중단됨 (앱 내 다운로드는 이어받기 불가)"
                        }
                    } else if item.isActive {
                        self.startTask(for: item.id)
                    }
                }
                self.save(force: true)
                self.refreshKeepAlive()
            }
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let available = path.status == .satisfied
                let restored = available && !self.networkAvailable
                self.networkAvailable = available
                guard restored else { return }
                for item in self.items where item.state == .waiting && self.tasks[item.id] == nil {
                    self.startTask(for: item.id)
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "BackDown.network"))
    }

    private func markCompleted(_ idx: Int, fileURL: URL) {
        let id = items[idx].id
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        items[idx].fileName = fileURL.lastPathComponent
        items[idx].state = .completed
        items[idx].completedAt = Date()
        items[idx].errorMessage = nil
        if let size {
            items[idx].receivedBytes = size
            items[idx].totalBytes = size
        }
        speeds[id] = nil
        speedSamples[id] = nil
        try? fm.removeItem(at: resumeURL(id))
        Notifier.post(title: "다운로드 완료", body: items[idx].fileName)
        save(force: true)
        refreshKeepAlive()
    }

    private func updateSpeed(_ id: UUID, bytes: Int64) {
        let now = Date()
        guard let sample = speedSamples[id] else {
            speedSamples[id] = (now, bytes)
            return
        }
        let dt = now.timeIntervalSince(sample.date)
        guard dt >= 1 else { return }
        let instant = Double(bytes - sample.bytes) / dt
        let previous = speeds[id] ?? instant
        speeds[id] = max(0, previous * 0.6 + instant * 0.4)
        speedSamples[id] = (now, bytes)
    }

    private func refreshKeepAlive() {
        KeepAlive.shared.setActive(items.contains { $0.isActive })
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        let codes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorCannotLoadFromNetwork,
            NSURLErrorBackgroundSessionWasDisconnected,
            NSURLErrorSecureConnectionFailed,
            // 앱 강제 종료 등으로 시스템이 취소한 경우 (사용자 취소는 userCancelled로 걸러짐)
            NSURLErrorCancelled,
        ]
        return codes.contains(error.code)
    }

    static func sanitize(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? nil : cleaned
    }

    static func fallbackName(for url: URL) -> String {
        let last = url.lastPathComponent
        if let name = sanitize(last), last != "/" { return name }
        return url.host ?? "download"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([DownloadItem].self, from: data)) ?? []
    }

    private func save(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSave) > 2 else { return }
        lastSave = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = itemID(for: downloadTask), let idx = index(of: id) else { return }
        updateSpeed(id, bytes: totalBytesWritten)
        let now = Date()
        // UI 갱신은 초당 ~4회로 제한
        if let last = lastUIUpdate[id], now.timeIntervalSince(last) < 0.25 { return }
        lastUIUpdate[id] = now
        items[idx].receivedBytes = totalBytesWritten
        items[idx].totalBytes = totalBytesExpectedToWrite
        items[idx].retryCount = 0
        if items[idx].state != .downloading && items[idx].state != .paused {
            items[idx].state = .downloading
        }
        save()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let id = itemID(for: downloadTask), let idx = index(of: id) else { return }
        items[idx].receivedBytes = fileOffset
        items[idx].totalBytes = expectedTotalBytes
        speedSamples[id] = (Date(), fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = itemID(for: downloadTask), let idx = index(of: id) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            items[idx].state = .failed
            items[idx].errorMessage = "HTTP \(http.statusCode)"
            Notifier.post(title: "다운로드 실패", body: "\(items[idx].fileName) (HTTP \(http.statusCode))")
            return
        }
        var name = items[idx].fileName
        if !items[idx].nameFromServer, let suggested = downloadTask.response?.suggestedFilename.flatMap(Self.sanitize) {
            name = suggested
        }
        let destination = uniqueDestination(for: name)
        do {
            try fm.moveItem(at: location, to: destination)
            markCompleted(idx, fileURL: destination)
        } catch {
            items[idx].state = .failed
            items[idx].errorMessage = "파일 저장 실패: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = itemID(for: task) else { return }
        if tasks[id] === task { tasks[id] = nil }
        speeds[id] = nil
        let nsError = error as NSError?
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resumeData { try? resumeData.write(to: resumeURL(id)) }

        if userCancelled.remove(id) != nil {
            save(force: true)
            return
        }
        guard let idx = index(of: id) else { return }

        guard let nsError else {
            // 성공. didFinishDownloadingTo에서 이미 completed/failed 처리됨.
            if items[idx].state != .completed && items[idx].state != .failed {
                items[idx].state = .failed
                items[idx].errorMessage = "알 수 없는 오류"
            }
            save(force: true)
            refreshKeepAlive()
            return
        }

        if resumeData == nil {
            // 이어받기 데이터가 더는 유효하지 않음 → 다음 시도는 처음부터
            try? fm.removeItem(at: resumeURL(id))
        }
        items[idx].errorMessage = nsError.localizedDescription

        if Self.isRetryable(nsError) && items[idx].retryCount < maxAutoRetries {
            items[idx].retryCount += 1
            items[idx].state = .waiting
            let delay = min(pow(2, Double(items[idx].retryCount)), 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let i = self.index(of: id),
                      self.items[i].state == .waiting, self.tasks[id] == nil,
                      self.networkAvailable else { return }
                self.startTask(for: id)
            }
        } else {
            items[idx].state = .failed
            Notifier.post(title: "다운로드 실패", body: items[idx].fileName)
        }
        save(force: true)
        refreshKeepAlive()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
