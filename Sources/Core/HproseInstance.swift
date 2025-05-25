import Foundation
import hprose
import PhotosUI
import AVFoundation
import BackgroundTasks

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

// MARK: - Array Extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - HproseService
final class HproseInstance: ObservableObject {
    // MARK: - Properties
    static let shared = HproseInstance()
    @Published var appUser: User = User(mid: Constants.GUEST_ID) {
        didSet {
            // When appUser is set and is not guest, fetch following and follower lists
            if !appUser.isGuest {
                Task {
                    let following = try? await getFollows(user: appUser, entry: .FOLLOWING)
                    let followers = try? await getFollows(user: appUser, entry: .FOLLOWER)
                    await MainActor.run {
                        self.appUser.followingList = following
                        self.appUser.fansList = followers
                    }
                }
            }
        }
    }
    
    private var appId: String = Bundle.main.bundleIdentifier ?? ""
    private let cachedUsersLock = NSLock()
    private var _cachedUsers: Set<User> = []
    private var cachedUsers: Set<User> {
        get {
            cachedUsersLock.withLock { _cachedUsers }
        }
        set {
            cachedUsersLock.withLock { _cachedUsers = newValue }
        }
    }
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
            mid: Constants.GUEST_ID,
            baseUrl: preferenceHelper?.getAppUrls().first ?? "",
        )
        appUser.followingList = Gadget.getAlphaIds()
        
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
                    #if DEBUG
                        let firstIp = "183.128.49.46:8002"  // for testing
                    #endif
                    appUser = appUser.copy(baseUrl: "http://\(firstIp)")
                    client.uri = appUser.baseUrl!+"/webapi/"
                    hproseClient = client.useService(HproseService.self) as AnyObject
                    
                    if let userId = preferenceHelper?.getUserId(), userId != Constants.GUEST_ID,
                       // get best IP for the given userId
                       let providerIp = try await getProvider(userId) {
                        // get user object from this IP
                        if let user = try await getUser(userId, baseUrl: "http://\(providerIp)") {
                            appUser = user
                            appUser.baseUrl = "http://\(providerIp)"
                            cachedUsers.insert(appUser)
                            return
                        }
                    }
                    appUser.followingList = Gadget.getAlphaIds()
                    cachedUsers.insert(appUser)
                    return
                }
            } catch {
                print("Error initializing app entry: \(error)")
            }
        }
    }
    
    func logout() {
        appUser.mid = Constants.GUEST_ID
        appUser.followingList = Gadget.getAlphaIds()
        appUser.avatar = nil
        preferenceHelper?.setUserId(nil as String?)
    }
    
    func fetchComments(
        tweet: Tweet,
        pageNumber: Int = 0,
        pageSize: Int = 20
    ) async throws -> [Tweet] {
        try await withRetry {
            let entry = "get_comments"
            let params = [
                "aid": appId,
                "ver": "last",
                "tweetid": tweet.mid,
                "userid": appUser.mid,
                "pn": pageNumber,
                "ps": pageSize,
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                print("Invalid response format from server in fetchComments, params: \(params)")
                return []
            }
            
            let comments = response.compactMap { dict -> Tweet? in
                return Tweet.from(dict: dict)
            }
            // Then fetch author data for each tweet
            var tweetsWithAuthors: [Tweet] = []
            for var tweet in comments {
                if let author = try await getUser(tweet.authorId) {
                    tweet.author = author
                    tweetsWithAuthors.append(tweet)
                }
            }
            return tweetsWithAuthors
        }
    }
    
    // MARK: - Tweet Operations
    /// Updated: Use pageNumber and pageSize for easier pagination
    func fetchTweetFeed(
        user: User,
        pageNumber: Int = 0,
        pageSize: Int = 20,
        entry: String = "get_tweet_feed"
    ) async throws -> [Tweet] {
        print("[fetchTweetFeed] Starting fetch for page \(pageNumber) with page size \(pageSize)")
        
        // Calculate initial ranks
        var startRank = UInt(pageNumber * pageSize)
        var endRank = UInt(startRank + UInt(pageSize))
        
        print("[fetchTweetFeed] Initial ranks - start: \(startRank), end: \(endRank)")
        
        return try await withRetry {
            guard let service = hproseClient else {
                print("[fetchTweetFeed] Service not initialized")
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            var accumulatedTweets: [Tweet] = []
            
            while startRank <= 1000 && accumulatedTweets.count < pageSize { // Continue until we have enough tweets or hit the limit
                let params = [
                    "aid": appId,
                    "ver": "last",
                    "start": startRank,
                    "end": endRank,
                    "userid": user.mid,
                    "appuserid": appUser.mid,
                ]
                
                print("[fetchTweetFeed] Requesting tweets with params: \(params)")
                
                let rawResponse = service.runMApp(entry, params, nil)
                print("[fetchTweetFeed] Raw response type: \(type(of: rawResponse))")
                
                // Unwrap the Optional<Any> response
                guard let unwrappedResponse = rawResponse else {
                    print("[fetchTweetFeed] Response is nil")
                    return accumulatedTweets
                }
                
                // Try to cast to array
                guard let responseArray = unwrappedResponse as? [Any] else {
                    print("[fetchTweetFeed] Response is not an array: \(unwrappedResponse)")
                    return accumulatedTweets
                }
                
                print("[fetchTweetFeed] Raw tweets from server: \(responseArray.count)")
                
                // If we got fewer items than page size, we've reached the end
                if responseArray.count < pageSize {
                    print("[fetchTweetFeed] Reached end of feed (response count: \(responseArray.count) < page size: \(pageSize))")
                    return accumulatedTweets
                }
                
                // Filter out null values and convert to dictionaries
                let validDictionaries = responseArray.compactMap { item -> [String: Any]? in
                    if let dict = item as? [String: Any] {
                        return dict
                    }
                    return nil
                }
                
                print("[fetchTweetFeed] Valid dictionaries count: \(validDictionaries.count)")
                
                // Create tweets from valid dictionaries
                let tweets = validDictionaries.compactMap { dict -> Tweet? in
                    if let tweet = Tweet.from(dict: dict) {
                        return tweet
                    } else {
                        print("[fetchTweetFeed] Failed to parse tweet from dict: \(dict)")
                        return nil
                    }
                }
                
                print("[fetchTweetFeed] Successfully parsed tweets: \(tweets.count)")
                
                // Then fetch author data for each tweet
                for var tweet in tweets {
                    if let author = try await getUser(tweet.authorId) {
                        tweet.author = author
                        accumulatedTweets.append(tweet)
                        
                        // If we've reached the page size, return what we have
                        if accumulatedTweets.count >= pageSize {
                            print("[fetchTweetFeed] Returning \(accumulatedTweets.count) tweets with authors (reached page size)")
                            return accumulatedTweets
                        }
                    } else {
                        print("[fetchTweetFeed] Failed to fetch author for tweet: \(tweet.mid)")
                    }
                }
                
                // If we got no valid tweets but have more items, increment the ranks
                print("[fetchTweetFeed] No more valid tweets in this batch, incrementing ranks. Current start: \(startRank), response count: \(responseArray.count)")
                startRank += UInt(responseArray.count)
                endRank = startRank + UInt(pageSize)
                print("[fetchTweetFeed] New ranks - start: \(startRank), end: \(endRank)")
            }
            
            // Return whatever tweets we've accumulated
            print("[fetchTweetFeed] Returning \(accumulatedTweets.count) accumulated tweets")
            return accumulatedTweets
        }
    }
    
    func fetchUserTweet(
        user: User,
        startRank: UInt,
        endRank: UInt,
        entry: String = "get_tweets_by_rank"
    ) async throws -> [Tweet] {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": user.mid,
                "start": startRank,
                "end": endRank,
                "appuserid": appUser.mid,
            ]
            
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                print("Invalid response format from server")
                return []
            }
            
            // First create tweets without author data
            let tweets = response.compactMap { dict -> Tweet? in
                return Tweet.from(dict: dict)
            }
            
            // Then fetch author data for each tweet
            var tweetsWithAuthors: [Tweet] = []
            for var tweet in tweets {
                if let author = try await getUser(tweet.authorId) {
                    tweet.author = author
                    tweetsWithAuthors.append(tweet)
                }
            }
            return tweetsWithAuthors
        }
    }
    
    func getTweet(
        tweetId: String,
        authorId: String,
        nodeUrl: String? = nil
    )  async throws -> Tweet? {
        try await withRetry {
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }

            let entry = "get_tweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "tweetid": tweetId,     // Tweet to be retrieved
                "appuserid": appUser.mid    // Used to check if the tweet is favored or bookmarked by appUser
            ]
            if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any] {
                if var tweet = Tweet.from(dict: tweetDict) {
                    tweet.author = try await getUser(authorId)
                    return tweet
                }
            } else {
                // the tweet is not on current node. Find its author's node.
                if let providerIp = try await getProvider(authorId) {
                    let newClient = HproseHttpClient()
                    newClient.timeout = 60
                    newClient.uri = "http://\(providerIp)/webapi/"
                    service = newClient.useService(HproseService.self) as AnyObject
                    if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any] {
                        if var tweet = Tweet.from(dict: tweetDict) {
                            tweet.author = try await getUser(authorId)
                            return tweet
                        }
                    }
                }
            }
            return nil
        }
    }
    
    func getUserId(_ username: String) async throws -> String? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let entry = "get_userid"
            let params = [
                "aid": appId,
                "ver": "last",
                "username": username,
            ]
            guard let response = service.runMApp(entry, params, nil) else {
                print("Invalid response format from server in getUserId, params: \(params)")
                return nil
            }
            return response as? String
        }
    }
    
    func getUser(_ userId: String, baseUrl: String = shared.appUser.baseUrl ?? "") async throws -> User? {
        // Check cache first
        if let cachedUser = cachedUsersLock.withLock({ _cachedUsers.first(where: { $0.mid == userId }) }) {
            return cachedUser
        }
        
        return try await withRetry {
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if baseUrl != appUser.baseUrl {
                // try to get User object from a different node other than the current one.
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "http://\(baseUrl)/webapi/"
                service = newClient.useService(HproseService.self) as AnyObject
            }

            let entry = "get_user"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": userId,
            ]
            /**
             response might be an user object if it can be found from the node,
             or an IP address where the user can be found.
             */
            guard let response = service.runMApp(entry, params, nil) else {
                print("Invalid response format from server in getUser, params: \(params)")
                return nil
            }
            
            // First try to decode it as User
            if let userDict = service.runMApp(entry, params, nil) as? [String: Any],
               let user = User.from(dict: userDict) {
                // Cache the user
                user.baseUrl = baseUrl
                _ = cachedUsersLock.withLock { _cachedUsers.insert(user) }
                return user
            }
            
            // If decoding as User failed, the response might be an IP address
            if let ipAddress = response as? String {
                // Create new client for this IP
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "http://\(ipAddress)/webapi/"
                let newService = newClient.useService(HproseService.self) as AnyObject
                
                // Make new request to get user from this IP
                if let userDict = newService.runMApp(entry, params, nil) as? [String: Any],
                   let user = User.from(dict: userDict) {
                    // Cache the user
                    user.baseUrl = "http://\(ipAddress)"
                    _ = cachedUsersLock.withLock { _cachedUsers.insert(user) }
                    return user
                }
            }
            return nil
        }
    }
    
    func login(_ loginUser: User) async throws -> [String: Any] {
        return try await withRetry {
            let entry = "login"
            let params = [
                "aid": appId,
                "ver": "last",
                "username": loginUser.username!,
                "password": loginUser.password!
            ]
            let newClient = HproseHttpClient()
            newClient.timeout = 60
            newClient.uri = "\(loginUser.baseUrl!)/webapi/"
            let newService = newClient.useService(HproseService.self) as AnyObject
            
            guard let response = newService.runMApp(entry, params, nil) as? [String: Any] else {
                print("Invalid response format from server in login, params: \(params)")
                return ["reason": "Invalid response format from server", "status": "failure"]
            }
            
            if let status = response["status"] as? String {
                if status == "failure" {
                    if let reason = response["reason"] as? String {
                        return ["reason": reason, "status": "failure"]
                    }
                    return ["reason": "Unknown error occurred", "status": "failure"]
                } else if status == "success" {
                    if let userDict = response["user"] as? [String: Any],
                       let userObject = User.from(dict: userDict) {
                        hproseClient = newService   // update serving node for current session.
                        userObject.baseUrl = loginUser.baseUrl
                        
                        // Capture the value before the MainActor block
                        let finalUser = userObject
                        
                        // Update appUser on the main thread
                        await MainActor.run {
                            self.appUser = finalUser
                            preferenceHelper?.setUserId(finalUser.mid)
                        }
                        return ["user": userObject, "status": "success"]
                    }
                    return ["reason": "User data not found", "status": "failure"]
                }
            }
            return ["reason": "Invalid response status", "status": "failure"]
        }
    }
    
    func getFollows(
        user: User,
        entry: UserContentType
    ) async throws -> [String] {
        try await withRetry {
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": user.mid,
            ]
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if user.baseUrl != appUser.baseUrl {
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "\(user.baseUrl!)/webapi/"
                service = newClient.useService(HproseService.self) as AnyObject
            }
            if let response = service.runMApp(entry.rawValue, params, nil) as? [[String: Any]] {
                // Sort by Value descending and return list of Field
                let sorted = response.sorted {
                    (lhs, rhs) in
                    let lval = (lhs["value"] as? Int) ?? 0
                    let rval = (rhs["value"] as? Int) ?? 0
                    return lval > rval
                }
                return sorted.compactMap { $0["field"] as? String }
            }
            return []
        }
    }
    
    func getUserTweetsByType(
        user: User,
        type: UserContentType,
        pageNumber: Int = 0,
        pageSize: Int = 20
    ) async throws -> [Tweet] {
        try await withRetry {
            let entry = "get_user_meta"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": user.mid,
                "type": type.rawValue,
                "pn": pageNumber,
                "ps": pageSize,
                "appuserid": appUser.mid
            ]
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if user.baseUrl != appUser.baseUrl {
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "\(user.baseUrl!)/webapi/"
                service = newClient.useService(HproseService.self) as AnyObject
            }
            if let response = service.runMApp(entry, params, nil) as? [[String: Any]] {
                // First create tweets without author data
                let tweets = response.compactMap { dict -> Tweet? in
                    return Tweet.from(dict: dict)
                }
                
                // Then fetch author data for each tweet
                var tweetsWithAuthors: [Tweet] = []
                for var tweet in tweets {
                    if let author = try await getUser(tweet.authorId) {
                        tweet.author = author
                        tweetsWithAuthors.append(tweet)
                    }
                }
                return tweetsWithAuthors
            }
            return []
        }
    }
    
    /**
     * @param isFollowing indicates if the appUser is following @param userId. Passing
     * an argument instead of toggling the status of a follower, because toggling
     * following/follower status happens on two different hosts.
     * */
    func toggleFollower(
        userId: String,
        isFollowing: Bool,
        followerId: String
    ) async throws {
        try await withRetry {
            let entry = "toggle_follower"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": userId,
                "otherid": followerId,
                "isfollower": isFollowing
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            _ = service.runMApp(entry, params, nil)
        }
    }
    
    /**
     * Called when appUser clicks the Follow button.
     * @param followedId is the user that appUser is following or unfollowing.
     * */
    func toggleFollowing(
        followedId: String,
        followingId: String
    )  async throws -> Bool? {
        try await withRetry {
            let followedUser = try await getUser(followedId)
            let entry = "toggle_following"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": followingId,
                "otherid": followedId,
                "otherhostid": followedUser?.hostIds?.first as Any
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if let response = service.runMApp(entry, params, nil) as? Bool {
                return response
            }
            return nil
        }
    }
    
    /*
     Return an updated tweet object after toggling favorite status of the tweet by appUser.
     */
    func toggleFavorite(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            let entry = "toggle_favorite"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.mid,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                print("Invalid response format toggle favorite")
                return nil
            }
            // update appUser object
            if let userDict = response["user"] as? [String: Any],
               let user = User.from(dict: userDict) {
                await MainActor.run {
                    appUser.favoritesCount = user.favoritesCount
                }
            }
            // update the tweet object
            if let isFavorite = response["isFavorite"] as? Bool,
               let favoriteCount = response["count"] as? Int {
                var favorites = tweet.favorites ?? [false, false, false]
                favorites[UserActions.FAVORITE.rawValue] = isFavorite
                return tweet.copy(favorites: favorites, favoriteCount: favoriteCount)
            }
            return nil
        }
    }
    
    func toggleBookmark(_ tweet: Tweet) async throws -> Tweet?  {
        try await withRetry {
            let entry = "toggle_bookmark"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.id,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                print("Invalid response format toggle bookmark")
                return nil
            }
            // update appUser object
            if let userDict = response["user"] as? [String: Any],
               let user = User.from(dict: userDict) {
                await MainActor.run {
                    appUser.bookmarksCount = user.bookmarksCount
                }
            }
            // update the tweet object
            if let hasBookmarked = response["hasBookmarked"] as? Bool,
               let bookmarkCount = response["count"] as? Int {
                var favorites = tweet.favorites ?? [false, false, false]
                favorites[UserActions.BOOKMARK.rawValue] = hasBookmarked
                return tweet.copy(favorites: favorites, bookmarkCount: bookmarkCount)
            }
            return nil
        }
    }

    func retweet(_ tweet: Tweet) async throws -> Tweet? {
        try await withRetry {
            if let retweet = try await uploadTweet(
                Tweet(
                    mid: Constants.GUEST_ID,
                    authorId: appUser.mid,
                    originalTweetId: tweet.mid,
                    originalAuthorId: tweet.authorId
                )
            ) {
                return retweet
            }
            return nil
        }
    }
    
    /**
     * Increase the retweetCount of the original tweet mimei.
     * @param tweet is the original tweet
     * @param retweetId of the retweet.
     * @param direction to indicate increase or decrease retweet count.
     * @return updated original tweet.
     * */
    func updateRetweetCount(
        tweet: Tweet,
        retweetId: String,
        direction: Bool = true   // add/remove retweet
    ) async throws -> Tweet? {
        try await withRetry {
            let entry = direction ? "retweet_added" : "retweet_removed"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.mid,
                "retweetid": retweetId,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any],
               let updatedOriginalTweet = Tweet.from(dict: tweetDict) {
                return updatedOriginalTweet
            }
            return nil
        }
    }
    
    /**
     * Delete a tweet and returned the deleted tweetId
     * */
    func deleteTweet(_ tweetId: String) async throws -> String? {
        try await withRetry {
            let entry = "delete_tweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "authorid": appUser.mid,
                "tweetid": tweetId
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? String else {
                print("Invalid response delete tweetID: \(tweetId)")
                return nil
            }
            return response     // deleted tweetId
        }
    }
    
    func deleteComment(parentTweet: Tweet, commentId: String) async throws -> String? {
        try await withRetry {
            let entry = "delete_comment"
            let params = [
                "aid": appId,
                "ver": "last",
                "authorid": appUser.mid,
                "tweetid": parentTweet.mid,
                "hostid": parentTweet.author?.hostIds?.first as Any,
                "commentid": commentId,
                "userid": appUser.mid
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? String else {
                print("Invalid response delete commentId: \(commentId)")
                return nil
            }
            return response     // deleted tweetId
        }
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil
    ) async throws -> MimeiFileType? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            // Create temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            var offset: Int64 = 0
            let chunkSize = 1024 * 1024 // 1MB chunks
            var request: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "offset": offset
            ]
            
            do {
                let fileHandle = try FileHandle(forReadingFrom: tempURL)
                defer { try? fileHandle.close() }
                
                while true {
                    let data = fileHandle.readData(ofLength: chunkSize)
                    if data.isEmpty { break }
                    
                    let nsData = data as NSData
                    if let fsid = service.runMApp("upload_ipfs", request, [nsData]) as? String {
                        offset += Int64(data.count)
                        request["offset"] = offset
                        request["fsid"] = fsid
                    }
                }
                
                // Mark upload as finished
                request["finished"] = "true"
                if let referenceId = referenceId {
                    request["referenceid"] = referenceId
                }
                
                guard let cid = service.runMApp("upload_ipfs", request, nil) as? String else {
                    return nil
                }
                
                // Determine media type
                let mediaType: MediaType
                if typeIdentifier.hasPrefix("public.image") {
                    // Check for specific image types
                    if typeIdentifier.contains("jpeg") || typeIdentifier.contains("jpg") {
                        mediaType = .image
                    } else if typeIdentifier.contains("png") {
                        mediaType = .image
                    } else if typeIdentifier.contains("gif") {
                        mediaType = .image
                    } else if typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
                        mediaType = .image
                    } else {
                        mediaType = .image // Default to image for any public.image type
                    }
                } else if typeIdentifier.hasPrefix("public.movie") {
                    mediaType = .video
                } else if typeIdentifier.hasPrefix("public.audio") {
                    mediaType = .audio
                } else if typeIdentifier == "public.composite-content" {
                    mediaType = .pdf
                } else if typeIdentifier == "public.zip-archive" {
                    mediaType = .zip
                } else if typeIdentifier == "public.composite-content" {
                    mediaType = .word
                } else {
                    // Try to determine type from file extension
                    let fileExtension = typeIdentifier.components(separatedBy: ".").last?.lowercased()
                    switch fileExtension {
                    case "jpg", "jpeg", "png", "gif", "heic", "heif":
                        mediaType = .image
                    case "mp4", "mov", "m4v", "mkv":
                        mediaType = .video
                    case "mp3", "m4a", "wav":
                        mediaType = .audio
                    case "pdf":
                        mediaType = .pdf
                    case "zip":
                        mediaType = .zip
                    case "doc", "docx":
                        mediaType = .word
                    default:
                        mediaType = .unknown
                    }
                }
                
                // Get file attributes
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let fileSize = fileAttributes[.size] as? UInt64 ?? 0
                let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
                
                // Get aspect ratio for videos
                var aspectRatio: Float?
                if mediaType == .video {
                    aspectRatio = try await getVideoAspectRatio(url: tempURL)
                }
                
                // Create MimeiFileType with the CID
                return MimeiFileType(
                    mid: cid,
                    type: mediaType.rawValue,
                    size: Int64(fileSize),
                    fileName: fileName,
                    timestamp: fileTimestamp,
                    aspectRatio: aspectRatio,
                    url: nil
                )
            } catch {
                print("Error uploading file: \(error)")
                throw error
            }
        }
    }
    
    private func getVideoAspectRatio(url: URL) async throws -> Float? {
        let asset = AVAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            return nil
        }
        
        let size = try await videoTrack.load(.naturalSize)
        return Float(size.width / size.height)
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
    
    private func getProvider(_ mid: String) async throws -> String? {
        return try await withRetry {
            let params = [
                "aid": appId,
                "ver": "last",
                "mid": mid
            ]
            if let response = hproseClient?.runMApp("get_provider", params, []) {
                return response as? String
            }
            return nil
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
    
    // MARK: - Background Upload
    struct PendingUpload: Codable {
        let tweet: Tweet
        let selectedItemData: [ItemData]
        
        struct ItemData: Codable {
            let identifier: String
            let typeIdentifier: String
            let data: Data
            let fileName: String
        }
    }
    
    // MARK: - Background Task Registration
    static func handleBackgroundTask(task: BGProcessingTask) {
        // Schedule the next background task
        scheduleNextBackgroundTask()
        
        // Create a task to handle the upload
        let uploadTask = Task {
            // Look for the temporary file
            let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            
            do {
                let data = try Data(contentsOf: tempFileURL)
                guard let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data) else {
                    print("DEBUG: Failed to decode pending upload data")
                    task.setTaskCompleted(success: false)
                    return
                }
                
                print("DEBUG: Found pending upload with \(pendingUpload.selectedItemData.count) items")
                
                // Clean up the temporary file immediately after reading
                try? FileManager.default.removeItem(at: tempFileURL)
                
                var tweet = pendingUpload.tweet
                var uploadedAttachments: [MimeiFileType] = []
                
                // Process items in pairs
                let itemPairs = pendingUpload.selectedItemData.chunked(into: 2)
                print("DEBUG: Processing \(itemPairs.count) item pairs")
                
                for (index, pair) in itemPairs.enumerated() {
                    print("DEBUG: Processing pair \(index + 1)")
                    do {
                        let pairAttachments = try await shared.uploadItemPair(pair)
                        print("DEBUG: Successfully uploaded pair \(index + 1)")
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("DEBUG: Error uploading pair \(index + 1): \(error)")
                        task.setTaskCompleted(success: false)
                        return
                    }
                }
                
                if pendingUpload.selectedItemData.count != uploadedAttachments.count {
                    print("DEBUG: Attachment count mismatch. Expected: \(pendingUpload.selectedItemData.count), Got: \(uploadedAttachments.count)")
                    task.setTaskCompleted(success: false)
                    return
                }
                
                // Update tweet with uploaded attachments
                tweet.attachments = uploadedAttachments
                
                // Upload the tweet
                print("DEBUG: Uploading final tweet")
                if let uploadedTweet = try await shared.uploadTweet(tweet) {
                    print("DEBUG: Successfully uploaded tweet: \(uploadedTweet)")
                    task.setTaskCompleted(success: true)
                } else {
                    print("DEBUG: Failed to upload tweet")
                    task.setTaskCompleted(success: false)
                }
            } catch {
                print("DEBUG: Error in background task: \(error)")
                task.setTaskCompleted(success: false)
            }
        }
        
        // Set up the task expiration handler
        task.expirationHandler = {
            uploadTask.cancel()
        }
    }
    
    private static func scheduleNextBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: "com.tweet.upload")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // Schedule next task in 1 hour
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Successfully scheduled next background task")
        } catch {
            print("Could not schedule next background task: \(error)")
        }
    }
    
    func uploadTweet(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": "ReyCUFHHZmk0N5w_wxUeEuoY5Xr",
                "tweet": String(data: try JSONEncoder().encode(tweet), encoding: .utf8) ?? ""
            ]
            
            let rawResponse = service.runMApp("add_tweet", params, nil)
            guard let newTweetId = rawResponse as? String else {
                return Tweet?.none
            }
            
            var uploadedTweet = tweet
            uploadedTweet.mid = newTweetId
            return uploadedTweet
        }
    }
    
    private func uploadItemPair(_ pair: [PendingUpload.ItemData]) async throws -> [MimeiFileType] {
        let uploadTasks = pair.map { itemData in
            Task {
                return try await uploadToIPFS(
                    data: itemData.data,
                    typeIdentifier: itemData.typeIdentifier,
                    fileName: itemData.fileName
                )
            }
        }
        
        return try await withThrowingTaskGroup(of: MimeiFileType?.self) { group in
            for task in uploadTasks {
                group.addTask {
                    return try await task.value
                }
            }
            
            var uploadResults: [MimeiFileType?] = []
            for try await result in group {
                uploadResults.append(result)
            }
            
            if uploadResults.contains(where: { $0 == nil }) {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment upload failure in pair"])
            }
            
            return uploadResults.compactMap { $0 }
        }
    }
    
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingUpload.ItemData]) {
        Task.detached(priority: .background) {
            do {
                var tweet = tweet
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                
                for (index, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(index + 1): \(error)")
                        return
                    }
                }
                
                if itemData.count != uploadedAttachments.count {
                    print("Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)")
                    return
                }
                
                tweet.attachments = uploadedAttachments
                
                if let uploadedTweet = try await self.uploadTweet(tweet) {
                    await MainActor.run {
                        print("Tweet published successfully \(uploadedTweet)")
                    }
                } else {
                    await MainActor.run {
                        print("Failed to publish tweet")
                    }
                }
            } catch {
                print("Error in background upload: \(error)")
                await MainActor.run {
                    print("Error during upload: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func scheduleCommentUpload(comment: Tweet, to tweet: Tweet, itemData: [PendingUpload.ItemData]) {
        Task.detached(priority: .background) {
            do {
                var comment = comment
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                
                for (index, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(index + 1): \(error)")
                        return
                    }
                }
                
                if itemData.count != uploadedAttachments.count {
                    print("Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)")
                    return
                }
                
                comment.attachments = uploadedAttachments
                
                if let (updatedTweet, newComment) = try await self.submitComment(comment, to: tweet) {
                    await MainActor.run {
                        // Notify observers about both the updated tweet and new comment
                        NotificationCenter.default.post(
                            name: NSNotification.Name("NewCommentAdded"),
                            object: nil,
                            userInfo: [
                                "tweetId": tweet.mid,
                                "updatedTweet": updatedTweet,
                                "comment": newComment
                            ]
                        )
                        
                        print("Comment published successfully. Parent tweet comment count: \(updatedTweet.commentCount ?? 0)")
                    }
                } else {
                    await MainActor.run {
                        print("Failed to publish comment")
                    }
                }
            } catch {
                print("Error in background upload: \(error)")
                await MainActor.run {
                    print("Error during upload: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func submitComment(_ comment: Tweet, to tweet: Tweet) async throws -> (Tweet, Tweet)? {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": tweet.author?.hostIds?.first as Any,
                "comment": String(data: try JSONEncoder().encode(comment), encoding: .utf8) ?? "",
                "tweetid": tweet.mid,
                "userid": appUser.mid
            ]
            
            if let response = service.runMApp("add_comment", params, nil) as? [String: Any],
               let commentId = response["commentId"] as? String,
               let count = response["count"] as? Int {
                // Create the new comment with its ID
                var newComment = comment
                newComment.mid = commentId
                
                // Update the parent tweet with new comment count
                let updatedTweet = tweet.copy(commentCount: count)
                
                return (updatedTweet, newComment)
            }
            return nil
        }
    }
    
    /**
     * Return the current tweet list that is pinned to top.
     */
    func togglePinnedTweet(tweetId: String) async throws -> [String: Any]? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            let entry = "toggle_top_tweets"
            let params = [
                "aid": appId,
                "ver": "last",
                "tweetid": tweetId,
                "userid": appUser.mid,
            ]
            if let response = service.runMApp(entry, params, nil) as? [String: Any] {
               return response
            }
            return nil
        }
    }

    /**
     * Return a list of {tweetId, timestamp} for each pinned Tweet. The timestamp is when
     * the tweet is pinned.
     */
    func getPinnedTweets(user: User) async throws -> [[String: Any]] {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            let entry = "get_top_tweets"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": user.mid,
                "appuserid": appUser.mid
            ]
            if let response = service.runMApp(entry, params, nil) as? [[String: Any]] {
                var result: [[String: Any]] = []
                for dict in response {
                    if let tweetDict = dict["tweet"] as? [String: Any],
                       let tweet = Tweet.from(dict: tweetDict) {
                        var tweetWithAuthor = tweet
                        if let author = try? await getUser(tweet.authorId) {
                            tweetWithAuthor.author = author
                        }
                        let timePinned = dict["timestamp"]
                        result.append([
                            "tweet": tweetWithAuthor,
                            "timePinned": timePinned as Any
                        ])
                    }
                }
                return result
            }
            return []
        }
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
