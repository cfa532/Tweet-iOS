import Foundation
import hprose

/// A pool for managing HproseClient instances
/// Thread-safe pool that manages creation and reuse of HproseHttpClient instances
class HproseClientPool {
    private var availableClients: [String: [HproseClient]] = [:]
    private let maxClientsPerURL: Int
    private let lock = NSLock()
    
    init(maxClientsPerURL: Int = 8) {
        self.maxClientsPerURL = maxClientsPerURL
    }
    
    /// Get a client for a specific URL. Creates a new one if needed.
    /// - Parameter urlString: The URL string for the server endpoint
    /// - Returns: A configured HproseClient instance
    func getClientByIP(for ip: String) -> HproseClient {
        // Properly format URL for IPv6 addresses
        // IPv6 addresses come in format: [ipv6]:port or ipv6:port (without brackets)
        let urlString: String
        if ip.hasPrefix("[") {
            // Already formatted with brackets: [ipv6]:port -> http://[ipv6]:port/webapi/
            urlString = "http://\(ip)/webapi/"
        } else if ip.contains(":") {
            // Check if it's IPv6 (multiple colons) or IPv4 with port (single colon)
            let colonCount = ip.filter { $0 == ":" }.count
            if colonCount > 1 {
                // IPv6 without brackets: ipv6:port -> http://[ipv6]:port/webapi/
                // Extract port if present (last component after last colon)
                if let lastColonIndex = ip.lastIndex(of: ":"),
                   let portString = Int(ip[ip.index(after: lastColonIndex)...].trimmingCharacters(in: .whitespaces)) {
                    // Has port: split and wrap IPv6 in brackets
                    let ipv6 = String(ip[..<lastColonIndex])
                    urlString = "http://[\(ipv6)]:\(portString)/webapi/"
                } else {
                    // No port or invalid format: wrap entire IPv6 in brackets with default port
                    urlString = "http://[\(ip)]:8080/webapi/"
                }
            } else {
                // IPv4 with port: ip:port -> http://ip:port/webapi/
                urlString = "http://\(ip)/webapi/"
            }
        } else {
            // IPv4 without port: ip -> http://ip/webapi/
            urlString = "http://\(ip)/webapi/"
        }

        lock.lock()
        defer { lock.unlock() }
        
        // Try to reuse an available client for this URL
        if var clients = availableClients[urlString], !clients.isEmpty {
            let client = clients.removeLast()
            availableClients[urlString] = clients
            return client
        }
        
        // Create a new client
        let client = HproseHttpClient()
        client.timeout = 5  // 5 seconds timeout for health checks (fast fail for bad servers)
        client.uri = urlString
        return client
    }
    
    func getClientByUrl(for url: String) -> HproseClient {
        let urlString = "\(url)/webapi/"
        lock.lock()
        defer { lock.unlock() }
        
        // Try to reuse an available client for this URL
        if var clients = availableClients[urlString], !clients.isEmpty {
            let client = clients.removeLast()
            availableClients[urlString] = clients
            return client
        }
        
        // Create a new client
        let client = HproseHttpClient()
        client.timeout = 5  // 5 seconds timeout for health checks (fast fail for bad servers)
        client.uri = urlString
        return client
    }
    
    /// Return a client to the pool for reuse
    /// - Parameters:
    ///   - client: The client to return
    ///   - urlString: The URL string this client was configured for
    func releaseClient(_ client: HproseClient, for ip: String) {
        // Use same URL construction logic as getClientByIP
        let urlString: String
        if ip.hasPrefix("[") {
            urlString = "http://\(ip)/webapi/"
        } else if ip.contains(":") {
            let colonCount = ip.filter { $0 == ":" }.count
            if colonCount > 1 {
                if let lastColonIndex = ip.lastIndex(of: ":"),
                   let portString = Int(ip[ip.index(after: lastColonIndex)...].trimmingCharacters(in: .whitespaces)) {
                    let ipv6 = String(ip[..<lastColonIndex])
                    urlString = "http://[\(ipv6)]:\(portString)/webapi/"
                } else {
                    urlString = "http://[\(ip)]:8080/webapi/"
                }
            } else {
                urlString = "http://\(ip)/webapi/"
            }
        } else {
            urlString = "http://\(ip)/webapi/"
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        var clients = availableClients[urlString] ?? []
        
        // Only keep up to maxClientsPerURL in the pool
        if clients.count < maxClientsPerURL {
            clients.append(client)
            availableClients[urlString] = clients
        }
        // If pool is full, let the client be deallocated
    }
    
    /// Clear all clients from the pool
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        
        availableClients.removeAll()
    }
    
    /// Clear clients for a specific URL
    func clear(for urlString: String) {
        lock.lock()
        defer { lock.unlock() }
        
        availableClients.removeValue(forKey: urlString)
    }
}
