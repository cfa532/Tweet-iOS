import Foundation
import hprose

/// A pool for managing HproseClient instances
/// Thread-safe pool that manages creation and reuse of HproseHttpClient instances
class HproseClientPool {
    private var availableClients: [String: [HproseClient]] = [:]
    private let maxClientsPerURL: Int
    private let lock = NSLock()
    
    init(maxClientsPerURL: Int = 5) {
        self.maxClientsPerURL = maxClientsPerURL
    }
    
    /// Get a client for a specific URL. Creates a new one if needed.
    /// - Parameter urlString: The URL string for the server endpoint
    /// - Returns: A configured HproseClient instance
    func getClient(for urlString: String) -> HproseClient {
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
        client.timeout = 30  // 30 seconds timeout for health checks
        client.uri = urlString
        return client
    }
    
    /// Return a client to the pool for reuse
    /// - Parameters:
    ///   - client: The client to return
    ///   - urlString: The URL string this client was configured for
    func releaseClient(_ client: HproseClient, for urlString: String) {
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
