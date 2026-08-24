import Foundation
import UIKit

/// Persists measured tweet cell heights to UserDefaults so they survive app restarts.
/// Mirrors the TweetAccessTimes pattern in TweetCacheManager.
final class TweetHeightCache: NSObject, @unchecked Sendable {
    static let shared = TweetHeightCache()

    /// Bump whenever the row-height CALCULATION changes, not just the storage format.
    ///
    /// `heightForRowAt` serves this cache ahead of `calculateTweetHeight`, and `willDisplay`
    /// re-persists whatever height UIKit actually laid the cell out at — which came from
    /// this cache. So a stale entry is self-sustaining: it is re-blessed on every display
    /// and the sub-pixel reconcile in `performPendingHeightRelayout` drops anything within
    /// 1.5pt. Without a version bump, an installed user would keep heights produced by the
    /// previous calculator indefinitely and never see the fix.
    ///
    /// v6: heights now match the cell's Auto Layout exactly (see docs/FEED_ROW_HEIGHTS.md).
    private let userDefaultsKey = "TweetHeightCache.v6"
    private let supersededUserDefaultsKeys = [
        "TweetHeightCache", "TweetHeightCache.v2", "TweetHeightCache.v3",
        "TweetHeightCache.v4", "TweetHeightCache.v5",
    ]
    private let maxEntries = 2000
    private var heights: [String: CGFloat] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        removeSupersededVersions()
        loadFromDisk()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveToDisk),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveToDisk),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func getHeight(for mid: String, width: CGFloat) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heights[cacheKey(for: mid, width: width)]
    }

    func setHeight(_ height: CGFloat, for mid: String, width: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        heights[cacheKey(for: mid, width: width)] = height
        trimIfNeededLocked()
    }

    /// Drops the persisted heights for one tweet.
    ///
    /// Deliberately does NOT write to disk: this runs from willDisplay/didEndDisplaying
    /// while the feed is scrolling, and saveToDisk() JSON-encodes the whole table (up to
    /// `maxEntries`) on the main thread — a dropped frame every time a row's height was
    /// invalidated mid-scroll. The background/terminate observers persist the result.
    func removeHeight(for mid: String) {
        lock.lock()
        defer { lock.unlock() }
        for key in heights.keys where key == mid || key.hasPrefix("\(mid)|") {
            heights.removeValue(forKey: key)
        }
    }

    func clearAll() {
        lock.lock()
        heights.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func cacheKey(for mid: String, width: CGFloat) -> String {
        "\(mid)|\(Int(width.rounded()))"
    }

    @objc func saveToDisk() {
        lock.lock()
        trimIfNeededLocked()
        let toSave = heights
        lock.unlock()

        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    /// Drops blobs written under an earlier calculator so they do not sit in UserDefaults
    /// forever after a version bump.
    private func removeSupersededVersions() {
        let defaults = UserDefaults.standard
        for key in supersededUserDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    private func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            lock.lock()
            heights = saved
            trimIfNeededLocked()
            lock.unlock()
        }
    }

    private func trimIfNeededLocked() {
        guard heights.count > maxEntries else { return }
        let excess = heights.count - maxEntries
        for key in Array(heights.keys.prefix(excess)) {
            heights.removeValue(forKey: key)
        }
    }
}
