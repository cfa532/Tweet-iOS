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
    static var baseUrl: URL = URL(string: "http://localhost")!
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
    var preferenceHelper: PreferenceHelper?
    
    private lazy var client: HproseClient = {
        let client = HproseHttpClient()
        client.timeout = 60
        return client
    }()
    var hproseService: AnyObject?
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        self.preferenceHelper = PreferenceHelper()
        
        await MainActor.run {
            _appUser = User.getInstance(mid: preferenceHelper?.getUserId() ?? Constants.GUEST_ID)
            _appUser.baseUrl = preferenceHelper?.getAppUrls().first.flatMap { URL(string: $0) } ?? URL(string: "http://localhost")!
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
//                        let firstIp = "36.24.162.94"  // for testing
                    #endif
                    
                    HproseInstance.baseUrl = URL(string: "http://\(firstIp)")!
                    client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                    hproseService = client.useService(HproseService.self) as AnyObject
                    
//                    let providerIp = firstIp
                    if !appUser.isGuest, let providerIp = try await getProviderIP(appUser.mid),
                       let user = try await fetchUser(appUser.mid, baseUrl: "http://\(providerIp)") {
                        // Valid login user is found, use its provider IP as base.
                        HproseInstance.baseUrl = URL(string: "http://\(providerIp)")!
                        client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                        hproseService = client.useService(HproseService.self) as AnyObject
                        let followings = (try? await getFollows(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                        await MainActor.run {
                            _appUser.baseUrl = HproseInstance.baseUrl
                            _appUser.followingList = followings
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
        let entry = "get_comments"
        let params = [
            "aid": appId,
            "ver": "last",
            "tweetid": parentTweet.mid,
            "appuserid": appUser.mid,
            "pn": pageNumber,
            "ps": pageSize,
        ] as [String : Any]
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in fetchComments"])
        }
        
        // Process each item in the response array, preserving nil positions
        var commentsWithAuthors: [Tweet?] = []
        for item in response {
            if let dict = item {
                do {
                    let comment = try await MainActor.run {
                        return try Tweet.from(dict: dict)
                    }
                    comment.author = try? await fetchUser(comment.authorId)
                    commentsWithAuthors.append(comment)
                } catch {
                    print("Error processing comment: \(error)")
                    commentsWithAuthors.append(nil)
                }
            } else {
                commentsWithAuthors.append(nil)
            }
        }
        return commentsWithAuthors
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
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        print("[fetchTweetFeed] Fetching tweets from server - pn: \(pageNumber), ps: \(pageSize)")
        let params = [
            "aid": appId,
            "ver": "last",
            "pn": pageNumber,
            "ps": pageSize,
            "userid": !user.isGuest ? user.mid : Gadget.getAlphaIds().first as Any,
            "appuserid": appUser.mid,
        ]
        guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in fetcTweetFeed"])
        }
        print("[fetchTweetFeed] Got \(response.count) tweets from server (including nil)")
        
        var tweets: [Tweet?] = []
        for item in response {
            if let tweetDict = item {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                    tweet.author = try await fetchUser(tweet.authorId)
                    // Skip private tweets in feed
                    if tweet.isPrivate == true {
                        tweets.append(nil)
                        continue
                    }
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
        print("[fetchTweetFeed] Returning \(tweets.count) tweets")
        return tweets
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
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUser.mid,
        ] as [String : Any]
        guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in fetchUserTweet"])
        }
        
        var tweets: [Tweet?] = []
        for item in response {
            if let tweetDict = item{
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                    tweet.author = try await fetchUser(tweet.authorId)
                    // Only show private tweets if the current user is the author
//                    if tweet.isPrivate == true && tweet.authorId != appUser.mid {
//                        tweets.append(nil)
//                        continue
//                    }
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
        let validTweets = tweets.compactMap{ $0 }
        print("[fetchUserTweet] Returning \(tweets.count) tweets, valid=\(validTweets.count) for \(user.mid) \(pageNumber) \(pageSize)")
        return tweets
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
        guard let service = hproseService else {
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
                tweet.author = try? await fetchUser(authorId)
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
            guard let service = hproseService else {
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
    
    /// If @baseUrl is an empty string, the function will ignore the cache and try to find a provider's IP for this user
    /// and update cache with the new user.
    /// If @baseUrl is omitted, an user object will be retrieved from cache or the default serving node of appUser.
    /// Otherwise, user object will be retrieved from the node of the given baseUrl.
    ///
    /// Do not really need to return the user, for user instance with the same mid has been updated or created.
    func fetchUser(
        _ userId: String,
        baseUrl: String = shared.appUser.baseUrl?.absoluteString ?? ""
    ) async throws -> User? {
        // Step 1: Check user cache in Core Data.
        if !TweetCacheManager.shared.shouldRefreshUser(mid: userId), baseUrl == appUser.baseUrl?.absoluteString {
            // get cached user instance, whose baseUrl might not be the same as appUser's.
            return TweetCacheManager.shared.fetchUser(mid: userId)
        }
        
        // Step 2: Fetch from server. No instance available in memory or cache.
        let user = User.getInstance(mid: userId)
        if baseUrl.isEmpty {
            guard let providerIP = try await getProviderIP(userId) else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Provide not found"])
            }
            await MainActor.run {
                user.baseUrl = URL(string: "http://\(providerIP)")!
            }
            try await updateUserFromServer(user)
            return user
        } else {
            await MainActor.run {
                user.baseUrl = URL(string: baseUrl)!
            }
            try await updateUserFromServer(user)
            return user
        }
    }
    
    func updateUserFromServer(_ user: User) async throws {
        let entry = "get_user"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
        ]
        if let service = user.hproseService, let response = service.runMApp(entry, params, nil) {
            if let userDict = response as? [String: Any]
            {
                // user instance of the given mid is updated.
                _ = try User.from(dict: userDict)
                TweetCacheManager.shared.saveUser(user)
            } else if let ipAddress = response as? String {
                // the user is not found on this node, a provider IP of the user is returned.
                // point server to this new IP.
                await MainActor.run {
                    user.baseUrl = URL(string: "http://\(ipAddress)")!
                }
                if let newService = user.hproseService, let userDict = newService.runMApp(entry, params, nil) as? [String: Any] {
                    _ = try User.from(dict: userDict)
                    TweetCacheManager.shared.saveUser(user)
                }
            }
        }
    }
    
    func login(_ loginUser: User) async throws -> [String: Any] {
        let entry = "login"
        let params = [
            "aid": appId,
            "ver": "last",
            "username": loginUser.username!,
            "password": loginUser.password!
        ]
        let newClient = HproseHttpClient()
        newClient.timeout = 60
        newClient.uri = "\(loginUser.baseUrl!.absoluteString)/webapi/"
        let newService = newClient.useService(HproseService.self) as AnyObject
        guard let response = newService.runMApp(entry, params, nil) as? [String: Any] else {
            newClient.close()
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in login"])
        }
        newClient.close()
        
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
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
        ]
        guard var service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        var newClient: HproseClient? = nil
        if user.baseUrl != appUser.baseUrl {
            let client = HproseHttpClient()
            client.timeout = 60
            client.uri = "\(user.baseUrl!.absoluteString)/webapi/"
            service = client.useService(HproseService.self) as AnyObject
            newClient = client
        }

        guard let response = service.runMApp(entry.rawValue, params, nil) as? [[String: Any]] else {
            newClient?.close()
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "getFollows: No response"])
        }
        newClient?.close()
        
        let sorted = response.sorted {
            (lhs, rhs) in
            let lval = (lhs["value"] as? Int) ?? 0
            let rval = (rhs["value"] as? Int) ?? 0
            return lval > rval
        }
        return sorted.compactMap { $0["field"] as? String }
    }
    
    func getUserTweetsByType(
        user: User,
        type: UserContentType,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        let entry = "get_user_meta"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "type": type.rawValue,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUser.mid
        ] as [String : Any]
        guard var service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        var newClient: HproseClient? = nil
        if user.baseUrl != appUser.baseUrl {
            let client = HproseHttpClient()
            client.timeout = 60
            client.uri = "\(user.baseUrl!.absoluteString)/webapi/"
            service = client.useService(HproseService.self) as AnyObject
            newClient = client
        }
        
        guard let response = service.runMApp(entry, params, nil) as? [[String: Any]?] else {
            newClient?.close()
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserTweetsByType"])
        }
        newClient?.close()
        
        var tweetsWithAuthors: [Tweet?] = []
        for dict in response {
            if let item = dict {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: item) }
                    if (tweet.author == nil) {
                        tweet.author = try? await fetchUser(tweet.authorId)
                    }
                    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                    tweetsWithAuthors.append(tweet)
                } catch {
                    print("Error processing tweet: \(error)")
                    tweetsWithAuthors.append(nil)
                }
            } else {
                tweetsWithAuthors.append(nil)
            }
        }
        return tweetsWithAuthors
    }
    
    /**
     * Called when appUser clicks the Follow button.
     * @param followedId is the user that appUser is following or unfollowing.
     * */
    func toggleFollowing(
        userId: String,
        followingId: String
    )  async throws -> Bool? {
        try await withRetry {
            let entry = "toggle_following"
            let params = [
                "aid": appId,
                "ver": "last",
                "followingid": followingId,
                "userid": userId,
            ]
            guard let service = hproseService else {
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
            guard let service = hproseService else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFavorite: Invalid response"])
            }
            if let userDict = response["user"] as? [String: Any] {
                let _ = try User.from(dict: userDict)
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
            guard let service = hproseService else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleBookmark: Invalid response"])
            }
            if let userDict = response["user"] as? [String: Any] {
                let _ = try User.from(dict: userDict)
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
        let entry = direction ? "retweet_added" : "retweet_removed"
        let params = [
            "aid": appId,
            "ver": "last",
            "appuserid": appUser.mid,
            "retweetid": retweetId,
            "tweetid": tweet.mid,
            "authorid": tweet.authorId,
        ]
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        if let tweetDict = service.runMApp(entry, params, nil) as? [String: Any] {
            try await MainActor.run { try tweet.update(from: tweetDict) }
        } else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "updateRetweetCount: No response"])
        }
    }
    
    /**
     * Delete a tweet and returned the deleted tweetId
     * */
    func deleteTweet(_ tweetId: String) async throws -> String? {
        let entry = "delete_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "appuserid": appUser.mid,
            "tweetid": tweetId
        ]
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        guard let response = service.runMApp(entry, params, nil) as? String else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response"])
        }
        return response
    }
        
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        await appUser.resolveWritableUrl()
        guard let uploadService = appUser.uploadService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload service not available"])
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
        guard let response = uploadService.runMApp(entry, params, nil) as? [String: Any] else {
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

    // both author and tweet author can delete this comment
    // TODO
    func deleteComment(parentTweet: Tweet, commentId: String) async throws -> [String: Any]? {
        let entry = "delete_comment"
        let params = [
            "aid": appId,
            "ver": "last",
            "tweetid": parentTweet.mid,
            "hostid": parentTweet.author?.hostIds?.first as Any,
            "commentid": commentId,
            "appuserid": appUser.mid
        ]
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response"])
        }
        return response
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil
    ) async throws -> MimeiFileType? {
        await appUser.resolveWritableUrl()
        print("Starting upload to IPFS: typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil")")
        
        // Determine media type first
        let mediaType: MediaType
        if typeIdentifier.hasPrefix("public.image") {
            mediaType = .image
        } else if typeIdentifier.hasPrefix("public.movie") || typeIdentifier.contains("quicktime-movie") || typeIdentifier.contains("movie") {
            mediaType = .video
        } else if typeIdentifier.hasPrefix("public.audio") || typeIdentifier.contains("audio") {
            mediaType = .audio
        } else if typeIdentifier == "public.composite-content" {
            mediaType = .pdf
        } else if typeIdentifier == "public.zip-archive" {
            mediaType = .zip
        } else {
            // Try to determine type from file extension
            let fileExtension = typeIdentifier.components(separatedBy: ".").last?.lowercased()
            switch fileExtension {
            case "jpg", "jpeg", "png", "gif", "heic", "heif":
                mediaType = .image
            case "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf":
                mediaType = .video
            case "mp3", "m4a", "wav", "flac", "aac":
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
        
        print("DEBUG: Detected media type: \(mediaType.rawValue)")
        
        // Handle video conversion to HLS if it's a video
        if mediaType == .video {
            print("Processing video with HLS transcoding")
            return try await uploadVideoAsHLS(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId
            )
        } else {
            print("Processing non-video file with regular upload")
            // Handle non-video files with original logic
            return try await uploadRegularFile(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId,
                mediaType: mediaType
            )
        }
    }
    
    private func uploadVideoAsHLS(
        data: Data,
        typeIdentifier: String,
        fileName: String?,
        referenceId: String?
    ) async throws -> MimeiFileType? {
        print("Starting HLS conversion, data size: \(data.count) bytes")
        
        // Create temporary directory for video processing
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Save original video to temp directory
        let originalVideoPath = tempDir.appendingPathComponent("original_video.mp4")
        try data.write(to: originalVideoPath)
        
        // Check if the video format is supported
        let hlsProcessor = HLSVideoProcessor.shared
        
        // First check file extension support
        if let fileName = fileName, !hlsProcessor.isSupportedVideoFormat(fileName) {
            print("Warning: File extension not in supported list: \(fileName)")
        }
        
        // Then check if AVFoundation can actually handle the format
        let canHandle = await hlsProcessor.canHandleVideoFormat(url: originalVideoPath)
        
        if !canHandle {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video format not supported by AVFoundation"])
        }
        
        // Get input video aspect ratio to determine orientation
        let aspectRatio = try await getVideoAspectRatio(url: originalVideoPath)
        print("DEBUG: Detected input video aspect ratio: \(aspectRatio ?? 0)")
        
        // Set target resolution based on input aspect ratio
        let targetResolution: CGSize
        if let ratio = aspectRatio {
            print("DEBUG: Aspect ratio is: \(ratio)")
            if ratio < 1.0 {
                // Portrait video: aspect ratio < 1.0 (width < height)
                targetResolution = CGSize(width: 270, height: 480)
                print("DEBUG: Aspect ratio < 1.0, detected as PORTRAIT")
                print("Input video is portrait (aspect ratio: \(ratio)), using portrait output: 270x480")
            } else {
                // Landscape video: aspect ratio >= 1.0 (width >= height)
                targetResolution = CGSize(width: 480, height: 270)
                print("DEBUG: Aspect ratio >= 1.0, detected as LANDSCAPE")
                print("Input video is landscape (aspect ratio: \(ratio)), using landscape output: 480x270")
            }
        } else {
            // Fallback to landscape if aspect ratio detection fails
            targetResolution = CGSize(width: 480, height: 270)
            print("DEBUG: Aspect ratio detection failed, using fallback LANDSCAPE")
            print("Input video aspect ratio detection failed, using landscape output: 480x270")
        }
        
        // Configure HLS configuration for medium quality transcoding
        let hlsConfig = HLSVideoProcessor.HLSConfig(
            segmentDuration: 6.0,
            targetResolution: targetResolution,
            keyframeInterval: 2.0,
            qualityLevels: [] // Not used by FFmpeg wrapper - transcoding is handled in C code
        )
        
        let hlsOutputDir = tempDir.appendingPathComponent("hls_output")
        
        do {
            // Convert video to medium quality HLS format with proper transcoding
            _ = try await hlsProcessor.convertToAdaptiveHLS(
                inputURL: originalVideoPath,
                outputDirectory: hlsOutputDir,
                config: hlsConfig
            )
            
            // Create a simple archive of HLS files
            let archivePath = tempDir.appendingPathComponent("hls_package.tar")
            let archiveSuccess = await createSimpleArchive(from: hlsOutputDir.path, to: archivePath.path)
            
            guard archiveSuccess else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create archive package"])
            }
            
            // Read archive data
            let archiveData = try Data(contentsOf: archivePath)
            
            // Upload archive package to extract-tar endpoint
            
            // Create HLS archive filename by replacing any video extension with _hls.tar
            let hlsArchiveFileName: String
            if let originalFileName = fileName {
                // Handle various video extensions
                let videoExtensions = [".mp4", ".mov", ".m4v", ".avi", ".mkv", ".flv", ".wmv", ".webm", ".3gp"]
                var newFileName = originalFileName
                for ext in videoExtensions {
                    if originalFileName.lowercased().hasSuffix(ext) {
                        newFileName = String(originalFileName.dropLast(ext.count)) + "_hls.tar"
                        break
                    }
                }
                hlsArchiveFileName = newFileName
            } else {
                hlsArchiveFileName = "hls_package.tar"
            }
            
            var uploadedFile = try await uploadHLSArchive(
                data: archiveData,
                fileName: hlsArchiveFileName,
                referenceId: referenceId,
                originalVideoURL: originalVideoPath
            )
            uploadedFile.fileName = fileName
            return uploadedFile
            
        } catch {
            print("Error converting video to HLS: \(error)")
            
            // Throw error indicating video processing failure
            throw NSError(
                domain: "HproseService", 
                code: -1, 
                userInfo: [
                    NSLocalizedDescriptionKey: "Video processing failed: \(error.localizedDescription). Tweet upload will be cancelled."
                ]
            )
        }
    }
    
    private func createSimpleArchive(from sourceDir: String, to archivePath: String) async -> Bool {
        // Create a proper tar file for iOS compatibility
        do {
            let fileManager = FileManager.default
            let sourceURL = URL(fileURLWithPath: sourceDir)
            let archiveURL = URL(fileURLWithPath: archivePath)
            
            // Get all files in the source directory recursively
            let enumerator = fileManager.enumerator(at: sourceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            var files: [URL] = []
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    files.append(fileURL)
                }
            }
            
            // Create tar file data
            var tarData = Data()
            
            for fileURL in files {
                // Get relative path from source directory
                let relativePath: String
                if fileURL.path.hasPrefix(sourceDir) {
                    let sourceDirLength = sourceDir.count
                    
                    if sourceDirLength < fileURL.path.count {
                        let startIndex = fileURL.path.index(fileURL.path.startIndex, offsetBy: sourceDirLength)
                        let remainingPath = String(fileURL.path[startIndex...])
                        relativePath = remainingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    } else {
                        relativePath = fileURL.lastPathComponent
                    }
                } else {
                    relativePath = fileURL.lastPathComponent
                }
                
                let fileName = relativePath.isEmpty ? fileURL.lastPathComponent : relativePath
                
                // Ensure filename fits in tar header (100 bytes max)
                let maxFileNameLength = 100
                let finalFileName: String
                if fileName.count > maxFileNameLength {
                    // Truncate filename if too long
                    let truncated = String(fileName.prefix(maxFileNameLength - 4)) + ".ts"
                    finalFileName = truncated
                } else {
                    finalFileName = fileName
                }
                
                let fileData = try Data(contentsOf: fileURL)
                
                // Create tar header (512 bytes)
                var header = Data(count: 512)
                var offset = 0
                
                // Helper function to safely write string data to header
                func writeStringToHeader(_ string: String, maxLength: Int) {
                    let stringData = string.data(using: .ascii) ?? Data()
                    let writeLength = min(stringData.count, maxLength)
                    if writeLength > 0 && offset + writeLength <= header.count {
                        header.replaceSubrange(offset..<(offset + writeLength), with: stringData)
                    }
                    offset += maxLength
                }
                
                // File name (100 bytes)
                writeStringToHeader(finalFileName, maxLength: 100)
                
                // File mode (8 bytes) - 0644 for regular files
                writeStringToHeader("0000644", maxLength: 8)
                
                // Owner ID (8 bytes)
                writeStringToHeader("0000000", maxLength: 8)
                
                // Group ID (8 bytes)
                writeStringToHeader("0000000", maxLength: 8)
                
                // File size (12 bytes) - octal format
                let sizeOctal = String(format: "%011o", fileData.count)
                writeStringToHeader(sizeOctal, maxLength: 12)
                
                // Modification time (12 bytes) - current time in octal
                let timeOctal = String(format: "%011o", Int(Date().timeIntervalSince1970))
                writeStringToHeader(timeOctal, maxLength: 12)
                
                // Checksum placeholder (8 bytes) - filled with spaces initially
                writeStringToHeader("        ", maxLength: 8)
                
                // Type flag (1 byte) - '0' for regular file
                if offset < header.count {
                    header[offset] = UInt8("0".utf8.first!)
                }
                offset += 1
                
                // Link name (100 bytes) - empty for regular files
                offset += 100
                
                // Magic (6 bytes) - "ustar"
                writeStringToHeader("ustar ", maxLength: 6)
                
                // Version (2 bytes) - "00"
                writeStringToHeader("00", maxLength: 2)
                
                // User name (32 bytes)
                writeStringToHeader("root", maxLength: 32)
                
                // Group name (32 bytes)
                writeStringToHeader("root", maxLength: 32)
                
                // Device major (8 bytes)
                offset += 8
                
                // Device minor (8 bytes)
                offset += 8
                
                // Prefix (155 bytes) - empty for files in current directory
                offset += 155
                
                // Calculate checksum (sum of all bytes in header, treating them as unsigned)
                var checksum: UInt32 = 0
                for i in 0..<512 {
                    if i >= 148 && i < 156 { // Skip checksum field itself
                        checksum += UInt32(" ".utf8.first!)
                    } else {
                        checksum += UInt32(header[i])
                    }
                }
                
                // Write checksum (6 bytes, octal format)
                let checksumOctal = String(format: "%06o", checksum)
                let checksumData = checksumOctal.data(using: .ascii) ?? Data()
                let checksumLength = min(checksumData.count, 6)
                if checksumLength > 0 && 148 + checksumLength <= header.count {
                    header.replaceSubrange(148..<(148 + checksumLength), with: checksumData)
                }
                if 154 < header.count {
                    header[154] = UInt8(" ".utf8.first!)
                }
                if 155 < header.count {
                    header[155] = UInt8(" ".utf8.first!)
                }
                
                // Add header to tar data
                tarData.append(header)
                
                // Add file data, padded to 512-byte boundary
                tarData.append(fileData)
                let padding = (512 - (fileData.count % 512)) % 512
                if padding > 0 {
                    tarData.append(Data(count: padding))
                }
            }
            
            // Add two empty blocks at the end (tar convention)
            tarData.append(Data(count: 1024))
            
            // Write the tar file
            try tarData.write(to: archiveURL)
            return true
            
        } catch {
            print("Error creating tar archive: \(error)")
            return false
        }
    }
    
    private func uploadRegularFile(
        data: Data,
        typeIdentifier: String,
        fileName: String?,
        referenceId: String?,
        mediaType: MediaType
    ) async throws -> MimeiFileType {
        print("Uploading regular file: type=\(mediaType.rawValue), size=\(data.count) bytes")
        
        // Use a mutable variable for uploadService
        var uploadService = appUser.uploadService
        if uploadService == nil {
            await appUser.resolveWritableUrl()
            uploadService = appUser.uploadService
            if uploadService == nil {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload service not available"])
            }
        }
        let uploadServiceUnwrapped = uploadService!
        
        // Handle non-video files with original logic
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
            
            var chunkCount = 0
            while true {
                let data = fileHandle.readData(ofLength: chunkSize)
                if data.isEmpty { break }
                
                chunkCount += 1
                
                // Add retry logic for chunk upload
                let nsData = data as NSData
                let response = try await uploadChunkWithRetry(
                    uploadService: uploadServiceUnwrapped,
                    request: request,
                    data: nsData,
                    chunkNumber: chunkCount
                )
                
                if let fsid = response as? String {
                    offset += Int64(data.count)
                    request["offset"] = offset
                    request["fsid"] = fsid
                } else {
                    throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload chunk \(chunkCount)"])
                }
            }
            
            // Mark upload as finished
            request["finished"] = "true"
            if let referenceId = referenceId {
                request["referenceid"] = referenceId
            }
            
            let finalResponse = uploadServiceUnwrapped.runMApp("upload_ipfs", request, nil)
            
            guard let cid = finalResponse as? String else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CID from final upload response"])
            }
            
            // Get file attributes
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
            
            // Get aspect ratio for videos (only for original videos, not HLS packages)
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
    
    private func uploadChunkWithRetry(
        uploadService: AnyObject,
        request: [String: Any],
        data: NSData,
        chunkNumber: Int,
        maxRetries: Int = 3
    ) async throws -> Any {
        for _ in 1...maxRetries {
            let response = uploadService.runMApp("upload_ipfs", request, [data]) as Any
            return response
        }
        
        // All retries failed
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload chunk after \(maxRetries) attempts"])
    }
    
    private func getVideoAspectRatio(url: URL) async throws -> Float? {
        return try await HLSVideoProcessor.shared.getVideoAspectRatio(url: url)
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
    
    private func getProviderIP(_ mid: String) async throws -> String? {
        let params = [
            "aid": appId,
            "ver": "last",
            "mid": mid
        ]
        if let response = hproseService?.runMApp("get_provider", params, []) {
            return response as? String
        }
        return nil
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
                TweetCacheManager.shared.clearAllUsers()
                return try await block()
            } catch {
                retryCount += 1
                try await initAppEntry()
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error: All retries failed."])
    }
    
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
    
    // MARK: - Background Tasks
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
                    task.setTaskCompleted(success: false)
                    return
                }
                
                // Clean up the temporary file immediately after reading
                try? FileManager.default.removeItem(at: tempFileURL)
                
                let tweet = pendingUpload.tweet
                var uploadedAttachments: [MimeiFileType] = []
                
                // Process items in pairs
                let itemPairs = pendingUpload.selectedItemData.chunked(into: 2)
                
                for (pairIndex, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await shared.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(pairIndex + 1): \(error)")
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
                
                if pendingUpload.selectedItemData.count != uploadedAttachments.count {
                    task.setTaskCompleted(success: false)
                    return
                }
                
                // Update tweet with uploaded attachments
                tweet.attachments = uploadedAttachments
                
                // Upload the tweet
                if try await shared.uploadTweet(tweet) != nil {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            } catch {
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
        } catch {
            print("Could not schedule next background task: \(error)")
        }
    }
    
    func uploadTweet(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            guard let service = hproseService else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            // Create a copy of the tweet and remove its author attribute
            tweet.author = nil
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": appUser.hostIds?.first as Any,
                "tweet": String(data: try JSONEncoder().encode(tweet), encoding: .utf8) ?? ""
            ]
            
            let rawResponse = service.runMApp("add_tweet", params, nil)
            guard let newTweetId = rawResponse as? String else {
                return Tweet?.none
            }
            
            let uploadedTweet = tweet
            uploadedTweet.mid = newTweetId
            uploadedTweet.author = try? await self.fetchUser(tweet.authorId)
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
                
                for (pairIndex, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(pairIndex + 1): \(error)")
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
                
                tweet.attachments = uploadedAttachments
                
                if let uploadedTweet = try await self.uploadTweet(tweet) {
                    await MainActor.run {
                        // Post notification for new tweet
                        NotificationCenter.default.post(
                            name: .newTweetCreated,
                            object: nil,
                            userInfo: ["tweet": uploadedTweet]
                        )
                    }
                } else {
                    let error = NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload tweet"])
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error]
                        )
                    }
                }
            } catch {
                print("Error in background upload: \(error)")
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
    
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingUpload.ItemData]
    ) {
        Task.detached(priority: .background) {
            do {
                let comment = comment
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                for (pairIndex, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(pairIndex + 1): \(error)")
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
        guard let service = hproseService else {
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

    /**
     * Return a list of {tweetId, timestamp} for each pinned Tweet. The timestamp is when
     * the tweet is pinned.
     */
    func getPinnedTweets(user: User) async throws -> [[String: Any]] {
        guard let service = hproseService else {
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
                tweet.author = try? await fetchUser(tweet.authorId)
                let timePinned = dict["timestamp"]
                result.append([
                    "tweet": tweet,
                    "timePinned": timePinned as Any
                ])
            }
        }
        return result
    }
    
    func registerUser(
        username: String,
        password: String,
        alias: String?,
        profile: String,
        hostId: String? = nil,
        cloudDrivePort: Int? = nil
    ) async throws -> Bool {
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        var hosts: [String]? = nil
        if let hostId = hostId, !hostId.isEmpty {
            hosts = [hostId]
        }
        let newUser = User(mid: appUser.mid, name: alias, username: username, password: password,
                           profile: profile, cloudDrivePort: cloudDrivePort, hostIds: hosts)
        let entry = "register"
        let params = [
            "aid": appId,
            "ver": "last",
            "user": String(data: try JSONEncoder().encode(newUser), encoding: .utf8) ?? "",
            "followings": String(data: try JSONEncoder().encode(Gadget.getAlphaIds()), encoding: .utf8) ?? ""
        ]
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Registration failure."])
        }
        if let result = response["status"] as? String {
            if result == "success" {
                return true
            } else {
                throw NSError(domain: "hproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: response["reason"] as? String ?? "Unknown registration error."])
            }
        }
        return false
    }
    
    func updateUserCore(
        password: String? = nil,
        alias: String? = nil,
        profile: String? = nil,
        hostId: String? = nil,
        cloudDrivePort: Int? = nil
    ) async throws -> Bool {
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        let updatedUser = User(mid: appUser.mid, name: alias, password: password, profile: profile, cloudDrivePort: cloudDrivePort)
        if let hostId = hostId, !hostId.isEmpty {
            updatedUser.hostIds = [hostId]
        }

        let entry = "set_author_core_data"
        let params = [
            "aid": appId,
            "ver": "last",
            "user": String(data: try JSONEncoder().encode(updatedUser), encoding: .utf8) ?? ""
        ]
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Registration failure."])
        }
        if let result = response["status"] as? String {
            if result == "success" {
                return true
            } else {
                throw NSError(domain: "hproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: response["reason"] as? String ?? "Unknown registration error."])
            }
        }
        return false
    }

    // MARK: - User Avatar
    /// Sets the user's avatar on the server
    func setUserAvatar(user: User, avatar: String) async throws {
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        let entry = "set_user_avatar"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "avatar": avatar
        ]
        _ = service.runMApp(entry, params, nil)
    }

    /// Find IP addresses of given nodeId
    func getHostIP(_ nodeId: String) async -> String? {
        // Check if we have a valid baseUrl
        guard let baseUrl = appUser.baseUrl else {
            return nil
        }
        
        let urlString = "\(baseUrl.absoluteString)/getvar?name=ips&arg0=\(nodeId)"
        guard let url = URL(string: urlString) else { 
            return nil 
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ,\n\r")) ?? ""
                    
                    let ips = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    
                    if !ips.isEmpty {
                        // Find the first available public IP
                        for ip in ips {
                            // Extract clean IP and port
                            let (cleanIP, port): (String, String)
                            
                            if ip.hasPrefix("[") && ip.contains("]:") {
                                // IPv6 with port, e.g. [240e:391:edf:ad90:b25a:daff:fe87:21d4]:8002
                                if let endBracket = ip.firstIndex(of: "]"),
                                   let colon = ip[endBracket...].firstIndex(of: ":") {
                                    let ipv6 = String(ip[ip.index(after: ip.startIndex)..<endBracket])
                                    port = String(ip[ip.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                                    cleanIP = ipv6
                                } else {
                                    continue
                                }
                            } else if ip.contains(":") && !ip.contains("]:") && !ip.contains("[") {
                                // IPv4 with port, e.g. 60.163.239.184:8002
                                let parts = ip.split(separator: ":", maxSplits: 1)
                                if parts.count == 2 {
                                    cleanIP = String(parts[0])
                                    port = String(parts[1])
                                } else {
                                    continue
                                }
                            } else {
                                // No port specified, use default port 8010
                                cleanIP = ip.hasPrefix("[") && ip.hasSuffix("]") ? 
                                    String(ip.dropFirst().dropLast()) : ip
                                port = "8010"
                            }
                            
                            // Check if this is a valid public IP with correct port
                            if Gadget.isValidPublicIpAddress(cleanIP) {
                                if let portNumber = Int(port), (8000...9000).contains(portNumber) {
                                    return ip
                                }
                            }
                        }
                        
                        // If no public IPs found, return the first IP as fallback
                        return ips.first!
                    }
                }
            }
        } catch {
            print("Network error getting host IP: \(error)")
        }
        
        return nil
    }
    
    private func uploadHLSArchive(
        data: Data,
        fileName: String?,
        referenceId: String?,
        originalVideoURL: URL? = nil
    ) async throws -> MimeiFileType {
        // Get the user's cloudDrivePort with fallback to default
        let cloudDrivePort = appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
        
        // Ensure writableUrl is available
        if appUser.writableUrl == nil {
            await appUser.resolveWritableUrl()
        }
        
        // Use writableUrl to construct the extract-tar endpoint URL
        guard let writableUrl = appUser.writableUrl else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available after resolution"])
        }
        
        let extractTarURL = "\(writableUrl.scheme ?? "http")://\(writableUrl.host ?? writableUrl.absoluteString):\(cloudDrivePort)/extract-tar"
        guard let url = URL(string: extractTarURL) else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid extract-tar URL"])
        }
        
        // Create multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Build multipart form data
        var body = Data()
        
        // Add filename if provided (use original video filename, not archive filename)
        if let fileName = fileName {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"filename\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(fileName)\r\n".data(using: .utf8)!)
        }
        
        // Add reference ID if provided
        if let referenceId = referenceId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"referenceId\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(referenceId)\r\n".data(using: .utf8)!)
        }
        
        // Add the tar file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"tarFile\"; filename=\"\(fileName ?? "hls_package.tar")\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-tar\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        // Get aspect ratio from original video if available
        var aspectRatio: Float?
        if let originalVideoURL = originalVideoURL {
            aspectRatio = try await getVideoAspectRatio(url: originalVideoURL)
        }
        
        // Upload with retry mechanism
        var lastError: Error?
        
        for attempt in 1...3 {
            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        // Parse the JSON response to get the CID
                        if let responseString = String(data: responseData, encoding: .utf8) {
                            do {
                                if let jsonData = responseString.data(using: .utf8),
                                   let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    
                                    if let success = json["success"] as? Bool, success {
                                        if let cid = json["cid"] as? String, !cid.isEmpty {
                                            // Create MimeiFileType with the CID
                                            return MimeiFileType(
                                                mid: cid,
                                                type: "hls_video", // Set as hls_video type for HLS content
                                                size: Int64(data.count),
                                                fileName: fileName,
                                                timestamp: Date(),
                                                aspectRatio: aspectRatio,
                                                url: nil
                                            )
                                        } else {
                                            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No CID in response"])
                                        }
                                    } else {
                                        let message = json["message"] as? String ?? "Unknown error"
                                        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server error: \(message)"])
                                    }
                                } else {
                                    throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
                                }
                            } catch {
                                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response: \(error.localizedDescription)"])
                            }
                        }
                        
                        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from extract-tar endpoint"])
                    } else {
                        throw NSError(domain: "HproseService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) error"])
                    }
                } else {
                    throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
                }
            } catch {
                lastError = error
                print("HLS archive upload attempt \(attempt) failed: \(error)")
                
                if attempt < 3 {
                    // Wait before retrying (exponential backoff)
                    let delay = TimeInterval(attempt * 2) // 2, 4 seconds
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    
                    // Re-resolve writable URL in case it changed
                    await appUser.resolveWritableUrl()
                }
            }
        }
        
        // All retries failed
        throw lastError ?? NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload HLS archive after 3 attempts"])
    }
}
