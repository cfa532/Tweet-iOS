//
//  NodePool.swift
//  Tweet
//
//  Manages a persistent pool of nodes with their valid IP addresses.
//  The pool is the authoritative source for node IPs.
//  Uses User.hostIds to track writable and access nodes.
//

import Foundation

/// Where each user's requests currently go.
///
/// A route is not a property of a user. It is where the app can reach that user's data
/// right now, and it changes with node health, discovery and writes. Keeping it on the
/// User object made every path that copies, caches, merges or re-renders a user a place
/// the route could be silently rewritten — six such places on iOS alone, each needing to
/// learn the same rule. This table owns it instead, so a user object cannot carry a
/// route at all.
///
/// Three facts per user, and the precedence between them is the whole rule:
/// - `access` — the ordinary read route (the access node). Written by discovery, the
///   node pool, cache loads and route repair. This is the one that gets persisted.
/// - `writable` — the resolved root host, refreshed before every mutation. Used to build
///   write clients; on its own it changes nothing about reads.
/// - `readsFromWriteHost` — set when a write succeeds. While it holds, reads go to the
///   root host, because the access node has not copied that write yet. Route repair
///   drops it, which puts the user back on the access route.
final class UserRoutes: @unchecked Sendable {
    static let shared = UserRoutes()

    private struct Routes {
        var access: URL?
        var writable: URL?
        var readsFromWriteHost = false
    }

    private var routes: [MimeiId: Routes] = [:]
    private let lock = NSLock()

    private init() {}

    private func withRoutes<T>(_ mid: MimeiId, _ body: (inout Routes) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var entry = routes[mid] ?? Routes()
        let result = body(&entry)
        routes[mid] = entry
        return result
    }

    /// The route reads should use: the root host while a write is being waited out,
    /// otherwise the access node.
    func readRoute(for mid: MimeiId) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = routes[mid] else { return nil }
        if entry.readsFromWriteHost, let writable = entry.writable { return writable }
        return entry.access
    }

    /// The access node route alone. This is what gets written to the cache and recorded
    /// in NodePool, so neither can ever describe an access node with a root host address.
    func accessRoute(for mid: MimeiId) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return routes[mid]?.access
    }

    /// The resolved root host, for building write clients.
    func writableRoute(for mid: MimeiId) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return routes[mid]?.writable
    }

    /// - Returns: true when the route reads use changed.
    @discardableResult
    func setAccessRoute(_ url: URL?, for mid: MimeiId) -> Bool {
        withRoutes(mid) { entry in
            guard entry.access != url else { return false }
            let before = entry.readsFromWriteHost ? (entry.writable ?? entry.access) : entry.access
            entry.access = url
            let after = entry.readsFromWriteHost ? (entry.writable ?? entry.access) : entry.access
            return before != after
        }
    }

    @discardableResult
    func setWritableRoute(_ url: URL?, for mid: MimeiId) -> Bool {
        withRoutes(mid) { entry in
            guard entry.writable != url else { return false }
            let wasReading = entry.readsFromWriteHost
            entry.writable = url
            if url == nil { entry.readsFromWriteHost = false }
            return wasReading
        }
    }

    /// Read from the node that just took a write, until that route stops answering.
    @discardableResult
    func readFromWriteHost(for mid: MimeiId) -> Bool {
        withRoutes(mid) { entry in
            guard entry.writable != nil, !entry.readsFromWriteHost else { return false }
            entry.readsFromWriteHost = true
            return true
        }
    }

    /// Called when the current route fails, so recovery starts from the access node.
    @discardableResult
    func stopReadingFromWriteHost(for mid: MimeiId) -> Bool {
        withRoutes(mid) { entry in
            guard entry.readsFromWriteHost else { return false }
            entry.readsFromWriteHost = false
            return true
        }
    }
}

/// Pool of nodes indexed by node MID
/// Each node maintains an array of valid IP addresses (IPv4 and IPv6)
/// The pool persists and acts as the source of truth for node connectivity
final class NodePool: @unchecked Sendable {
    static let shared = NodePool()
    
    private var nodes: [String: NodeInfo] = [:]  // [nodeMID: NodeInfo]
    private let queue = DispatchQueue(label: "com.tweet.nodepool", attributes: .concurrent)
    
    private init() {}
    
    /// Information about a network node
    struct NodeInfo: Sendable {
        let mid: String           // Node MID
        var ips: [String]         // Array of valid IP addresses (IPv6 and IPv4)
        var lastUpdate: Date      // When we last updated this node's IPs
        var successCount: Int     // Total successful accesses
        
