import Foundation
import hprose

// MARK: - HproseService
final class HproseService {
    // MARK: - Properties
    static let shared = HproseService()
    
    private var appId: String = Bundle.main.bundleIdentifier ?? ""
    private var appUser: User = User(id: Constants.GUEST_ID)
    private var cachedUsers: Set<User> = []
    private var preferenceHelper: PreferenceHelper?
    private var chatDatabase: ChatDatabase?
    private var tweetDao: CachedTweetDao?
    
    private lazy var client: HproseClient = {
        let client = HproseClient()
        client.timeout = 60
        return client
    }()
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        self.preferenceHelper = PreferenceHelper()
        self.chatDatabase = ChatDatabase.shared
        self.tweetDao = TweetCacheDatabase.shared.tweetDao()
        
        appUser = User(
            id: Constants.GUEST_ID,
            baseUrl: preferenceHelper?.getAppUrls().first ?? ""
        )
        
        try await initAppEntry()
    }
    
    // MARK: - Tweet Operations
    func fetchTweets() async throws -> [Tweet] {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "get_tweet_feed"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                0,  // startRank
                20  // count
            ]
            
            let response = try await client.invoke("getTweetFeed", params) as? [[String: Any]]
            return try response?.compactMap { dict in
                let data = try JSONSerialization.data(withJSONObject: dict)
                return try JSONDecoder().decode(Tweet.self, from: data)
            } ?? []
        }
    }
    
    func fetchMoreTweets() async throws -> [Tweet] {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "get_tweet_feed"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetDao?.getLastTweetRank() ?? 0,  // startRank
                20  // count
            ]
            
            let response = try await client.invoke("getTweetFeed", params) as? [[String: Any]]
            return try response?.compactMap { dict in
                let data = try JSONSerialization.data(withJSONObject: dict)
                return try JSONDecoder().decode(Tweet.self, from: data)
            } ?? []
        }
    }
    
    func likeTweet(_ tweetId: String) async throws {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "like_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
            
            _ = try await client.invoke("likeTweet", params)
        }
    }
    
    func retweet(_ tweetId: String) async throws {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "retweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
            
            _ = try await client.invoke("retweet", params)
        }
    }
    
    func bookmarkTweet(_ tweetId: String) async throws {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "bookmark_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
            
            _ = try await client.invoke("bookmarkTweet", params)
        }
    }
    
    func deleteTweet(_ tweetId: String) async throws {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "delete_tweet"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                tweetId
            ]
            
            _ = try await client.invoke("deleteTweet", params)
        }
    }
    
    // MARK: - Private Methods
    private func getAlphaIds() -> [String] {
        return Bundle.main.infoDictionary?["ALPHA_ID"] as? String ?? ""
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
    
    private func initAppEntry() async throws {
        // Clear cached users during retry init
        cachedUsers.removeAll()
        
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                client.uri = url
                let response = try await client.invoke("getParam", []) as? [String: Any]
                
                if let paramData = response {
                    appId = paramData["mid"] as? String ?? ""
                    
                    if let hostIPs = filterIpAddresses(paramData["addrs"] as? [[Any]] ?? []) {
                        if let firstIp = getAccessibleIP(hostIPs) ?? getAccessibleIP2(hostIPs) {
                            appUser = appUser.copy(baseUrl: "http://\(firstIp)")
                            
                            if let userId = preferenceHelper?.getUserId(),
                               userId != Constants.GUEST_ID {
                                if let providers = try await getProviders(userId: userId, baseUrl: "http://\(firstIp)") {
                                    if let accessibleUser = getAccessibleUser(providers, userId: userId) {
                                        appUser = accessibleUser
                                        cachedUsers.insert(appUser)
                                    }
                                }
                            } else {
                                appUser.followingList = getAlphaIds()
                                cachedUsers.insert(appUser)
                            }
                            return
                        }
                    }
                }
            } catch {
                print("Error initializing app entry: \(error)")
            }
        }
    }
    
    private func filterIpAddresses(_ addrs: [[Any]]) -> [String]? {
        // Implementation of IP address filtering logic
        return nil // TODO: Implement IP filtering logic
    }
    
    private func getAccessibleIP(_ ips: [String]) -> String? {
        // Implementation of accessible IP check
        return nil // TODO: Implement IP accessibility check
    }
    
    private func getAccessibleIP2(_ ips: [String]) -> String? {
        // Implementation of alternative accessible IP check
        return nil // TODO: Implement alternative IP accessibility check
    }
    
    private func getProviders(userId: String, baseUrl: String) async throws -> [String]? {
        client.uri = baseUrl
        return try await client.invoke("getProviders", [userId]) as? [String]
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
    
    func sendMessage(receiptId: String, message: ChatMessage) async throws {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "message_outgoing"
            let encodedMsg = try JSONEncoder().encode(message).base64EncodedString()
            
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                receiptId,
                encodedMsg,
                appUser.hostIds?.first ?? ""
            ]
            
            _ = try await client.invoke("sendMessage", params)
            
            // Write message to receipt's Mimei db
            if let receipt = try await getUser(receiptId) {
                client.uri = receipt.baseUrl
                let receiptEntry = "message_incoming"
                let receiptParams: [Any] = [
                    appId,
                    "last",
                    receiptEntry,
                    appUser.id,
                    receiptId,
                    encodedMsg
                ]
                _ = try await client.invoke("sendMessage", receiptParams)
            }
        }
    }
    
    func fetchMessages(senderId: String, messageCount: Int = 50) async throws -> [ChatMessage]? {
        try await withRetry {
            client.uri = appUser.baseUrl
            let entry = "message_fetch"
            let params: [Any] = [
                appId,
                "last",
                entry,
                appUser.id,
                senderId
            ]
            
            let response = try await client.invoke("fetchMessages", params) as? [[String: Any]]
            return try response?.compactMap { dict in
                let data = try JSONSerialization.data(withJSONObject: dict)
                return try JSONDecoder().decode(ChatMessage.self, from: data)
            }
        }
    }
    
    func getUser(_ userId: String) async throws -> User? {
        client.uri = appUser.baseUrl
        let params: [Any] = [appId, "last", "getUser", userId]
        let response = try await client.invoke("getUser", params) as? [String: Any]
        
        guard let response = response else { return nil }
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(User.self, from: data)
    }
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

class PreferenceHelper {
    func getAppUrls() -> [String] {
        // TODO: Implement URL retrieval
        return []
    }
    
    func getUserId() -> String? {
        // TODO: Implement user ID retrieval
        return nil
    }
}

