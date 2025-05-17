import Foundation
import hprose

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

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
        let client = HproseHttpClient()
        client.timeout = 60
        return client
    }()
    private var hproseClient: AnyObject?
    
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
    
    private func initAppEntry() async throws {
        // Clear cached users during retry init
        cachedUsers.removeAll()
        
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = Gadget.shared.extractParamMap(from: html)
                appId = paramData["mid"] as? String ?? ""
                guard let addrs = paramData["addrs"] as? String else {return}
                print(addrs)
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    appUser = appUser.copy(baseUrl: "http://\(firstIp)")
                    client.uri = appUser.baseUrl!+"/webapi/"
                    hproseClient = client.useService(HproseService.self) as AnyObject
                    
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
    
    // MARK: - Tweet Operations
    func fetchTweets(
        user: User,
        startRank: UInt,
        endRank: UInt,
        entry: String = "test"
    ) async throws -> [Tweet] {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.isGuest ? "iFG4GC9r0fF22jYBCkuPThybzwO" : appUser.mid,
                "start": startRank,
                "end": endRank,
                "gid": appUser.mid,
                "hostid": user.hostIds?.first as Any
            ]
            let response = service.runMApp(entry, params, nil)
            print(response as Any)
            return []
//            return try await callService(service, entry: entry, params: params) { response in
//                guard let response = response as? [[String: Any]] else { return [] }
//                return try response.compactMap { dict -> Tweet? in
//                    let data = try JSONSerialization.data(withJSONObject: dict)
//                    return try JSONDecoder().decode(Tweet.self, from: data)
//                }
//            }
        }
    }
    
    // MARK: - Hprose Service Wrapper
    private func callService<T>(_ service: AnyObject?, entry: String, params: [String: Any], transform: @escaping ((Any?) throws -> T)) async throws -> T {
        guard let service = service else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let response = service.runMApp(entry, params, [])
                    let result = try transform(response)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func callService(_ service: AnyObject?, entry: String, params: [String: Any]) async throws {
        guard let service = service else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    _ = service.runMApp(entry, params, [])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
