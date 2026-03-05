// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
// Limits concurrent IPFS downloads to 3 per node:
//   - 1 reserved for primary video (currently playing)
//   - 2 shared for preloads (hard cap: total preload downloads <= 2 at any time)
//
// Primary video is NEVER blocked. When primary is waiting and all 3 slots
// are occupied, primaryStarved flips true — no new preload acquisitions are
// allowed until primary acquires its slot and clears the flag.

import Foundation

// MARK: - NodeConnectionPool (actor, one per IPFS node host:port)

actor NodeConnectionPool {
    let nodeHost: String
    private let maxSlots = 3

    /// Count of active IPFS connections per mediaID.
    private var activeSlots: [String: Int] = [:]

    /// When true, preloads may not acquire new slots until the primary clears this flag.
    private(set) var primaryStarved = false

    /// Suspended callers waiting for a slot.
    private var waiters: [(mediaID: String, isPrimary: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    // MARK: - Public API

    /// Acquire a slot before starting an IPFS download.
    /// Primary video always gets a slot (waits if all 3 are taken, then sets primaryStarved).
    /// Preloads wait when primaryStarved or when 2 preload slots are already taken.
    func acquireSlot(mediaID: String, isPrimary: Bool) async {
        await withCheckedContinuation { continuation in
            if canAcquire(mediaID: mediaID, isPrimary: isPrimary) {
                occupy(mediaID: mediaID)
                if isPrimary { primaryStarved = false }
                continuation.resume()
            } else {
                if isPrimary { primaryStarved = true }
                waiters.append((mediaID, isPrimary, continuation))
            }
        }
    }

    /// Release a slot after an IPFS download completes (or is cancelled).
    func releaseSlot(mediaID: String) {
        guard let count = activeSlots[mediaID] else { return }
        if count <= 1 { activeSlots.removeValue(forKey: mediaID) }
        else { activeSlots[mediaID] = count - 1 }
        wakeWaiters()
    }

    /// Called when primary mediaID changes. Clears starvation so preloads can resume
    /// once the new primary has acquired its slot.
    func clearStarvation() {
        primaryStarved = false
        wakeWaiters()
    }

    // MARK: - Internal

    private var totalActive: Int { activeSlots.values.reduce(0, +) }

    private func canAcquire(mediaID: String, isPrimary: Bool) -> Bool {
        if isPrimary {
            // Primary: allowed as long as total slots < max
            return totalActive < maxSlots
        }
        // Preload: blocked when primary is starved OR when 2 preload slots are already used.
        // NOTE: no alreadyHasSlot bypass — preloads are strictly capped at (maxSlots-1) total.
        if primaryStarved { return false }
        return totalActive < (maxSlots - 1)
    }

    private func occupy(mediaID: String) {
        activeSlots[mediaID, default: 0] += 1
    }

    private func wakeWaiters() {
        var remaining: [(String, Bool, CheckedContinuation<Void, Never>)] = []

        // Wake primary waiters first
        for waiter in waiters where waiter.isPrimary {
            if canAcquire(mediaID: waiter.mediaID, isPrimary: true) {
                occupy(mediaID: waiter.mediaID)
                primaryStarved = false
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }

        // Wake preload waiters only if not starved
        let preloadWaiters = waiters.filter { !$0.isPrimary }
        for waiter in preloadWaiters {
            if canAcquire(mediaID: waiter.mediaID, isPrimary: false) {
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

    /// Extract host:port from a URL (used to key pools per IPFS node).
    static func nodeHost(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
