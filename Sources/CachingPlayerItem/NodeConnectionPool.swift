// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
//
// Soft cap of maxSlots (3) concurrent downloads per node.
// Primary video:
//   - Never waits — acquires a slot immediately, even if totalActive ≥ maxSlots.
//   - Capped at primarySlotCap concurrent slots: 1 for HLS (sequential), 2 for progressive.
//   - totalActive may temporarily exceed maxSlots.
// Non-primary (preloads):
//   - Non-blocking: acquires immediately if totalActive < maxSlots, otherwise returns false.
//   - Never holds proxy TCP connections while waiting — ensures the primary's AVPlayer can
//     always connect to the proxy (iOS limits concurrent connections per host to ~6).
//   - Rejected preloads rely on AVPlayer's built-in retry with exponential backoff.

import Foundation

// MARK: - NodeConnectionPool (actor, one per IPFS node host:port)

actor NodeConnectionPool {
    let nodeHost: String
    /// Soft cap on total concurrent downloads. Preloads are rejected at this limit; primary may exceed it.
    private let maxSlots = 3

    /// Count of active IPFS slot holds per mediaID.
    private var activeSlots: [String: Int] = [:]

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    // MARK: - Public API

    /// Acquire a slot before starting an IPFS download.
    ///
    /// Returns `true` if a slot was actually occupied (caller must call `releaseSlot` when done).
    /// Returns `false` in two cases (caller must NOT call `releaseSlot`):
    ///   - Primary at `primarySlotCap`: download still proceeds (no slot needed).
    ///   - Non-primary rejected (pool full): caller should close the connection.
    ///
    /// - Primary (`isPrimary: true`): granted immediately, even if totalActive ≥ maxSlots.
    /// - Non-primary (`isPrimary: false`): granted immediately if totalActive < maxSlots,
    ///   otherwise returns `false`. Never blocks — keeps TCP connection count low so the
    ///   primary's AVPlayer can always connect to the localhost proxy.
    @discardableResult
    func acquireSlot(mediaID: String, isPrimary: Bool, primarySlotCap: Int = 1) -> Bool {
        let short = String(mediaID.prefix(8))
        if isPrimary {
            let current = activeSlots[mediaID] ?? 0
            if current < primarySlotCap {
                occupy(mediaID: mediaID)
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) acquired slot \(current + 1)/\(primarySlotCap) (total=\(totalActive))")
                return true
            } else {
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) at cap (\(primarySlotCap)), skipping slot (total=\(totalActive))")
                return false
            }
        }
        // Non-primary: acquire immediately if capacity available, else reject.
        // Never blocks — prevents TCP connection accumulation that starves the primary.
        if totalActive < maxSlots {
            occupy(mediaID: mediaID)
            print("🎰 [POOL \(nodeHost)] preload \(short) acquired slot (total=\(totalActive))")
            return true
        } else {
            print("🎰 [POOL \(nodeHost)] preload \(short) rejected (total=\(totalActive), max=\(maxSlots))")
            return false
        }
    }

    /// Release a slot after an IPFS download completes or is cancelled.
    func releaseSlot(mediaID: String) {
        guard let count = activeSlots[mediaID] else { return }
        let short = String(mediaID.prefix(8))
        if count <= 1 { activeSlots.removeValue(forKey: mediaID) }
        else { activeSlots[mediaID] = count - 1 }
        print("🎰 [POOL \(nodeHost)] \(short) released slot (total=\(totalActive))")
    }

    /// Called when the server stops. Clears all stale slot counts.
    func reset() {
        activeSlots.removeAll()
    }

    // MARK: - Internal

    private var totalActive: Int { activeSlots.values.reduce(0, +) }

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
