import Foundation
import Network

// MARK: - String Extension for getIP
extension String {
    func getIP() -> String? {
        let ipv4Regex = "^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(?::\\d+)?$"
        let ipv6Regex = "\\[(.*?)\\]"
        if let _ = self.range(of: ipv4Regex, options: .regularExpression) {
            return self
        }
        if let match = self.range(of: ipv6Regex, options: .regularExpression) {
            let nsrange = NSRange(match, in: self)
            if let regex = try? NSRegularExpression(pattern: ipv6Regex),
               let result = regex.firstMatch(in: self, options: [], range: nsrange),
               let range = Range(result.range(at: 1), in: self) {
                return String(self[range])
            }
        }
        return nil
    }
}

// MARK: - Comment spinner cap

/// Hard cap on how long a comment spinner may block a detail screen.
let maxCommentSpinnerSeconds: TimeInterval = 15

/// Runs `work` but stops *waiting* on it after `seconds`, returning either way.
///
/// Why not `withTaskGroup` + `Task.sleep`: `invokeRunMApp` bridges a blocking hprose
/// call, so cancellation cannot interrupt an in-flight socket read, and a task group
/// awaits its children on exit — a structured timeout would still sit here until the
/// read returned. Running `work` unstructured and waiting on a one-shot signal lets the
/// caller give up on schedule while the work finishes in the background, so its results
/// still land in the list when they arrive.
@MainActor
func runWithSpinnerCap(
    seconds: TimeInterval = maxCommentSpinnerSeconds,
    _ work: @escaping @MainActor () async -> Void
) async {
    var signal: AsyncStream<Void>.Continuation!
    let settled = AsyncStream<Void> { signal = $0 }
    let finish = signal!

    Task {
        await work()
        finish.finish()
    }
    let cap = Task {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        finish.finish()
    }

    for await _ in settled {}
    cap.cancel()
}

// MARK: - Gadget Utility
final class Gadget: Sendable {
    static let shared = Gadget()
    
    private init() {}
    
