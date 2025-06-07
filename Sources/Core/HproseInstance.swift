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
    static var baseUrl: String = ""
    @Published private var _appUser: User = User.getInstance(mid: Constants.GUEST_ID)
    var appUser: User {
        get { _appUser }
        set {
            // Get the singleton instance for the new user
            let instance = User.getInstance(mid: newValue.mid)
            Task { @MainActor in
                // Update the singleton instance with new values
                instance.baseUrl = newValue.baseUrl
                instance.writableUrl = newValue.writableUrl
                instance.name = newValue.name
                instance.username = newValue.username
                instance.avatar = newValue.avatar
                instance.email = newValue.email
                instance.profile = newValue.profile
                instance.cloudDrivePort = newValue.cloudDrivePort
                
                instance.tweetCount = newValue.tweetCount
                instance.followingCount = newValue.followingCount
                instance.followersCount = newValue.followersCount
                instance.bookmarksCount = newValue.bookmarksCount
                instance.favoritesCount = newValue.favoritesCount
                instance.commentsCount = newValue.commentsCount
                
                instance.hostIds = newValue.hostIds
                // Update the reference to point to the singleton instance
                self._appUser = instance
                // Notify observers that appUser has changed
                self.objectWillChange.send()
            }
        }
    }
    
    private var appId: String = Constants.GUEST_ID      // placeholder mimei id
    private var preferenceHelper: PreferenceHelper?
    
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
        
        await MainActor.run {
            _appUser = User.getInstance(mid: preferenceHelper?.getUserId() ?? Constants.GUEST_ID)
            _appUser.baseUrl = preferenceHelper?.getAppUrls().first ?? ""
            _appUser.followingList = Gadget.getAlphaIds()
        }
        
        // Try to initialize app entry only once
        do {
            try await initAppEntry()
        } catch {
            print("Error initializing app entry: \(error)")
            // Don't throw here, allow the app to continue with default settings
        }
        
        TweetCacheManager.shared.deleteExpiredTweets()
    }
    
    private func initAppEntry() async throws {
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = Gadget.shared.extractParamMap(from: html)
                appId = paramData["mid"] as? String ?? ""
                guard let addrs = paramData["addrs"] as? String else { continue }
                print("Initializing with addresses: \(addrs)")
                
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    #if DEBUG
                        let firstIp = "218.72.53.166:8002"  // for testing
                    #endif
                    
                    HproseInstance.baseUrl = "http://\(firstIp)"
                    client.uri = HproseInstance.baseUrl + "/webapi/"
                    hproseClient = client.useService(HproseService.self) as AnyObject
                    
                    let providerIp = firstIp
                    if !appUser.isGuest, //let providerIp = try await getProvider(appUser.mid),
                       let user = try await getUser(appUser.mid, baseUrl: "http://\(providerIp)") {
                        // Valid login user is found, use its provider IP as base.
                        HproseInstance.baseUrl = "http://\(providerIp)"
                        client.uri = HproseInstance.baseUrl + "/webapi/"
                        hproseClient = client.useService(HproseService.self) as AnyObject
                        let followings = (try? await getFollows(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                        await MainActor.run {
                            _appUser = user.copy(baseUrl: HproseInstance.baseUrl, followingList: followings)
                        }
                        return
                    } else {
                        let user = User.getInstance(mid: Constants.GUEST_ID)
                        await MainActor.run {
                            user.baseUrl = HproseInstance.baseUrl
                            user.followingList = Gadget.getAlphaIds()
                            _appUser = user
                        }
                        return
                    }
                }
            } catch {
                print("Error processing URL \(url): \(error)")
                continue
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize app entry with any URL"])
    }
    
    func fetchComments(
        _ parentTweet: Tweet,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        try await withRetry {
            let entry = "get_comments"
            let params = [
                "aid": appId,
                "ver": "last",
                "tweetid": parentTweet.mid,
                "appuserid": appUser.mid,
                "pn": pageNumber,
                "ps": pageSize,
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchComments"])
            }
            
            // Process each item in the response array, preserving nil positions
            var tweetsWithAuthors: [Tweet?] = []
            for item in response {
                if let dict = item {
                    do {
                        let comment = try await MainActor.run {
                            return try Tweet.from(dict: dict)
                        }
                        comment.author = try? await getUser(comment.authorId)
                        tweetsWithAuthors.append(comment)
                    } catch {
                        print("Error processing comment: \(error)")
                        tweetsWithAuthors.append(nil)
                    }
                } else {
                    tweetsWithAuthors.append(nil)
                }
            }
            return tweetsWithAuthors
        }
    }
    
    // MARK: - Tweet Operations
    /// Fetches a page of tweets for the user's timeline/feed.
    /// - Parameters:
    ///   - user: The user whose feed to fetch.
    ///   - pageNumber: The page number to fetch (0-based).
    ///   - pageSize: The number of tweets per page.
    ///   - entry: The backend entry point (default: "get_tweet_feed").
    /// - Returns: An array of Tweet objects (non-nil, up to pageSize).
    ///
    /// The backend may return an array containing nils. If the returned array size is less than pageSize, it means there are no more tweets on the backend.
    /// This function accumulates only non-nil tweets and stops fetching when the backend returns fewer than pageSize items.
    func fetchTweetFeed(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweet_feed"
    ) async throws -> [Tweet?] {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            print("[HproseInstance] Fetching tweets from server - pn: \(pageNumber), ps: \(pageSize)")
            let params = [
                "aid": appId,
                "ver": "last",
                "pn": pageNumber,
                "ps": pageSize,
                "userid": !user.isGuest ? user.mid : Gadget.getAlphaIds().first as Any,
                "appuserid": appUser.mid,
            ]
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetcTweetFeed"])
            }
            print("[HproseInstance] Got \(response.count) tweets from server (including nil)")
            
            var tweets: [Tweet?] = []
            for item in response {
                if let tweetDict = item["tweet"] as? [String: Any] {
                    do {
                        let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                        tweet.author = try await getUser(tweet.authorId)
                        // Save tweet back to cache
                        TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
                        tweets.append(tweet)
                    } catch {
                        print("Error processing tweet: \(error)")
                        tweets.append(nil)
                    }
                } else {
                    tweets.append(nil)
                }
            }
            print("[HproseInstance] Returning \(tweets.count) tweets")
            return tweets
        }
    }
    
    /// Fetches a page of tweets for a specific user.
    /// - Parameters:
    ///   - user: The user whose tweets to fetch.
    ///   - startRank: The starting index for pagination.
    ///   - endRank: The ending index for pagination.
    ///   - entry: The backend entry point (default: "get_tweets_by_user").
    /// - Returns: An array of Tweet objects (non-nil, up to requested page size).
    ///
    /// The backend may return an array containing nils. If the returned array size is less than pageSize, it means there are no more tweets on the backend.
    /// This function accumulates only non-nil tweets and stops fetching when the backend returns fewer than pageSize items.
    func fetchUserTweet(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweets_by_user"
    ) async throws -> [Tweet?] {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": user.mid,
                "pn": pageNumber,
                "ps": pageSize,
                "appuserid": appUser.mid,
            ]
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchUserTweet"])
            }
            
            var tweets: [Tweet?] = []
            for item in response {
                if let tweetDict = item["tweet"] as? [String: Any] {
                    do {
                        let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                        tweet.author = try await getUser(tweet.authorId)
                        // Save tweet back to cache
//                        TweetCacheManager.shared.saveTweet(tweet, userId: user.mid)
                        tweets.append(tweet)
                    } catch {
                        print("Error processing tweet: \(error)")
                        tweets.append(nil)
                    }
                } else {
                    // Cache nil tweet using tid
                    tweets.append(nil)
                }
            }
            return tweets
        }
    }
    
    func getTweet(
        tweetId: String,
        authorId: String,
        nodeUrl: String? = nil
    ) async throws -> Tweet? {
        if let cached = await TweetCacheManager.shared.fetchTweet(mid: tweetId) {
            return cached
        }
        return try await refreshTweet(tweetId: tweetId, authorId: authorId)
    }
    
    func refreshTweet(
        tweetId: String,
        authorId: String,
    ) async throws -> Tweet? {
        guard let service = hproseClient else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        let entry = "get_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "tweetid": tweetId,
            "appuserid": appUser.mid
        ]
        if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any] {
            do {
                let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                tweet.author = try? await getUser(authorId)
                TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
                
                if let origId = tweet.originalTweetId, let origAuthorId = tweet.originalAuthorId {
                    if await TweetCacheManager.shared.fetchTweet(mid: origId) == nil {
                        if let origTweet = try? await getTweet(tweetId: origId, authorId: origAuthorId) {
                            TweetCacheManager.shared.saveTweet(origTweet, userId: origAuthorId)
                        }
                    }
                }
                return tweet
            } catch {
                print("Error processing tweet: \(error)")
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tweet not found"])
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
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserId"])
            }
            return response as? String
        }
    }
    
    func getUser(_ userId: String, baseUrl: String = shared.appUser.baseUrl ?? "")
    async throws -> User? {
        // Step 1: Check user cache in Core Data
        if !TweetCacheManager.shared.shouldRefreshUser(mid: userId) {
            return TweetCacheManager.shared.fetchUser(mid: userId)
        }
        
        // Step 2: Fetch from server
        return try await withRetry {
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if baseUrl != appUser.baseUrl {
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "\(baseUrl)/webapi/"
                service = newClient.useService(HproseService.self) as AnyObject
            }
            let entry = "get_user"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": userId,
            ]
            guard let response = service.runMApp(entry, params, nil) else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUser"])
            }
            if let userDict = response as? [String: Any] {
                // a valid User object is returned
                let user = User.from(dict: userDict)
                await MainActor.run { user.baseUrl = baseUrl }
                
                // Save to Core Data cache
                TweetCacheManager.shared.saveUser(user)
                return user
            }
            // the user is not found on this node, a provider IP of the user is returned.
            if let ipAddress = response as? String {
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "http://\(ipAddress)/webapi/"
                let newService = newClient.useService(HproseService.self) as AnyObject
                if let userDict = newService.runMApp(entry, params, nil) as? [String: Any] {
                    let user = User.from(dict: userDict)
                    await MainActor.run { user.baseUrl = "http://\(ipAddress)" }
                    
                    // Save to Core Data cache
                    TweetCacheManager.shared.saveUser(user)
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
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in login"])
            }
            if let status = response["status"] as? String {
                if status == "failure" {
                    if let reason = response["reason"] as? String {
                        return ["reason": reason, "status": "failure"]
                    }
                    return ["reason": "Unknown error occurred", "status": "failure"]
                } else if status == "success" {
                    await MainActor.run {
                        // Update the appUser reference to point to the new user instance
                        preferenceHelper?.setUserId(loginUser.mid)
                    }
                    return ["reason": "Success", "status": "success"]
                }
            }
            return ["reason": "Invalid response status", "status": "failure"]
        }
    }
    
    func logout() {
        preferenceHelper?.setUserId(nil as String?)
    }
    
    /*
     Get the UserId list of followers or followings of given user.
     */
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
            guard let response = service.runMApp(entry.rawValue, params, nil) as? [[String: Any]] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "getFollows: No response"])
            }
            let sorted = response.sorted {
                (lhs, rhs) in
                let lval = (lhs["value"] as? Int) ?? 0
                let rval = (rhs["value"] as? Int) ?? 0
                return lval > rval
            }
            return sorted.compactMap { $0["field"] as? String }
        }
    }
    
    func getUserTweetsByType(
        user: User,
        type: UserContentType,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
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
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserTweetsByType"])
            }
            let validDictionaries = response.compactMap { dict -> [String: Any]? in
                guard let dict = dict else { return nil }
                return dict
            }
            var tweetsWithAuthors: [Tweet] = []
            for item in validDictionaries {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: item) }
                    if (tweet.author == nil) {
                        tweet.author = try? await getUser(tweet.authorId)
                    }
                    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                    tweetsWithAuthors.append(tweet)
                } catch {
                    print("Error processing tweet: \(error)")
                }
            }
            return tweetsWithAuthors
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
            guard let response = service.runMApp(entry, params, nil) as? Bool else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFollowing: No response"])
            }
            return response
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
                "appuserid": appUser.mid,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFavorite: Invalid response"])
            }
            if let userDict = response["user"] as? [String: Any] {
                let user = User.from(dict: userDict)
                await MainActor.run {
                    appUser.favoritesCount = user.favoritesCount
                }
            }
            if let isFavorite = response["isFavorite"] as? Bool,
               let favoriteCount = response["count"] as? Int {
                var favorites = tweet.favorites ?? [false, false, false]
                favorites[UserActions.FAVORITE.rawValue] = isFavorite
                let updatedFavorites = favorites
                return await MainActor.run {
                    return tweet.copy(favorites: updatedFavorites, favoriteCount: favoriteCount)
                }
            }
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFavorite: No favorite info"])
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
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleBookmark: Invalid response"])
            }
            if let userDict = response["user"] as? [String: Any] {
                let user = User.from(dict: userDict)
                await MainActor.run {
                    appUser.bookmarksCount = user.bookmarksCount
                }
            }
            if let hasBookmarked = response["hasBookmarked"] as? Bool,
               let bookmarkCount = response["count"] as? Int {
                var favorites = tweet.favorites ?? [false, false, false]
                favorites[UserActions.BOOKMARK.rawValue] = hasBookmarked
                let updatedFavorites = favorites
                return await MainActor.run {
                    return tweet.copy(favorites: updatedFavorites, bookmarkCount: bookmarkCount)
                }
            }
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleBookmark: No bookmark info"])
        }
    }

    func retweet(_ tweet: Tweet) async throws -> Tweet? {
        try await withRetry {
            if let retweet = try await uploadTweet(
                await MainActor.run {
                    Tweet(
                        mid: Constants.GUEST_ID,
                        authorId: appUser.mid,
                        originalTweetId: tweet.mid,
                        originalAuthorId: tweet.authorId
                    )
                }
            ) {
                return retweet
            }
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "retweet: Upload failed"])
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
    ) async throws {
        try await withRetry {
            let entry = direction ? "retweet_added" : "retweet_removed"
            let params = [
                "aid": appId,
                "ver": "last",
                "appuserid": appUser.mid,
                "retweetid": retweetId,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any] {
                try await MainActor.run { try tweet.update(from: tweetDict) }
            } else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "updateRetweetCount: No response"])
            }
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
                "appuserid": appUser.mid,
                "tweetid": tweetId
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? String else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response"])
            }
            return response
        }
    }
        
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            comment.author = nil
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": tweet.author?.hostIds?.first as Any,
                "comment": String(data: try JSONEncoder().encode(comment), encoding: .utf8) ?? "",
                "tweetid": tweet.mid,
                "appuserid": appUser.mid
            ]
            let entry = "add_comment"
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Invalid response"])
            }
            if let commentId = response["commentId"] as? String,
               let count = response["count"] as? Int {
                await MainActor.run {
                    comment.mid = commentId
                    comment.author = appUser
                    tweet.commentCount = count
                }
                return comment
            }
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: No commentId or count"])
        }
    }

    // both author and tweet author can delete this comment
    // TODO
    func deleteComment(parentTweet: Tweet, commentId: String) async throws -> [String: Any]? {
        try await withRetry {
            let entry = "delete_comment"
            let params = [
                "aid": appId,
                "ver": "last",
                "authorid": appUser.mid,
                "tweetid": parentTweet.mid,
                "hostid": parentTweet.author?.hostIds?.first as Any,
                "commentid": commentId,
                "appuserid": appUser.mid
            ]
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response"])
            }
            return response
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
                
                let tweet = pendingUpload.tweet
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
            // Create a copy of the tweet and remove its author attribute
            tweet.author = nil
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
            
            let uploadedTweet = tweet
            uploadedTweet.mid = newTweetId
            uploadedTweet.author = try? await self.getUser(tweet.authorId)
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
                let tweet = tweet
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
                        // Post notification for new tweet
                        NotificationCenter.default.post(
                            name: .newTweetCreated,
                            object: nil,
                            userInfo: ["tweet": uploadedTweet]
                        )
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
    
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingUpload.ItemData]
    ) {
        Task.detached(priority: .background) {
            do {
                let comment = comment
                var uploadedAttachments: [MimeiFileType] = []
                
                // Post notification that comment upload is starting
                if !itemData.isEmpty {
                    print("Uploading comment with attachments...")
                }
                
                let itemPairs = itemData.chunked(into: 2)
                for (index, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(index + 1): \(error)")
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .backgroundUploadFailed,
                                object: nil,
                                userInfo: ["error": error]
                            )
                        }
                        return
                    }
                }
                
                if itemData.count != uploadedAttachments.count {
                    let error = NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)"])
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error]
                        )
                    }
                    return
                }
                
                comment.attachments = uploadedAttachments
                
                if let newComment = try await self.addComment(comment, to: tweet) {
                    await MainActor.run {
                        // Notify observers about both the updated tweet and new comment
                        NotificationCenter.default.post(
                            name: .newCommentAdded,
                            object: nil,
                            userInfo: ["comment": newComment]
                        )
                    }
                } else {
                    let error = NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment returned nil"])
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error]
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .backgroundUploadFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
            }
        }
    }
    
    /**
     * Return the current tweet list that is pinned to top.
     */
    func togglePinnedTweet(tweetId: String) async throws -> Bool? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            let entry = "toggle_top_tweets"
            let params = [
                "aid": appId,
                "ver": "last",
                "tweetid": tweetId,
                "appuserid": appUser.mid,
            ]
            guard let response = service.runMApp(entry, params, nil) as? Bool else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "togglePinnedTweet: No response"])
            }
            return response
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
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "getPinnedTweets: No response"])
            }
            var result: [[String: Any]] = []
            for dict in response {
                if let tweetDict = dict["tweet"] as? [String: Any] {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                    tweet.author = try? await getUser(tweet.authorId)
                    let timePinned = dict["timestamp"]
                    result.append([
                        "tweet": tweet,
                        "timePinned": timePinned as Any
                    ])
                }
            }
            return result
        }
    }
}
