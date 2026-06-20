import Foundation
import UIKit

/// Persists measured tweet cell heights to UserDefaults so they survive app restarts.
/// Mirrors the TweetAccessTimes pattern in TweetCacheManager.
final class TweetHeightCache: NSObject {
    static let shared = TweetHeightCache()

    private let userDefaultsKey = "TweetHeightCache.v2"
    private let maxEntries = 2000
    private var heights: [String: CGFloat] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
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

    func removeHeight(for mid: String) {
        lock.lock()
        let keysToRemove = heights.keys
            .filter { $0 == mid || $0.hasPrefix("\(mid)|") }
        for key in keysToRemove {
            heights.removeValue(forKey: key)
        }
        lock.unlock()

        if !keysToRemove.isEmpty {
            saveToDisk()
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
