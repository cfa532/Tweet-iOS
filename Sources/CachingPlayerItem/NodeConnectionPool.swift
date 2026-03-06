// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
//
// Soft cap of maxSlots (3) concurrent downloads per node.
// Primary video:
//   - Never waits — acquires a slot immediately, even if totalActive ≥ maxSlots.
//   - Capped at primarySlotCap concurrent slots: 1 for HLS (sequential), 2 for progressive.
//   - acquireSlot returns false when at cap — download proceeds unmetered, caller skips releaseSlot.
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
    /// Returns `true` if a slot was actually occupied (caller must call `releaseSlot` when done).
    /// Returns `false` if the primary was already at `primarySlotCap` — the download still
    /// proceeds unmetered, but the caller must NOT call `releaseSlot` (no slot was acquired).
    ///
    /// - Primary (`isPrimary: true`): granted immediately, even if totalActive ≥ maxSlots.
    ///   Capped at `primarySlotCap` concurrent slots; HLS passes 1 (sequential segments),
    ///   progressive video passes 2 (parallel range requests benefit from extra bandwidth).
    /// - Non-primary (`isPrimary: false`): suspends until totalActive < maxSlots. Always returns true.
    @discardableResult
    func acquireSlot(mediaID: String, isPrimary: Bool, primarySlotCap: Int = 1) async -> Bool {
        let short = String(mediaID.prefix(8))
        if isPrimary {
            let current = activeSlots[mediaID] ?? 0
            if current < primarySlotCap {
                occupy(mediaID: mediaID)
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) acquired slot \(current + 1)/\(primarySlotCap) (total=\(totalActive))")
                return true
            } else {
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) at cap (\(primarySlotCap)), skipping slot (total=\(totalActive))")
                return false  // download proceeds but no slot acquired — caller must NOT releaseSlot
            }
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
        return true  // non-primary always acquires a slot after waiting
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

    /// Called when the server stops. Clears all slot counts and resumes any suspended
    /// preload continuations so they are not permanently leaked. Woken callers will
    /// proceed past acquireSlot but their downloads will fail gracefully (server is down).
    func reset() {
        let waiterCount = waiters.count
        activeSlots.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
        waiters.removeAll()
        if waiterCount > 0 {
            print("🎰 [POOL \(nodeHost)] reset: cleared slots, released \(waiterCount) waiters")
        }
    }

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

    /// Reset all pools on server stop: clears stale slot counts and resumes suspended waiters.
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
