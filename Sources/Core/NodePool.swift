//
//  NodePool.swift
//  Tweet
//
//  Manages a persistent pool of nodes with their valid IP addresses.
//  The pool is the authoritative source for node IPs.
//  Uses User.hostIds to track writable and access nodes.
//

import Foundation

/// Pool of nodes indexed by node MID
/// Each node maintains an array of valid IP addresses (IPv4 and IPv6)
/// The pool persists and acts as the source of truth for node connectivity
class NodePool {
    static let shared = NodePool()
    
    private var nodes: [String: NodeInfo] = [:]  // [nodeMID: NodeInfo]
    private let queue = DispatchQueue(label: "com.tweet.nodepool", attributes: .concurrent)
    
    private init() {}
    
    /// Information about a network node
    struct NodeInfo {
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
            return ips.first(where: { !$0.contains("[") && !$0.contains(":") }) ?? ips.first
        }
        
        /// Normalize IP by removing http:// prefix and trailing slashes
        static func normalizeIP(_ urlString: String) -> String {
            var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Remove protocol
            if normalized.hasPrefix("http://") {
                normalized = String(normalized.dropFirst(7))
            } else if normalized.hasPrefix("https://") {
                normalized = String(normalized.dropFirst(8))
            }
            
            // Remove trailing slash
            if normalized.hasSuffix("/") {
                normalized = String(normalized.dropLast())
            }
            
            return normalized
        }
    }
    
    // MARK: - Public Methods
    
    /// Check if user's current IP is valid in the pool
    /// Only checks access node (hostIds[1]) - the node we read data from
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
    func getIPFromNode(for user: User) -> String? {
        guard let hostIds = user.hostIds, hostIds.count > 1 else {
            print("DEBUG: [NodePool] User has no access node (hostIds[1])")
            return nil
        }
        
        return queue.sync {
            let accessNodeMid = hostIds[1]
            if let node = nodes[accessNodeMid], let ip = node.getPreferredIP() {
                print("DEBUG: [NodePool] Using IP from access node \(accessNodeMid): \(ip)")
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
    
    /// Update node in pool with new IP (replaces entire IP list)
    /// Called after successfully resolving a new IP for a user
    func updateNodeIP(nodeMid: String, newIP: String) {
        queue.async(flags: .barrier) {
            let normalizedIP = NodeInfo.normalizeIP(newIP)
            
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
        queue.async(flags: .barrier) {
            let normalizedIP = NodeInfo.normalizeIP(ip)
            
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
    func updateFromUser(_ user: User) {
        guard let baseUrlString = user.baseUrl?.absoluteString,
              let hostIds = user.hostIds,
              hostIds.count > 1 else {
            return
        }
        
        let normalizedIP = NodeInfo.normalizeIP(baseUrlString)
        let accessNodeMid = hostIds[1]
        addIPToNode(nodeMid: accessNodeMid, ip: normalizedIP)
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