    /// IPv4 octets, or nil when `ip` is not a dotted-quad literal.
    private static func ipv4Octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// True for any address that is not routable on the public internet: RFC 1918
    /// LANs, RFC 6598 / Tailscale CGNAT space, loopback, link-local, multicast and
    /// reserved space, plus their IPv6 equivalents. Expects a bare address with no
    /// port — use `isPrivateHostAddress(_:)` for `host:port` strings.
    static func isPrivateIP(_ ip: String) -> Bool {
        let address = ip.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPv6Address(address) {
            guard let parsed = IPv6Address(address) else { return true }
            let bytes = Array(parsed.rawValue)
            let words = stride(from: 0, to: 16, by: 2).map { Int(bytes[$0]) * 256 + Int(bytes[$0 + 1]) }
            return words[0] < 0x2000 || words[0] > 0x3fff ||
                (words[0] == 0x2001 && words[1] == 0xdb8) ||
                (words[0] == 0x3fff && words[1] < 0x1000) ||
                (words[0] == 0x2001 && words[1] == 2 && words[2] == 0) ||
                (Array(words.prefix(4)) == [0x2001, 0, 0, 0] &&
                 words[4..<7].allSatisfy { $0 == 0xffff } && (0xfff0...0xfff3).contains(words[7]))
        }
        guard let octets = ipv4Octets(address) else { return false }
        let (a, b, c) = (octets[0], octets[1], octets[2])
        return a == 0 || a == 10 || a == 127 || a >= 224 ||
            (a == 26 && b == 26 && c == 26) ||
            (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
            (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
            (a == 192 && b == 0 && (c == 0 || c == 2)) ||
            (a == 192 && b == 88 && c == 99) || (a == 198 && (18...19).contains(b)) ||
            (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113)
    }

    /// True when `hostPort` ("1.2.3.4:8002", "[fd7a::1]:8002", or a bare address)
    /// resolves to a private/non-routable IP literal. Hostnames return false —
    /// they are not IP literals, so this can't judge them; use it to *reject*
    /// private addresses, not to require public ones.
    static func isPrivateHostAddress(_ hostPort: String) -> Bool {
        guard let host = hostComponent(of: hostPort) else { return false }
        return isPrivateIP(host)
    }

    /// The app's canonical `host:port` form: trimmed, scheme stripped, no trailing
    /// slash. Route addresses reach the app in both shapes — `baseUrl.absoluteString`
    /// carries `http://`, server address lists do not — and every route comparison,
    /// cache key and health probe has to agree on one of them or the same node reads
    /// as two different routes.
    static func normalizeHostPort(_ hostPort: String) -> String {
        var normalized = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("http://") {
            normalized = String(normalized.dropFirst(7))
        } else if normalized.hasPrefix("https://") {
            normalized = String(normalized.dropFirst(8))
        }
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }

    /// Strips scheme, brackets and port, yielding the bare host of a `host:port`
    /// string. Returns nil when the input is malformed.
    static func hostComponent(of fullIp: String) -> String? {
        var value = fullIp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") {
            // Bracketed IPv6, with or without a port: [::1] / [::1]:8002
            guard let endBracket = value.firstIndex(of: "]") else { return nil }
            return String(value[value.index(after: value.startIndex)..<endBracket])
        }
        // A bare IPv6 literal has several colons; a host:port pair has exactly one.
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if value.filter({ $0 == ":" }).count == 1, parts.count == 2 {
            return parts[0].isEmpty ? nil : String(parts[0])
        }
        return value
    }

    /// True only for a public, internet-routable IP literal. Accepts `host:port`
    /// and bracketed IPv6. Hostnames are rejected — this requires a literal
    /// address, so use it where an IP is expected (server-advertised node and
    /// provider address lists). IPv6 is allowed as long as it is public.
    static func isValidPublicIpAddress(_ fullIp: String) -> Bool {
        guard let ip = hostComponent(of: fullIp) else { return false }
        return isValidIpAddress(fullIp) && !isPrivateIP(ip)
    }

    static func isValidIpAddress(_ fullIp: String) -> Bool {
        guard let ip = hostComponent(of: fullIp) else { return false }
        return isIPv6Address(ip) ? IPv6Address(ip) != nil : ipv4Octets(ip) != nil
    }

    /// Input is already ranked. Retain private/VPN routes only for a node with
    /// no public IP, and cap those alternatives at two, matching TweetWeb.
    static func preferredIpAddresses(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        let valid = addresses.map(normalizeHostPort).filter {
            isValidIpAddress($0) && seen.insert($0).inserted
        }
        let publicIPs = valid.filter(isValidPublicIpAddress)
        return publicIPs.isEmpty ? Array(valid.prefix(2)) : publicIPs
    }

    /// Decode the published JSON without flattening away node identity. Rank
    /// within each node, prefer public IPs, then interleave nodes by address rank.
    static func entryIPCandidates(from raw: String, addressesPerNode: Int = Int.max) -> [String] {
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let rawNodes = decoded as? [[[Any]]] else { return [] }
        let nodes: [[(ip: String, responseTime: Double)]] = rawNodes.map { node in
            let addresses: [(ip: String, responseTime: Double)] = node.compactMap { pair in
                guard let address = pair.first as? String else { return nil }
                let ip = normalizeHostPort(address)
                guard isValidIpAddress(ip),
                      let port = URLComponents(string: "http://\(ip)")?.port,
                      (1...65535).contains(port) else { return nil }
                let metric = pair.count > 1 ? (pair[1] as? NSNumber)?.doubleValue : nil
                return (ip, metric.flatMap { $0.isFinite ? $0 : nil } ?? Double.infinity)
            }.sorted { $0.responseTime < $1.responseTime }
            let publicIPs = addresses.filter { isValidPublicIpAddress($0.ip) }
            return Array((publicIPs.isEmpty ? Array(addresses.prefix(2)) : publicIPs).prefix(addressesPerNode))
        }.filter { !$0.isEmpty }
        var ordered: [String] = []
        var seen = Set<String>()
        for rank in 0..<(nodes.map(\.count).max() ?? 0) {
            let round = nodes.compactMap { rank < $0.count ? $0[rank] : nil }
                .sorted { $0.responseTime < $1.responseTime }
            for candidate in round where seen.insert(candidate.ip).inserted {
                ordered.append(candidate.ip)
            }
        }
        return ordered
    }

    // Check if an IP is IPv6
    static func isIPv6Address(_ ip: String) -> Bool {
        return ip.contains(":")
    }

    // Get accessible IP (prefer IPv4, fallback to IPv6)
    func getAccessibleIP2(_ ipList: [String]) -> String? {
        var ip4: String? = nil
        var ip6: String? = nil
        for it in ipList {
            let i = it.split(separator: ":").dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard let p = Int(it.split(separator: ":").last ?? "") else { continue }
            if !(8000...9000).contains(p) { continue }
            if Gadget.isIPv6Address(i) {
                ip6 = "[i]:\(p)"
            } else {
                let ipv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
                guard i.range(of: ipv4Regex, options: .regularExpression) != nil else { continue }
                let octets = i.split(separator: ".").compactMap { UInt8($0) }
                guard octets.count == 4 else { continue }
                if Gadget.isPrivateIP(i) { continue }
                ip4 = "\(i):\(p)"
            }
        }
        return ip4 ?? ip6
    }

    static func getAlphaIds() -> [String] {
        let alphaIdString = AppConfig.alphaId
        return alphaIdString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } // Remove whitespace if needed
            .map { String($0) }
    }

