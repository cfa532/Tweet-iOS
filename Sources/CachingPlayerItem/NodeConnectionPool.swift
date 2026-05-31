// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
//
// Separate caps for primary and preload downloads per node:
// Primary video:
//   - Never waits — acquires a slot immediately.
//   - Capped at primarySlotCap concurrent slots: 1 for HLS (sequential), 2 for progressive.
//   - Primary slots do NOT count toward the preload cap.
// Non-primary (preloads):
//   - Soft cap of maxPreloadSlots (3) concurrent downloads, counting only non-primary slots.
//   - Acquires immediately if nonPrimaryActive < maxPreloadSlots, otherwise returns false.
//   - Polling and primary-promotion handled by the proxy handler (not the pool).
//   - When primary changes, forceReleaseNonPrimary clears stale slot counts so
//     preloads see capacity (old IPFS downloads continue to disk cache uncounted).

import Foundation

// MARK: - NodeConnectionPool (actor, one per IPFS node host:port)

actor NodeConnectionPool {
    let nodeHost: String
#if DEBUG && VERBOSE_VIDEO_LOGS
    private static let verboseLogsEnabled = true
#else
    private static let verboseLogsEnabled = false
#endif
    /// Cap on concurrent preload downloads. Primary slots are separate and don't count here.
    private let maxPreloadSlots = 3

    /// Count of active IPFS slot holds per mediaID.
    private var activeSlots: [String: Int] = [:]

    /// The currently-playing primary mediaID. Its slots are excluded from the preload cap.
    private var primaryMediaID: String?

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    // MARK: - Public API

    /// Acquire a slot before starting an IPFS download. Non-blocking.
    ///
    /// Returns `true` if a slot was occupied (caller must call `releaseSlot` when done).
    /// Returns `false` in two cases (caller must NOT call `releaseSlot`):
    ///   - Primary at `primarySlotCap`: download still proceeds (no slot needed).
    ///   - Non-primary rejected (preload pool full): caller should poll and retry.
    ///
    /// - Primary (`isPrimary: true`): granted immediately; slots don't count toward preload cap.
    /// - Non-primary (`isPrimary: false`): granted if nonPrimaryActive < maxPreloadSlots,
    ///   otherwise returns `false`. Caller (proxy handler) manages retry polling.
    @discardableResult
    func acquireSlot(mediaID: String, isPrimary: Bool, primarySlotCap: Int = 1) -> Bool {
        let short = String(mediaID.prefix(8))
        if isPrimary {
            primaryMediaID = mediaID
            let current = activeSlots[mediaID] ?? 0
            if current < primarySlotCap {
                occupy(mediaID: mediaID)
                if Self.verboseLogsEnabled {
                    print("🎰 [POOL \(nodeHost)] PRIMARY \(short) slot \(current + 1)/\(primarySlotCap) (preload=\(nonPrimaryActive)/\(maxPreloadSlots))")
                }
                return true
            } else {
                return false
            }
        }
        if nonPrimaryActive < maxPreloadSlots {
            occupy(mediaID: mediaID)
            return true
        } else {
            return false  // caller polls; no per-attempt log to avoid spam
        }
    }

    /// Release a slot after an IPFS download completes or is cancelled.
    func releaseSlot(mediaID: String) {
        guard let count = activeSlots[mediaID] else { return }
        if count <= 1 { activeSlots.removeValue(forKey: mediaID) }
        else { activeSlots[mediaID] = count - 1 }
    }

    /// Force-release all slots except the new primary's. Called when primary changes.
    /// Old IPFS downloads continue to disk cache but no longer count toward the cap,
    /// freeing slots so preloads can acquire capacity.
    func forceReleaseNonPrimary(primaryMediaID: String?) {
        self.primaryMediaID = primaryMediaID
        var released = 0
        for (mediaID, count) in activeSlots where mediaID != primaryMediaID {
            activeSlots.removeValue(forKey: mediaID)
            released += count
        }
        if released > 0 {
            let short = primaryMediaID.map { String($0.prefix(8)) } ?? "nil"
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] force-released \(released) non-primary slots (primary=\(short), preload=\(nonPrimaryActive)/\(maxPreloadSlots))")
            }
        }
    }

    /// Called when the server stops. Clears all stale slot counts.
    func reset() {
        activeSlots.removeAll()
        primaryMediaID = nil
    }

    // MARK: - Internal

    private var totalActive: Int { activeSlots.values.reduce(0, +) }

    /// Count of active slots held by non-primary mediaIDs.
    private var nonPrimaryActive: Int {
        activeSlots.filter { $0.key != primaryMediaID }.values.reduce(0, +)
    }

    private func occupy(mediaID: String) {
        activeSlots[mediaID, default: 0] += 1
    }
}

// MARK: - NodePoolRegistry (global, thread-safe via NSLock)

/// Maps "host:port" strings to their NodeConnectionPool actors.
/// Pools are created lazily and never removed (nodes are long-lived).
class NodePoolRegistry {
    static let shared = NodePoolRegistry()
    private init() {}

    private var pools: [String: NodeConnectionPool] = [:]
    private let lock = NSLock()

    func pool(for nodeHost: String) -> NodeConnectionPool {
        lock.lock()
        defer { lock.unlock() }
        if let pool = pools[nodeHost] { return pool }
        let pool = NodeConnectionPool(nodeHost: nodeHost)
        pools[nodeHost] = pool
        return pool
    }

    /// Force-release non-primary slots from all pools.
    func forceReleaseNonPrimary(primaryMediaID: String?) {
        lock.lock()
        let allPools = Array(pools.values)
        lock.unlock()
        Task {
            for pool in allPools {
                await pool.forceReleaseNonPrimary(primaryMediaID: primaryMediaID)
            }
        }
    }

    /// Reset all pools on server stop: clears stale slot counts.
    func resetAllPools() {
        lock.lock()
        let allPools = Array(pools.values)
        lock.unlock()
        Task {
            for pool in allPools {
                await pool.reset()
            }
        }
    }

    /// Extract host:port from a URL (used to key pools per IPFS node).
    static func nodeHost(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