        /// Check if a given IP is in this node's valid IP list
        func hasIP(_ ip: String) -> Bool {
            let normalized = Self.normalizeIP(ip)
            return ips.contains(where: { Self.normalizeIP($0) == normalized })
        }
        
        /// Get the preferred IP (prefer IPv4 over IPv6)
        func getPreferredIP() -> String? {
            // Prefer IPv4 over IPv6 for better compatibility
            return ips.first { ip in
                let normalized = Self.normalizeIP(ip)
                return !normalized.hasPrefix("[") && normalized.filter { $0 == ":" }.count <= 1
            } ?? ips.first
        }
        
        /// Normalize IP by removing http:// prefix and trailing slashes.
        /// Shares `Gadget.normalizeHostPort` with the health probe and every route
        /// comparison in HproseInstance, so a pooled address and a probed address are
        /// always the same string for the same node.
        static func normalizeIP(_ urlString: String) -> String {
            return Gadget.normalizeHostPort(urlString)
        }
    }
    
    // MARK: - Public Methods
    
    /// Check if user's current IP is valid in the pool
    /// Only checks access node (hostIds[1]) - the node we read data from
    @MainActor
    func isUserIPValid(for user: User) -> Bool {
        guard let baseUrlString = user.baseUrl?.absoluteString,
              let hostIds = user.hostIds,
              hostIds.count > 1 else {
            return false
        }
        
        return queue.sync {
            let normalizedUserIP = NodeInfo.normalizeIP(baseUrlString)
            let accessNodeMid = hostIds[1]
            
            if let node = nodes[accessNodeMid] {
                if node.hasIP(normalizedUserIP) {
                    print("DEBUG: [NodePool] ✅ User IP \(normalizedUserIP) found in access node \(accessNodeMid)")
                    return true
                } else {
                    print("DEBUG: [NodePool] ⚠️ User IP \(normalizedUserIP) not in access node \(accessNodeMid)'s IP list (has \(node.ips.count) IPs)")
                }
            } else {
                print("DEBUG: [NodePool] Access node \(accessNodeMid) not in pool yet")
            }
            
            return false
        }
    }
    
    /// Get a valid IP from the user's access node in the pool
    /// Only uses access node (hostIds[1]) - the node we read data from
    @MainActor
    func getIPFromNode(for user: User) -> String? {
        guard let hostIds = user.hostIds, hostIds.count > 1 else {
            print("DEBUG: [NodePool] User has no access node (hostIds[1])")
            return nil
        }
        
        return queue.sync {
            let accessNodeMid = hostIds[1]
            if let node = nodes[accessNodeMid], let ip = node.getPreferredIP() {
                return ip
            }
            
            print("DEBUG: [NodePool] Access node \(accessNodeMid) not in pool or has no IPs")
            return nil
        }
    }
    
    /// Get a valid IP for a specific node by nodeMid
    /// Can be used for any node (writable host, access node, etc.)
    func getIPForNode(nodeMid: String) -> String? {
        return queue.sync {
            if let node = nodes[nodeMid], let ip = node.getPreferredIP() {
                print("DEBUG: [NodePool] Using IP from node \(nodeMid): \(ip)")
                return ip
            }
            
            print("DEBUG: [NodePool] Node \(nodeMid) not in pool or has no IPs")
            return nil
        }
    }
    
    /// Rejects routes that can never work off the advertising machine's own
    /// network: Tailscale CGNAT (100.64.0.0/10), RFC 1918 LANs, loopback,
    /// link-local. A private address that health-checks fine on the developer's
    /// tailnet would be cached here and then fail for every other user.
    /// Hostnames pass through — `baseUrl` is a domain in normal operation
    /// (see `AppConfig.baseUrl`), and only IP literals can be judged private.
    private static func isUnroutable(_ normalizedIP: String, nodeMid: String) -> Bool {
        guard Gadget.isPrivateHostAddress(normalizedIP) else { return false }
        print("DEBUG: [NodePool] 🚫 Rejecting private address \(normalizedIP) for node \(nodeMid)")
        return true
    }

    /// Update node in pool with new IP (replaces entire IP list)
    /// Called after successfully resolving a new IP for a user
    func updateNodeIP(nodeMid: String, newIP: String) {
        let normalizedIP = NodeInfo.normalizeIP(newIP)
        guard !Self.isUnroutable(normalizedIP, nodeMid: nodeMid) else { return }

        queue.async(flags: .barrier) {
            if var node = self.nodes[nodeMid] {
                // Replace IP list with new IP
                node.ips = [normalizedIP]
                node.lastUpdate = Date()
                node.successCount += 1
                self.nodes[nodeMid] = node
                print("DEBUG: [NodePool] 🔄 Updated node \(nodeMid) with new IP: \(normalizedIP)")
            } else {
                // Create new node
                let newNode = NodeInfo(
                    mid: nodeMid,
                    ips: [normalizedIP],
                    lastUpdate: Date(),
                    successCount: 1
                )
                self.nodes[nodeMid] = newNode
                print("DEBUG: [NodePool] 🆕 Created new node \(nodeMid) with IP: \(normalizedIP)")
            }
        }
    }
    
