import Foundation
@preconcurrency import hprose

/// Hands out one shared HproseHttpClient per (endpoint URL, timeout) pair.
///
/// Each HproseHttpClient owns an NSURLSession whose delegate strongly retains the
/// client — a session/delegate/client cycle that only breaks when close() is called.
/// The old checkout model created a fresh client per RPC and never released it,
/// leaking one NSURLSession per call. Sharing bounds live sessions to the number of
/// distinct (URL, timeout) pairs and lets HTTP keep-alive actually reuse sockets.
///
/// Concurrency: NSURLSession is thread-safe and hprose's invoke path keeps all
/// per-call state in per-invocation context/settings objects, so concurrent invokes
/// on a shared client are safe — PROVIDED nobody mutates client.uri / client.timeout
/// after creation. Timeout is part of the pool key precisely so call sites never
/// need to mutate a handed-out client. Do not set properties on returned clients.
/// Safe to pass across concurrency domains: pooled clients are configured once at
/// creation and never mutated afterwards (see pool doc above); NSURLSession is
/// thread-safe and hprose keeps per-invoke state in per-call context objects.
extension HproseClient: @unchecked @retroactive Sendable {}

final class HproseClientPool: @unchecked Sendable {
    private var sharedClients: [String: HproseHttpClient] = [:]
    private let lock = NSLock()

    /// Get a shared client for a specific IP (host[:port]). Default 5s timeout for health checks.
    /// - Parameter ip: host, host:port, [ipv6]:port, or bare ipv6
    func getClientByIP(for ip: String, timeout: TimeInterval = 5) -> HproseClient {
        return sharedClient(urlString: Self.urlString(forIP: ip), timeout: timeout)
    }

    /// Get a shared client for a base URL (without the /webapi/ suffix). Default 5s timeout.
    func getClientByUrl(for url: String, timeout: TimeInterval = 5) -> HproseClient {
        return sharedClient(urlString: "\(url)/webapi/", timeout: timeout)
    }

    /// Close and remove all shared clients (e.g. on logout, so stale sessions
    /// from the previous user's nodes don't linger).
    func clear() {
        lock.lock()
        let clients = sharedClients.values
        sharedClients.removeAll()
        lock.unlock()

        for client in clients {
            client.close(false) // finishTasksAndInvalidate: let in-flight RPCs complete
        }
    }

    /// Close and remove shared clients for a specific endpoint URL (all timeout classes).
    func clear(for urlString: String) {
        lock.lock()
        let matchingKeys = sharedClients.keys.filter { $0.hasPrefix("\(urlString)|") }
        let clients = matchingKeys.compactMap { sharedClients.removeValue(forKey: $0) }
        lock.unlock()

        for client in clients {
            client.close(false)
        }
    }

    // MARK: - Private

    private func sharedClient(urlString: String, timeout: TimeInterval) -> HproseClient {
        let key = "\(urlString)|\(timeout)"
        lock.lock()
        defer { lock.unlock() }

        if let client = sharedClients[key] {
            return client
        }

        let client = HproseHttpClient()
        client.timeout = timeout
        client.uri = urlString
        sharedClients[key] = client
        return client
    }

    /// Properly format URL for IPv4/IPv6 addresses.
    /// IPv6 addresses come in format: [ipv6]:port or ipv6:port (without brackets)
    private static func urlString(forIP ip: String) -> String {
        if ip.hasPrefix("[") {
            // Already formatted with brackets: [ipv6]:port -> http://[ipv6]:port/webapi/
            return "http://\(ip)/webapi/"
        } else if ip.contains(":") {
            // Check if it's IPv6 (multiple colons) or IPv4 with port (single colon)
            let colonCount = ip.filter { $0 == ":" }.count
            if colonCount > 1 {
                // IPv6 without brackets: ipv6:port -> http://[ipv6]:port/webapi/
                if let lastColonIndex = ip.lastIndex(of: ":"),
                   let portString = Int(ip[ip.index(after: lastColonIndex)...].trimmingCharacters(in: .whitespaces)) {
                    // Has port: split and wrap IPv6 in brackets
                    let ipv6 = String(ip[..<lastColonIndex])
                    return "http://[\(ipv6)]:\(portString)/webapi/"
                } else {
                    // No port or invalid format: wrap entire IPv6 in brackets with default port
                    return "http://[\(ip)]:8080/webapi/"
                }
            } else {
                // IPv4 with port: ip:port -> http://ip:port/webapi/
                return "http://\(ip)/webapi/"
            }
        } else {
            // IPv4 without port: ip -> http://ip/webapi/
            return "http://\(ip)/webapi/"
        }
    }
}
