import Foundation
import hprose
import PhotosUI
import AVFoundation

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
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
        client.timeout = 300  // Increased from 60 to 300 seconds for large uploads
        client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
        return client
    }()
    var hproseService: AnyObject?
    
    // MARK: - Helper Methods
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        self.preferenceHelper = PreferenceHelper()
        
        // Clear cached users during initialization
        TweetCacheManager.shared.clearAllUsers()
        
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
        
        // Recover any pending uploads
        await recoverPendingUploads()
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
                            // Update the appUser to the fetched user with all properties
                            user.baseUrl = HproseInstance.baseUrl
                            user.followingList = followings
                            self.appUser = user
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
    func fetchTweetFeed(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweet_feed"
    ) async throws -> [Tweet?] {
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "pn": pageNumber,
            "ps": pageSize,
            "userid": !user.isGuest ? user.mid : Gadget.getAlphaIds().first as Any,
            "appuserid": appUser.mid,
        ]
        
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchTweetFeed"])
        }
        
        // Check success status first
        guard let success = response["success"] as? Bool, success else {
            let errorMessage = response["message"] as? String ?? "Unknown error occurred"
            print("[fetchTweetFeed] Tweet feed loading failed: \(errorMessage)")
            print("[fetchTweetFeed] Response: \(response)")
            
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        print("[fetchTweetFeed] Got \(tweetsData.count) tweets and \(originalTweetsData.count) original tweets from server")
        
        // Cache original tweets first
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                    originalTweet.author = try? await fetchUser(originalTweet.authorId)
                    TweetCacheManager.shared.saveTweet(originalTweet, userId: appUser.mid)
                    print("[fetchTweetFeed] Cached original tweet: \(originalTweet.mid)")
                } catch {
                    print("[fetchTweetFeed] Error caching original tweet: \(error)")
                }
            }
        }
        
        // Process main tweets
        var tweets: [Tweet?] = []
        for item in tweetsData {
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
                    print("[fetchTweetFeed] Error processing tweet: \(error)")
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
        guard let service = user.hproseService else {
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
        
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchUserTweet"])
        }
        
        // Check success status first
        guard let success = response["success"] as? Bool, success else {
            let errorMessage = response["message"] as? String ?? "Unknown error occurred"
            print("[fetchUserTweet] Tweets loading failed for user \(user.mid): \(errorMessage)")
            print("[fetchUserTweet] Response: \(response)")
            
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        print("[fetchUserTweet] Fetching tweets for user: \(user.mid), page: \(pageNumber), size: \(pageSize)")
        print("[fetchUserTweet] Got \(tweetsData.count) tweets and \(originalTweetsData.count) original tweets from server")
        
        // Cache original tweets first (memory cache only for profile tweets)
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                    originalTweet.author = try? await fetchUser(originalTweet.authorId)
                    TweetCacheManager.shared.saveTweet(originalTweet, userId: appUser.mid)
                    print("[fetchUserTweet] Cached original tweet: \(originalTweet.mid)")
                } catch {
                    print("[fetchUserTweet] Error caching original tweet: \(error)")
                }
            }
        }
        
        var tweets: [Tweet?] = []
        for item in tweetsData {
            if let tweetDict = item {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                    tweet.author = user
                    
                    // Only show private tweets if the current user is the author
                    if tweet.isPrivate == true && tweet.authorId != appUser.mid {
                        tweets.append(nil)
                        continue
                    }
                    
                    // Keep tweets only in memory cache (not database cache) for profile views
                    TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
                    tweets.append(tweet)
                } catch {
                    print("[fetchUserTweet] Error processing tweet: \(error)")
                    tweets.append(nil)
                }
            } else {
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
                
                // Update cached data for main feed
                TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
                
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
        let user = User.getInstance(mid: userId)
        if !user.hasExpired {
            // get cached user instance if it is not expired.
            return TweetCacheManager.shared.fetchUser(mid: userId)
        }
        
        // Step 2: Fetch from server. No instance available in memory or cache.
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
        newClient.timeout = 300  // Increased from 60 to 300 seconds for large uploads
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
                    // Update appUser to the logged-in user
                    self.appUser = loginUser
                }
                return ["reason": "Success", "status": "success"]
            }
        }
        return ["reason": "Invalid response status", "status": "failure"]
    }
    
    func logout() {
        preferenceHelper?.setUserId(nil as String?)
        // Reset appUser to guest user
        let guestUser = User.getInstance(mid: Constants.GUEST_ID)
        guestUser.baseUrl = HproseInstance.baseUrl
        guestUser.followingList = Gadget.getAlphaIds()
        self.appUser = guestUser
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
            client.timeout = 300  // Increased from 60 to 300 seconds for large uploads
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
        
        guard var service = user.hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        var newClient: HproseClient? = nil
        if let baseUrl = user.baseUrl, baseUrl != appUser.baseUrl {
            let client = HproseHttpClient()
            client.timeout = 300  // Increased from 60 to 300 seconds for large uploads
            client.uri = "\(baseUrl)/webapi/"
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
                    // Don't cache tweets from bookmarks/favorites - only cache from main feed
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
                let updatedTweet = await MainActor.run {
                    return tweet.copy(favorites: updatedFavorites, favoriteCount: favoriteCount)
                }
                // Cache the updated tweet for main feed
                TweetCacheManager.shared.saveTweet(updatedTweet, userId: appUser.mid)
                return updatedTweet
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
                let updatedTweet = await MainActor.run {
                    return tweet.copy(favorites: updatedFavorites, bookmarkCount: bookmarkCount)
                }
                // Cache the updated tweet for main feed
                TweetCacheManager.shared.saveTweet(updatedTweet, userId: appUser.mid)
                return updatedTweet
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
            // Cache the updated tweet for main feed
            TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
        } else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "updateRetweetCount: No response"])
        }
    }
    
    /**
     * Delete a tweet and returned the deleted tweetId. Only appUser can delete its own tweet.
     * */
    func deleteTweet(_ tweetId: String) async throws -> String? {
        let entry = "delete_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "authorid": appUser.mid,
            "tweetid": tweetId
        ]
        guard let service = hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        guard let response = service.runMApp(entry, params, nil) as? [String: Any] else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: return the tweet ID
            guard let deletedTweetId = response["tweetid"] as? String else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Success response missing tweet ID"])
            }
            return deletedTweetId
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown tweet deletion error"
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
        
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        // Wait for writableUrl to be resolved
        let resolvedUrl = await appUser.resolveWritableUrl()
        guard resolvedUrl != nil else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve writable URL"])
        }
        
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
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: extract comment ID and count
            guard let commentId = response["mid"] as? String else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Success response missing comment ID"])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Success response missing comment count"])
            }
            
            await MainActor.run {
                comment.mid = commentId
                comment.author = appUser
                tweet.commentCount = count
            }
            // Cache the updated tweet for main feed
            TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
            
            // Check if retweetid is present and create a new tweet
            if let retweetId = response["retweetid"] as? String, !retweetId.isEmpty {
                print("[HproseInstance] Retweet ID received: \(retweetId)")
                
                // Create a new tweet with the comment's content and original tweet ID
                let newTweet = Tweet(
                    mid: retweetId,
                    authorId: appUser.mid,
                    content: comment.content,
                    timestamp: comment.timestamp,
                    originalTweetId: tweet.mid,
                    originalAuthorId: tweet.authorId,
                    attachments: comment.attachments
                )
                
                // Set the author
                newTweet.author = appUser
                
                // Post notification for the new tweet on main thread
                await MainActor.run {
                    print("[HproseInstance] Posting newTweetCreated notification for retweet")
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": newTweet]
                    )
                }
                
                // Also post the comment notification on main thread
                await MainActor.run {
                    print("[HproseInstance] Posting newCommentAdded notification")
                    print("[HproseInstance] New comment mid: \(comment.mid)")
                    print("[HproseInstance] New retweet ID: \(retweetId)")
                    print("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                    
                    NotificationCenter.default.post(
                        name: .newCommentAdded,
                        object: nil,
                        userInfo: ["comment": comment]
                    )
                }
                
                return comment
            } else {
                // No retweetid, just post comment notification on main thread
                await MainActor.run {
                    print("[HproseInstance] No retweet ID, posting only newCommentAdded notification")
                    print("[HproseInstance] New comment mid: \(comment.mid)")
                    print("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                    
                    NotificationCenter.default.post(
                        name: .newCommentAdded,
                        object: nil,
                        userInfo: ["comment": comment]
                    )
                }
                
                return comment
            }
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown comment upload error"
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    // both author and tweet author can delete this comment
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
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: return the response with commentId and count
            guard let deletedCommentId = response["commentId"] as? String else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Success response missing comment ID"])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Success response missing comment count"])
            }
            
            return [
                "commentId": deletedCommentId,
                "count": count
            ]
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown comment deletion error"
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil,
        noResample: Bool = false
    ) async throws -> MimeiFileType? {
        _ = await appUser.resolveWritableUrl()
        print("Starting upload to IPFS: typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil"), noResample=\(noResample)")
        
        // Use VideoProcessor to determine media type and handle upload
        let videoProcessor = VideoProcessor()
        return try await videoProcessor.processAndUpload(
            data: data,
            typeIdentifier: typeIdentifier,
            fileName: fileName,
            referenceId: referenceId,
            noResample: noResample,
            appUser: appUser,
            appId: appId
        )
    }
    
    // MARK: - Video Processing
    /// Consolidated video processing class that handles all video-related operations
    class VideoProcessor {
        
        /// Process and upload video or other media files
        func processAndUpload(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            appId: String
        ) async throws -> MimeiFileType? {
            
            // Determine media type
            let mediaType = detectMediaType(from: typeIdentifier, fileName: fileName)
            print("DEBUG: Detected media type: \(mediaType.rawValue)")
            
            // Handle video files with backend conversion
            if mediaType == .video {
                print("Processing video with backend conversion")
                return try await uploadVideoForBackendConversion(
                    data: data,
                    fileName: fileName,
                    referenceId: referenceId,
                    noResample: noResample,
                    appUser: appUser
                )
            } else {
                print("Processing non-video file with regular upload")
                return try await uploadRegularFile(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    mediaType: mediaType,
                    appUser: appUser,
                    appId: appId
                )
            }
        }
        
        /// Detect media type from type identifier and filename
        private func detectMediaType(from typeIdentifier: String, fileName: String?) -> MediaType {
            // Check type identifier first
            if typeIdentifier.hasPrefix("public.image") {
                return .image
            } else if typeIdentifier.hasPrefix("public.movie") || typeIdentifier.contains("quicktime-movie") || typeIdentifier.contains("movie") {
                return .video
            } else if typeIdentifier.hasPrefix("public.audio") || typeIdentifier.contains("audio") {
                return .audio
            } else if typeIdentifier == "public.composite-content" {
                return .pdf
            } else if typeIdentifier == "public.zip-archive" {
                return .zip
            }
            
            // Fallback to file extension check
            let fileExtension = (fileName ?? typeIdentifier).components(separatedBy: ".").last?.lowercased()
            switch fileExtension {
            case "jpg", "jpeg", "png", "gif", "heic", "heif":
                return .image
            case "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf":
                return .video
            case "mp3", "m4a", "wav", "flac", "aac":
                return .audio
            case "pdf":
                return .pdf
            case "zip":
                return .zip
            case "doc", "docx":
                return .word
            default:
                return .unknown
            }
        }
        
        /// Upload video to backend for conversion
        private func uploadVideoForBackendConversion(
            data: Data,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User
        ) async throws -> MimeiFileType? {
            print("Uploading original video to backend for conversion, data size: \(data.count) bytes")
            
            // Get the user's cloudDrivePort with fallback to default
            let cloudDrivePort = appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
            
            // Ensure writableUrl is available
            var writableUrl = appUser.writableUrl
            if writableUrl == nil {
                writableUrl = await appUser.resolveWritableUrl()
            }
            
            guard let writableUrl = writableUrl else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available"])
            }
            
            // Construct convert-video endpoint URL
            let convertVideoURL = "\(writableUrl.scheme ?? "http")://\(writableUrl.host ?? writableUrl.absoluteString):\(cloudDrivePort)/convert-video"
            guard let url = URL(string: convertVideoURL) else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid convert-video URL"])
            }
            
            // Determine content type based on file extension
            let contentType = determineVideoContentType(fileName: fileName)
            print("DEBUG: Determined content type: \(contentType)")
            
            // Create multipart form data
            let boundary = "Boundary-\(UUID().uuidString)"
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var body = Data()
            
            // Add filename if provided (server expects this field)
            if let fileName = fileName {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"filename\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(fileName)\r\n".data(using: .utf8)!)
            }
            
            // Add reference ID if provided (server expects this field)
            if let referenceId = referenceId {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"referenceId\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(referenceId)\r\n".data(using: .utf8)!)
            }
            
            // Add noResample parameter - use the value passed from compose view
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"noResample\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(noResample)\r\n".data(using: .utf8)!)
            
            // Add the video file (server expects field name "videoFile")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"videoFile\"; filename=\"\(fileName ?? "video.mp4")\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
            
            // End boundary
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            
            request.httpBody = body
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
            
            // Get aspect ratio from original video for metadata (with fallback)
            let aspectRatio = await getVideoAspectRatioWithFallback(from: data)
            
            // Upload with retry mechanism
            return try await uploadWithRetry(request: request, data: data, fileName: fileName, aspectRatio: aspectRatio)
        }
        
        /// Determine video content type based on file extension
        private func determineVideoContentType(fileName: String?) -> String {
            guard let fileName = fileName else {
                return "video/mp4" // Default fallback
            }
            
            let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
            
            switch fileExtension {
            case "mp4", "m4v":
                return "video/mp4"
            case "avi":
                return "video/avi"
            case "mov":
                return "video/mov"
            case "mkv":
                return "video/mkv"
            case "wmv":
                return "video/wmv"
            case "flv":
                return "video/flv"
            case "webm":
                return "video/webm"
            case "ts", "mts", "m2ts":
                return "video/mp2t"
            case "vob":
                return "video/mpeg"
            case "dat":
                return "video/mpeg"
            case "ogv":
                return "video/ogg"
            case "f4v":
                return "video/x-f4v"
            case "asf":
                return "video/x-ms-asf"
            default:
                return "video/mp4" // Default fallback
            }
        }
        
        /// Get video aspect ratio with fallback to default values
        private func getVideoAspectRatioWithFallback(from data: Data) async -> Float? {
            do {
                let aspectRatio = try await getVideoAspectRatio(from: data)
                if let ratio = aspectRatio, ratio > 0 {
                    print("DEBUG: Successfully determined aspect ratio: \(ratio)")
                    return ratio
                } else {
                    print("DEBUG: Aspect ratio detection failed, using default 16:9")
                    return 16.0 / 9.0 // Default to 16:9 aspect ratio
                }
            } catch {
                print("DEBUG: Aspect ratio detection failed with error: \(error), using default 16:9")
                return 16.0 / 9.0 // Default to 16:9 aspect ratio
            }
        }
        
        /// Upload regular (non-video) files
        private func uploadRegularFile(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            mediaType: MediaType,
            appUser: User,
            appId: String
        ) async throws -> MimeiFileType {
            print("Uploading regular file: type=\(mediaType.rawValue), size=\(data.count) bytes")
            
            // Get upload service
            var uploadService = appUser.uploadService
            if uploadService == nil {
                _ = await appUser.resolveWritableUrl()
                uploadService = appUser.uploadService
                if uploadService == nil {
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload service not available"])
                }
            }
            
            // Create temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            // Upload in chunks
            var offset: Int64 = 0
            let chunkSize = 1024 * 1024 // 1MB chunks
            var request: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "offset": offset
            ]
            
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            defer { try? fileHandle.close() }
            
            var chunkCount = 0
            while true {
                let chunkData = fileHandle.readData(ofLength: chunkSize)
                if chunkData.isEmpty { break }
                
                chunkCount += 1
                
                let nsData = chunkData as NSData
                let response = try await uploadChunkWithRetry(
                    uploadService: uploadService!,
                    request: request,
                    data: nsData,
                    chunkNumber: chunkCount
                )
                
                if let fsid = response as? String {
                    offset += Int64(chunkData.count)
                    request["offset"] = offset
                    request["fsid"] = fsid
                } else {
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload chunk \(chunkCount)"])
                }
            }
            
            // Mark upload as finished
            request["finished"] = "true"
            if let referenceId = referenceId {
                request["referenceid"] = referenceId
            }
            
            let finalResponse = uploadService!.runMApp("upload_ipfs", request, nil)
            
            guard let cid = finalResponse as? String else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CID from final upload response"])
            }
            
            // Get file attributes
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
            
            // Get aspect ratio for videos (only for original videos, not HLS packages)
            var aspectRatio: Float?
            if mediaType == .video {
                aspectRatio = try await getVideoAspectRatio(from: data)
            }
            
            return MimeiFileType(
                mid: cid,
                type: mediaType.rawValue,
                size: Int64(fileSize),
                fileName: fileName,
                timestamp: fileTimestamp,
                aspectRatio: aspectRatio,
                url: nil
            )
        }
        
        /// Get video aspect ratio from data
        private func getVideoAspectRatio(from data: Data) async throws -> Float? {
            do {
                // Create a temporary file with a proper extension to help AVFoundation identify the format
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                try data.write(to: tempURL)
                
                // Ensure the file exists and is readable
                guard FileManager.default.fileExists(atPath: tempURL.path) else {
                    print("Warning: Temporary video file was not created successfully")
                    return nil
                }
                
                // Get file size to ensure it's not empty
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let fileSize = fileAttributes[.size] as? UInt64 ?? 0
                
                if fileSize == 0 {
                    print("Warning: Temporary video file is empty")
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }
                
                // Try to get aspect ratio with proper error handling
                let aspectRatio = try await HLSVideoProcessor.shared.getVideoAspectRatio(filePath: tempURL.path)
                
                // Clean up the temporary file after successful processing
                try? FileManager.default.removeItem(at: tempURL)
                
                return aspectRatio
            } catch {
                print("Warning: Could not determine video aspect ratio: \(error)")
                // Clean up any temporary files that might have been created
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        }
        
        /// Upload with retry mechanism for video conversion
        private func uploadWithRetry(
            request: URLRequest,
            data: Data,
            fileName: String?,
            aspectRatio: Float?
        ) async throws -> MimeiFileType? {
            var lastError: Error?
            
            // Create a custom URLSession with longer timeout for large uploads
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600  // 5 minutes
            config.timeoutIntervalForResource = 600 // 10 minutes
            let session = URLSession(configuration: config)
            
            for attempt in 1...3 {
                do {
                    print("DEBUG: Video upload attempt \(attempt)/3")
                    let (responseData, response) = try await session.data(for: request)
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        print("DEBUG: HTTP status code: \(httpResponse.statusCode)")
                        
                        if httpResponse.statusCode == 200 {
                            return try parseVideoConversionResponse(
                                responseData: responseData,
                                data: data,
                                fileName: fileName,
                                aspectRatio: aspectRatio
                            )
                        } else if httpResponse.statusCode == 400 {
                            // Bad request - don't retry, parse error message
                            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Bad request"
                            throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Bad request: \(errorMessage)"])
                        } else if httpResponse.statusCode == 413 {
                            // Payload too large - don't retry
                            throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Video file too large for processing"])
                        } else if httpResponse.statusCode >= 500 {
                            // Server error - retry
                            throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error (HTTP \(httpResponse.statusCode))"])
                        } else {
                            throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) error"])
                        }
                    } else {
                        throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
                    }
                } catch {
                    lastError = error
                    print("DEBUG: Video upload attempt \(attempt) failed: \(error)")
                    
                    if attempt < 3 {
                        // Wait before retrying (exponential backoff)
                        let delay = TimeInterval(attempt * 2) // 2, 4 seconds
                        print("DEBUG: Waiting \(delay) seconds before retry...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
            
            // All retries failed
            print("DEBUG: All video upload attempts failed")
            throw lastError ?? NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload video after 3 attempts"])
        }
        
        /// Parse video conversion response
        private func parseVideoConversionResponse(
            responseData: Data,
            data: Data,
            fileName: String?,
            aspectRatio: Float?
        ) throws -> MimeiFileType? {
            guard let responseString = String(data: responseData, encoding: .utf8) else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
            }
            
            print("DEBUG: Server response: \(responseString)")
            
            do {
                guard let jsonData = responseString.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
                }
                
                if let success = json["success"] as? Bool, success {
                    if let cid = json["cid"] as? String, !cid.isEmpty {
                        print("DEBUG: Video conversion successful, CID: \(cid)")
                        return MimeiFileType(
                            mid: cid,
                            type: "hls_video",
                            size: Int64(data.count),
                            fileName: fileName,
                            timestamp: Date(),
                            aspectRatio: aspectRatio,
                            url: nil
                        )
                    } else {
                        throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No CID in response"])
                    }
                } else {
                    let message = json["message"] as? String ?? "Unknown error"
                    let error = json["error"] as? String
                    let errorMessage = error != nil ? "\(message). Error: \(error!)" : message
                    
                    print("DEBUG: Server reported error: \(errorMessage)")
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server error: \(errorMessage)"])
                }
            } catch {
                print("DEBUG: Failed to parse response: \(error)")
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response: \(error.localizedDescription)"])
            }
        }
        
        /// Upload chunk with retry for regular files
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
            
            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload chunk after \(maxRetries) attempts"])
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
    // Background task approach removed - using immediate upload with persistence instead
    
    // MARK: - Persistence and Retry
    struct PendingTweetUpload: Codable {
        let tweet: Tweet
        let itemData: [ItemData]
        let timestamp: Date
        let retryCount: Int
        
        struct ItemData: Codable {
            let identifier: String
            let typeIdentifier: String
            let data: Data
            let fileName: String
            let noResample: Bool
            
            init(identifier: String, typeIdentifier: String, data: Data, fileName: String, noResample: Bool = false) {
                self.identifier = identifier
                self.typeIdentifier = typeIdentifier
                self.data = data
                self.fileName = fileName
                self.noResample = noResample
            }
        }
        
        init(tweet: Tweet, itemData: [ItemData], retryCount: Int = 0) {
            self.tweet = tweet
            self.itemData = itemData
            self.timestamp = Date()
            self.retryCount = retryCount
        }
    }
    
    private let maxRetryAttempts = 3
    private let retryDelaySeconds: TimeInterval = 5.0
    
    func uploadTweet(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            // Create a copy of the tweet and remove its author attribute
            tweet.author = nil
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": appUser.hostIds?.first as Any,
                "tweet": String(data: try JSONEncoder().encode(tweet), encoding: .utf8) ?? ""
            ]
            
            let rawResponse = appUser.hproseService?.runMApp("add_tweet", params, nil)
            
            // Handle the JSON response format
            guard let responseDict = rawResponse as? [String: Any] else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server"])
            }
            
            guard let success = responseDict["success"] as? Bool else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format: missing success field"])
            }
            
            if success {
                // Success case: extract the tweet ID
                guard let newTweetId = responseDict["mid"] as? String else {
                    throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Success response missing tweet ID"])
                }
                
                let uploadedTweet = tweet
                uploadedTweet.mid = newTweetId
                uploadedTweet.author = try? await self.fetchUser(tweet.authorId)
                return uploadedTweet
            } else {
                // Failure case: extract error message
                let errorMessage = responseDict["message"] as? String ?? "Unknown upload error"
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
    }
    
    private func uploadItemPair(_ pair: [PendingTweetUpload.ItemData]) async throws -> [MimeiFileType] {
        let uploadTasks = pair.map { itemData in
            Task {
                return try await uploadToIPFS(
                    data: itemData.data,
                    typeIdentifier: itemData.typeIdentifier,
                    fileName: itemData.fileName,
                    noResample: itemData.noResample
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
    
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData)
        }
    }
    
    private func uploadTweetWithPersistenceAndRetry(tweet: Tweet, itemData: [PendingTweetUpload.ItemData], retryCount: Int = 0) async {
        // Save pending upload to disk for persistence
        let pendingUpload = PendingTweetUpload(tweet: tweet, itemData: itemData, retryCount: retryCount)
        await savePendingUpload(pendingUpload)
        
        do {
            // Upload attachments first
            let uploadedAttachments = try await uploadAttachmentsWithRetry(itemData: itemData, retryCount: retryCount)
            
            // Update tweet with uploaded attachments
            tweet.attachments = uploadedAttachments
            
            // Upload the tweet
            if let uploadedTweet = try await self.uploadTweet(tweet) {
                // Success - remove pending upload and notify
                await removePendingUpload()
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
            } else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload tweet"])
            }
        } catch {
            print("Error uploading tweet (attempt \(retryCount + 1)/\(maxRetryAttempts)): \(error)")
            
            if retryCount < maxRetryAttempts - 1 {
                // Retry after delay
                print("Retrying upload in \(retryDelaySeconds) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(retryDelaySeconds * 1_000_000_000))
                await uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData, retryCount: retryCount + 1)
            } else {
                // Max retries reached - notify failure but keep pending upload for manual retry
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
    
    private func uploadAttachmentsWithRetry(itemData: [PendingTweetUpload.ItemData], retryCount: Int) async throws -> [MimeiFileType] {
        var uploadedAttachments: [MimeiFileType] = []
        let itemPairs = itemData.chunked(into: 2)
        
        for (pairIndex, pair) in itemPairs.enumerated() {
            do {
                let pairAttachments = try await self.uploadItemPair(pair)
                uploadedAttachments.append(contentsOf: pairAttachments)
            } catch {
                print("Error uploading pair \(pairIndex + 1): \(error)")
                throw error
            }
        }
        
        if itemData.count != uploadedAttachments.count {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)"])
        }
        
        return uploadedAttachments
    }
    
    private func savePendingUpload(_ pendingUpload: PendingTweetUpload) async {
        do {
            let data = try JSONEncoder().encode(pendingUpload)
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            try data.write(to: fileURL)
            print("Saved pending upload to disk")
        } catch {
            print("Failed to save pending upload: \(error)")
        }
    }
    
    private func removePendingUpload() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        try? FileManager.default.removeItem(at: fileURL)
        print("Removed pending upload from disk")
    }
    
    // MARK: - Recovery Methods
    func recoverPendingUploads() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let pendingUpload = try JSONDecoder().decode(PendingTweetUpload.self, from: data)
            
            // Check if the pending upload is not too old (e.g., within 24 hours)
            let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours
            if Date().timeIntervalSince(pendingUpload.timestamp) < maxAge {
                print("Recovering pending upload from \(pendingUpload.timestamp)")
                await uploadTweetWithPersistenceAndRetry(
                    tweet: pendingUpload.tweet,
                    itemData: pendingUpload.itemData,
                    retryCount: pendingUpload.retryCount
                )
            } else {
                // Remove old pending upload
                try? FileManager.default.removeItem(at: fileURL)
                print("Removed old pending upload from \(pendingUpload.timestamp)")
            }
        } catch {
            print("Failed to recover pending upload: \(error)")
            // Remove corrupted file
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData]
    ) {
        Task.detached(priority: .background) {
            do {
                let comment = comment
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                for (pairIndex, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)   // Upload attachments to IPFS
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
                        print("[HproseInstance] Comment upload completed successfully")
                        print("[HproseInstance] New comment mid: \(newComment.mid)")
                        print("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                        
                        // The addComment method now handles both comment and retweet notifications
                        // No need to post notifications here as they're handled in addComment
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
        let entry = "toggle_pinned_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "tweetid": tweetId,
            "appuserid": appUser.mid,
        ]
        guard let response = appUser.hproseService?.runMApp(entry, params, nil) as? Bool else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "togglePinnedTweet: No response"])
        }
        return response
    }

    /**
     * Return a list of {tweetId, timestamp} for each pinned Tweet. The timestamp is when
     * the tweet is pinned.
     */
    func getPinnedTweets(user: User) async throws -> [[String: Any]] {
        let entry = "get_pinned_tweets"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "appuserid": appUser.mid
        ]
        guard let response = user.hproseService?.runMApp(entry, params, nil) as? [[String: Any]] else {
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
        
        guard let response = appUser.hproseService?.runMApp(entry, params, nil) as? [String: Any] else {
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
        guard let response = appUser.hproseService?.runMApp(entry, params, nil) as? [String: Any] else {
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
        let entry = "set_user_avatar"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "avatar": avatar
        ]
        _ = appUser.hproseService?.runMApp(entry, params, nil)
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
    
    // MARK: - Chat Functions
    
    /// Send a chat message to a recipient
    func sendMessage(receiptId: String, message: ChatMessage) async throws {

        let entry = "message_outgoing"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid,
            "receiptid": receiptId,
            "msg": message.toJSONString()
        ]
        
        let response = appUser.hproseService?.runMApp(entry, params, nil) as? Bool
        
        if response == true {
            // Try to send to recipient's node as well
            if let receiptUser = try await fetchUser(receiptId) {
                let receiptEntry = "message_incoming"
                let receiptParams: [String: Any] = [
                    "aid": appId,
                    "ver": "last",
                    "senderid": appUser.mid,
                    "receiptid": receiptId,
                    "msg": message.toJSONString()
                ]
                
                let receiptResponse = receiptUser.hproseService?.runMApp(receiptEntry, receiptParams, nil) as? Bool
                if receiptResponse != true {
                    print("[sendMessage] Warning: Failed to send to recipient node")
                }
            }
        } else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
        }
    }
    
    /// Fetch recent unread messages from a sender (incoming messages only)
    func fetchMessages(senderId: String) async throws -> [ChatMessage] {
        guard let service = appUser.hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        let entry = "message_fetch"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid,
            "senderid": senderId
        ]
        
        let response = service.runMApp(entry, params, nil) as? [[String: Any]] ?? []
        
        return response.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    return message
                } else {
                    print("[fetchMessages] Filtered out outgoing message from \(message.authorId)")
                    return nil
                }
            } catch {
                print("[fetchMessages] Error decoding message: \(error)")
                return nil
            }
        }
    }
    
    /// Check for new incoming messages (only check, do not fetch them)
    func checkNewMessages() async throws -> [ChatMessage] {
        guard !appUser.isGuest else { return [] }
        
        guard let service = appUser.hproseService else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        let entry = "message_check"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid
        ]
        
        let response = service.runMApp(entry, params, nil) as? [[String: Any]] ?? []
        
        return response.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    return message
                } else {
                    print("[checkNewMessages] Filtered out outgoing message from \(message.authorId)")
                    return nil
                }
            } catch {
                print("[checkNewMessages] Error decoding message: \(error)")
                return nil
            }
        }
    }
}


// MARK: - Array Extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
