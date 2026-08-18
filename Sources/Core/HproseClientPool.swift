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
    /// One pool per process. `HproseInstance.clientPool` points here, and
    /// `HproseTransport` reaches it directly to gate invocations.
    static let shared = HproseClientPool()

    private var sharedClients: [String: HproseHttpClient] = [:]
    /// In-flight invocation count per client, keyed by object identity. An entry
    /// only exists between `beginInvocation` and `endInvocation`, i.e. only while
    /// the caller holds a strong reference, so the identity can never be recycled
    /// out from under us.
    private var activeInvocations: [ObjectIdentifier: Int] = [:]
    /// Clients dropped from the pool whose last invocation hasn't returned yet.
    /// Held strongly so they stay alive until they can be closed safely.
    private var retiredClients: [ObjectIdentifier: HproseHttpClient] = [:]
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

    /// Retire and remove all shared clients (e.g. on logout, so stale sessions
    /// from the previous user's nodes don't linger).
    func clear() {
        lock.lock()
        let clients = Array(sharedClients.values)
        sharedClients.removeAll()
        let closeNow = markRetiredLocked(clients)
        lock.unlock()

        closeNow.forEach { $0.close(false) }
    }

    /// Retire and remove shared clients for a specific endpoint URL (all timeout classes).
    func clear(for urlString: String) {
        lock.lock()
        let matchingKeys = sharedClients.keys.filter { $0.hasPrefix("\(urlString)|") }
        let clients = matchingKeys.compactMap { sharedClients.removeValue(forKey: $0) }
        let closeNow = markRetiredLocked(clients)
        lock.unlock()

        closeNow.forEach { $0.close(false) }
    }

    // MARK: - Invocation Gate

    /// Registers an in-flight invocation on `client`, returning false when the
    /// client is no longer the pool's live client for its endpoint.
    ///
    /// A retired client's NSURLSession has been (or is about to be) invalidated,
    /// and `-[NSURLSession dataTaskWithRequest:]` raises an uncatchable
    /// NSGenericException on an invalidated session. Because clients are shared,
    /// a caller can be holding one at the moment another code path retires it
    /// (an unhealthy route being evicted, logout, background memory release), so
    /// every invocation must check in here first. The check and the retire both
    /// run under `lock`, and a retired client is only closed once its in-flight
    /// count reaches zero — so no invocation can ever reach an invalidated session.
    func beginInvocation(on client: HproseClient) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard sharedClients.values.contains(where: { $0 === client }) else { return false }
        activeInvocations[ObjectIdentifier(client), default: 0] += 1
        return true
    }

    /// Balances `beginInvocation`. Closes the client if it was retired while this
    /// invocation was in flight and this was the last one outstanding.
    func endInvocation(on client: HproseClient) {
        let id = ObjectIdentifier(client)

        lock.lock()
        let remaining = (activeInvocations[id] ?? 1) - 1
        if remaining > 0 {
            activeInvocations[id] = remaining
        } else {
            activeInvocations.removeValue(forKey: id)
        }
        let drained = remaining > 0 ? nil : retiredClients.removeValue(forKey: id)
        lock.unlock()

        // finishTasksAndInvalidate: this client is out of the pool and idle.
        drained?.close(false)
    }

    // MARK: - Private

    /// Marks removed clients as retired. Returns the ones that are idle and can be
    /// closed immediately; the rest are parked in `retiredClients` and closed by
    /// `endInvocation` when their last in-flight call returns. Caller holds `lock`.
    private func markRetiredLocked(_ clients: [HproseHttpClient]) -> [HproseHttpClient] {
        var closeNow: [HproseHttpClient] = []
        for client in clients {
            let id = ObjectIdentifier(client)
            if (activeInvocations[id] ?? 0) > 0 {
                retiredClients[id] = client
            } else {
                closeNow.append(client)
            }
        }
        return closeNow
    }

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
