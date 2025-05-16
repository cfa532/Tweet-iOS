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

// MARK: - Gadget Utility
class Gadget {
    static let shared = Gadget()
    
    private init() {}
    
    // Filter IP addresses from a nested array structure
    func filterIpAddresses(_ nodeList: Any) -> String? {
        guard let nodes = nodeList as? [[[Any]]] else {
            return nil
        }
        
        var fastestIP: String? = nil
        var fastestResponseTime: UInt64 = UInt64.max
        
        for nodeGroup in nodes {
            for ipData in nodeGroup {
                guard ipData.count >= 2,
                      let ipWithPort = ipData[0] as? String,
                      let responseTime = ipData[1] as? UInt64 else {
                    continue
                }
                
                // Extract IP and port
                let components = ipWithPort.split(separator: ":")
                guard components.count >= 2 else { continue }
                
                let port = String(components.last!)
                guard let portNumber = Int(port), (8000...9000).contains(portNumber) else {
                    continue
                }
                
                // Get clean IP address
                var ipAddress = ipWithPort.replacingOccurrences(of: ":" + port, with: "")
                if ipAddress.hasPrefix("[") && ipAddress.hasSuffix("]") {
                    ipAddress = String(ipAddress.dropFirst().dropLast())
                }
                
                // Check if it's a private IP
                if Gadget.isPrivateIP(ipAddress) {
                    continue
                }
                
                // Check if this is the fastest response so far
                if responseTime < fastestResponseTime {
                    fastestResponseTime = responseTime
                    fastestIP = ipWithPort
                }
            }
        }
        
        return fastestIP
    }
    
//    func getAccessibleIP(ipList: [String]) async -> String? {
//        await withTaskGroup(of: String?.self) { group in
//            for ip in ipList {
//                if Gadget.isValidPublicIpAddress(ip) {
//                    group.addTask {
//                        // Replace this with your actual async accessibility check
//                        let accessible = await HproseInstance.isAccessible(ip)
//                        return accessible
//                    }
//                }
//            }
//            // Wait for the first non-nil result, or nil if none found
//            for await result in group {
//                if let ip = result {
//                    print("Fastest ip: \(ip)")
//                    group.cancelAll() // Cancel remaining tasks
//                    return ip
//                }
//            }
//            return nil
//        }
//    }
    
    // Helper function to check if an IP is private
    static private func isPrivateIP(_ ip: String) -> Bool {
        // IPv4 private ranges
        if ip.starts(with: "10.") ||
           ip.starts(with: "192.168.") ||
           ip.range(of: "^172\\.(1[6-9]|2[0-9]|3[0-1])\\.", options: .regularExpression) != nil {
            return true
        }
        
        // IPv6 private ranges (fc00::/7 - unique local addresses)
        if ip.lowercased().starts(with: "fc") || ip.lowercased().starts(with: "fd") {
            return true
        }
        
        // IPv6 link-local (fe80::/10)
        if ip.lowercased().starts(with: "fe8") ||
           ip.lowercased().starts(with: "fe9") ||
           ip.lowercased().starts(with: "fea") ||
           ip.lowercased().starts(with: "feb") {
            return true
        }
        
        return false
    }

    // Check if an IP is a valid public IP address
    static func isValidPublicIpAddress(_ fullIp: String) -> Bool {
        let ip = fullIp.split(separator: ":").first?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        if isIPv6Address(ip) {
            return true
        } else {
            let ipv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
            guard ip.range(of: ipv4Regex, options: .regularExpression) != nil else { return false }
            let octets = ip.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            // Check for private IP ranges
            if octets[0] == 10 { return false }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return false }
            if octets[0] == 192 && octets[1] == 168 { return false }
            return true
        }
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
            if !(8000...8999).contains(p) { continue }
            if Gadget.isIPv6Address(i) {
                ip6 = "[i]:\(p)"
            } else {
                let ipv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
                guard i.range(of: ipv4Regex, options: .regularExpression) != nil else { continue }
                let octets = i.split(separator: ".").compactMap { UInt8($0) }
                guard octets.count == 4 else { continue }
                if octets[0] == 10 { continue }
                if octets[0] == 172 && (16...31).contains(octets[1]) { continue }
                if octets[0] == 192 && octets[1] == 168 { continue }
                ip4 = "\(i):\(p)"
            }
        }
        return ip4 ?? ip6
    }

    func getAlphaIds() -> [String] {
        let alphaIdString = AppConfig.alphaId
        return alphaIdString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } // Remove whitespace if needed
            .map { String($0) }
    }
} 
