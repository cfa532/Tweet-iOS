import Foundation
import UIKit

/// Persists measured tweet cell heights to UserDefaults so they survive app restarts.
/// Mirrors the TweetAccessTimes pattern in TweetCacheManager.
class TweetHeightCache {
    static let shared = TweetHeightCache()

    private let userDefaultsKey = "TweetHeightCache"
    private let maxEntries = 2000
    private var heights: [String: CGFloat] = [:]

    private init() {
        // Disk persistence disabled for testing — heights are in-memory only this session
        // loadFromDisk()
        // NotificationCenter.default.addObserver(
        //     self,
        //     selector: #selector(saveToDisk),
        //     name: UIApplication.didEnterBackgroundNotification,
        //     object: nil
        // )
    }

    func getHeight(for mid: String) -> CGFloat? {
        heights[mid]
    }

    func setHeight(_ height: CGFloat, for mid: String) {
        heights[mid] = height
        // Trim in-memory cache when exceeding limit to prevent unbounded growth
        if heights.count > maxEntries {
            let excess = heights.count - maxEntries
            let keysToRemove = Array(heights.keys.prefix(excess))
            for key in keysToRemove {
                heights.removeValue(forKey: key)
            }
        }
    }

    func removeHeight(for mid: String) {
        heights.removeValue(forKey: mid)
    }

    @objc func saveToDisk() {
        var toSave = heights
        // Trim to maxEntries if needed (drop arbitrary entries to stay within limit)
        if toSave.count > maxEntries {
            let excess = toSave.count - maxEntries
            for key in toSave.keys.prefix(excess) {
                toSave.removeValue(forKey: key)
            }
        }
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            heights = saved
        }
    }
}