    /// True for builds installed directly from Xcode / non-App-Store distribution.
    /// App Store builds strip embedded.mobileprovision, so this evaluates to false there.
    static var isNonAppStoreInstall: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    /// TweetWeb uses `loginUser.username === 'admin'` for moderation UI.
    /// Here we also require non-App-Store install so App Store distribution hides it.
    @MainActor
    static func isResearchAdminUser(_ user: User) -> Bool {
        user.username == "admin" && isNonAppStoreInstall
    }

    /// Delete menu: own tweet or (debug admin only) any tweet — matches TweetWeb corner menu rules.
    @MainActor
    static func canShowTweetDeleteMenu(appUser: User, tweetAuthorId: String, allowDeleteAll: Bool) -> Bool {
        if tweetAuthorId == appUser.mid { return true }
        if allowDeleteAll { return true }
        return isResearchAdminUser(appUser)
    }
    
    func extractParamMap(from html: String) -> [String: Any] {
        var result: [String: Any] = [:]
        
        // Find the window.setParam section
        let startText = "window.setParam({"
        let endText = "})\nwindow.request()"
        
        guard let startRange = html.range(of: startText),
              let endRange = html.range(of: endText, options: .backwards) else {
            return result
        }
        
        // Extract the parameter text
        let startIndex = startRange.upperBound
        let endIndex = endRange.lowerBound
        let paramText = html[startIndex..<endIndex]
        
        // Extract addrs (complex array)
        if let addrsStartRange = paramText.range(of: "addrs: "),
           let bracketStart = paramText[addrsStartRange.upperBound...].firstIndex(of: "["),
           let lastBracketRange = paramText[bracketStart...].range(of: "]]]", options: .backwards) {
            let addrsValue = paramText[bracketStart..<lastBracketRange.upperBound]
            result["addrs"] = String(addrsValue)
        }
        
        // Extract mid (string) - using double quotes
        if let midStartRange = paramText.range(of: "mid:\""),
           let midEndRange = paramText[midStartRange.upperBound...].range(of: "\"") {
            let midValue = paramText[midStartRange.upperBound..<midEndRange.lowerBound]
            result["mid"] = String(midValue)
        }
        
        return result
    }
    

}

// MARK: - Error Message Helper
/// Converts technical error messages into user-friendly messages
struct ErrorMessageHelper {
    
