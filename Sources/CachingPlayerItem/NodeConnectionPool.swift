// NodeConnectionPool.swift
// Tweet
//
// Per-node IPFS bandwidth manager.
//
// Priority model:
// - Primary gets its own lane and never competes with visible/preload work.
// - Visible non-primary videos get a small lane so on-screen media can buffer.
// - Off-screen preloads are allowed only after LocalHTTPServer says primary and
//   visible non-primary buffers are healthy.

import Foundation

enum NodeDownloadPriority: Sendable, Equatable {
    case primary
    case visible
    case preload
}

// MARK: - NodeConnectionPool (actor, one per IPFS node host:port)

actor NodeConnectionPool {
    let nodeHost: String
#if DEBUG && VERBOSE_VIDEO_LOGS
    private static let verboseLogsEnabled = true
#else
    private static let verboseLogsEnabled = false
#endif

    private let maxVisibleSlots = 2
    private let maxPreloadSlots = 2

    private var primarySlots: [String: Int] = [:]
    private var visibleSlots: [String: Int] = [:]
    private var preloadSlots: [String: Int] = [:]

    private var primaryMediaID: String?
    private var preloadsAllowed = true

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    @discardableResult
    func acquireSlot(mediaID: String, priority: NodeDownloadPriority, primarySlotCap: Int = 1) -> Bool {
        let short = String(mediaID.prefix(8))
        switch priority {
        case .primary:
            primaryMediaID = mediaID
            let current = primarySlots[mediaID] ?? 0
            guard current < primarySlotCap else { return false }
            primarySlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) slot \(current + 1)/\(primarySlotCap) (visible=\(visibleActive)/\(maxVisibleSlots), preload=\(preloadActive)/\(maxPreloadSlots))")
            }
            return true

        case .visible:
            guard visibleActive < maxVisibleSlots else { return false }
            visibleSlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] VISIBLE \(short) slot \(visibleActive)/\(maxVisibleSlots) (preload=\(preloadActive)/\(maxPreloadSlots))")
            }
            return true

        case .preload:
            guard preloadsAllowed,
                  preloadActive < maxPreloadSlots else { return false }
            preloadSlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] PRELOAD \(short) slot \(preloadActive)/\(maxPreloadSlots)")
            }
            return true
        }
    }

    func releaseSlot(mediaID: String, priority: NodeDownloadPriority) {
        switch priority {
        case .primary:
            release(mediaID: mediaID, from: &primarySlots)
        case .visible:
            release(mediaID: mediaID, from: &visibleSlots)
        case .preload:
            release(mediaID: mediaID, from: &preloadSlots)
        }
    }

    /// Primary changed; stale lower-lane counters should not keep future work blocked.
    /// Existing URLSession tasks may continue, but primary still has its own lane.
    func forceReleaseLowerPriority(primaryMediaID: String?) {
        self.primaryMediaID = primaryMediaID
        let released = visibleSlots.values.reduce(0, +) + preloadSlots.values.reduce(0, +)
        visibleSlots.removeAll()
        preloadSlots.removeAll()
        preloadsAllowed = primaryMediaID == nil
        if released > 0, Self.verboseLogsEnabled {
            let short = primaryMediaID.map { String($0.prefix(8)) } ?? "nil"
            print("🎰 [POOL \(nodeHost)] released \(released) lower-priority slot(s) (primary=\(short))")
        }
    }

    func setPreloadsAllowed(_ allowed: Bool) {
        preloadsAllowed = allowed
    }

    func reset() {
        primarySlots.removeAll()
        visibleSlots.removeAll()
        preloadSlots.removeAll()
        primaryMediaID = nil
        preloadsAllowed = true
    }

    /// Whether this node has bandwidth to spare for work nobody is waiting on.
    /// LocalHTTPServer.recomputePreloadPermission clears it while a primary or visible
    /// video is still filling its buffer.
    ///
    /// Slot counts deliberately do NOT answer this: a lane is held for the whole time a
    /// video is on screen, so a comfortably buffered player still reads as "active" and
    /// would gate off-screen work forever.
    var hasSpareBandwidth: Bool {
        preloadsAllowed
    }

    private var visibleActive: Int {
        visibleSlots.values.reduce(0, +)
    }

    private var preloadActive: Int {
        preloadSlots.values.reduce(0, +)
    }

    private func release(mediaID: String, from slots: inout [String: Int]) {
        guard let count = slots[mediaID] else { return }
        if count <= 1 {
            slots.removeValue(forKey: mediaID)
        } else {
            slots[mediaID] = count - 1
        }
    }
}

// MARK: - NodePoolRegistry (global, thread-safe via NSLock)

final class NodePoolRegistry: @unchecked Sendable {
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

    /// Snapshot the pools under the lock. Callers that then `await` must go through
    /// this: NSLock is unavailable inside an async function body.
    private func allPools() -> [NodeConnectionPool] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pools.values)
    }

    func forceReleaseLowerPriority(primaryMediaID: String?) {
        let pools = allPools()
        Task {
            for pool in pools {
                await pool.forceReleaseLowerPriority(primaryMediaID: primaryMediaID)
            }
        }
    }

    func setPreloadsAllowed(_ allowed: Bool) {
        let pools = allPools()
        Task {
            for pool in pools {
                await pool.setPreloadsAllowed(allowed)
            }
        }
    }

    /// True when every node has bandwidth to spare. This is the same judgement the
    /// video subsystem already makes about its own preloads, reused so that a
    /// BackgroundTweetPrefetcher read-ahead backs off exactly when video preloading does.
    func hasSpareBandwidth() async -> Bool {
        for pool in allPools() where await !pool.hasSpareBandwidth {
            return false
        }
        return true
    }

    func resetAllPools() {
        let pools = allPools()
        Task {
            for pool in pools {
                await pool.reset()
            }
        }
    }

    static func nodeHost(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
