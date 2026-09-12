import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The asset owns the delegate because AVFoundation keeps only a weak reference.
/// Keeping ownership here also covers callers that create fresh items from a cached asset.
final class ProgressiveVideoAsset: AVURLAsset, @unchecked Sendable {
    private let loader: ProgressiveResourceLoader

    init(remoteURL: URL, mediaID: String) throws {
        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        components?.scheme = "tweet-progressive"
        guard let resourceURL = components?.url else { throw URLError(.badURL) }
        loader = ProgressiveResourceLoader(remoteURL: remoteURL, mediaID: mediaID)
        super.init(url: resourceURL, options: nil)
        resourceLoader.setDelegate(loader, queue: ProgressiveResourceLoader.queue)
    }

    override func cancelLoading() {
        loader.cancelRequests()
        super.cancelLoading()
    }

    deinit { loader.invalidate() }
}

/// All request state, AVFoundation responses, and range-cache I/O run on one
/// serial queue, including URLSession callbacks. No video model crosses actors.
final class ProgressiveResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "video.progressive.resources", qos: .userInitiated)
    private final class WeakLoader {
        weak var value: ProgressiveResourceLoader?
        init(_ value: ProgressiveResourceLoader) { self.value = value }
    }
    // Accessed exclusively on queue; weak entries must not keep assets downloading.
    private nonisolated(unsafe) static var loaders: [WeakLoader] = []

    private final class Request: @unchecked Sendable {
        let loading: AVAssetResourceLoadingRequest
        var waiting: Task<Void, Never>?
        var task: URLSessionDataTask?
        var priority: NodeDownloadPriority?
        var offset: Int64
        var responseEnd: Int64 = 0
        var total: Int64?
        var finished = false

        init(_ loading: AVAssetResourceLoadingRequest) {
            self.loading = loading
            offset = loading.dataRequest?.currentOffset ?? 0
        }
    }

    private let remoteURL: URL
    private let mediaID: String
    private let pool: NodeConnectionPool
    private let cache: ProgressiveRangeCache
    private let contentType: String
    private var requests: [ObjectIdentifier: Request] = [:]
    private var transfers: [Int: Request] = [:]
    private var invalidated = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = Self.queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }()

    init(remoteURL: URL, mediaID: String) {
        self.remoteURL = remoteURL
        self.mediaID = mediaID
        pool = NodePoolRegistry.shared.pool(for: NodePoolRegistry.nodeHost(from: remoteURL))
        cache = ProgressiveRangeCache(mediaID: mediaID)
        contentType = UTType(filenameExtension: remoteURL.pathExtension)?.identifier ?? UTType.mpeg4Movie.identifier
        super.init()
        Self.queue.async { [weak self] in
            Self.loaders.removeAll { $0.value == nil }
            if let self { Self.loaders.append(WeakLoader(self)) }
        }
    }

    static func cancelRequests(for mediaID: String) {
        queue.async {
            loaders.removeAll { $0.value == nil }
            for loader in loaders.compactMap(\.value) where loader.mediaID == mediaID {
                loader.cancelAll()
            }
        }
    }

    func cancelRequests() {
        Self.queue.async { self.cancelAll() }
    }

    func invalidate() {
        Self.queue.async {
            self.invalidated = true
            self.cancelAll()
            self.session.invalidateAndCancel()
        }
    }

    private func cancelAll() {
        for request in Array(requests.values) {
            finish(request, error: URLError(.cancelled))
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated else { return false }
        let request = Request(loadingRequest)
        requests[ObjectIdentifier(loadingRequest)] = request
        guard !BlackList.shared.isBlacklisted(mediaID) else {
            finish(request, error: URLError(.resourceUnavailable))
            return true
        }
        do {
            request.total = try cache.snapshot().total
            serveCache(request)
        } catch {
            finish(request, error: error)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let request = requests[ObjectIdentifier(loadingRequest)] {
            finish(request, error: URLError(.cancelled))
        }
    }

    private func setInformation(_ request: Request, length: Int64, ranges: Bool) {
        let information = request.loading.contentInformationRequest
        information?.contentType = contentType
        information?.contentLength = length
        information?.isByteRangeAccessSupported = ranges
    }

    private func requestedEnd(_ request: Request, total: Int64) -> Int64 {
        guard let data = request.loading.dataRequest else { return 0 }
        if data.requestsAllDataToEndOfResource { return total }
        return min(total, data.requestedOffset + Int64(data.requestedLength))
    }

    private func serveCache(_ request: Request) {
        guard !request.finished else { return }
        if let total = request.total {
            setInformation(request, length: total, ranges: true)
            let end = requestedEnd(request, total: total)
            if request.offset >= end {
                finish(request)
                return
            }
            do {
                if let data = try cache.read(at: request.offset, count: min(64 * 1024, end - request.offset)) {
                    request.loading.dataRequest?.respond(with: data)
                    request.offset += Int64(data.count)
                    // Yield between disk chunks so seeks and cancellations are serviced.
                    Self.queue.async { self.serveCache(request) }
                    return
                }
            } catch {
                finish(request, error: error)
                return
            }
        }
        acquireAndStart(request)
    }

    private func acquireAndStart(_ request: Request) {
        let mediaID = mediaID
        let pool = pool
        request.waiting = Task.detached { [weak self] in
            do {
                // Use the same primary/visible/preload policy as HLS, without
                // requiring its HTTP listener to be running.
                while true {
                    try Task.checkCancellation()
                    let priority = LocalHTTPServer.shared.downloadPriority(for: mediaID)
                    if await pool.acquireSlot(mediaID: mediaID, priority: priority, primarySlotCap: 2) {
                        Self.queue.async { [weak self] in
                            guard let self, !request.finished else {
                                Task { await pool.releaseSlot(mediaID: mediaID, priority: priority) }
                                return
                            }
                            request.priority = priority
                            self.start(request)
                        }
                        return
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                Self.queue.async { [weak self] in self?.finish(request, error: error) }
            }
        }
    }

    private func start(_ request: Request) {
        request.waiting = nil
        var upstream = URLRequest(url: remoteURL)
        // Stop the network range before the next cached interval. Completion of
        // this transfer resumes the same AVFoundation request from disk.
        let end: String
        do {
            let snapshot = try cache.snapshot()
            request.total = request.total ?? snapshot.total
            if request.loading.dataRequest == nil {
                end = "1"
            } else {
                let wantedEnd = request.total.map { requestedEnd(request, total: $0) }
                    ?? request.loading.dataRequest.flatMap { data in
                        data.requestsAllDataToEndOfResource ? nil
                            : data.requestedOffset + Int64(data.requestedLength)
                    }
                // Coverage alone cannot answer content information. If length
                // is unknown, fetch headers before trying to serve cached bytes.
                let nextCached = request.total == nil ? nil
                    : snapshot.ranges.first { $0.upperBound > request.offset }
                if let nextCached, nextCached.contains(request.offset) {
                    // Another request filled this gap while we waited for a slot.
                    releaseSlot(request)
                    serveCache(request)
                    return
                }
                let gapEnd = [wantedEnd, nextCached?.lowerBound].compactMap { $0 }.min()
                end = gapEnd.map { String($0 - 1) } ?? ""
            }
        } catch {
            finish(request, error: error)
            return
        }
        upstream.setValue("bytes=\(request.offset)-\(end)", forHTTPHeaderField: "Range")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: upstream)
        request.task = task
        transfers[task.taskIdentifier] = request
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let request = transfers[dataTask.taskIdentifier], !request.finished,
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let total: Int64
        let end: Int64
        if http.statusCode == 206,
           let header = http.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") {
            let pieces = header.dropFirst(6).split(separator: "/")
            let range = pieces.first?.split(separator: "-") ?? []
            guard pieces.count == 2, range.count == 2,
                  let start = Int64(range[0]), let last = Int64(range[1]), let length = Int64(pieces[1]),
                  start == request.offset, last >= start, length > last else {
                finish(request, error: URLError(.badServerResponse))
                completionHandler(.cancel)
                return
            }
            total = length
            end = last + 1
        } else if http.statusCode == 200, request.offset == 0, http.expectedContentLength > 0 {
            // A non-range server can still stream from the beginning without
            // buffering the whole response. A seek needs an actual 206 response.
            total = http.expectedContentLength
            end = total
        } else {
            finish(request, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        request.total = total
        request.responseEnd = end
        setInformation(request, length: total, ranges: http.statusCode == 206)
        if http.statusCode == 206 { cache.storeTotal(total) }
        if request.loading.dataRequest == nil {
            finish(request)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let request = transfers[dataTask.taskIdentifier], !request.finished,
              let total = request.total else { return }
        let end = requestedEnd(request, total: total)
        guard Int64(data.count) <= request.responseEnd - request.offset else {
            finish(request, error: URLError(.badServerResponse))
            return
        }
        let bytes = Data(data.prefix(Int(min(Int64(data.count), end - request.offset))))
        cache.write(bytes, at: request.offset)
        request.loading.dataRequest?.respond(with: bytes)
        request.offset += Int64(bytes.count)
        if request.offset == end { finish(request) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        releaseSlot(request)
        request.task = nil
        guard !request.finished else { return }
        if let error {
            finish(request, error: error)
        } else if request.offset == request.responseEnd {
            serveCache(request)
        } else {
            // A short body must not be treated as a completed gap.
            finish(request, error: URLError(.networkConnectionLost))
        }
    }

    private func releaseSlot(_ request: Request) {
        if let priority = request.priority {
            request.priority = nil
            let pool = pool
            let mediaID = mediaID
            Task { await pool.releaseSlot(mediaID: mediaID, priority: priority) }
        }
    }

    private func finish(_ request: Request, error: Error? = nil) {
        guard !request.finished else { return }
        request.finished = true
        request.waiting?.cancel()
        request.waiting = nil
        request.task?.cancel()
        // Running transfers release their slot in didComplete, after cancellation.
        if request.task == nil { releaseSlot(request) }
        requests.removeValue(forKey: ObjectIdentifier(request.loading))
        if !request.loading.isCancelled {
            if let error { request.loading.finishLoading(with: error) }
            else { request.loading.finishLoading() }
        }
    }
}

/// Indexed byte coverage is authoritative: a sparse file's length says nothing
/// about its holes. All writers run on ProgressiveResourceLoader.queue. Readers
/// outside that queue see an atomic index containing only finished disk writes.
struct ProgressiveRangeCache {
    struct Snapshot: Codable {
        var ranges: [Range<Int64>]
        var total: Int64?

        var cachedBytes: Int64 { ranges.reduce(0) { $0 + $1.count64 } }
        var contiguousBytes: Int64 { ranges.first?.lowerBound == 0 ? ranges[0].upperBound : 0 }
        var isComplete: Bool {
            guard let total, total > 0 else { return false }
            return ranges.count == 1 && ranges[0] == 0..<total
        }

        mutating func insert(_ arrived: Range<Int64>) {
            var merged: [Range<Int64>] = []
            for range in (ranges + [arrived]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            ranges = merged
        }

        func gaps(in requested: Range<Int64>) -> [Range<Int64>] {
            var cursor = requested.lowerBound
            var gaps: [Range<Int64>] = []
            for range in ranges where range.upperBound > cursor && range.lowerBound < requested.upperBound {
                if cursor < range.lowerBound { gaps.append(cursor..<range.lowerBound) }
                cursor = max(cursor, range.upperBound)
            }
            if cursor < requested.upperBound { gaps.append(cursor..<requested.upperBound) }
            return gaps
        }
    }

    private let directory: URL
    var file: URL { directory.appendingPathComponent("video.mp4") }
    private var index: URL { directory.appendingPathComponent("video.ranges") }
    private var contiguous: URL { directory.appendingPathComponent("video.contiguous") }
    private var metadata: URL { directory.appendingPathComponent("video.meta") }
    private let limit: Int64 = 50 * 1024 * 1024
    var hasIndex: Bool { FileManager.default.fileExists(atPath: index.path) }

    init(mediaID: String) {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(mediaID)
    }

    private func number(at url: URL) -> Int64? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func snapshot() throws -> Snapshot {
        if hasIndex {
            return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: index))
        }
        // Upgrade recorded legacy coverage, never infer it from file length or
        // scan its bytes. Existing cache content is neither repaired nor cleared.
        let prefix = number(at: contiguous) ?? 0
        return Snapshot(ranges: prefix > 0 ? [0..<prefix] : [], total: number(at: metadata))
    }

    private func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: index, options: .atomic)
    }

    func storeTotal(_ total: Int64) {
        do {
            var state = try snapshot()
            state.total = total
            try save(state)
        } catch { print("[Progressive cache] Metadata write failed: \(error)") }
    }

    func read(at offset: Int64, count: Int64) throws -> Data? {
        guard let range = try snapshot().ranges.first(where: { $0.contains(offset) }) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let expected = Int(min(count, range.upperBound - offset))
        guard let data = try handle.read(upToCount: expected), data.count == expected else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    func write(_ data: Data, at offset: Int64) {
        do {
            var state = try snapshot()
            var allowance = limit - state.cachedBytes
            guard allowance > 0, !data.isEmpty else { return }
            let gaps = state.gaps(in: offset..<(offset + Int64(data.count)))
            guard !gaps.isEmpty else { return }
            // Publish legacy coverage before the first sparse write, so existing
            // prefix readers cannot infer coverage from the newly extended file.
            if !hasIndex { try save(state) }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            for gap in gaps where allowance > 0 {
                let count = min(gap.count64, allowance)
                let start = Int(gap.lowerBound - offset)
                try handle.seek(toOffset: UInt64(gap.lowerBound))
                try handle.write(contentsOf: data.subdata(in: start..<(start + Int(count))))
                state.insert(gap.lowerBound..<(gap.lowerBound + count))
                allowance -= count
            }
            // Publish coverage after the bytes, including across process restarts.
            try handle.synchronize()
            try save(state)
        } catch { print("[Progressive cache] Range write failed: \(error)") }
    }
}

private extension Range where Bound == Int64 {
    var count64: Int64 { upperBound - lowerBound }
}
