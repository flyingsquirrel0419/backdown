import Foundation
import Network

enum DownloadSettings {
    static let connectionsKey = "connectionsPerDownload"
    static let defaultConnections = 8
    static let connectionOptions = [1, 2, 4, 8, 12, 16]

    /// 다운로드 하나당 동시에 여는 Range 요청 수
    static var connections: Int {
        let value = UserDefaults.standard.object(forKey: connectionsKey) as? Int ?? defaultConnections
        return min(max(value, 1), 16)
    }
}

/// 시스템 background URLSession으로 다운로드한다. 앱이 백그라운드로 가거나 종료돼도
/// nsurlsessiond가 계속 받고, 끊기면 resumeData로 이어받는다.
///
/// 서버가 Range 요청을 지원하면 파일을 여러 조각으로 나눠 동시에 받는다(멀티 커넥션).
/// 조각은 작게(최대 16MB) 잘라서 실패해도 그 조각만 다시 받고, 다 받으면 하나로 합친다.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "com.flyingsquirrel.backdown") + ".background"

    /// 이보다 작은 파일은 분할하지 않는다
    private static let minSegmentedSize: Int64 = 2 << 20
    private static let minSegmentSize: Int64 = 1 << 20
    private static let maxSegmentSize: Int64 = 16 << 20
    private static let maxSegmentRetries = 12

    @Published private(set) var items: [DownloadItem] = []
    /// bytes/sec
    @Published private(set) var speeds: [UUID: Double] = [:]

    var backgroundCompletionHandler: (() -> Void)?

    let downloadsDirectory: URL
    private let supportDirectory: URL
    private let resumeDirectory: URL
    private let partsRoot: URL
    private var stateFile: URL { supportDirectory.appendingPathComponent("downloads.json") }

    private var session: URLSession!
    private let probeSession: URLSession
    /// 단일 연결 task
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// 분할 다운로드 task: item id → 조각 번호 → task
    private var segmentTasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
    /// 진행 중인 조각이 지금까지 받은 바이트
    private var segmentBytes: [UUID: [Int: Int64]] = [:]
    /// 실패한 조각을 이 시각 전까지는 다시 시작하지 않음 (백오프)
    private var segmentCooldown: [UUID: [Int: Date]] = [:]
    /// 서버가 429/503으로 거부하면 해당 다운로드의 동시 연결 수를 줄인다
    private var adaptiveLimit: [UUID: Int] = [:]
    /// didFinishDownloadingTo에서 판정한 조각 실패 사유 (task identifier 기준)
    private var segmentFailures: [Int: SegmentFailure] = [:]
    /// 사용자가 일시정지/삭제해서(또는 내부적으로) 취소한 task. 실패로 처리하지 않는다.
    private var cancelledTasks: Set<Int> = []
    private var probing: Set<UUID> = []
    private var merging: Set<UUID> = []
    private let mergeQueue = DispatchQueue(label: "BackDown.merge", qos: .userInitiated)

    private var speedSamples: [UUID: (date: Date, bytes: Int64)] = [:]
    private var lastUIUpdate: [UUID: Date] = [:]
    private var lastSave = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    private let maxAutoRetries = 10
    private let fm = FileManager.default

    private enum SegmentFailure {
        /// 서버가 Range를 무시(200)했거나 거부 → 단일 연결로 전환
        case fallback(String)
        case retry(String, throttled: Bool)
        case fatal(String)
    }

    private struct ProbeResult {
        let total: Int64
        let validator: String?
        let fileName: String?
    }

    private override init() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackDown", isDirectory: true)
        downloadsDirectory = docs.appendingPathComponent("Downloads", isDirectory: true)
        supportDirectory = support
        resumeDirectory = support.appendingPathComponent("resume", isDirectory: true)
        partsRoot = support.appendingPathComponent("parts", isDirectory: true)

        let probeConfig = URLSessionConfiguration.default
        probeConfig.timeoutIntervalForRequest = 15
        probeConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        probeSession = URLSession(configuration: probeConfig)
        super.init()

        for dir in [downloadsDirectory, supportDirectory, resumeDirectory, partsRoot] {
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
        // 멈춘 연결은 빨리 끊고 그 조각만 다시 받는다
        config.timeoutIntervalForRequest = 30
        // 동시 연결 수는 앱이 조각 단위로 직접 조절한다
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
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
        save(force: true)
        refreshKeepAlive()
        prepare(item.id)
    }

    func pause(_ id: UUID) {
        guard let idx = index(of: id), !items[idx].isForeground, items[idx].state != .merging else { return }
        items[idx].state = .paused
        speeds[id] = nil
        speedSamples[id] = nil
        if items[idx].segments != nil {
            cancelSegments(id)
            refreshReceived(id)
        } else if let task = tasks[id] {
            cancelledTasks.insert(task.taskIdentifier)
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
        items[idx].errorMessage = nil
        if items[idx].segments != nil {
            for i in items[idx].segments!.indices { items[idx].segments![i].retries = 0 }
            segmentCooldown[id] = nil
            adaptiveLimit[id] = nil
            validateParts(id)
            items[idx].state = .downloading
            pumpSegments(id)
        } else if let task = tasks[id] {
            task.resume()
            items[idx].state = .downloading
        } else if fm.fileExists(atPath: resumeURL(id).path) {
            startTask(for: id)
        } else {
            prepare(id)
        }
    }

    /// 처음부터 다시 받기 (이어받기 데이터·받은 조각 폐기)
    func restart(_ id: UUID) {
        guard let idx = index(of: id), !items[idx].isForeground, items[idx].state != .merging else { return }
        if let task = tasks[id] {
            cancelledTasks.insert(task.taskIdentifier)
            task.cancel()
            tasks[id] = nil
        }
        cancelSegments(id)
        adaptiveLimit[id] = nil
        try? fm.removeItem(at: resumeURL(id))
        try? fm.removeItem(at: partsDirectory(id))
        items[idx].segments = nil
        items[idx].validator = nil
        items[idx].receivedBytes = 0
        items[idx].retryCount = 0
        prepare(id)
    }

    func remove(_ id: UUID, deleteFile: Bool) {
        if let task = tasks[id] {
            cancelledTasks.insert(task.taskIdentifier)
            task.cancel()
        }
        tasks[id] = nil
        cancelSegments(id)
        adaptiveLimit[id] = nil
        speeds[id] = nil
        try? fm.removeItem(at: resumeURL(id))
        if !merging.contains(id) {
            try? fm.removeItem(at: partsDirectory(id))
        }
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

    /// 설정에서 동시 연결 수를 바꾸면 진행 중인 분할 다운로드에 바로 반영
    func connectionsChanged() {
        for item in items where item.segments != nil && (item.state == .downloading || item.state == .waiting) {
            pumpSegments(item.id)
        }
    }

    /// 지금 열려 있는 연결 수 (UI 표시용)
    func activeConnections(for id: UUID) -> Int {
        if let count = segmentTasks[id]?.count, count > 0 { return count }
        return tasks[id] == nil ? 0 : 1
    }

    func isProbing(_ id: UUID) -> Bool {
        probing.contains(id)
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

    /// taskDescription: 단일 연결은 "<uuid>", 조각은 "<uuid>#<번호>"
    private func taskKey(_ task: URLSessionTask) -> (id: UUID, segment: Int?)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "#", maxSplits: 1)
        guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
        if parts.count == 2 {
            guard let segment = Int(parts[1]) else { return nil }
            return (id, segment)
        }
        return (id, nil)
    }

    private func resumeURL(_ id: UUID) -> URL {
        resumeDirectory.appendingPathComponent("\(id.uuidString).resume")
    }

    private func partsDirectory(_ id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func partURL(_ id: UUID, _ segment: Int) -> URL {
        partsDirectory(id).appendingPathComponent("\(segment).part")
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func baseRequest(for item: DownloadItem) -> URLRequest {
        var request = URLRequest(url: item.url)
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// 단일 연결 다운로드 시작 (resumeData가 있으면 이어받기)
    private func startTask(for id: UUID) {
        guard let idx = index(of: id) else { return }
        items[idx].segments = nil
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL(id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: baseRequest(for: items[idx]))
            items[idx].receivedBytes = 0
        }
        task.taskDescription = id.uuidString
        task.priority = URLSessionTask.highPriority
        tasks[id] = task
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        task.resume()
        save(force: true)
        refreshKeepAlive()
    }

    // MARK: - Multi-connection (segmented) download

    /// 서버가 Range를 지원하는지 먼저 확인하고, 되면 분할, 안 되면 단일 연결로 받는다.
    private func prepare(_ id: UUID) {
        guard let idx = index(of: id), !probing.contains(id) else { return }
        let connections = DownloadSettings.connections
        guard connections > 1 else {
            startTask(for: id)
            return
        }
        probing.insert(id)
        items[idx].state = .queued
        items[idx].errorMessage = nil
        let request = baseRequest(for: items[idx])
        let probeSession = self.probeSession
        Task {
            let result = await Self.probe(request, session: probeSession)
            DispatchQueue.main.async {
                self.finishProbe(id, result: result, connections: connections)
            }
        }
    }

    /// `Range: bytes=0-0` 요청으로 전체 크기·Range 지원 여부를 알아낸다. 헤더만 받고 바로 끊는다.
    private static func probe(_ base: URLRequest, session: URLSession) async -> ProbeResult? {
        var request = base
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                  let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let slash = range.lastIndex(of: "/"),
                  let total = Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
                  total > 0
            else { return nil }
            // 약한 ETag(W/)는 If-Range에 쓸 수 없다
            let etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
            let validator = etag ?? http.value(forHTTPHeaderField: "Last-Modified")
            return ProbeResult(total: total, validator: validator, fileName: http.suggestedFilename)
        } catch {
            return nil
        }
    }

    private func finishProbe(_ id: UUID, result: ProbeResult?, connections: Int) {
        probing.remove(id)
        // 확인하는 동안 일시정지/삭제됐으면 아무것도 안 함
        guard let idx = index(of: id), items[idx].state == .queued else { return }
        guard let result, result.total >= Self.minSegmentedSize else {
            startTask(for: id)
            return
        }
        if !items[idx].nameFromServer, let name = result.fileName.flatMap(Self.sanitize) {
            items[idx].fileName = name
            items[idx].nameFromServer = true
        }
        items[idx].totalBytes = result.total
        items[idx].receivedBytes = 0
        items[idx].validator = result.validator
        items[idx].segments = Self.makeSegments(total: result.total, connections: connections)
        try? fm.removeItem(at: partsDirectory(id))
        try? fm.createDirectory(at: partsDirectory(id), withIntermediateDirectories: true)
        items[idx].state = .downloading
        pumpSegments(id)
    }

    /// 조각 크기 = 전체 / 연결 수, 1MB~16MB로 제한. 큰 파일은 조각이 많아지고 동시에 N개씩 받는다.
    private static func makeSegments(total: Int64, connections: Int) -> [DownloadSegment] {
        let target = (total + Int64(connections) - 1) / Int64(connections)
        let size = min(max(target, minSegmentSize), maxSegmentSize)
        var result: [DownloadSegment] = []
        var start: Int64 = 0
        while start < total {
            let end = min(start + size, total) - 1
            result.append(DownloadSegment(start: start, end: end))
            start = end + 1
        }
        return result
    }

    private func segmentRequest(_ item: DownloadItem, _ segment: DownloadSegment) -> URLRequest {
        var request = baseRequest(for: item)
        request.setValue("bytes=\(segment.start)-\(segment.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator = item.validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    /// 빈 연결 슬롯만큼 다음 조각을 시작한다. 다 받았으면 합친다.
    private func pumpSegments(_ id: UUID) {
        guard let idx = index(of: id), let segments = items[idx].segments else { return }
        let state = items[idx].state
        guard state == .downloading || state == .waiting || state == .queued else { return }

        var active = segmentTasks[id] ?? [:]
        if segments.allSatisfy(\.done) {
            if active.isEmpty { merge(id) }
            return
        }
        guard networkAvailable else {
            if active.isEmpty { items[idx].state = .waiting }
            save(force: true)
            return
        }

        let limit = min(DownloadSettings.connections, adaptiveLimit[id] ?? .max)
        let now = Date()
        var nextCooldown: Date?
        for i in segments.indices where !segments[i].done && active[i] == nil {
            guard active.count < limit else { break }
            if let until = segmentCooldown[id]?[i], until > now {
                nextCooldown = min(nextCooldown ?? until, until)
                continue
            }
            let task = session.downloadTask(with: segmentRequest(items[idx], segments[i]))
            task.taskDescription = "\(id.uuidString)#\(i)"
            task.priority = URLSessionTask.highPriority
            active[i] = task
            task.resume()
        }
        segmentTasks[id] = active

        if active.isEmpty {
            items[idx].state = .waiting
        } else {
            items[idx].state = .downloading
        }
        if let nextCooldown {
            let delay = max(0.2, nextCooldown.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pumpSegments(id)
            }
        }
        refreshReceived(id)
        save(force: true)
        refreshKeepAlive()
    }

    private func cancelSegments(_ id: UUID) {
        for task in (segmentTasks[id] ?? [:]).values {
            cancelledTasks.insert(task.taskIdentifier)
            task.cancel()
        }
        segmentTasks[id] = nil
        segmentBytes[id] = nil
        segmentCooldown[id] = nil
    }

    private func refreshReceived(_ id: UUID) {
        guard let idx = index(of: id), let segments = items[idx].segments else { return }
        let done = segments.reduce(Int64(0)) { $0 + ($1.done ? $1.length : 0) }
        let inFlight = segmentBytes[id]?.values.reduce(0, +) ?? 0
        items[idx].receivedBytes = min(done + inFlight, items[idx].totalBytes)
    }

    /// 완료 표시된 조각인데 파일이 없거나 크기가 다르면 다시 받도록 되돌린다.
    private func validateParts(_ id: UUID) {
        guard let idx = index(of: id), let segments = items[idx].segments else { return }
        for i in segments.indices where segments[i].done {
            if fileSize(partURL(id, i)) != segments[i].length {
                items[idx].segments![i].done = false
            }
        }
        try? fm.removeItem(at: partsDirectory(id).appendingPathComponent("merged.tmp"))
        refreshReceived(id)
    }

    /// 서버가 Range를 제대로 지원하지 않음 → 받은 조각을 버리고 단일 연결로 처음부터
    private func fallBackToSingle(_ id: UUID, reason: String) {
        cancelSegments(id)
        adaptiveLimit[id] = nil
        try? fm.removeItem(at: partsDirectory(id))
        guard let idx = index(of: id) else { return }
        print("BackDown: segmented download disabled for \(items[idx].fileName): \(reason)")
        items[idx].segments = nil
        items[idx].validator = nil
        items[idx].receivedBytes = 0
        speedSamples[id] = nil
        startTask(for: id)
    }

    private func failItem(_ id: UUID, message: String) {
        cancelSegments(id)
        guard let idx = index(of: id) else { return }
        items[idx].state = .failed
        items[idx].errorMessage = message
        speeds[id] = nil
        refreshReceived(id)
        Notifier.post(title: "다운로드 실패", body: items[idx].fileName)
        save(force: true)
        refreshKeepAlive()
    }

    /// didFinishDownloadingTo: 받은 조각을 검증하고 parts 폴더로 옮긴다 (location은 반환 즉시 삭제됨)
    private func finishSegment(_ id: UUID, _ i: Int, task: URLSessionDownloadTask, location: URL) {
        guard let idx = index(of: id), let segments = items[idx].segments, segments.indices.contains(i) else { return }
        let segment = segments[i]
        let http = task.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        switch status {
        case 206:
            break
        case 200:
            // Range 무시, 또는 If-Range 불일치(서버 파일이 바뀜)
            segmentFailures[task.taskIdentifier] = .fallback("HTTP 200 (Range 미지원)")
            return
        case 408, 425, 429, 500, 502, 503, 504:
            segmentFailures[task.taskIdentifier] = .retry("HTTP \(status)", throttled: status == 429 || status == 503)
            return
        default:
            segmentFailures[task.taskIdentifier] = .fallback("HTTP \(status)")
            return
        }

        let rangeStart = http?.value(forHTTPHeaderField: "Content-Range").flatMap(Self.contentRangeStart)
        guard rangeStart == nil || rangeStart == segment.start else {
            segmentFailures[task.taskIdentifier] = .fallback("Content-Range 불일치")
            return
        }
        guard fileSize(location) == segment.length else {
            segmentFailures[task.taskIdentifier] = .retry("조각 크기 불일치", throttled: false)
            return
        }
        let destination = partURL(id, i)
        do {
            try fm.createDirectory(at: partsDirectory(id), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            items[idx].segments![i].done = true
        } catch {
            segmentFailures[task.taskIdentifier] = .fatal("파일 저장 실패: \(error.localizedDescription)")
        }
    }

    /// didCompleteWithError: 조각 하나가 끝남 → 다음 조각 시작, 실패면 백오프 후 재시도
    private func completeSegment(_ id: UUID, _ i: Int, task: URLSessionTask, error: NSError?) {
        if segmentTasks[id]?[i] === task { segmentTasks[id]?[i] = nil }
        segmentBytes[id]?[i] = nil
        let recorded = segmentFailures.removeValue(forKey: task.taskIdentifier)
        if cancelledTasks.remove(task.taskIdentifier) != nil { return }
        guard let idx = index(of: id), let segments = items[idx].segments, segments.indices.contains(i),
              items[idx].isActive else { return }

        var failure = recorded
        if let error {
            failure = Self.isRetryable(error)
                ? .retry(error.localizedDescription, throttled: false)
                : .fatal(error.localizedDescription)
        } else if failure == nil && !segments[i].done {
            failure = .retry("알 수 없는 오류", throttled: false)
        }

        switch failure {
        case nil:
            segmentCooldown[id]?[i] = nil
            items[idx].retryCount = 0
            pumpSegments(id)
        case .fallback(let reason):
            fallBackToSingle(id, reason: reason)
        case .fatal(let message):
            failItem(id, message: message)
        case .retry(let message, let throttled):
            items[idx].segments![i].retries += 1
            let retries = items[idx].segments![i].retries
            items[idx].retryCount = retries
            items[idx].errorMessage = message
            guard retries <= Self.maxSegmentRetries else {
                failItem(id, message: message)
                return
            }
            if throttled {
                // 서버가 연결이 너무 많다고 함 → 동시 연결 절반으로
                let current = max(segmentTasks[id]?.count ?? 1, 1)
                adaptiveLimit[id] = max(1, min(adaptiveLimit[id] ?? .max, (current + 1) / 2))
            }
            let delay = min(pow(2, Double(retries - 1)), 30)
            segmentCooldown[id, default: [:]][i] = Date().addingTimeInterval(delay)
            pumpSegments(id)
        }
    }

    /// 조각 파일을 순서대로 이어 붙인다 (백그라운드 큐, 4MB 버퍼)
    private func merge(_ id: UUID) {
        guard let idx = index(of: id), let segments = items[idx].segments, !merging.contains(id) else { return }
        merging.insert(id)
        items[idx].state = .merging
        items[idx].receivedBytes = items[idx].totalBytes
        speeds[id] = nil
        speedSamples[id] = nil
        save(force: true)

        let parts = segments.indices.map { partURL(id, $0) }
        let temp = partsDirectory(id).appendingPathComponent("merged.tmp")
        let expected = items[idx].totalBytes
        mergeQueue.async {
            let result = Result { try Self.concatenate(parts, into: temp, expectedSize: expected) }
            DispatchQueue.main.async {
                self.finishMerge(id, temp: temp, result: result)
            }
        }
    }

    private func finishMerge(_ id: UUID, temp: URL, result: Result<Void, Error>) {
        merging.remove(id)
        guard let idx = index(of: id) else {
            // 합치는 도중 목록에서 삭제됨
            try? fm.removeItem(at: partsDirectory(id))
            return
        }
        do {
            try result.get()
            let destination = uniqueDestination(for: items[idx].fileName)
            try fm.moveItem(at: temp, to: destination)
            try? fm.removeItem(at: partsDirectory(id))
            items[idx].segments = nil
            adaptiveLimit[id] = nil
            markCompleted(idx, fileURL: destination)
        } catch {
            // 사라진 조각은 다시 받도록 되돌리고, 재개하면 이어서 받는다
            validateParts(id)
            items[idx].state = .failed
            items[idx].errorMessage = "파일 합치기 실패: \(error.localizedDescription)"
            Notifier.post(title: "다운로드 실패", body: items[idx].fileName)
            save(force: true)
            refreshKeepAlive()
        }
    }

    private struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func concatenate(_ parts: [URL], into output: URL, expectedSize: Int64) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        guard let first = parts.first else { throw MergeError(message: "조각 없음") }
        // 첫 조각은 복사 없이 이름만 바꿔서 시작
        try fm.moveItem(at: first, to: output)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try writer.seekToEnd()
        for part in parts.dropFirst() {
            let reader = try FileHandle(forReadingFrom: part)
            defer { try? reader.close() }
            while true {
                let chunk: Data? = try autoreleasepool { try reader.read(upToCount: 4 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
            }
            try? fm.removeItem(at: part)
        }
        try writer.synchronize()
        let size = (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else {
            throw MergeError(message: "크기 불일치 (\(size) / \(expectedSize))")
        }
    }

    /// "bytes 100-199/1000" → 100
    private static func contentRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash])
    }

    // MARK: - Relaunch / network

    /// 앱 재실행 시 시스템에 살아 있는 task를 다시 연결하고, 끊긴 항목은 이어받기를 시도한다.
    private func reattach() {
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in all {
                    guard let download = task as? URLSessionDownloadTask,
                          let key = self.taskKey(task),
                          let idx = self.index(of: key.id) else {
                        self.cancelledTasks.insert(task.taskIdentifier)
                        task.cancel()
                        continue
                    }
                    if let segment = key.segment {
                        guard let segments = self.items[idx].segments, segments.indices.contains(segment),
                              !segments[segment].done, self.items[idx].isActive, self.items[idx].state != .merging else {
                            self.cancelledTasks.insert(task.taskIdentifier)
                            task.cancel()
                            continue
                        }
                        self.segmentTasks[key.id, default: [:]][segment] = download
                        self.items[idx].state = .downloading
                    } else {
                        guard self.items[idx].segments == nil else {
                            self.cancelledTasks.insert(task.taskIdentifier)
                            task.cancel()
                            continue
                        }
                        self.tasks[key.id] = download
                        if self.items[idx].state != .paused {
                            self.items[idx].state = .downloading
                        }
                    }
                }
                for item in self.items {
                    guard let idx = self.index(of: item.id) else { continue }
                    if item.isForeground {
                        if item.state == .downloading {
                            self.items[idx].state = .failed
                            self.items[idx].errorMessage = "앱이 종료되어 중단됨 (앱 내 다운로드는 이어받기 불가)"
                        }
                    } else if item.segments != nil {
                        guard item.isActive else { continue }
                        self.validateParts(item.id)
                        if self.items[idx].state == .merging { self.items[idx].state = .downloading }
                        self.pumpSegments(item.id)
                    } else if item.isActive && self.tasks[item.id] == nil {
                        if item.state == .queued && !self.fm.fileExists(atPath: self.resumeURL(item.id).path) {
                            self.prepare(item.id)
                        } else {
                            self.startTask(for: item.id)
                        }
                    }
                }
                self.cleanOrphanParts()
                self.save(force: true)
                self.refreshKeepAlive()
            }
        }
    }

    /// 목록에 없는 다운로드의 조각 폴더 정리
    private func cleanOrphanParts() {
        let known = Set(items.map(\.id.uuidString))
        let dirs = (try? fm.contentsOfDirectory(atPath: partsRoot.path)) ?? []
        for name in dirs where !known.contains(name) {
            try? fm.removeItem(at: partsRoot.appendingPathComponent(name))
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
                for item in self.items where item.state == .waiting {
                    if item.segments != nil {
                        // 네트워크가 돌아오면 대기 없이 바로 재시도
                        self.segmentCooldown[item.id] = nil
                        self.pumpSegments(item.id)
                    } else if self.tasks[item.id] == nil {
                        self.startTask(for: item.id)
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "BackDown.network"))
    }

    private func markCompleted(_ idx: Int, fileURL: URL) {
        let id = items[idx].id
        let size = fileSize(fileURL)
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
            // 앱 강제 종료 등으로 시스템이 취소한 경우 (사용자 취소는 cancelledTasks로 걸러짐)
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
        guard let key = taskKey(downloadTask), let idx = index(of: key.id) else { return }
        let id = key.id
        if let segment = key.segment {
            segmentBytes[id, default: [:]][segment] = totalBytesWritten
        }
        let now = Date()
        // UI 갱신은 초당 ~4회로 제한
        if let last = lastUIUpdate[id], now.timeIntervalSince(last) < 0.25 { return }
        lastUIUpdate[id] = now
        if key.segment != nil {
            refreshReceived(id)
        } else {
            items[idx].receivedBytes = totalBytesWritten
            items[idx].totalBytes = totalBytesExpectedToWrite
            items[idx].retryCount = 0
        }
        updateSpeed(id, bytes: items[idx].receivedBytes)
        if items[idx].state == .waiting || items[idx].state == .queued {
            items[idx].state = .downloading
        }
        save()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let key = taskKey(downloadTask), key.segment == nil, let idx = index(of: key.id) else { return }
        items[idx].receivedBytes = fileOffset
        items[idx].totalBytes = expectedTotalBytes
        speedSamples[key.id] = (Date(), fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = taskKey(downloadTask) else { return }
        if let segment = key.segment {
            finishSegment(key.id, segment, task: downloadTask, location: location)
            return
        }
        guard let idx = index(of: key.id) else { return }
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
        guard let key = taskKey(task) else { return }
        let id = key.id
        let nsError = error as NSError?
        if let segment = key.segment {
            completeSegment(id, segment, task: task, error: nsError)
            return
        }

        if tasks[id] === task { tasks[id] = nil }
        speeds[id] = nil
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resumeData { try? resumeData.write(to: resumeURL(id)) }

        if cancelledTasks.remove(task.taskIdentifier) != nil {
            save(force: true)
            return
        }
        guard let idx = index(of: id), items[idx].segments == nil else { return }

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
