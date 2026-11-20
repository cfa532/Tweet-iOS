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

/// One granted slot. Release exactly the lease you were given.
///
/// `forceReleaseLowerPriority` clears the visible/preload counters when the primary
/// changes, while the transfers holding those slots keep running. Without a lease,
/// an old transfer finishing later decremented a counter that now belonged to a
/// newer holder of the same media ID, so the lane admitted more transfers than its
/// cap. A lease remembers the lane generation it was granted in; releasing a lease
/// from before a clear is a no-op.
struct NodeSlotLease: Sendable {
    let mediaID: String
    let priority: NodeDownloadPriority
    fileprivate let generation: Int
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

    /// Bumped by reset(): invalidates every outstanding lease.
    private var primaryGeneration = 0
    /// Bumped by reset() and forceReleaseLowerPriority(): invalidates visible/preload leases.
    private var lowerGeneration = 0

    private var primaryMediaID: String?

    init(nodeHost: String) {
        self.nodeHost = nodeHost
    }

    func acquireSlot(mediaID: String, priority: NodeDownloadPriority, primarySlotCap: Int = 1) -> NodeSlotLease? {
        let short = String(mediaID.prefix(8))
        switch priority {
        case .primary:
            primaryMediaID = mediaID
            let current = primarySlots[mediaID] ?? 0
            guard current < primarySlotCap else { return nil }
            primarySlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] PRIMARY \(short) slot \(current + 1)/\(primarySlotCap) (visible=\(visibleActive)/\(maxVisibleSlots), preload=\(preloadActive)/\(maxPreloadSlots))")
            }
            return NodeSlotLease(mediaID: mediaID, priority: priority, generation: primaryGeneration)

        case .visible:
            guard visibleActive < maxVisibleSlots else { return nil }
            visibleSlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] VISIBLE \(short) slot \(visibleActive)/\(maxVisibleSlots) (preload=\(preloadActive)/\(maxPreloadSlots))")
            }
            return NodeSlotLease(mediaID: mediaID, priority: priority, generation: lowerGeneration)

        case .preload:
            guard NodePoolRegistry.shared.preloadsAllowed,
                  preloadActive < maxPreloadSlots else { return nil }
            preloadSlots[mediaID, default: 0] += 1
            if Self.verboseLogsEnabled {
                print("🎰 [POOL \(nodeHost)] PRELOAD \(short) slot \(preloadActive)/\(maxPreloadSlots)")
            }
            return NodeSlotLease(mediaID: mediaID, priority: priority, generation: lowerGeneration)
        }
    }

    func releaseSlot(_ lease: NodeSlotLease) {
        switch lease.priority {
        case .primary:
            guard lease.generation == primaryGeneration else { return }
            release(mediaID: lease.mediaID, from: &primarySlots)
        case .visible:
            guard lease.generation == lowerGeneration else { return }
            release(mediaID: lease.mediaID, from: &visibleSlots)
        case .preload:
            guard lease.generation == lowerGeneration else { return }
            release(mediaID: lease.mediaID, from: &preloadSlots)
        }
    }

    /// Primary changed; stale lower-lane counters should not keep future work blocked.
    /// Existing URLSession tasks may continue, but primary still has its own lane.
    /// Their leases are invalidated so they cannot release slots granted after this.
    func forceReleaseLowerPriority(primaryMediaID: String?) {
        self.primaryMediaID = primaryMediaID
        let released = visibleSlots.values.reduce(0, +) + preloadSlots.values.reduce(0, +)
        visibleSlots.removeAll()
        preloadSlots.removeAll()
        lowerGeneration += 1
        if released > 0, Self.verboseLogsEnabled {
            let short = primaryMediaID.map { String($0.prefix(8)) } ?? "nil"
            print("🎰 [POOL \(nodeHost)] released \(released) lower-priority slot(s) (primary=\(short))")
        }
    }

    func reset() {
        primarySlots.removeAll()
        visibleSlots.removeAll()
        preloadSlots.removeAll()
        primaryGeneration += 1
        lowerGeneration += 1
        primaryMediaID = nil
    }

    /// Diagnostic only: lane occupancy, for the stuck-spinner log.
    func diagnosticSummary() -> String {
        "primary=\(primarySlots.map { "\($0.key.prefix(8)):\($0.value)" }) visible=\(visibleActive)/\(maxVisibleSlots) \(visibleSlots.map { "\($0.key.prefix(8)):\($0.value)" }) preload=\(preloadActive)/\(maxPreloadSlots) preloadsAllowed=\(NodePoolRegistry.shared.preloadsAllowed)"
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
    private var _preloadsAllowed = true
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

    /// Whether off-screen preloads may start, on every node.
    ///
    /// Owned by LocalHTTPServer.recomputePreloadPermission, which derives it from the
    /// primary/visible buffer state. It is one value set synchronously: it used to be
    /// copied into each pool by a fire-and-forget Task per call, and those Tasks (plus
    /// the one forceReleaseLowerPriority started) ran in no particular order, so an
    /// older decision could land last. A pool created later also started at `true`
    /// regardless of the current decision.
    var preloadsAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _preloadsAllowed
    }

    func setPreloadsAllowed(_ allowed: Bool) {
        lock.lock()
        _preloadsAllowed = allowed
        lock.unlock()
    }

    /// Whether video has bandwidth to spare for work nobody is waiting on. This is the
    /// same judgement the video subsystem makes about its own preloads, reused so that
    /// a BackgroundTweetPrefetcher read-ahead backs off exactly when video preloading does.
    ///
    /// Slot counts deliberately do NOT answer this: a lane is held for the whole time a
    /// video is on screen, so a comfortably buffered player still reads as "active" and
    /// would gate off-screen work forever.
    func hasSpareBandwidth() -> Bool {
        preloadsAllowed
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
