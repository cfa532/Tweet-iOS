import Foundation
import hprose

// MARK: - HproseService
final class HproseInstance {
    // MARK: - Properties
    static let shared = HproseInstance()
    var appUser: User = User(id: Constants.GUEST_ID)
    
    private var appId: String = Bundle.main.bundleIdentifier ?? ""
    private var cachedUsers: Set<User> = []
    private var preferenceHelper: PreferenceHelper?
    private var chatDatabase: ChatDatabase?
    private var tweetDao: CachedTweetDao?
    
    private lazy var client: HproseClient = {
        let client = HproseClient()
        client.timeout = 60
        //        guard let service = client.useService(HproseService.self as Protocol) as? HproseService else {
        //            fatalError("Could not cast service to HproseService")
        //        }
        //        return service
        return client
    }()
    private var hproseClient: HproseService?
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        self.preferenceHelper = PreferenceHelper()
        self.chatDatabase = ChatDatabase.shared
        self.tweetDao = TweetCacheDatabase.shared.tweetDao()
        
        appUser = User(
            id: Constants.GUEST_ID,
            baseUrl: preferenceHelper?.getAppUrls().first ?? "",
        )
        appUser.followingList = Gadget.shared.getAlphaIds()
        
        try await initAppEntry()
    }
    
    // MARK: - Tweet Operations
    func fetchTweets(
        user: User,
        startRank: UInt,
        endRank: UInt,
        entry: String = "get_tweet_feed"
    ) async throws -> [Tweet] {
        try await withRetry {
            let params = [
                "aid": appId,
                "ver": "last",
                "entry": entry,
                "userid": appUser.id,
                "start": 0,  // startRank
                "end": 20,  // count
                "gid": appUser.mid,
                "hostid": user.hostIds?.first as Any
            ]
            let response = hproseClient?.runMApp(entry, params, []) as? [[String: Any]]
            return try response?.compactMap { dict in
                let data = try JSONSerialization.data(withJSONObject: dict)
                return try JSONDecoder().decode(Tweet.self, from: data)
            } ?? []
        }
    }
    
    func likeTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "like_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
        }
    }
    
    func retweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "retweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
        }
    }
    
    func bookmarkTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "bookmark_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
        }
    }
    
    func deleteTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "delete_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
        }
    }
    
    // MARK: - Private Methods
    private func fetchHTML(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let htmlString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return htmlString
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
    
    private func initAppEntry() async throws {
        // Clear cached users during retry init
        cachedUsers.removeAll()
        
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = extractParamMap(from: html)
                appId = paramData["mid"] as? String ?? ""
                guard let addrs = paramData["addrs"] as? String else {return}
                print(addrs)
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    appUser = appUser.copy(baseUrl: "http://\(firstIp)")
                    client.uri = appUser.baseUrl
                    guard let service = client.useService(HproseService.self as Protocol) as? HproseService else {
                        fatalError("Could not cast service to HproseService")
                    }
                    hproseClient = service
                    
                    if let userId = preferenceHelper?.getUserId(), userId != Constants.GUEST_ID {
                        let providers = try await getProviders(userId, baseUrl: "http://\(firstIp)")
                        if let accessibleUser = getAccessibleUser(providers, userId: userId) {
                            appUser = accessibleUser
                            cachedUsers.insert(appUser)
                        }
                        
                    } else {
                        appUser.followingList = Gadget.shared.getAlphaIds()
                        cachedUsers.insert(appUser)
                    }
                    return
                }
            } catch {
                print("Error initializing app entry: \(error)")
            }
        }
    }
    
    private func getProviders(_ mid: String, baseUrl: String) async throws -> [String] {
        return try await withRetry {
            let params = [
                "aid": appId,
                "ver": "last",
            ]
            if let response = hproseClient?.runMApp("get_providers", params, []) {
                if let ips = response as? [String] {
                    return Array(Set(ips))
                }
            }
            return []
        }
    }
    
    private func getAccessibleUser(_ providers: [String], userId: String) -> User? {
        // Implementation of accessible user check
        return nil // TODO: Implement user accessibility check
    }
    
    // MARK: - Network Operations
    private func withRetry<T>(_ block: () async throws -> T) async throws -> T {
        var retryCount = 0
        while retryCount < 2 {
            do {
                return try await block()
            } catch {
                retryCount += 1
                try await initAppEntry()
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error: All retries failed."])
    }
    
//    func sendMessage(receiptId: String, message: ChatMessage) async throws {
//        try await withRetry {
//            let entry = "message_outgoing"
//            let encodedMsg = try JSONEncoder().encode(message).base64EncodedString()
//            
//            let params: [Any] = [
//                appId,
//                "last",
//                entry,
//                appUser.id,
//                receiptId,
//                encodedMsg,
//                appUser.hostIds?.first ?? ""
//            ]
//            
//            
//            // Write message to receipt's Mimei db
//            if let receipt = try await getUser(receiptId) {
//                client.uri = receipt.baseUrl
//                let receiptEntry = "message_incoming"
//                let receiptParams: [Any] = [
//                    appId,
//                    "last",
//                    receiptEntry,
//                    appUser.id,
//                    receiptId,
//                    encodedMsg
//                ]
//
//            }
//        }
//    }
    
//    func fetchMessages(senderId: String, messageCount: Int = 50) async throws -> [ChatMessage]? {
//        try await withRetry {
//            client.uri = appUser.baseUrl
//            let entry = "message_fetch"
//            let params: [Any] = [
//                appId,
//                "last",
//                entry,
//                appUser.id,
//                senderId
//            ]
//            
//            let response = try await client.invoke("fetchMessages", params) as? [[String: Any]]
//            return try response?.compactMap { dict in
//                let data = try JSONSerialization.data(withJSONObject: dict)
//                return try JSONDecoder().decode(ChatMessage.self, from: data)
//            }
//        }
//    }
    
//    func getUser(_ userId: String) async throws -> User? {
//        client.uri = appUser.baseUrl
//        let params: [Any] = [appId, "last", "getUser", userId]
//        let response = try await client.invoke("getUser", params) as? [String: Any]
//        
//        guard let response = response else { return nil }
//        let data = try JSONSerialization.data(withJSONObject: response)
//        return try JSONDecoder().decode(User.self, from: data)
//    }
}

struct ChatMessage: Codable {
    // TODO: Implement ChatMessage properties
}

// MARK: - Database Types
class ChatDatabase {
    static let shared = ChatDatabase()
    private init() {}
}

class TweetCacheDatabase {
    static let shared = TweetCacheDatabase()
    private init() {}
    
    func tweetDao() -> CachedTweetDao {
        return CachedTweetDao()
    }
}

class CachedTweetDao {
    func getLastTweetRank() -> Int {
        // TODO: Implement last tweet rank retrieval
        return 0
    }
}

@objc protocol HproseService: AnyObject {
    func runMApp(_ entry: String, _ request: [AnyHashable: Any], _ args: [NSData]) -> Any?
}
