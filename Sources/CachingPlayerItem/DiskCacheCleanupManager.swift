import Foundation

/// Automatic cleanup of the on-disk video cache: one `Caches/<mediaID>/` folder per video
/// (progressive `video.mp4` + range index, or HLS playlists and segments).
///
/// Policy:
/// - A video not used for 7 days is deleted. "Used" means a player or preload opened it
///   (`noteVideoUsed`), not merely that bytes were downloaded.
/// - The whole video cache is capped at 10 GB; above that, least recently used videos go first.
/// - Media of private, bookmarked or favorited posts is never deleted here, by age or by
///   size, and survives logout. Only a manual "Clear Media Cache" removes it.
final class DiskCacheCleanupManager: @unchecked Sendable {
    static let shared = DiskCacheCleanupManager()

    private init() {
        setupCleanupTimer()
    }

    // MARK: - Configuration
    private let retentionInterval: TimeInterval = 7 * 24 * 60 * 60 // 1 week since last use
    private let maxCacheBytes: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB for all videos
    private let cleanupCheckInterval: TimeInterval = 24 * 60 * 60 // Check daily
    private nonisolated(unsafe) var cleanupTimer: Timer?
    private let ioQueue = DispatchQueue(label: "com.tweet.videoDiskCache", qos: .utility)

    // MARK: - Cache Directory
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    // MARK: - Setup

    private func setupCleanupTimer() {
        // Run cleanup daily
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            self?.performScheduledCleanup()
        }

        // Perform initial cleanup after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            self.performScheduledCleanup()
        }
    }

    // MARK: - Public Methods

    /// Record that a video was opened for playback or preload. Its folder's modification
    /// date is the last-use time that age and size cleanup sort by; downloads alone only
    /// move it when a file is added to the folder.
    func noteVideoUsed(mediaID: String) {
        let folder = cacheDirectory.appendingPathComponent(mediaID)
        ioQueue.async {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        }
    }

    /// Perform scheduled cleanup of old cache files
    func performScheduledCleanup() {
        Task.detached(priority: .utility) { [weak self] in
            let permanent = await TweetCacheManager.shared.permanentMediaIDs()
            // Bind once: the queue closure must capture a constant, not the weak var.
            guard let self else { return }
            self.ioQueue.async { self.cleanupCacheFolders(keeping: permanent) }
        }
    }

    /// Manually clear all cache (for settings)
    func clearAllCache() {
        ioQueue.async { [weak self] in
            self?.clearAllCacheFiles()
        }
    }

    // MARK: - Private Methods

    private struct VideoFolder {
        let url: URL
        let mediaID: String
        let lastUsed: Date
        let bytes: Int64
    }

    private func videoFolders() -> [VideoFolder] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.compactMap { url in
            let mediaID = url.lastPathComponent
            guard url.hasDirectoryPath, isValidMediaID(mediaID) else { return nil }
            let lastUsed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return VideoFolder(url: url, mediaID: mediaID, lastUsed: lastUsed,
                               bytes: FileManager.default.allocatedSizeOfDirectory(at: url))
        }
    }

    private func cleanupCacheFolders(keeping permanent: Set<String>) {
        let now = Date()
        var expired = 0
        var evicted = 0
        var remaining: [VideoFolder] = []

        for folder in videoFolders() {
            if !permanent.contains(folder.mediaID),
               now.timeIntervalSince(folder.lastUsed) > retentionInterval,
               (try? FileManager.default.removeItem(at: folder.url)) != nil {
                expired += 1
            } else {
                remaining.append(folder)
            }
        }

        // Permanent media counts toward the cap but is never evicted for it.
        var total = remaining.reduce(Int64(0)) { $0 + $1.bytes }
        if total > maxCacheBytes {
            let evictable = remaining
                .filter { !permanent.contains($0.mediaID) }
                .sorted { $0.lastUsed < $1.lastUsed }
            for folder in evictable where total > maxCacheBytes {
                if (try? FileManager.default.removeItem(at: folder.url)) != nil {
                    total -= folder.bytes
                    evicted += 1
                }
            }
        }

        print("DEBUG: [DiskCacheCleanupManager] Video cache: removed \(expired) unused for 7 days, \(evicted) over the 10 GB cap; \(total / 1_048_576) MB kept, \(permanent.count) permanent media IDs protected")
    }

    private func clearAllCacheFiles() {
        for folder in videoFolders() {
            try? FileManager.default.removeItem(at: folder.url)
        }
        print("DEBUG: [DiskCacheCleanupManager] Cleared all video cache folders")
    }

    /// Video folders are named by IPFS CID (Qm..., 46 characters).
    private func isValidMediaID(_ mediaID: String) -> Bool {
        return mediaID.hasPrefix("Qm") && mediaID.count == 46
    }

    deinit {
        cleanupTimer?.invalidate()
    }
}

// MARK: - FileManager Extension for Directory Size
extension FileManager {
    /// Disk space occupied by everything under `url`, including subfolders (HLS keeps
    /// segments in per-resolution folders). Allocated size, because sparse progressive
    /// caches have a large logical length after seeking.
    func allocatedSizeOfDirectory(at url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let allocated = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }
}
