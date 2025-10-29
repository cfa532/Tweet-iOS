import Foundation
import Network
import SwiftUI

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
        let cleanedInput = (nodeList as? String)?.replacingOccurrences(of: "\"", with: "") ?? ""
        
        // Split the input into groups
        let groups = cleanedInput.components(separatedBy: "],[")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            .filter { !$0.isEmpty }
        
        var fastestIP: String? = nil
        var fastestResponseTime: UInt64 = UInt64.max
        
        for group in groups {
            let pairs = group.components(separatedBy: "],[")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
                .filter { !$0.isEmpty }
            
            for pair in pairs {
                let components = pair.components(separatedBy: ",")
                guard components.count >= 2,
                      let responseTime = UInt64(components[1].trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                
                let ipWithPort = components[0].trimmingCharacters(in: .whitespaces)
                
                // Extract IP and port
                let ipComponents = ipWithPort.split(separator: ":")
                guard ipComponents.count >= 2 else { continue }
                
                let port = String(ipComponents.last!)
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
    static func isPrivateIP(_ ip: String) -> Bool {
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
        // Extract clean IP address from the full IP string (which may include port)
        let cleanIP: String
        
        if fullIp.hasPrefix("[") && fullIp.contains("]:") {
            // IPv6 with port, e.g. [240e:391:edf:ad90:b25a:daff:fe87:21d4]:8002
            if let endBracket = fullIp.firstIndex(of: "]") {
                cleanIP = String(fullIp[fullIp.index(after: fullIp.startIndex)..<endBracket])
            } else {
                return false
            }
        } else if fullIp.contains(":") && !fullIp.contains("]:") && !fullIp.contains("[") {
            // IPv4 with port, e.g. 60.163.239.184:8002
            let parts = fullIp.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                cleanIP = String(parts[0])
            } else {
                return false
            }
        } else {
            // No port specified, use the full string
            cleanIP = fullIp.hasPrefix("[") && fullIp.hasSuffix("]") ? 
                String(fullIp.dropFirst().dropLast()) : fullIp
        }
        
        if isIPv6Address(cleanIP) {
            // For IPv6, check if it's NOT a private address
            return !isPrivateIP(cleanIP)
        } else {
            let ipv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
            guard cleanIP.range(of: ipv4Regex, options: .regularExpression) != nil else { return false }
            let octets = cleanIP.split(separator: ".").compactMap { UInt8($0) }
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
            if !(8000...9000).contains(p) { continue }
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

    static func getAlphaIds() -> [String] {
        let alphaIdString = AppConfig.alphaId
        return alphaIdString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } // Remove whitespace if needed
            .map { String($0) }
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
            let addrsValue = paramText[bracketStart...lastBracketRange.upperBound]
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

// MARK: - Environment Keys for Video Playlist

struct VideoPlaylistKey: EnvironmentKey {
    static let defaultValue: [FeedVideoPlaylistManager.VideoItem] = []
}

struct FeedIdKey: EnvironmentKey {
    static let defaultValue: String = "default"
}

extension EnvironmentValues {
    var videoPlaylist: [FeedVideoPlaylistManager.VideoItem] {
        get { self[VideoPlaylistKey.self] }
        set { self[VideoPlaylistKey.self] = newValue }
    }
    
    var feedId: String {
        get { self[FeedIdKey.self] }
        set { self[FeedIdKey.self] = newValue }
    }
}

// MARK: - Feed Video Playlist Manager
/// Manages a cached playlist of all videos in the tweet feed for full-screen browsing
class FeedVideoPlaylistManager: ObservableObject {
    static let shared = FeedVideoPlaylistManager()
    
    // MARK: - Video Item
    struct VideoItem: Codable, Identifiable {
        let id: String  // Unique ID for this video item
        let tweetId: String
        let videoMediaId: String
        let videoIndex: Int  // Index within the tweet's attachments
        let tweetAuthorId: String
        let tweetTimestamp: Date
        let videoType: VideoType
        let aspectRatio: Double?
        let duration: TimeInterval?
        let isPrivate: Bool
        
        enum VideoType: String, Codable {
            case video
            case hls_video
            case audio
        }
        
        // Unique identifier combining tweet and video
        var uniqueId: String {
            return "\(tweetId)_\(videoIndex)_\(videoMediaId)"
        }
    }
    
    // MARK: - State
    @Published private(set) var playlist: [VideoItem] = []
    private let playlistQueue = DispatchQueue(label: "FeedVideoPlaylistManager", qos: .userInitiated)
    
    // Track which feeds we've loaded
    private var loadedFeeds: Set<String> = []
    
    private init() {}
    
    // MARK: - Cache Keys
    private func playlistCacheKey(for feedId: String) -> String {
        return "feed_video_playlist_\(feedId)"
    }
    
    // MARK: - Public API
    
    /// Build playlist from tweets (called when tweets are first loaded)
    /// Returns the playlist immediately for the current feed
    func buildPlaylist(from tweets: [Tweet], feedId: String) -> [VideoItem] {
        var videoItems: [VideoItem] = []
        
        for tweet in tweets {
            guard let attachments = tweet.attachments, !attachments.isEmpty else { continue }
            
            for (index, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video || attachment.type == .audio {
                    let videoItem = VideoItem(
                        id: "\(tweet.mid)_\(index)",
                        tweetId: tweet.mid,
                        videoMediaId: attachment.mid,
                        videoIndex: index,
                        tweetAuthorId: tweet.authorId,
                        tweetTimestamp: tweet.timestamp,
                        videoType: attachment.type == .audio ? .audio : (attachment.type == .hls_video ? .hls_video : .video),
                        aspectRatio: attachment.aspectRatio != nil ? Double(attachment.aspectRatio!) : nil,
                        duration: nil,
                        isPrivate: tweet.isPrivate ?? false
                    )
                    print("🎬 [Playlist Build] Added video: tweetId=\(tweet.mid), index=\(index), type=\(attachment.type), mediaId=\(attachment.mid)")
                    videoItems.append(videoItem)
                }
            }
        }
        
        // Update playlist only for main_feed
        if feedId == "main_feed" {
            DispatchQueue.main.async {
                self.playlist = videoItems
                self.loadedFeeds.insert(feedId)
                print("📹 [VideoPlaylist] Built main_feed playlist with \(videoItems.count) videos from \(tweets.count) tweets")
            }
        } else {
            print("📹 [VideoPlaylist] Built \(feedId) playlist with \(videoItems.count) videos from \(tweets.count) tweets")
        }
        
        // Save to cache asynchronously
        playlistQueue.async { [weak self] in
            self?.savePlaylist(videoItems, feedId: feedId)
        }
        
        return videoItems
    }
    
    /// Add new videos to playlist (called when new tweets arrive)
    func addVideos(from newTweets: [Tweet], feedId: String = "main_feed") {
        playlistQueue.async { [weak self] in
            guard let self = self else { return }
            
            var newVideoItems: [VideoItem] = []
            
            for tweet in newTweets {
                guard let attachments = tweet.attachments, !attachments.isEmpty else { continue }
                
                for (index, attachment) in attachments.enumerated() {
                    if attachment.type == .video || attachment.type == .hls_video || attachment.type == .audio {
                        let videoItem = VideoItem(
                            id: "\(tweet.mid)_\(index)",
                            tweetId: tweet.mid,
                            videoMediaId: attachment.mid,
                            videoIndex: index,
                            tweetAuthorId: tweet.authorId,
                            tweetTimestamp: tweet.timestamp,
                            videoType: attachment.type == .audio ? .audio : (attachment.type == .hls_video ? .hls_video : .video),
                            aspectRatio: attachment.aspectRatio != nil ? Double(attachment.aspectRatio!) : nil,
                            duration: nil,
                            isPrivate: tweet.isPrivate ?? false
                        )
                        
                        if !self.playlist.contains(where: { $0.uniqueId == videoItem.uniqueId }) {
                            newVideoItems.append(videoItem)
                        }
                    }
                }
            }
            
            guard !newVideoItems.isEmpty else { return }
            
            DispatchQueue.main.async {
                self.playlist.append(contentsOf: newVideoItems)
                self.playlist.sort { $0.tweetTimestamp > $1.tweetTimestamp }
                print("📹 [VideoPlaylist] Added \(newVideoItems.count) new videos (total: \(self.playlist.count))")
            }
            
            self.savePlaylist(self.playlist, feedId: feedId)
        }
    }
    
    /// Remove videos from deleted tweet
    func removeVideos(tweetId: String, feedId: String = "main_feed") {
        playlistQueue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                let countBefore = self.playlist.count
                self.playlist.removeAll { $0.tweetId == tweetId }
                let countAfter = self.playlist.count
                
                if countBefore != countAfter {
                    print("📹 [VideoPlaylist] Removed \(countBefore - countAfter) videos from tweet: \(tweetId)")
                }
            }
            
            self.savePlaylist(self.playlist, feedId: feedId)
        }
    }
    
    /// Find video index in a specific playlist
    func findVideoIndex(tweetId: String, videoIndex: Int, in playlist: [VideoItem]) -> Int? {
        return playlist.firstIndex { $0.tweetId == tweetId && $0.videoIndex == videoIndex }
    }
    
    /// Get video at index from a playlist
    func getVideo(at index: Int, from playlist: [VideoItem]) -> VideoItem? {
        guard index >= 0 && index < playlist.count else { return nil }
        return playlist[index]
    }
    
    /// Get next video in playlist
    func getNextVideo(after index: Int, from playlist: [VideoItem]) -> VideoItem? {
        let nextIndex = index + 1
        return getVideo(at: nextIndex, from: playlist)
    }
    
    /// Get previous video in playlist
    func getPreviousVideo(before index: Int, from playlist: [VideoItem]) -> VideoItem? {
        let prevIndex = index - 1
        return getVideo(at: prevIndex, from: playlist)
    }
    
    /// Clear playlist
    func clearPlaylist(feedId: String = "main_feed") {
        playlistQueue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.playlist.removeAll()
                print("📹 [VideoPlaylist] Cleared playlist")
            }
            
            let key = self.playlistCacheKey(for: feedId)
            UserDefaults.standard.removeObject(forKey: key)
            self.loadedFeeds.remove(feedId)
        }
    }
    
    // MARK: - Persistence
    
    private func savePlaylist(_ items: [VideoItem], feedId: String) {
        let key = playlistCacheKey(for: feedId)
        
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: key)
            print("💾 [VideoPlaylist] Saved \(items.count) videos to storage")
        } catch {
            print("❌ [VideoPlaylist] Failed to encode: \(error)")
        }
    }
    
    func loadPlaylist(feedId: String = "main_feed") {
        playlistQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.loadedFeeds.contains(feedId) else { return }
            
            let key = self.playlistCacheKey(for: feedId)
            guard let data = UserDefaults.standard.data(forKey: key) else {
                print("📹 [VideoPlaylist] No cached playlist found")
                return
            }
            
            do {
                let items = try JSONDecoder().decode([VideoItem].self, from: data)
                
                DispatchQueue.main.async {
                    self.playlist = items
                    self.loadedFeeds.insert(feedId)
                    print("📦 [VideoPlaylist] Loaded \(items.count) videos from storage")
                }
            } catch {
                print("❌ [VideoPlaylist] Failed to decode: \(error)")
            }
        }
    }
    
    func getPlaylistStats() -> (totalVideos: Int, hlsCount: Int, progressiveCount: Int, audioCount: Int) {
        let total = playlist.count
        let hls = playlist.filter { $0.videoType == .hls_video }.count
        let progressive = playlist.filter { $0.videoType == .video }.count
        let audio = playlist.filter { $0.videoType == .audio }.count
        return (total, hls, progressive, audio)
    }
    
    /// Clear all cached playlists (useful for debugging or after updates)
    func clearAllCaches() {
        playlistQueue.async { [weak self] in
            guard let self = self else { return }
            
            let defaults = UserDefaults.standard
            let allKeys = defaults.dictionaryRepresentation().keys
            
            // Clear video playlist caches
            let playlistKeys = allKeys.filter { $0.hasPrefix("feed_video_playlist_") }
            for key in playlistKeys {
                defaults.removeObject(forKey: key)
                print("🗑️ Cleared playlist cache: \(key)")
            }
            
            DispatchQueue.main.async {
                self.playlist.removeAll()
                self.loadedFeeds.removeAll()
                print("✅ [VideoPlaylist] All caches cleared")
            }
        }
    }
}

// MARK: - Error Message Helper
/// Converts technical error messages into user-friendly messages
struct ErrorMessageHelper {
    
    /// Convert a technical error to a user-friendly message
    static func userFriendlyMessage(from error: Error) -> String {
        let errorDescription = error.localizedDescription.lowercased()
        
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
        
        if errorDescription.contains("could not connect to the server") ||
           errorDescription.contains("server is not responding") ||
           errorDescription.contains("cannot find the server") ||
           errorDescription.contains("host") ||
           errorDescription.contains("dns") {
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