    /// Add IP to node's IP list (doesn't replace existing IPs)
    /// Used when discovering additional valid IPs for a node
    func addIPToNode(nodeMid: String, ip: String) {
        let normalizedIP = NodeInfo.normalizeIP(ip)
        guard !Self.isUnroutable(normalizedIP, nodeMid: nodeMid) else { return }

        queue.async(flags: .barrier) {
            if var node = self.nodes[nodeMid] {
                // Only add if not already in list
                if !node.hasIP(normalizedIP) {
                    node.ips.append(normalizedIP)
                    node.lastUpdate = Date()
                    self.nodes[nodeMid] = node
                    print("DEBUG: [NodePool] ➕ Added IP \(normalizedIP) to node \(nodeMid) (total: \(node.ips.count))")
                }
            } else {
                // Create new node
                let newNode = NodeInfo(
                    mid: nodeMid,
                    ips: [normalizedIP],
                    lastUpdate: Date(),
                    successCount: 1
                )
                self.nodes[nodeMid] = newNode
                print("DEBUG: [NodePool] 🆕 Created new node \(nodeMid) with IP: \(normalizedIP)")
            }
        }
    }
    
    /// Update node info from user's hostIds after successful fetch
    /// Only tracks access node (hostIds[1]) - the node we read data from
    @MainActor
    func updateFromUser(_ user: User) {
        // The access route, not whatever route reads are taking: while a write is being
        // waited out those are the root host's, and filing that address here would
        // describe the access node with it for every user who shares that node.
        guard let baseUrlString = UserRoutes.shared.accessRoute(for: user.mid)?.absoluteString,
              let hostIds = user.hostIds,
              hostIds.count > 1 else {
            return
        }
        
        let normalizedIP = NodeInfo.normalizeIP(baseUrlString)
        let accessNodeMid = hostIds[1]
        addIPToNode(nodeMid: accessNodeMid, ip: normalizedIP)
    }
    
    /// Remove a node from the pool (e.g., when discovered to be unhealthy)
    /// - Parameter nodeMid: The node ID to remove
    func removeNode(nodeMid: String) {
        queue.async(flags: .barrier) {
            if self.nodes.removeValue(forKey: nodeMid) != nil {
                print("DEBUG: [NodePool] ❌ Removed unhealthy node \(nodeMid) from pool")
            }
        }
    }
    
    /// Remove a specific IP from a node's IP list
    /// If the node has no IPs left after removal, the node is removed from the pool
    /// - Parameters:
    ///   - nodeMid: The node ID
    ///   - ip: The IP address to remove
    func removeIPFromNode(nodeMid: String, ip: String) {
        queue.async(flags: .barrier) {
            let normalizedIP = NodeInfo.normalizeIP(ip)
            
            if var node = self.nodes[nodeMid] {
                node.ips.removeAll { NodeInfo.normalizeIP($0) == normalizedIP }
                
                if node.ips.isEmpty {
                    // No IPs left, remove the entire node
                    self.nodes.removeValue(forKey: nodeMid)
                    print("DEBUG: [NodePool] ❌ Removed node \(nodeMid) from pool (no IPs left)")
                } else {
                    // Still has other IPs, update the node
                    self.nodes[nodeMid] = node
                    print("DEBUG: [NodePool] 🗑️ Removed IP \(normalizedIP) from node \(nodeMid) (remaining: \(node.ips.count))")
                }
            }
        }
    }
    
    /// Get pool statistics for debugging
    func getStats() -> (total: Int, totalIPs: Int) {
        return queue.sync {
            let total = nodes.count
            let totalIPs = nodes.values.reduce(0) { $0 + $1.ips.count }
            return (total, totalIPs)
        }
    }
    
    /// Log detailed pool statistics
    func logDetailedStats() {
        queue.sync {
            print("DEBUG: [NodePool] 📊 Detailed pool stats:")
            print("DEBUG: [NodePool]   Total nodes: \(nodes.count)")
            for (nodeMid, node) in nodes {
                print("DEBUG: [NodePool]   Node \(nodeMid): \(node.ips.count) IPs, \(node.successCount) successes")
                for ip in node.ips {
                    print("DEBUG: [NodePool]     - \(ip)")
                }
            }
        }
    }
}
