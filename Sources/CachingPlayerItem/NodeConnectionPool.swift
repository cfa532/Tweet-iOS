// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
//
// Soft cap of maxSlots (3) concurrent downloads per node.
// Primary video:
//   - Never waits — acquires a slot immediately, temporarily exceeding maxSlots if needed.
//   - Capped at maxPrimarySlots (2) concurrent slots to avoid monopolising bandwidth.
// Non-primary (preloads):
//   - Wait until totalActive < maxSlots (3).
//   - As preloads finish their segments and release slots, totalActive falls back to ≤ 3.

import Foundation

// MARK: - NodeConnectionPool (actor, one per IPFS node host:port)

actor NodeConnectionPool {
    let nodeHost: String
    /// Soft cap on total concurrent downloads. Preloads wait at this limit; primary may exceed it.
    private let maxSlots = 3

    /// Count of active IPFS slot holds per mediaID.
    private var activeSlots: [String: Int] = [:]

    /// Suspended preload callers waiting for a slot to free up.
    private var waiters: [(mediaID: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    // MARK: - Public API

    /// Acquire a slot before starting an IPFS download.
    ///
    /// - Primary (`isPrimary: true`): granted immediately, even if totalActive ≥ maxSlots.
    ///   Capped at `primarySlotCap` concurrent slots; HLS passes 1 (sequential segments),
    ///   progressive video passes 2 (parallel range requests benefit from extra bandwidth).
    ///   If already at cap, returns without acquiring (download proceeds unmetered).
    /// - Non-primary (`isPrimary: false`): suspends until totalActive < maxSlots.
    func acquireSlot(mediaID: String, isPrimary: Bool, primarySlotCap: Int = 1) async {
        let short = String(mediaID.prefix(8))
        if isPrimary {
            let current = activeSlots[mediaID] ?? 0
            if current < primarySlotCap {
                occupy(mediaID: mediaID)
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) acquired slot \(current + 1)/\(primarySlotCap) (total=\(totalActive))")
            } else {
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) at cap (\(primarySlotCap)), skipping slot (total=\(totalActive))")
            }
            return  // never waits
        }
        await withCheckedContinuation { continuation in
            if totalActive < maxSlots {
                occupy(mediaID: mediaID)
                print("🎰 [POOL \(nodeHost)] preload \(short) acquired slot (total=\(totalActive))")
                continuation.resume()
            } else {
                print("🎰 [POOL \(nodeHost)] preload \(short) waiting (total=\(totalActive), max=\(maxSlots))")
                waiters.append((mediaID, continuation))
            }
        }
    }

    /// Release a slot after an IPFS download completes or is cancelled.
    /// Wakes any preload waiters that can now proceed.
    func releaseSlot(mediaID: String) {
        guard let count = activeSlots[mediaID] else { return }
        let short = String(mediaID.prefix(8))
        if count <= 1 { activeSlots.removeValue(forKey: mediaID) }
        else { activeSlots[mediaID] = count - 1 }
        print("🎰 [POOL \(nodeHost)] \(short) released slot (total=\(totalActive), waiters=\(waiters.count))")
        wakeWaiters()
    }

    /// Called when the primary mediaID changes. No-op in this design — primary identity
    /// does not affect slot logic; the `isPrimary` flag at acquisition time is sufficient.
    func setPrimaryMediaID(_ mediaID: String?) { }

    // MARK: - Internal

    private var totalActive: Int { activeSlots.values.reduce(0, +) }

    private func occupy(mediaID: String) {
        activeSlots[mediaID, default: 0] += 1
    }

    private func wakeWaiters() {
        var remaining: [(String, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if totalActive < maxSlots {
                occupy(mediaID: waiter.mediaID)
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
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

    /// Notifies all pools of the current primary. No-op in the current design;
    /// kept so LocalHTTPServer callers don't need to change.
    func setPrimaryMediaID(_ mediaID: String?) {
        lock.lock()
        let allPools = Array(pools.values)
        lock.unlock()
        for pool in allPools {
            Task { await pool.setPrimaryMediaID(mediaID) }
        }
    }

    /// Extract host:port from a URL (used to key pools per IPFS node).
    static func nodeHost(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
