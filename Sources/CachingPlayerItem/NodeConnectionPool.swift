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

    func forceReleaseLowerPriority(primaryMediaID: String?) {
        lock.lock()
        let allPools = Array(pools.values)
        lock.unlock()
        Task {
            for pool in allPools {
                await pool.forceReleaseLowerPriority(primaryMediaID: primaryMediaID)
            }
        }
    }

    func setPreloadsAllowed(_ allowed: Bool) {
        lock.lock()
        let allPools = Array(pools.values)
        lock.unlock()
        Task {
            for pool in allPools {
                await pool.setPreloadsAllowed(allowed)
            }
        }
    }

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

    static func nodeHost(from url: URL) -> String {
        guard let host = url.host else { return "unknown" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