    /// Convert a technical error to a user-friendly message
    static func userFriendlyMessage(from error: Error) -> String {
        let originalMessage = error.localizedDescription
        let errorDescription = originalMessage.lowercased()
        
        // Check if the error message is already user-friendly
        // User-friendly messages are typically short, clear, and don't contain technical jargon
        let technicalTerms = ["nsurlsession", "nsurlerror", "domain error", "error code", "error -", 
                             "failed with", "underlying error", "userinfo", "nserror", "exception",
                             "stack trace", "debug", "parse", "decode", "json", "http", "https",
                             "ssl", "certificate", "tcp", "socket", "connection", "timeout"]
        
        let isTechnicalError = technicalTerms.contains { errorDescription.contains($0) }
        let isShortAndClear = originalMessage.count < 100 && !originalMessage.contains("Error Domain")
        
        // Server-provided user-friendly error messages mapping to localized versions
        // These are actual error messages returned from the server API
        let serverErrorMapping: [String: String] = [
            // Registration errors
            "username is taken": NSLocalizedString("Username is taken", comment: "Server error: username already taken"),
            // Login errors
            "user not found": NSLocalizedString("User not found", comment: "Server error: user not found"),
            "wrong password": NSLocalizedString("Wrong password", comment: "Server error: wrong password"),
            "unknown error": NSLocalizedString("Unknown error", comment: "Server error: unknown error"),
            // User/host errors
            "user not found or missing host": NSLocalizedString("User not found or missing host", comment: "Server error: user not found or missing host"),
            "user host not found": NSLocalizedString("User host not found", comment: "Server error: user host not found"),
            "author host not found": NSLocalizedString("Author host not found", comment: "Server error: author host not found"),
            "user not found in database": NSLocalizedString("User not found in database", comment: "Server error: user not found in database"),
            "user missing host": NSLocalizedString("User missing host", comment: "Server error: user missing host"),
            // Following/follower errors
            "cannot follow yourself": NSLocalizedString("Cannot follow yourself", comment: "Server error: cannot follow yourself"),
            "cannot get followed user": NSLocalizedString("Cannot get followed user", comment: "Server error: cannot get followed user"),
            "missing host for followed user": NSLocalizedString("Missing host for followed user", comment: "Server error: missing host for followed user"),
            // Tweet errors
            "tweet not found": NSLocalizedString("Tweet not found", comment: "Server error: tweet not found"),
            "only the tweet author can update privacy settings": NSLocalizedString("Only the tweet author can update privacy settings", comment: "Server error: only author can update privacy"),
            // Authentication/authorization errors
            "not a friend of the host": NSLocalizedString("Not a friend of the host", comment: "Server error: not a friend of the host"),
            "no provider ip found.": NSLocalizedString("No provider IP found.", comment: "Server error: no provider IP found"),
            // Upload errors
            "failed to extract zip file": NSLocalizedString("Failed to extract zip file", comment: "Server error: failed to extract zip file"),
            "invalid hls structure": NSLocalizedString("Invalid HLS structure", comment: "Server error: invalid HLS structure"),
            // App errors
            "app id mismatch": NSLocalizedString("App ID mismatch", comment: "Server error: app ID mismatch")
        ]
        
        // Check for exact match first (case-insensitive)
        if let localizedMessage = serverErrorMapping[errorDescription] {
            return localizedMessage
        }
        
        // Check for chunk size error (has variable size like "Chunk size 1234 exceeds 1MB limit")
        if errorDescription.contains("chunk size") && errorDescription.contains("exceeds") && errorDescription.contains("1mb limit") {
            return NSLocalizedString("Chunk size exceeds 1MB limit", comment: "Server error: chunk size exceeds limit")
        }
        
        // Check for partial matches (for messages that might have additional context)
        // Sort by length (longest first) to match more specific messages first
        let sortedKeys = serverErrorMapping.keys.sorted { $0.count > $1.count }
        for serverKey in sortedKeys {
            if errorDescription.contains(serverKey) {
                return serverErrorMapping[serverKey]!
            }
        }
        
        // If the message is already user-friendly, return it as-is
        if !isTechnicalError && isShortAndClear {
            return originalMessage
        }
        
        // Network connectivity issues
        if errorDescription.contains("network connection was lost") ||
           errorDescription.contains("connection was lost") ||
           errorDescription.contains("network is down") ||
           errorDescription.contains("not connected to the internet") {
            return NSLocalizedString("Network connection lost. Please check your internet connection.", comment: "Network connection lost error")
        }
        
        if errorDescription.contains("timed out") ||
           errorDescription.contains("timeout") ||
           errorDescription.contains("request timed out") {
            return NSLocalizedString("The request took too long. Please try again.", comment: "Timeout error")
        }
        
        // Network/server errors (but not server-provided user-friendly messages)
        if (errorDescription.contains("could not connect to the server") ||
            errorDescription.contains("server is not responding") ||
            errorDescription.contains("cannot find the server") ||
            errorDescription.contains("dns")) &&
            !errorDescription.contains("user host not found") &&
            !errorDescription.contains("author host not found") &&
            !errorDescription.contains("missing host") {
            return NSLocalizedString("Cannot reach the server. Please try again later.", comment: "Server unreachable error")
        }
        
        if errorDescription.contains("connection reset") ||
           errorDescription.contains("connection was reset") ||
           errorDescription.contains("broken pipe") {
            return NSLocalizedString("Connection interrupted. Please try again.", comment: "Connection reset error")
        }
        
        if errorDescription.contains("ssl") ||
           errorDescription.contains("certificate") ||
           errorDescription.contains("secure connection") {
            return NSLocalizedString("Secure connection failed. Please check your network settings.", comment: "SSL error")
        }
        
        if errorDescription.contains("address already in use") ||
           errorDescription.contains("eaddrinuse") {
            return NSLocalizedString("Service temporarily unavailable. Please try again.", comment: "Port in use error")
        }
        
        // HTTP errors
        if errorDescription.contains("404") ||
           errorDescription.contains("not found") {
            return NSLocalizedString("Content not found.", comment: "404 error")
        }
        
        if errorDescription.contains("401") ||
           errorDescription.contains("unauthorized") {
            return NSLocalizedString("Session expired. Please log in again.", comment: "401 error")
        }
        
        if errorDescription.contains("403") ||
           errorDescription.contains("forbidden") {
            return NSLocalizedString("You don't have permission to access this.", comment: "403 error")
        }
        
        if errorDescription.contains("500") ||
           errorDescription.contains("internal server error") ||
           errorDescription.contains("server error") {
            return NSLocalizedString("Server error. Please try again later.", comment: "500 error")
        }
        
        if errorDescription.contains("503") ||
           errorDescription.contains("service unavailable") {
            return NSLocalizedString("Service temporarily unavailable. Please try again later.", comment: "503 error")
        }
        
        // Data/parsing errors
        if errorDescription.contains("parse") ||
           errorDescription.contains("decode") ||
           errorDescription.contains("json") {
            return NSLocalizedString("Unable to process data. Please try again.", comment: "Parse error")
        }
        
        // File/disk errors
        if errorDescription.contains("disk") ||
           errorDescription.contains("storage") ||
           errorDescription.contains("no space") {
            return NSLocalizedString("Not enough storage space available.", comment: "Storage error")
        }
        
        // Generic fallback for other network errors
        if errorDescription.contains("nsurlsession") ||
           errorDescription.contains("nsurlerror") ||
           errorDescription.contains("domain error") {
            return NSLocalizedString("Network error. Please check your connection and try again.", comment: "Generic network error")
        }
        
        // If no specific match, return a generic friendly message
        // But avoid showing raw technical details
        return NSLocalizedString("Something went wrong. Please try again.", comment: "Generic error")
    }
    
    /// Convert a technical error to a user-friendly message with optional context
    static func userFriendlyMessage(from error: Error, context: String?) -> String {
        let baseMessage = userFriendlyMessage(from: error)
        
        // If context is provided, prepend it
        if let context = context, !context.isEmpty {
            return "\(context): \(baseMessage)"
        }
        
        return baseMessage
    }
}
