import Foundation
import hprose
import PhotosUI
import AVFoundation

// MARK: - Video Conversion Status
struct VideoConversionStatus {
    let status: String
    let progress: Int
    let message: String?
    let cid: String?
}

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

// MARK: - HproseInstance
final class HproseInstance: ObservableObject {
    // MARK: - Properties
    static let shared = HproseInstance()
    static var baseUrl: URL = URL(string: AppConfig.baseUrl)!
    // Removed _HproseClient as we now use client directly
    private var _domainToShare: String = AppConfig.baseUrl
    
    /// The domain to use for sharing links
    var domainToShare: String {
        get { _domainToShare }
        set { _domainToShare = newValue }
    }
    
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
    
    // MARK: - BlackList Management
    private let blackList = BlackList.shared
    
    private lazy var client: HproseClient = {
        let client = HproseHttpClient()
        client.timeout = 300  // Increased from 60 to 300 seconds for large uploads
        client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
        return client
    }()
    
    // MARK: - Helper Methods
    
    /// Generic retry helper with exponential backoff
    private func retryOperation<T>(
        maxRetries: Int = 3,
        baseDelay: UInt64 = 1_000_000_000, // 1 second in nanoseconds
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                print("DEBUG: [retryOperation] Attempt \(attempt)/\(maxRetries) failed: \(error)")
                
                if attempt < maxRetries {
                    let delay = baseDelay * UInt64(attempt) // Exponential backoff
                    print("DEBUG: [retryOperation] Retrying in \(delay / 1_000_000_000) seconds...")
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        
        throw lastError ?? NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "All retry attempts failed"])
    }
    
    /// Print detailed app user content for debugging
    private func printAppUserContent(_ context: String) {
        print("=== APP USER CONTENT [\(context)] ===")
        print("MID: \(appUser.mid)")
        print("Username: \(appUser.username ?? "nil")")
        print("Name: \(appUser.name ?? "nil")")
        print("Profile: \(appUser.profile ?? "nil")")
        print("Avatar: \(appUser.avatar ?? "nil")")
        print("Base URL: \(appUser.baseUrl?.absoluteString ?? "nil")")
        print("Writable URL: \(appUser.writableUrl?.absoluteString ?? "nil")")
        print("Cloud Drive Port: \(appUser.cloudDrivePort?.description ?? "nil")")
        print("Host IDs: \(appUser.hostIds ?? [])")
        print("Tweet Count: \(appUser.tweetCount?.description ?? "nil")")
        print("Following Count: \(appUser.followingCount?.description ?? "nil")")
        print("Followers Count: \(appUser.followersCount?.description ?? "nil")")
        print("Bookmarks Count: \(appUser.bookmarksCount?.description ?? "nil")")
        print("Favorites Count: \(appUser.favoritesCount?.description ?? "nil")")
        print("Comments Count: \(appUser.commentsCount?.description ?? "nil")")
        print("Following List: \(appUser.followingList ?? [])")
        print("Fans List: \(appUser.fansList ?? [])")
        print("User Black List: \(appUser.userBlackList ?? [])")
        print("Bookmarked Tweets: \(appUser.bookmarkedTweets ?? [])")
        print("Favorite Tweets: \(appUser.favoriteTweets ?? [])")
        print("Replied Tweets: \(appUser.repliedTweets ?? [])")
        print("Comments List: \(appUser.commentsList ?? [])")
        print("Top Tweets: \(appUser.topTweets ?? [])")
        print("Has Accepted Terms: \(appUser.hasAcceptedTerms)")
        print("Is Guest: \(appUser.isGuest)")
        print("Timestamp: \(appUser.timestamp)")
        print("Last Login: \(appUser.lastLogin?.description ?? "nil")")
        print("=====================================")
    }
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        print("DEBUG: [HproseInstance] Starting initialization")
        
        // Step 1: Initialize preference helper first
        self.preferenceHelper = PreferenceHelper()
        
        // Step 2: Initialize app user with default values
        await initializeAppUser()
        
        // Step 3: Try to initialize app entry and update user if successful
        do {
            try await initAppEntry()
        } catch {
            print("Error initializing app entry: \(error)")
            // Don't throw here, allow the app to continue with default settings
        }
        
        // Step 5: Clean up expired tweets
        TweetCacheManager.shared.deleteExpiredTweets()
        
        // Step 6: Schedule background tasks
        scheduleBackgroundTasks()
        
        print("DEBUG: [HproseInstance] Initialization completed")
    }
    
    /// Initialize app user with default values
    func initializeAppUser() async {
        await MainActor.run {
            // Get user ID from preferences or use guest ID
            let userId = preferenceHelper?.getUserId() ?? Constants.GUEST_ID
            
            // Try to load cached user first, then fall back to new instance
            let cachedUser = TweetCacheManager.shared.fetchUser(mid: userId)
            _appUser = cachedUser
            
            // Set base URL from preferences or use default
            let baseUrlString = preferenceHelper?.getAppUrls().first ?? AppConfig.baseUrl
            _appUser.baseUrl = URL(string: baseUrlString)!
            
            // Set following list
            _appUser.followingList = Gadget.getAlphaIds()
            
            // Update domain to share
            _domainToShare = baseUrlString
            
            print("DEBUG: [HproseInstance] Initialized app user: \(userId), baseUrl: \(baseUrlString)")
        }
    }
    
    /// Schedule background tasks
    private func scheduleBackgroundTasks() {
        // Schedule domain update and pending upload recovery
        Task.detached(priority: .background) {
            // Wait for 30 seconds to ensure app is fully initialized
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
            
            // Check for domain updates
            await self.checkAndUpdateDomain()
            
            // Recover any pending uploads
            await self.recoverPendingUploads()
        }
    }
    
    /// Fetch alphaId user from backend for guest users
    private func fetchAlphaIdUserForGuest() async {
        guard appUser.isGuest else { return }
        
        do {
            print("DEBUG: [HproseInstance] Fetching alphaId user for guest user: \(AppConfig.alphaId)")
            
            // Create alphaId user with proper baseUrl
            let alphaUser = User.getInstance(mid: AppConfig.alphaId)
            await MainActor.run {
                alphaUser.baseUrl = HproseInstance.baseUrl
            }
            
            // Fetch user data from server
            try await updateUserFromServer(alphaUser)
            
            print("DEBUG: [HproseInstance] Successfully fetched alphaId user for guest")
            
            // Notify FollowingsTweetView to refresh
            await MainActor.run {
                NotificationCenter.default.post(name: .appUserReady, object: nil)
            }
            
        } catch {
            print("DEBUG: [HproseInstance] Failed to fetch alphaId user for guest: \(error)")
        }
    }
    
    func initAppEntry() async throws {
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = Gadget.shared.extractParamMap(from: html)
                appId = paramData["mid"] as? String ?? ""
                guard let addrs = paramData["addrs"] as? String else { continue }
                print("Initializing with addresses: \(addrs)")
                
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    
                    HproseInstance.baseUrl = URL(string: "http://\(firstIp)")!
                    client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                    
                    if !appUser.isGuest, let providerIp = try await getProviderIP(appUser.mid) {
                        print("provider ip:  \(providerIp)")
                        // Try to fetch user (retry logic is now built into fetchUser method)
                        let user = try await fetchUser(appUser.mid, baseUrl: "http://\(providerIp)")
                        
                        if let user = user {
                            // Valid login user is found, use its provider IP as base.
                            HproseInstance.baseUrl = URL(string: "http://\(providerIp)")!
                            client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                            let followings = (try? await getListByType(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                            let blackList = (try? await getListByType(user: user, entry: .BLACK_LIST)) ?? []
                            await MainActor.run {
                                // Update the appUser to the fetched user with all properties
                                user.baseUrl = HproseInstance.baseUrl
                                user.followingList = followings
                                user.userBlackList = blackList
                                self.appUser = user
                                // Update domain to share with the new base URL
                                self._domainToShare = HproseInstance.baseUrl.absoluteString
                                
                                // Print detailed app user content after successful login
                                self.printAppUserContent("After successful login")
                                
                                // Notify FollowingsTweetView to refresh for logged-in user
                                NotificationCenter.default.post(name: .appUserReady, object: nil)
                            }
                            return
                        } else {
                            print("DEBUG: [initAppEntry] fetchUser failed after retry, falling back to guest user")
                            let user = User.getInstance(mid: Constants.GUEST_ID)
                            await MainActor.run {
                                user.baseUrl = HproseInstance.baseUrl
                                user.followingList = Gadget.getAlphaIds()
                                _appUser = user
                                // Update domain to share with the new base URL
                                self._domainToShare = HproseInstance.baseUrl.absoluteString
                            }
                            return
                        }
                    } else {
                        let user = User.getInstance(mid: Constants.GUEST_ID)
                        await MainActor.run {
                            user.baseUrl = HproseInstance.baseUrl
                            user.followingList = Gadget.getAlphaIds()
                            _appUser = user
                            // Update domain to share with the new base URL
                            self._domainToShare = HproseInstance.baseUrl.absoluteString
                        }
                        
                        // For guest users, fetch the alphaId user from backend now that we have proper IP
                        await fetchAlphaIdUserForGuest()
                        
                        return
                    }
                }
            } catch {
                print("Error processing URL \(url): \(error)")
                continue
            }
        }
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize app entry with any URL"])
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
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]?] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in fetchComments"])
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
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        var params = [
            "aid": appId,
            "ver": "last",
            "pn": pageNumber,
            "ps": pageSize,
            "userid": !user.isGuest ? user.mid : Gadget.getAlphaIds().first as Any,
            "appuserid": appUser.mid,
        ]
        
        if entry == "update_following_tweets" {
            params["hostid"] = appUser.hostIds?.first
        }
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchTweetFeed"])
        }
        
        // Check success status first
        guard let success = response["success"] as? Bool, success else {
            let errorMessage = response["message"] as? String ?? "Unknown error occurred"
            print("[fetchTweetFeed] Tweet feed loading failed: \(errorMessage)")
            print("[fetchTweetFeed] Response: \(response)")
            
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: localizeBackendError(errorMessage)])
        }
        
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        if entry == "update_following_tweets" {
            print("[fetchTweetFeed] Got \(tweetsData.count) tweets and \(originalTweetsData.count) original tweets from server")
        }
        
        // Cache original tweets first
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                    originalTweet.author = try? await fetchUser(originalTweet.authorId)
                    TweetCacheManager.shared.updateTweetInAppUserCaches(originalTweet, appUserId: appUser.mid)
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
                    TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: appUser.mid)
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
    func fetchUserTweets(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweets_by_user"
    ) async throws -> [Tweet?] {
        guard let client = user.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUser.mid,
        ] as [String : Any]
        
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchUserTweet"])
        }
        
        // Check success status first
        guard let success = response["success"] as? Bool, success else {
            let errorMessage = response["message"] as? String ?? "Unknown error occurred"
            print("[fetchUserTweet] Tweets loading failed for user \(user.mid): \(errorMessage)")
            print("[fetchUserTweet] Response: \(response)")
            
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        print("[fetchUserTweet] Fetching tweets for user: \(user.mid), page: \(pageNumber), size: \(pageSize)")
        print("[fetchUserTweet] Got \(tweetsData.count) tweets and \(originalTweetsData.count) original tweets from server")
        
        // Cache original tweets first (only if the user is appUser)
        if user.mid == appUser.mid {
            for originalTweetDict in originalTweetsData {
                if let dict = originalTweetDict {
                    do {
                        let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                        originalTweet.author = try? await fetchUser(originalTweet.authorId)
                        TweetCacheManager.shared.updateTweetInAppUserCaches(originalTweet, appUserId: appUser.mid)
                        print("[fetchUserTweet] Cached original tweet: \(originalTweet.mid)")
                    } catch {
                        print("[fetchUserTweet] Error caching original tweet: \(error)")
                    }
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
                    
                    // Cache tweets only if the user is appUser
                    if user.mid == appUser.mid {
                        TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: appUser.mid)
                    }
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
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        let entry = "get_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "tweetid": tweetId,
            "appuserid": appUser.mid
        ]
        if let tweetDict = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] {
            do {
                let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                tweet.author = try? await fetchUser(authorId)
                
                // Update cached data for main feed
                TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: appUser.mid)
                
                return tweet
            } catch {
                print("Error processing tweet: \(error)")
            }
        }
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tweet not found"])
    }
    
    func getUserId(_ username: String) async throws -> String? {
        try await withRetry {
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            let entry = "get_userid"
            let params = [
                "aid": appId,
                "ver": "last",
                "username": username,
            ]
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserId"])
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
        
        // Step 2: Fetch from server with retry logic. No instance available in memory or cache.
        return try await retryOperation(maxRetries: 3) {
            if baseUrl.isEmpty {
                guard let providerIP = try await self.getProviderIP(userId) else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Provider not found"])
                }
                await MainActor.run {
                    user.baseUrl = URL(string: "http://\(providerIP)")!
                }
                try await self.updateUserFromServer(user)
                return user
            } else {
                await MainActor.run {
                    user.baseUrl = URL(string: baseUrl)!
                }
                try await self.updateUserFromServer(user)
                return user
            }
        }
    }
    
    func updateUserFromServer(_ user: User) async throws {
        let entry = "get_user"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
        ]
        
        // Call runMApp following the sample code pattern
        guard let response = user.hproseClient?.invoke("runMApp", withArgs: [entry, params]) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No hprose client available for user: \(user.mid)"])
        }
        
        // Check for IP address response first (user not found on this node)
        if let ipAddress = response as? String, !ipAddress.isEmpty {
            print("DEBUG: [updateUserFromServer] User not found on current node, redirecting to IP: \(ipAddress)")
            // the user is not found on this node, a provider IP of the user is returned.
            // point server to this new IP.
            await MainActor.run {
                user.baseUrl = URL(string: "http://\(ipAddress)")!
            }
            
            // Create a new client for the new IP
            let newClient = HproseHttpClient()
            newClient.timeout = 300
            newClient.uri = "\(user.baseUrl?.absoluteString ?? "")/webapi/"
            
            // Call runMApp with the new client following the sample code pattern
            let newResponse = newClient.invoke("runMApp", withArgs: [entry, params])
            
            if let newUserDict = newResponse as? [String: Any] {
                await MainActor.run {
                    do {
                        _ = try User.from(dict: newUserDict)
                    } catch {
                        print("DEBUG: [updateUserFromServer] Error updating user with new service: \(error)")
                    }
                }
            } else if let newIpAddress = newResponse as? String {
                print("DEBUG: [updateUserFromServer] User still not found on redirected IP: \(newIpAddress)")
            }
            
            // Close the new client
            newClient.close()
        } else if let userDict = response as? [String: Any] {
            // User found on current node
            await MainActor.run {
                do {
                    _ = try User.from(dict: userDict)
                } catch {
                    print("DEBUG: [updateUserFromServer] Error updating user: \(error)")
                    print("DEBUG: [updateUserFromServer] Response that caused error: \(response)")
                }
            }
        } else {
            print("DEBUG: [updateUserFromServer] Unexpected response type: \(type(of: response)), value: \(response)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response from server: \(response))"])
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
        
        return try await retryOperation(maxRetries: 3) {
            let newClient = HproseHttpClient()
            newClient.timeout = 300  // Increased from 60 to 300 seconds for large uploads
            newClient.uri = "\(loginUser.baseUrl!.absoluteString)/webapi/"
            
            defer { newClient.close() }
            
            guard let response = newClient.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil response from server in login"])
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
                        self.preferenceHelper?.setUserId(loginUser.mid)
                        // Update appUser to the logged-in user
                        self.appUser = loginUser
                    }
                    
                    // Populate fans and following lists for the logged-in user
                    Task {
                        await self.populateUserLists(user: loginUser)
                    }
                    
                    return ["reason": "Success", "status": "success"]
                }
            }
            return ["reason": "Invalid response status", "status": "failure"]
        }
    }
    
    func logout() async {
        preferenceHelper?.setUserId(nil as String?)
        
        // Clear all caches
        TweetCacheManager.shared.clearAllCache()
        ImageCacheManager.shared.clearAllCache()
        ChatCacheManager.shared.clearAllCache()
        Task { @MainActor in
            SharedAssetCache.shared.clearCache()
        }
        
        // Reset appUser to guest user
        let guestUser = User.getInstance(mid: Constants.GUEST_ID)
        await MainActor.run {
            guestUser.baseUrl = appUser.baseUrl
            guestUser.followingList = Gadget.getAlphaIds()
            self.appUser = guestUser
        }
        
        // Fetch alphaId user for guest and notify FollowingsTweetView
        Task {
            await fetchAlphaIdUserForGuest()
        }
    }
    
    /*
     Get the UserId list of followers or followings of given user.
     */
    func getListByType(
        user: User,
        entry: UserContentType
    ) async throws -> [String] {
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
        ]
        guard let client = user.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }

        guard let response = client.invoke("runMApp", withArgs: [entry.rawValue, params]) as? [[String: Any]] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "getFollows: No response"])
        }
        
        let sorted = response.sorted {
            (lhs, rhs) in
            let lval = (lhs["value"] as? Int) ?? 0
            let rval = (rhs["value"] as? Int) ?? 0
            return lval > rval
        }
        return sorted.compactMap { $0["field"] as? String }
    }
    
    /**
     * Get a list of users that the given user is following, sorted by timestamp when followed.
     * For guest users, returns alpha IDs as fallback.
     */
    func getFollowings(user: User) async throws -> [MimeiId] {
        let entry = "get_followings_sorted"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid
        ]
        
        do {
            guard let client = user.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "getFollowings: No response"])
            }
            
            let sorted = response.sorted { (lhs, rhs) in
                let lval = (lhs["value"] as? Int) ?? 0
                let rval = (rhs["value"] as? Int) ?? 0
                return lval > rval
            }
            return sorted.compactMap { $0["field"] as? String }
        } catch {
            print("DEBUG: [HproseInstance] getFollowings error: \(error)")
            return Gadget.getAlphaIds()
        }
    }
    
    /**
     * Check if the app user is in the target user's blacklist
     * @param targetUserId The user ID to check against
     * @return true if app user is blacklisted, false otherwise
     */
    func isAppUserBlacklisted(by targetUserId: MimeiId) async -> Bool {
        do {
            guard let targetUser = try await fetchUser(targetUserId) else {
                print("DEBUG: [HproseInstance] Target user not found: \(targetUserId)")
                return false
            }
            let blackList = (try? await getListByType(user: targetUser, entry: .BLACK_LIST)) ?? []
            return blackList.contains(appUser.mid)
        } catch {
            print("DEBUG: [HproseInstance] Error checking blacklist for user \(targetUserId): \(error)")
            return false
        }
    }
    
    /**
     * Populate fans and following lists for a given user
     */
    func populateUserLists(user: User) async {
        do {
            // Get followings (users that the user is following)
            let followings = try await getFollowings(user: user)
            await MainActor.run {
                user.followingList = followings
            }
            print("DEBUG: [HproseInstance] Populated followingList for user \(user.mid) with \(followings.count) users")
            
            // Get fans (users who are following the user)
            if let fans = try await getFans(user: user) {
                await MainActor.run {
                    user.fansList = fans
                }
                print("DEBUG: [HproseInstance] Populated fansList for user \(user.mid) with \(fans.count) users")
            } else {
                print("DEBUG: [HproseInstance] No fans found for user \(user.mid)")
            }
        } catch {
            print("DEBUG: [HproseInstance] Error populating fans/following lists for user \(user.mid): \(error)")
        }
    }
    
    /**
     * Get a list of users who are following the given user, sorted by timestamp when they started following.
     * Returns nil for guest users.
     */
    func getFans(user: User) async throws -> [MimeiId]? {
        let entry = "get_followers_sorted"
        let params = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid
        ]
        
        do {
            guard let client = user.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "getFans: No response"])
            }
            
            let sorted = response.sorted { (lhs, rhs) in
                let lval = (lhs["value"] as? Int) ?? 0
                let rval = (rhs["value"] as? Int) ?? 0
                return lval > rval
            }
            return sorted.compactMap { $0["field"] as? String }
        } catch {
            print("DEBUG: [HproseInstance] getFans error: \(error)")
            return nil
        }
    }
    
    func getUserTweetsByType(
        user: User,
        type: UserContentType,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        print("DEBUG: [HproseInstance] getUserTweetsByType called - user: \(user.mid), type: \(type.rawValue), page: \(pageNumber), size: \(pageSize)")
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
        print("DEBUG: [HproseInstance] getUserTweetsByType params: \(params)")
        
        guard var client = user.hproseClient else {
            print("DEBUG: [HproseInstance] getUserTweetsByType - Client not initialized for user: \(user.mid)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        
        var newClient: HproseClient? = nil
        if let baseUrl = user.baseUrl, baseUrl != appUser.baseUrl {
            print("DEBUG: [HproseInstance] getUserTweetsByType - Creating new client for different baseUrl: \(baseUrl)")
            let newHproseClient = HproseHttpClient()
            newHproseClient.timeout = 300
            newHproseClient.uri = "\(baseUrl)/webapi/"
            client = newHproseClient
            newClient = newHproseClient
        }
        
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]?] else {
            newClient?.close()
            print("DEBUG: [HproseInstance] getUserTweetsByType - Invalid response format")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserTweetsByType"])
        }
        
        print("DEBUG: [HproseInstance] getUserTweetsByType - Got response with \(response.count) items")
        
        var tweetsWithAuthors: [Tweet?] = []
        for (index, dict) in response.enumerated() {
            if let item = dict {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: item) }
                    if (tweet.author == nil) {
                        tweet.author = try? await fetchUser(tweet.authorId)
                    }
                    // Don't cache tweets from bookmarks/favorites - only cache from main feed
                    tweetsWithAuthors.append(tweet)
                    print("DEBUG: [HproseInstance] getUserTweetsByType - Successfully processed tweet \(index): \(tweet.mid)")
                } catch {
                    print("DEBUG: [HproseInstance] getUserTweetsByType - Error processing tweet \(index): \(error)")
                    tweetsWithAuthors.append(nil)
                }
            } else {
                print("DEBUG: [HproseInstance] getUserTweetsByType - Item \(index) is nil")
                tweetsWithAuthors.append(nil)
            }
        }
        
        newClient?.close()
        
        // Sort tweets in descending order by timestamp (most recent first)
        let sortedTweets = tweetsWithAuthors.sorted { tweet1, tweet2 in
            guard let t1 = tweet1, let t2 = tweet2 else {
                // Put non-nil tweets before nil tweets
                return tweet1 != nil && tweet2 == nil
            }
            return t1.timestamp > t2.timestamp
        }
        
        print("DEBUG: [HproseInstance] getUserTweetsByType - Returning \(sortedTweets.count) tweets, valid: \(sortedTweets.compactMap { $0 }.count), sorted by timestamp (descending)")
        return sortedTweets
    }
    
    /**
     * Called when appUser clicks the Follow button.
     * @param followedId is the user that appUser is following or unfollowing.
     * */
    func toggleFollowing(
        followingId: MimeiId
    )  async throws -> Bool? {
        // Check if app user is blacklisted by the target user
        guard let targetUser = try await fetchUser(followingId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Target user not found"])
        }
        if targetUser.isUserBlacklisted(appUser.mid) {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "You cannot follow this user because you are blocked"])
        }
        
        return try await withRetry {
            let entry = "toggle_following"
            let params = [
                "aid": appId,
                "ver": "last",
                "followingid": followingId,
                "userid": appUser.mid,
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? Bool else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFollowing: No response"])
            }
            return response
        }
    }
    
    /*
     Return an updated tweet object after toggling favorite status of the tweet by appUser.
     */
    func toggleFavorite(_ tweet: Tweet) async throws -> (Tweet?, User?) {
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
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleFavorite: Invalid response"])
            }
            
            // Check if the operation was successful
            guard let success = response["success"] as? Bool, success else {
                let errorMessage = response["error"] as? String ?? "toggleFavorite: Operation failed"
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
            
            var updatedUser: User?
            var updatedTweet: Tweet?
            
            // Parse updated user
            if let userDict = response["user"] as? [String: Any] {
                updatedUser = try User.from(dict: userDict)
            }
            
            // Parse updated tweet
            if let tweetDict = response["tweet"] as? [String: Any] {
                updatedTweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                // Cache the updated tweet for main feed
                TweetCacheManager.shared.updateTweetInAppUserCaches(updatedTweet!, appUserId: appUser.mid)
            }
            
            return (updatedTweet, updatedUser)
        }
    }
    
    func toggleBookmark(_ tweet: Tweet) async throws -> (Tweet?, User?)  {
        try await withRetry {
            let entry = "toggle_bookmark"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.mid,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
            }
            guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "toggleBookmark: Invalid response"])
            }
            
            // Check if the operation was successful
            guard let success = response["success"] as? Bool, success else {
                let errorMessage = response["error"] as? String ?? "toggleBookmark: Operation failed"
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
            
            var updatedUser: User?
            var updatedTweet: Tweet?
            
            // Parse updated user
            if let userDict = response["user"] as? [String: Any] {
                updatedUser = try User.from(dict: userDict)
            }
            
            // Parse updated tweet
            if let tweetDict = response["tweet"] as? [String: Any] {
                updatedTweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                // Cache the updated tweet for main feed
                TweetCacheManager.shared.updateTweetInAppUserCaches(updatedTweet!, appUserId: appUser.mid)
            }
            
            return (updatedTweet, updatedUser)
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
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "retweet: Upload failed"])
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
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        if let tweetDict = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] {
            try await MainActor.run { try tweet.update(from: tweetDict) }
            // Cache the updated tweet for main feed
            TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: appUser.mid)
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "updateRetweetCount: No response"])
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
            "userid": appUser.mid,
            "tweetid": tweetId
        ]
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: return the tweet ID
            guard let deletedTweetId = response["tweetid"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteTweet: Success response missing tweet ID"])
            }
            return deletedTweetId
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown tweet deletion error"
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
        
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        // Check if app user is blacklisted by the tweet author
        if let tweetAuthor = tweet.author {
            if tweetAuthor.isUserBlacklisted(appUser.mid) {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "You cannot comment on this tweet because you are blocked by the author"])
            }
        }
        
        // Wait for writableUrl to be resolved
        let resolvedUrl = try await appUser.resolveWritableUrl()
        guard resolvedUrl != nil else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve writable URL"])
        }
        
        guard let uploadClient = appUser.uploadClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload client not available"])
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
        guard let response = uploadClient.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: extract comment ID and count
            guard let commentId = response["mid"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Success response missing comment ID"])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment: Success response missing comment count"])
            }
            
            await MainActor.run {
                comment.mid = commentId
                comment.author = appUser
                tweet.commentCount = count
            }
            // Cache the updated tweet for main feed
            TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: appUser.mid)
            
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
                
                // For comments, we should NOT post newTweetCreated notification
                // Comments should only appear in comment sections, not in the main feed
                print("[HproseInstance] Comment created with retweetId: \(retweetId), but NOT posting newTweetCreated notification")
                
                // Only post the comment notification on main thread
                await MainActor.run {
                    print("[HproseInstance] Posting newCommentAdded notification")
                    print("[HproseInstance] New comment mid: \(comment.mid)")
                    print("[HproseInstance] New retweet ID: \(retweetId)")
                    print("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                    
                    NotificationCenter.default.post(
                        name: .newCommentAdded,
                        object: nil,
                        userInfo: ["comment": comment, "parentTweetId": tweet.mid]
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
                        userInfo: ["comment": comment, "parentTweetId": tweet.mid]
                    )
                }
                
                return comment
            }
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown comment upload error"
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
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
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response format"])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Invalid response format: missing success field"])
        }
        
        if success {
            // Success case: return the response with commentId and count
            guard let deletedCommentId = response["commentId"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Success response missing comment ID"])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "deleteComment: Success response missing comment count"])
            }
            
            return [
                "commentId": deletedCommentId,
                "count": count
            ]
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown comment deletion error"
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil,
        noResample: Bool = false,
        progressCallback: ((String, Int) -> Void)? = nil
    ) async throws -> (MimeiFileType?, String?) {
        _ = try await appUser.resolveWritableUrl()
        print("Starting upload to IPFS: typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil"), noResample=\(noResample)")
        
        // Force refresh upload service to ensure we have a fresh connection
        appUser.refreshUploadClient()
        
        // Use MediaProcessor to determine media type and handle upload
        let mediaProcessor = MediaProcessor()
        return try await mediaProcessor.processAndUpload(
            data: data,
            typeIdentifier: typeIdentifier,
            fileName: fileName,
            referenceId: referenceId,
            noResample: noResample,
            appUser: appUser,
            appId: appId,
            progressCallback: progressCallback
        )
    }
    
    // MARK: - Media Processing
    /// Consolidated media processing class that handles all media-related operations (images, videos, audio, documents)
    class MediaProcessor {
        
        /// Robust file type detection utility using multiple methods
        private class FileTypeDetector {
            
            /// Comprehensive file signature database
            private static let fileSignatures: [(signature: [UInt8], mediaType: MediaType, name: String)] = [
                // Image formats
                ([0xFF, 0xD8, 0xFF], .image, "JPEG"),
                ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, "PNG"),
                ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], .image, "GIF87a"),
                ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], .image, "GIF89a"),
                ([0x42, 0x4D], .image, "BMP"),
                ([0x49, 0x49, 0x2A, 0x00], .image, "TIFF (Intel)"),
                ([0x4D, 0x4D, 0x00, 0x2A], .image, "TIFF (Motorola)"),
                ([0x52, 0x49, 0x46, 0x46], .image, "WebP/RIFF"), // Will be refined below
                
                // Video formats - MP4/MOV family
                ([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70], .video, "MP4/MOV"), // Will be refined below
                ([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70], .video, "MP4/MOV"), // Will be refined below
                ([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70], .video, "MP4/MOV"), // Will be refined below
                ([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70], .video, "MP4/MOV"), // Will be refined below
                
                // Other video formats
                ([0x1A, 0x45, 0xDF, 0xA3], .video, "MKV/WebM"),
                ([0x46, 0x4C, 0x56], .video, "FLV"),
                ([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11], .video, "WMV/ASF"),
                ([0x52, 0x49, 0x46, 0x46], .video, "AVI"), // Will be refined below
                
                // Audio formats
                ([0x49, 0x44, 0x33], .audio, "MP3 (ID3)"),
                ([0xFF, 0xFB], .audio, "MP3 (MPEG)"),
                ([0xFF, 0xF3], .audio, "MP3 (MPEG)"),
                ([0xFF, 0xF2], .audio, "MP3 (MPEG)"),
                ([0x66, 0x4C, 0x61, 0x43], .audio, "FLAC"),
                ([0x4F, 0x67, 0x67, 0x53], .audio, "OGG"),
                
                // Document formats
                ([0x25, 0x50, 0x44, 0x46], .pdf, "PDF"),
                ([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], .word, "Office Document"), // Will be refined below
                ([0x50, 0x4B, 0x03, 0x04], .zip, "ZIP"),
                ([0x50, 0x4B, 0x05, 0x06], .zip, "ZIP"),
                ([0x50, 0x4B, 0x07, 0x08], .zip, "ZIP"),
                
                // Text formats
                ([0x3C, 0x21, 0x44, 0x4F, 0x43, 0x54, 0x59, 0x50, 0x45], .html, "HTML"),
                ([0x3C, 0x68, 0x74, 0x6D, 0x6C], .html, "HTML"),
                ([0x3C, 0x48, 0x54, 0x4D, 0x4C], .html, "HTML"),
            ]
            
            /// Detect file type using multiple methods
            static func detectFromData(_ data: Data) async -> MediaType {
                print("DEBUG: [FILE TYPE] Starting file type detection for \(data.count) bytes")
                
                // Method 1: Try iOS UniformTypeIdentifiers first (most reliable)
                if let mediaType = detectUsingUTType(data) {
                    print("DEBUG: [FILE TYPE] Detected using UTType: \(mediaType.rawValue)")
                    return mediaType
                }
                
                // Method 2: Try comprehensive file signature detection
                if let mediaType = detectUsingFileSignatures(data) {
                    print("DEBUG: [FILE TYPE] Detected using file signatures: \(mediaType.rawValue)")
                    return mediaType
                }
                
                // Method 3: Try AVFoundation for media files
                if let mediaType = await detectUsingAVFoundation(data) {
                    print("DEBUG: [FILE TYPE] Detected using AVFoundation: \(mediaType.rawValue)")
                    return mediaType
                }
                
                print("DEBUG: [FILE TYPE] Could not determine file type")
                return .unknown
            }
            
            /// Detect using iOS UniformTypeIdentifiers
            private static func detectUsingUTType(_ data: Data) -> MediaType? {
                guard data.count >= 512 else { return nil }
                
                // Create a temporary file to use UTType detection
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
                
                do {
                    try data.write(to: tempURL)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    
                    // Try to determine the UTI
                    let resourceValues = try tempURL.resourceValues(forKeys: [.typeIdentifierKey])
                    if let typeIdentifier = resourceValues.typeIdentifier {
                        print("DEBUG: [FILE TYPE] UTType identifier: \(typeIdentifier)")
                        
                        // Map UTI to MediaType
                        if typeIdentifier.hasPrefix("public.image") || 
                           typeIdentifier.contains("jpeg") || 
                           typeIdentifier.contains("png") || 
                           typeIdentifier.contains("gif") || 
                           typeIdentifier.contains("heic") || 
                           typeIdentifier.contains("heif") ||
                           typeIdentifier.contains("tiff") ||
                           typeIdentifier.contains("bmp") ||
                           typeIdentifier.contains("webp") {
                            return .image
                        } else if typeIdentifier.hasPrefix("public.movie") || 
                                  typeIdentifier.contains("quicktime") || 
                                  typeIdentifier.contains("movie") ||
                                  typeIdentifier.contains("video") ||
                                  typeIdentifier.contains("mp4") ||
                                  typeIdentifier.contains("mov") ||
                                  typeIdentifier.contains("m4v") ||
                                  typeIdentifier.contains("avi") ||
                                  typeIdentifier.contains("mkv") ||
                                  typeIdentifier.contains("wmv") ||
                                  typeIdentifier.contains("flv") ||
                                  typeIdentifier.contains("webm") {
                            return .video
                        } else if typeIdentifier.hasPrefix("public.audio") || 
                                  typeIdentifier.contains("audio") ||
                                  typeIdentifier.contains("mp3") ||
                                  typeIdentifier.contains("m4a") ||
                                  typeIdentifier.contains("wav") ||
                                  typeIdentifier.contains("aac") ||
                                  typeIdentifier.contains("flac") ||
                                  typeIdentifier.contains("ogg") {
                            return .audio
                        } else if typeIdentifier == "public.composite-content" || 
                                  typeIdentifier.contains("pdf") {
                            return .pdf
                        } else if typeIdentifier == "public.zip-archive" || 
                                  typeIdentifier.contains("zip") {
                            return .zip
                        }
                    }
                } catch {
                    print("DEBUG: [FILE TYPE] UTType detection failed: \(error)")
                }
                
                return nil
            }
            
            /// Detect using comprehensive file signatures
            private static func detectUsingFileSignatures(_ data: Data) -> MediaType? {
                guard data.count >= 12 else { return nil }
                
                let bytes = [UInt8](data.prefix(12))
                
                // Check basic signatures first
                for (signature, mediaType, name) in fileSignatures {
                    if bytes.starts(with: signature) {
                        print("DEBUG: [FILE TYPE] Found signature for \(name)")
                        
                        // Refine detection for complex formats
                        switch mediaType {
                        case .image where name == "WebP/RIFF":
                            return refineRIFFDetection(data, bytes)
                        case .video where name == "MP4/MOV":
                            return refineMP4Detection(data, bytes)
                        case .video where name == "AVI":
                            return refineAVIDetection(data, bytes)
                        case .word where name == "Office Document":
                            return refineOfficeDetection(data, bytes)
                        default:
                            return mediaType
                        }
                    }
                }
                
                // Special handling for HEIC/HEIF
                if bytes.count >= 12 {
                    let ftypString = String(bytes: bytes[4...11], encoding: .ascii) ?? ""
                    if ftypString.hasPrefix("ftyp") && (ftypString.contains("heic") || ftypString.contains("heix") || 
                                                       ftypString.contains("heis") || ftypString.contains("heim") ||
                                                       ftypString.contains("hevc") || ftypString.contains("hevx")) {
                        print("DEBUG: [FILE TYPE] Detected HEIC/HEIF from ftyp")
                        return .image
                    }
                }
                
                // Check for plain text
                if data.count >= 512 {
                    let textCheck = data.prefix(512)
                    if !textCheck.contains(0) && textCheck.allSatisfy({ $0 >= 32 || $0 == 9 || $0 == 10 || $0 == 13 }) {
                        print("DEBUG: [FILE TYPE] Detected as plain text")
                        return .txt
                    }
                }
                
                return nil
            }
            
            /// Detect using AVFoundation for media files
            private static func detectUsingAVFoundation(_ data: Data) async -> MediaType? {
                guard data.count >= 1024 else { return nil }
                
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
                
                do {
                    try data.write(to: tempURL)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    
                    let asset = AVURLAsset(url: tempURL)
                    
                    // Check if it has video tracks
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if !videoTracks.isEmpty {
                        print("DEBUG: [FILE TYPE] AVFoundation detected video tracks")
                        return .video
                    }
                    
                    // Check if it has audio tracks
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    if !audioTracks.isEmpty {
                        print("DEBUG: [FILE TYPE] AVFoundation detected audio tracks")
                        return .audio
                    }
                    
                } catch {
                    print("DEBUG: [FILE TYPE] AVFoundation detection failed: \(error)")
                }
                
                return nil
            }
            
            // MARK: - Refinement Methods
            
            private static func refineRIFFDetection(_ data: Data, _ bytes: [UInt8]) -> MediaType? {
                guard bytes.count >= 12 else { return .image }
                
                let format = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
                switch format {
                case "WEBP":
                    return .image
                case "AVI ":
                    return .video
                case "WAVE":
                    return .audio
                default:
                    return .image // Default to image for other RIFF formats
                }
            }
            
            private static func refineMP4Detection(_ data: Data, _ bytes: [UInt8]) -> MediaType? {
                guard bytes.count >= 12 else { return .video }
                
                let codecString = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
                print("DEBUG: [FILE TYPE] MP4 codec string: \(codecString)")
                
                // Video codecs
                if codecString.contains("mp4") || codecString.contains("M4V") || codecString.contains("isom") ||
                   codecString.contains("iso2") || codecString.contains("avc1") || codecString.contains("mp41") ||
                   codecString.contains("mp42") || codecString.contains("3gp") || codecString.contains("qt") ||
                   codecString.contains("M4A") || codecString.contains("M4B") || codecString.contains("M4P") {
                    return .video
                }
                
                // Audio codecs
                if codecString.contains("M4A") || codecString.contains("M4B") || codecString.contains("M4P") {
                    return .audio
                }
                
                return .video // Default to video for MP4 containers
            }
            
            private static func refineAVIDetection(_ data: Data, _ bytes: [UInt8]) -> MediaType? {
                guard bytes.count >= 12 else { return .video }
                
                let format = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
                return format == "AVI " ? .video : .video // Default to video
            }
            
            private static func refineOfficeDetection(_ data: Data, _ bytes: [UInt8]) -> MediaType? {
                guard data.count >= 512 else { return .word }
                
                let oleHeader = data.prefix(512)
                if let oleString = String(data: oleHeader, encoding: .ascii) {
                    if oleString.contains("WordDocument") {
                        return .word
                    } else if oleString.contains("Workbook") || oleString.contains("Excel") {
                        return .excel
                    } else if oleString.contains("PowerPoint") {
                        return .ppt
                    }
                }
                return .word // Default to Word for OLE files
            }
        }
        
        /// Process and upload media files (images, videos, audio, documents)
        func processAndUpload(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            
            // Determine media type
            let mediaType = await detectMediaType(from: typeIdentifier, fileName: fileName, data: data)
            print("DEBUG: Detected media type: \(mediaType.rawValue)")
            
            // Route to appropriate media type handler
            switch mediaType {
            case .video:
                print("Processing video with backend conversion")
                return try await processVideo(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    noResample: noResample,
                    appUser: appUser,
                    progressCallback: progressCallback
                )
            case .image:
                print("Processing image file")
                return try await processImage(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    noResample: noResample,
                    appUser: appUser,
                    appId: appId,
                    progressCallback: progressCallback
                )
            case .audio:
                print("Processing audio file")
                return try await processAudio(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    appUser: appUser,
                    appId: appId,
                    progressCallback: progressCallback
                )
            default:
                print("Processing document file: \(mediaType.rawValue)")
                return try await processDocument(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    mediaType: mediaType,
                    appUser: appUser,
                    appId: appId,
                    progressCallback: progressCallback
                )
            }
        }
        
        // MARK: - Media Type Specific Methods
        
        /// Process and upload image files
        func processImage(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Processing image file")
            let result = try await uploadRegularFile(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId,
                mediaType: .image,
                appUser: appUser,
                appId: appId
            )
            return (result, nil)
        }
        
        /// Process and upload video files
        func processVideo(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Processing video file")
            return try await uploadVideoForBackendConversion(
                data: data,
                fileName: fileName,
                referenceId: referenceId,
                noResample: noResample,
                appUser: appUser,
                progressCallback: progressCallback
            )
        }
        
        /// Process and upload audio files
        func processAudio(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Processing audio file")
            let result = try await uploadRegularFile(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId,
                mediaType: .audio,
                appUser: appUser,
                appId: appId
            )
            return (result, nil)
        }
        
        /// Process and upload document files (PDF, Word, Excel, etc.)
        func processDocument(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            mediaType: MediaType,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Processing document file: \(mediaType.rawValue)")
            let result = try await uploadRegularFile(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId,
                mediaType: mediaType,
                appUser: appUser,
                appId: appId
            )
            return (result, nil)
        }
        
        /// Detect media type from type identifier, filename, and file header
        func detectMediaType(from typeIdentifier: String, fileName: String?, data: Data) async -> MediaType {
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
            case "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp":
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
            case "xls", "xlsx":
                return .excel
            case "ppt", "pptx":
                return .ppt
            case "txt":
                return .txt
            case "html", "htm":
                return .html
            default:
                // If type identifier and file extension cannot determine the type,
                // try to read file header to figure out the file type
                print("DEBUG: Type identifier and file extension cannot determine file type, analyzing file header...")
                let detectedType = await FileTypeDetector.detectFromData(data)
                print("DEBUG: File header analysis detected type: \(detectedType.rawValue)")
                return detectedType
            }
        }
        
        /// Upload video to backend for conversion
        private func uploadVideoForBackendConversion(
            data: Data,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Uploading original video to backend for conversion, data size: \(data.count) bytes")
            
            // Always resolve writableUrl to ensure we have the correct IP address
            let writableUrl = try await appUser.resolveWritableUrl()
            guard let writableUrl = writableUrl else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available"])
            }
            
            // For HLS video uploads, use the cloud drive port instead of writableUrl port
            let host = writableUrl.host ?? HproseInstance.baseUrl.host ?? "localhost"
            let cloudPort = appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
            let cloudBaseURL = URL(string: "http://\(host):\(cloudPort)")!
            let convertVideoURL = cloudBaseURL.appendingPathComponent("convert-video").absoluteString
            print("DEBUG: Constructed convert-video URL: \(convertVideoURL)")
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
            return try await uploadWithRetry(request: request, data: data, fileName: fileName, aspectRatio: aspectRatio, progressCallback: progressCallback)
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
            
            // Always resolve writableUrl to ensure we have the correct IP address
            _ = try await appUser.resolveWritableUrl()
            guard let uploadClient = appUser.uploadClient else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload client not available"])
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
                let response = try await uploadChunk(
                    uploadClient: uploadClient,
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
            
            let finalResponse = uploadClient.invoke("runMApp", withArgs: ["upload_ipfs", request])
            
            guard let cid = finalResponse as? String else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CID from final upload response"])
            }
            
            // Get file attributes
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
            
            // Get aspect ratio for videos and images
            var aspectRatio: Float?
            if mediaType == .video {
                aspectRatio = try await getVideoAspectRatio(from: data)
            } else if mediaType == .image {
                aspectRatio = try await getImageAspectRatio(from: data)
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
        
        /// Get image aspect ratio from data
        private func getImageAspectRatio(from data: Data) async throws -> Float? {
            guard let image = UIImage(data: data) else {
                print("Warning: Could not create UIImage from data")
                return nil
            }
            
            let size = image.size
            guard size.height > 0 else {
                print("Warning: Image height is zero")
                return nil
            }
            
            let aspectRatio = Float(size.width / size.height)
            print("DEBUG: Image aspect ratio: \(aspectRatio) (size: \(size))")
            return aspectRatio
            
        }
        
        /// Upload with retry mechanism for video conversion using new async job-based API
        private func uploadWithRetry(
            request: URLRequest,
            data: Data,
            fileName: String?,
            aspectRatio: Float?,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            // Create a custom URLSession with longer timeout for large uploads
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600  // 5 minutes
            config.timeoutIntervalForResource = 600 // 10 minutes
            let session = URLSession(configuration: config)
            
            print("DEBUG: Video upload attempt")
            progressCallback?("Uploading video...", 10)
            let (responseData, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("DEBUG: HTTP status code: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    // Parse initial response to get job ID
                    let jobId = try parseVideoUploadResponse(responseData: responseData)
                    print("DEBUG: Video upload started, job ID: \(jobId)")
                    progressCallback?("Video uploaded, starting conversion...", 20)
                    
                    // Poll for job completion
                    let result = try await pollVideoConversionStatus(
                        jobId: jobId,
                        baseURL: request.url?.deletingLastPathComponent(),
                        data: data,
                        fileName: fileName,
                        aspectRatio: aspectRatio,
                        progressCallback: progressCallback
                    )
                    return (result, jobId)
                } else if httpResponse.statusCode == 400 {
                    // Bad request - don't retry, parse error message
                    let errorMessage = String(data: responseData, encoding: .utf8) ?? "Bad request"
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Bad request: \(errorMessage)"])
                } else if httpResponse.statusCode == 413 {
                    // Payload too large - don't retry
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Video file too large for processing"])
                } else if httpResponse.statusCode >= 500 {
                    // Server error - throw error
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error (HTTP \(httpResponse.statusCode))"])
                } else {
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) error"])
                }
            } else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }
        }
        
        /// Parse video upload response to get job ID
        private func parseVideoUploadResponse(responseData: Data) throws -> String {
            guard let responseString = String(data: responseData, encoding: .utf8) else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
            }
            
            print("DEBUG: Upload response: \(responseString)")
            
            do {
                guard let jsonData = responseString.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
                }
                
                if let success = json["success"] as? Bool, success {
                    if let jobId = json["jobId"] as? String, !jobId.isEmpty {
                        print("DEBUG: Video upload started, job ID: \(jobId)")
                        return jobId
                    } else {
                        throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No job ID in response"])
                    }
                } else {
                    let message = json["message"] as? String ?? "Unknown error"
                    print("DEBUG: Server reported error: \(message)")
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server error: \(message)"])
                }
            } catch {
                print("DEBUG: Failed to parse upload response: \(error)")
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse upload response: \(error.localizedDescription)"])
            }
        }
        
        /// Poll video conversion status until completion
        func pollVideoConversionStatus(
            jobId: String,
            baseURL: URL?,
            data: Data,
            fileName: String?,
            aspectRatio: Float?,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> MimeiFileType? {
            guard let baseURL = baseURL else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL for status polling"])
            }
            
            // For HLS video status polling, use the cloud drive port
            let host = baseURL.host ?? HproseInstance.baseUrl.host ?? "localhost"
            let cloudPort = HproseInstance.shared.appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
            let cloudBaseURL = URL(string: "http://\(host):\(cloudPort)")!
            let statusURL = cloudBaseURL.appendingPathComponent("convert-video/status/\(jobId)")
            print("DEBUG: Polling status at: \(statusURL)")
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30  // 30 seconds for status checks
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)
            
            var attempts = 0
            let maxAttempts = 120 // 10 minutes with 5-second intervals
            let pollInterval: TimeInterval = 5.0
            
            while attempts < maxAttempts {
                attempts += 1
                print("DEBUG: Status check attempt \(attempts)/\(maxAttempts)")
                
                do {
                    let (responseData, response) = try await session.data(from: statusURL)
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            let statusResult = try parseVideoStatusResponse(responseData: responseData)
                            
                            switch statusResult.status {
                            case "completed":
                                print("DEBUG: Video conversion completed, CID: \(statusResult.cid ?? "unknown")")
                                progressCallback?("Video conversion completed!", 100)
                                return MimeiFileType(
                                    mid: statusResult.cid ?? "",
                                    mediaType: .hls_video,
                                    size: Int64(data.count),
                                    fileName: fileName,
                                    timestamp: Date(),
                                    aspectRatio: aspectRatio,
                                    url: nil
                                )
                                
                            case "failed":
                                let errorMessage = statusResult.message ?? "Video conversion failed"
                                print("DEBUG: Video conversion failed: \(errorMessage)")
                                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video conversion failed: \(errorMessage)"])
                                
                            case "uploading", "processing":
                                let message = statusResult.message ?? "Processing..."
                                print("DEBUG: Video conversion in progress: \(message) (\(statusResult.progress)%)")
                                progressCallback?(message, statusResult.progress)
                                // Continue polling
                                
                            default:
                                print("DEBUG: Unknown status: \(statusResult.status)")
                                // Continue polling
                            }
                        } else if httpResponse.statusCode == 404 {
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Job not found"])
                        } else {
                            print("DEBUG: Status check failed with HTTP \(httpResponse.statusCode)")
                            // Continue polling on server errors
                        }
                    }
                } catch {
                    print("DEBUG: Status check error: \(error)")
                    // Continue polling on network errors
                }
                
                // Wait before next poll
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            
            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video conversion timed out after \(maxAttempts * Int(pollInterval)) seconds"])
        }
        
        /// Parse video status response
        private func parseVideoStatusResponse(responseData: Data) throws -> VideoConversionStatus {
            guard let responseString = String(data: responseData, encoding: .utf8) else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid status response encoding"])
            }
            
            print("DEBUG: Status response: \(responseString)")
            
            do {
                guard let jsonData = responseString.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON status response"])
                }
                
                if let success = json["success"] as? Bool, success {
                    let status = json["status"] as? String ?? "unknown"
                    let progress = json["progress"] as? Int ?? 0
                    let message = json["message"] as? String
                    let cid = json["cid"] as? String
                    
                    return VideoConversionStatus(
                        status: status,
                        progress: progress,
                        message: message,
                        cid: cid
                    )
                } else {
                    let message = json["message"] as? String ?? "Unknown error"
                    throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Status check failed: \(message)"])
                }
            } catch {
                print("DEBUG: Failed to parse status response: \(error)")
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse status response: \(error.localizedDescription)"])
            }
        }
        
        /// Parse video conversion response (legacy method for backward compatibility)
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
                            mediaType: .hls_video,
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
        
        /// Upload chunk for regular files (no retry)
        private func uploadChunk(
            uploadClient: HproseClient,
            request: [String: Any],
            data: NSData,
            chunkNumber: Int
        ) async throws -> Any {
            let response = uploadClient.invoke("runMApp", withArgs: ["upload_ipfs", request, [data]]) as Any
            return response
        }
    }
    
    // MARK: - Private Methods
    private func fetchHTML(from urlString: String) async throws -> String {
        // Extract MimeiId from URL if possible (assuming it's in the URL path)
        if let url = URL(string: urlString),
           let mimeiId = extractMimeiIdFromURL(url) {
            // Check if this resource is blacklisted
            if blackList.isBlacklisted(mimeiId) {
                print("[HproseInstance] Skipping blacklisted resource: \(mimeiId)")
                throw URLError(.badServerResponse)
            }
        }
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let htmlString = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            
            // Record success if we can extract MimeiId
            if let mimeiId = extractMimeiIdFromURL(url) {
                blackList.recordSuccess(mimeiId)
            }
            
            return htmlString
        } catch {
            // Record failure if we can extract MimeiId
            if let url = URL(string: urlString),
               let mimeiId = extractMimeiIdFromURL(url) {
                blackList.recordFailure(mimeiId)
            }
            throw error
        }
    }
    
    /// Extract MimeiId from URL if present
    private func extractMimeiIdFromURL(_ url: URL) -> MimeiId? {
        // Try to extract MimeiId from URL path components
        let pathComponents = url.pathComponents
        for component in pathComponents {
            // Check if component looks like a MimeiId (you may need to adjust this logic)
            if component.count > 10 && component.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil {
                return MimeiId(component)
            }
        }
        return nil
    }
    
    /// Access a resource by MimeiId with BlackList integration
    func accessResource(mimeiId: MimeiId, url: String) async throws -> Data {
        // Check if this resource is blacklisted
        if blackList.isBlacklisted(mimeiId) {
            print("[HproseInstance] Skipping blacklisted resource: \(mimeiId)")
            throw URLError(.badServerResponse)
        }
        
        guard let resourceURL = URL(string: url) else {
            throw URLError(.badURL)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: resourceURL)
            // Record success
            blackList.recordSuccess(mimeiId)
            return data
        } catch {
            // Record failure
            blackList.recordFailure(mimeiId)
            throw error
        }
    }

    /// Process BlackList candidates (move eligible ones to blacklist)
    func processBlackListCandidates() {
        blackList.processCandidates()
    }
    
    /// Get BlackList statistics for debugging/monitoring
    func getBlackListStats() -> (candidates: Int, blacklisted: Int) {
        return blackList.getStats()
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
                if retryCount < 2 {
                    // Refresh appUser from server instead of full app reinitialization
                    try await refreshAppUserFromServer()
                }
            }
        }
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error: All retries failed."])
    }
    
    /// Refresh appUser from server without full app reinitialization
    private func refreshAppUserFromServer() async throws {
        print("DEBUG: [HproseInstance] Refreshing appUser from server...")
        
        guard !appUser.isGuest else {
            print("DEBUG: [HproseInstance] Skipping refresh for guest user")
            return
        }
        
        do {
            // Get provider IP for the current user
            guard let providerIp = try await getProviderIP(appUser.mid) else {
                print("DEBUG: [HproseInstance] No provider IP found for user: \(appUser.mid)")
                return
            }
            
            print("DEBUG: [HproseInstance] Refreshing user from provider IP: \(providerIp)")
            
            // Fetch updated user data from server
            if let refreshedUser = try await fetchUser(appUser.mid, baseUrl: "http://\(providerIp)") {
                // Update base URL if needed
                if HproseInstance.baseUrl.absoluteString != "http://\(providerIp)" {
                    HproseInstance.baseUrl = URL(string: "http://\(providerIp)")!
                    client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                }
                
                // Update appUser with refreshed data
                await MainActor.run {
                    refreshedUser.baseUrl = HproseInstance.baseUrl
                    self.appUser = refreshedUser
                    self._domainToShare = HproseInstance.baseUrl.absoluteString
                }
                
                print("DEBUG: [HproseInstance] Successfully refreshed appUser from server")
            } else {
                print("DEBUG: [HproseInstance] Failed to refresh user from server")
            }
        } catch {
            print("DEBUG: [HproseInstance] Error refreshing appUser: \(error)")
            // Don't throw here - let the retry continue with existing appUser
        }
    }
    
    // MARK: - Background Upload
    // Background task approach removed - using immediate upload with persistence instead
    
    // MARK: - Persistence and Retry
    struct PendingTweetUpload: Codable {
        let tweet: Tweet
        let itemData: [ItemData]
        let timestamp: Date
        let retryCount: Int
        let videoJobId: String? // Store job ID for video uploads
        
        struct ItemData: Codable {
            let identifier: String
            let typeIdentifier: String
            let data: Data
            let fileName: String
            let noResample: Bool
            let videoJobId: String? // Store job ID for individual video items
            
            init(identifier: String, typeIdentifier: String, data: Data, fileName: String, noResample: Bool = false, videoJobId: String? = nil) {
                self.identifier = identifier
                self.typeIdentifier = typeIdentifier
                self.data = data
                self.fileName = fileName
                self.noResample = noResample
                self.videoJobId = videoJobId
            }
        }
        
        init(tweet: Tweet, itemData: [ItemData], retryCount: Int = 0, videoJobId: String? = nil) {
            self.tweet = tweet
            self.itemData = itemData
            self.timestamp = Date()
            self.retryCount = retryCount
            self.videoJobId = videoJobId
        }
    }
    
    // Retry mechanism removed to prevent duplicate uploads
    // Keeping persistence for unfinished uploads only
    
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
            
            let rawResponse = appUser.hproseClient?.invoke("runMApp", withArgs: ["add_tweet", params])
            
            // Handle the JSON response format
            guard let responseDict = rawResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server"])
            }
            
            guard let success = responseDict["success"] as? Bool else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format: missing success field"])
            }
            
            if success {
                // Success case: extract the tweet ID
                guard let newTweetId = responseDict["mid"] as? String else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Success response missing tweet ID"])
                }
                
                let uploadedTweet = tweet
                uploadedTweet.mid = newTweetId
                uploadedTweet.author = try? await self.fetchUser(tweet.authorId)
                return uploadedTweet
            } else {
                // Failure case: extract error message
                let errorMessage = responseDict["message"] as? String ?? "Unknown upload error"
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
    }
    
    private func uploadItemPair(_ pair: [PendingTweetUpload.ItemData]) async throws -> [MimeiFileType] {
        let uploadTasks = pair.map { itemData in
            Task {
                let (result, _) = try await uploadToIPFS(
                    data: itemData.data,
                    typeIdentifier: itemData.typeIdentifier,
                    fileName: itemData.fileName,
                    noResample: itemData.noResample,
                    progressCallback: { message, progress in
                        print("DEBUG: Upload progress for \(itemData.fileName): \(message) (\(progress)%)")
                    }
                )
                return result
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
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment upload failure in pair"])
            }
            
            return uploadResults.compactMap { $0 }
        }
    }
    
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData)
        }
    }
    
    func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            var mutableMessage = message
            await self.uploadChatMessageWithPersistenceAndRetry(message: &mutableMessage, itemData: itemData)
        }
    }
    
    private func uploadTweetWithPersistenceAndRetry(tweet: Tweet, itemData: [PendingTweetUpload.ItemData], retryCount: Int = 0, videoJobId: String? = nil) async {
        // Save pending upload to disk for persistence
        let pendingUpload = PendingTweetUpload(tweet: tweet, itemData: itemData, retryCount: retryCount, videoJobId: videoJobId)
        await savePendingUpload(pendingUpload)
        
        do {
            // Upload attachments first (no retry)
            let (uploadedAttachments, _) = try await uploadAttachments(itemData: itemData)
            
            // Update tweet with uploaded attachments
            tweet.attachments = uploadedAttachments
            
            // Upload the tweet - this will handle retries internally via withRetry
            if let uploadedTweet = try await self.uploadTweet(tweet) {
                // Success - remove pending upload and notify
                await removePendingUpload()
                
                // Update user's tweet count and post notification
                await MainActor.run {
                    self.appUser.tweetCount = (self.appUser.tweetCount ?? 0) + 1
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload tweet"])
            }
        } catch {
            print("Error uploading tweet: \(error)")
            
            // Show toast error only after all retries have failed
            // The withRetry mechanism in uploadTweet() handles the retries internally
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .backgroundUploadFailed,
                    object: nil,
                    userInfo: ["error": error]
                )
            }
        }
    }
    
    private func uploadChatMessageWithPersistenceAndRetry(message: inout ChatMessage, itemData: [PendingTweetUpload.ItemData], retryCount: Int = 0) async {
        do {
            // Upload attachments first (no retry)
            let (uploadedAttachments, _) = try await uploadAttachments(itemData: itemData)
            
            // Update message with uploaded attachments
            message.attachments = uploadedAttachments
            
            // Send the message
            let resultMessage = try await self.sendMessage(receiptId: message.receiptId, message: message)
            
            if resultMessage.success == true {
                // Success - message will appear in chat automatically
                print("Chat message sent successfully: \(resultMessage.id)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: resultMessage.errorMsg ?? "Failed to send chat message"])
            }
        } catch {
            print("Error uploading chat message: \(error)")
            
            // No retry - the message will show with a failure icon
            // No need to post notification since the UI already handles failed messages
            print("Chat message upload failed")
        }
    }
    
    private func uploadAttachments(itemData: [PendingTweetUpload.ItemData]) async throws -> ([MimeiFileType], String?) {
        var uploadedAttachments: [MimeiFileType] = []
        var videoJobId: String? = nil
        
        // Check if we have any video items that need job ID tracking
        let hasVideoItems = itemData.contains { item in
            item.typeIdentifier.contains("video") || item.typeIdentifier.contains("movie")
        }
        
        if hasVideoItems {
            // Upload video items individually to track job IDs
            for item in itemData {
                do {
                    let (result, jobId) = try await uploadToIPFS(
                        data: item.data,
                        typeIdentifier: item.typeIdentifier,
                        fileName: item.fileName,
                        noResample: item.noResample,
                        progressCallback: { message, progress in
                            print("DEBUG: Upload progress for \(item.fileName): \(message) (\(progress)%)")
                        }
                    )
                    
                    if let fileType = result {
                        uploadedAttachments.append(fileType)
                    }
                    
                    // Store the job ID for video items
                    if let jobId = jobId {
                        videoJobId = jobId
                        print("DEBUG: Stored video job ID: \(jobId)")
                    }
                } catch {
                    print("Error uploading item \(item.fileName): \(error)")
                    throw error
                }
            }
        } else {
            // Use the existing pair upload for non-video items
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
        }
        
        if itemData.count != uploadedAttachments.count {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)"])
        }
        
        return (uploadedAttachments, videoJobId)
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
    
    // MARK: - Video Job Status Checking
    private func parseVideoStatusResponse(responseData: Data) throws -> VideoConversionStatus {
        guard let responseString = String(data: responseData, encoding: .utf8) else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
        }
        
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
            
            let status = json?["status"] as? String ?? "unknown"
            let progress = json?["progress"] as? Int ?? 0
            let message = json?["message"] as? String
            let cid = json?["cid"] as? String
            
            return VideoConversionStatus(
                status: status,
                progress: progress,
                message: message,
                cid: cid
            )
        } catch {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse video status response: \(error.localizedDescription)"])
        }
    }
    
    private func checkVideoJobStatus(jobId: String, baseURL: URL?) async -> VideoConversionStatus? {
        guard let baseURL = baseURL else { return nil }
        
        let statusURL = baseURL.appendingPathComponent("convert-video/status/\(jobId)")
        print("DEBUG: Checking video job status at: \(statusURL)")
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        
        do {
            let (responseData, response) = try await session.data(from: statusURL)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return try parseVideoStatusResponse(responseData: responseData)
                } else if httpResponse.statusCode == 404 {
                    print("DEBUG: Video job not found: \(jobId)")
                    return nil
                } else {
                    print("DEBUG: Video job status check failed with HTTP \(httpResponse.statusCode)")
                    return nil
                }
            }
        } catch {
            print("DEBUG: Video job status check error: \(error)")
        }
        
        return nil
    }
    
    /// Handle a completed video job by creating MimeiFileType and continuing tweet upload
    private func handleCompletedVideoJob(pendingUpload: PendingTweetUpload, cid: String?) async {
        guard let cid = cid, !cid.isEmpty else {
            print("DEBUG: No CID available for completed video job")
            // Fallback to re-upload
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
            return
        }
        
        // Find the video item and create MimeiFileType with the CID
        var uploadedAttachments: [MimeiFileType] = []
        var hasVideoItem = false
        
        for item in pendingUpload.itemData {
            if item.typeIdentifier.contains("video") || item.typeIdentifier.contains("movie") {
                hasVideoItem = true
                
                // Create MimeiFileType for the completed video
                let videoFile = MimeiFileType(
                    mid: cid,
                    mediaType: .hls_video,
                    size: Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: Date(),
                    aspectRatio: nil, // We don't have aspect ratio from job status
                    url: nil
                )
                uploadedAttachments.append(videoFile)
            } else {
                // For non-video items, we need to upload them normally
                do {
                    let (result, _) = try await uploadToIPFS(
                        data: item.data,
                        typeIdentifier: item.typeIdentifier,
                        fileName: item.fileName,
                        noResample: item.noResample,
                        progressCallback: { message, progress in
                            print("DEBUG: Upload progress for \(item.fileName): \(message) (\(progress)%)")
                        }
                    )
                    if let fileType = result {
                        uploadedAttachments.append(fileType)
                    }
                } catch {
                    print("Error uploading non-video item \(item.fileName): \(error)")
                    // Fallback to re-upload everything
                    await uploadTweetWithPersistenceAndRetry(
                        tweet: pendingUpload.tweet,
                        itemData: pendingUpload.itemData,
                        retryCount: pendingUpload.retryCount,
                        videoJobId: pendingUpload.videoJobId
                    )
                    return
                }
            }
        }
        
        if hasVideoItem && uploadedAttachments.count == pendingUpload.itemData.count {
            // All attachments uploaded successfully, continue with tweet upload
            pendingUpload.tweet.attachments = uploadedAttachments
            
            do {
                if let uploadedTweet = try await self.uploadTweet(pendingUpload.tweet) {
                    // Success - remove pending upload and notify
                    await removePendingUpload()
                    
                    // Update user's tweet count and post notification
                    await MainActor.run {
                        self.appUser.tweetCount = (self.appUser.tweetCount ?? 0) + 1
                        NotificationCenter.default.post(
                            name: .newTweetCreated,
                            object: nil,
                            userInfo: ["tweet": uploadedTweet]
                        )
                    }
                } else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload tweet"])
                }
            } catch {
                print("Error uploading tweet: \(error)")
                
                // Notify failure but keep pending upload for manual retry
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .backgroundUploadFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
            }
        } else {
            print("DEBUG: No video item found or attachment count mismatch")
            // Fallback to re-upload
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
        }
    }
    
    /// Resume polling for a video job that's still in progress
    private func resumeVideoJobPolling(pendingUpload: PendingTweetUpload, jobId: String) async {
        print("DEBUG: Resuming video job polling for job ID: \(jobId)")
        
        // Get base URL for polling - ensure writableUrl is resolved
        _ = try? await appUser.resolveWritableUrl()
        let originalBaseURL = appUser.writableUrl?.deletingLastPathComponent()
        
        // For HLS video polling, use the cloud drive port
        let host = originalBaseURL?.host ?? HproseInstance.baseUrl.host ?? "localhost"
        let cloudPort = appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
        let baseURL = URL(string: "http://\(host):\(cloudPort)")
        
        // Find the video item to get its data
        guard let videoItem = pendingUpload.itemData.first(where: { 
            $0.typeIdentifier.contains("video") || $0.typeIdentifier.contains("movie") 
        }) else {
            print("DEBUG: No video item found for polling resume")
            return
        }
        
        // Resume polling with the stored job ID
        do {
            let mediaProcessor = MediaProcessor()
            let result = try await mediaProcessor.pollVideoConversionStatus(
                jobId: jobId,
                baseURL: baseURL,
                data: videoItem.data,
                fileName: videoItem.fileName,
                aspectRatio: nil as Float?, // We don't have aspect ratio stored
                progressCallback: { message, progress in
                    print("DEBUG: Resume polling progress: \(message) (\(progress)%)")
                }
            )
            
            if let completedVideo = result {
                print("DEBUG: Video job completed during resume polling, CID: \(completedVideo.mid)")
                
                // Update the item data with the completed video
                var updatedItemData = pendingUpload.itemData
                for (index, item) in updatedItemData.enumerated() {
                    if item.identifier == videoItem.identifier {
                        updatedItemData[index] = PendingTweetUpload.ItemData(
                            identifier: item.identifier,
                            typeIdentifier: item.typeIdentifier,
                            data: item.data,
                            fileName: item.fileName,
                            noResample: item.noResample,
                            videoJobId: nil // Clear job ID since it's completed
                        )
                        break
                    }
                }
                
                // Continue with tweet upload
                await uploadTweetWithPersistenceAndRetry(
                    tweet: pendingUpload.tweet,
                    itemData: updatedItemData,
                    retryCount: pendingUpload.retryCount,
                    videoJobId: nil // Clear job ID since it's completed
                )
            }
        } catch {
            print("DEBUG: Resume polling failed: \(error)")
            // Fallback to re-upload
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
        }
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
                
                // Check if we have video job IDs to check first
                if let videoJobId = pendingUpload.videoJobId {
                    print("DEBUG: Found video job ID: \(videoJobId), checking status...")
                    
                    // Get base URL for status checking - ensure writableUrl is resolved
                    _ = try? await appUser.resolveWritableUrl()
                    let originalBaseURL = appUser.writableUrl?.deletingLastPathComponent()
                    
                    // For HLS video status checking, use the cloud drive port
                    let host = originalBaseURL?.host ?? HproseInstance.baseUrl.host ?? "localhost"
                    let cloudPort = appUser.cloudDrivePort ?? Constants.DEFAULT_CLOUD_PORT
                    let baseURL = URL(string: "http://\(host):\(cloudPort)")
                    
                    if let status = await checkVideoJobStatus(jobId: videoJobId, baseURL: baseURL) {
                        switch status.status {
                        case "completed":
                            print("DEBUG: Video job completed while app was backgrounded, CID: \(status.cid ?? "unknown")")
                            // Job completed - we need to create MimeiFileType with the CID
                            // and continue with tweet upload
                            await handleCompletedVideoJob(pendingUpload: pendingUpload, cid: status.cid)
                            return
                            
                        case "failed":
                            print("DEBUG: Video job failed: \(status.message ?? "Unknown error")")
                            // Job failed - fall through to re-upload
                            
                        case "uploading", "processing":
                            print("DEBUG: Video job still in progress, resuming polling...")
                            // Job still in progress - resume polling
                            await resumeVideoJobPolling(pendingUpload: pendingUpload, jobId: videoJobId)
                            return
                            
                        default:
                            print("DEBUG: Unknown video job status: \(status.status)")
                            // Unknown status - fall through to re-upload
                        }
                    } else {
                        print("DEBUG: Could not check video job status, job may have expired")
                        // Job not found or error - fall through to re-upload
                    }
                }
                
                // Fallback to normal recovery (re-upload)
                await uploadTweetWithPersistenceAndRetry(
                    tweet: pendingUpload.tweet,
                    itemData: pendingUpload.itemData,
                    retryCount: pendingUpload.retryCount,
                    videoJobId: pendingUpload.videoJobId
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
                    let error = NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)"])
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
                    let error = NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "addComment returned nil"])
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
        guard let response = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params]) as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "togglePinnedTweet: No response"])
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
        guard let response = user.hproseClient?.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "getPinnedTweets: No response"])
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
        
        guard let response = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Registration failure."])
        }
        if let result = response["status"] as? String {
            if result == "success" {
                return true
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: response["reason"] as? String ?? "Unknown registration error."])
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
        print("DEBUG: updateUserCore called with - alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort?.description ?? "nil")")
        
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
        
        print("DEBUG: updateUserCore - sending request to server with user data")
        guard let response = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            print("DEBUG: updateUserCore - failed to get response from server")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Registration failure."])
        }
        
        print("DEBUG: updateUserCore - server response: \(response)")
        if let result = response["status"] as? String {
            if result == "success" {
                print("DEBUG: updateUserCore - server returned success")
                
                // Clear user cache to ensure fresh data is loaded
                TweetCacheManager.shared.deleteUser(mid: appUser.mid)
                print("DEBUG: updateUserCore - cleared user cache for: \(appUser.mid)")
                
                return true
            } else {
                let errorMessage = response["reason"] as? String ?? "Unknown registration error."
                print("DEBUG: updateUserCore - server returned error: \(errorMessage)")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        print("DEBUG: updateUserCore - unexpected response format")
        return false
    }

    // MARK: - User Avatar
    /// Sets the user's avatar on the server
    func setUserAvatar(user: User, avatar: MimeiId) async throws {
        let entry = "set_user_avatar"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": user.mid,
            "avatar": avatar
        ]
        _ = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params])
    }

    private func getProviderIP(_ mid: String) async throws -> String? {
        let params = [
            "aid": appId,
            "ver": "last",
            "mid": mid
        ]
        
        return try await retryOperation(maxRetries: 3) {
            guard let response = self.client.invoke("runMApp", withArgs: ["get_provider_ip", params]) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from server for get_provider_ip"])
            }
            
            guard let ipAddress = response as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format for get_provider_ip"])
            }
            
            return ipAddress
        }
    }
    
    /// Find IP addresses of given nodeId
    func getHostIP(_ nodeId: String, v4Only: String = "false") async -> String? {
        let params = [
            "aid": appId,
            "ver": "last",
            "nodeid": nodeId,
            "v4only": "false"
        ]
        if let response = client.invoke("runMApp", withArgs: ["get_node_ip", params]) {
            return response as? String
        }
        return nil
    }
    
    // MARK: - Chat Functions
    
    /// Send a chat message to a recipient
    func sendMessage(receiptId: String, message: ChatMessage) async throws -> ChatMessage {
        // Check if app user is blacklisted by the recipient
        guard let recipient = try await fetchUser(receiptId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Recipient user not found"])
        }
        if recipient.isUserBlacklisted(appUser.mid) {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "You cannot send a message to this user because you are blocked"])
        }

        let entry = "message_outgoing"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid,
            "receiptid": receiptId,
            "msg": message.toJSONString()
        ]
        
        let response = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params])
        
        // Handle new response format: {success: false, error: e.message}
        if let responseDict = response as? [String: Any] {
            if let success = responseDict["success"] as? Bool, !success {
                let errorMessage = responseDict["error"] as? String ?? "Unknown error"
                // Return message with failure status
                return ChatMessage(
                    id: message.id,
                    authorId: message.authorId,
                    receiptId: message.receiptId,
                    chatSessionId: message.chatSessionId,
                    content: message.content,
                    timestamp: message.timestamp,
                    attachments: message.attachments,
                    success: false,
                    errorMsg: errorMessage
                )
            }
        }
        
        // Handle legacy boolean response or successful response
        let isSuccess = response as? Bool ?? false
        
        if isSuccess {
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
                
                let receiptResponse = receiptUser.hproseClient?.invoke("runMApp", withArgs: [receiptEntry, receiptParams])
                
                // Handle new response format for message_incoming
                if let receiptResponseDict = receiptResponse as? [String: Any] {
                    if let success = receiptResponseDict["success"] as? Bool, !success {
                        let errorMessage = receiptResponseDict["error"] as? String ?? "Failed to send to recipient node"
                        print("[sendMessage] Warning: Failed to send to recipient node: \(errorMessage)")
                        // Return message with failure status
                        return ChatMessage(
                            id: message.id,
                            authorId: message.authorId,
                            receiptId: message.receiptId,
                            chatSessionId: message.chatSessionId,
                            content: message.content,
                            timestamp: message.timestamp,
                            attachments: message.attachments,
                            success: false,
                            errorMsg: errorMessage
                        )
                    }
                } else {
                    let receiptSuccess = receiptResponse as? Bool ?? false
                    if !receiptSuccess {
                        print("[sendMessage] Warning: Failed to send to recipient node")
                    }
                }
            } else {
                return ChatMessage(
                    id: message.id,
                    authorId: message.authorId,
                    receiptId: message.receiptId,
                    chatSessionId: message.chatSessionId,
                    content: message.content,
                    timestamp: message.timestamp,
                    attachments: message.attachments,
                    success: false,
                    errorMsg: "Failed to send message"
                )
            }
            
            // Return message with success status
            return ChatMessage(
                id: message.id,
                authorId: message.authorId,
                receiptId: message.receiptId,
                chatSessionId: message.chatSessionId,
                content: message.content,
                timestamp: message.timestamp,
                attachments: message.attachments,
                success: true,
                errorMsg: nil
            )
        } else {
            // Return message with failure status
            return ChatMessage(
                id: message.id,
                authorId: message.authorId,
                receiptId: message.receiptId,
                chatSessionId: message.chatSessionId,
                content: message.content,
                timestamp: message.timestamp,
                attachments: message.attachments,
                success: false,
                errorMsg: "Failed to send message"
            )
        }
    }
    
    /// Fetch recent unread messages from a sender (incoming messages only)
    func fetchMessages(senderId: String) async throws -> [ChatMessage] {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        
        let entry = "message_fetch"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid,
            "senderid": senderId
        ]
        
        let response = client.invoke("runMApp", withArgs: [entry, params])
        
        // Handle new response format: {success: false, error: e.message}
        if let responseDict = response as? [String: Any] {
            if let success = responseDict["success"] as? Bool, !success {
                let errorMessage = responseDict["error"] as? String ?? "Unknown error"
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        // Handle legacy array format or successful response
        let messageArray = response as? [[String: Any]] ?? []
        
        return messageArray.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    // Update timestamp to current system time for incoming messages
                    let updatedMessage = ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: Date().timeIntervalSince1970,
                        attachments: message.attachments
                    )
                    return updatedMessage
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
        
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        
        let entry = "message_check"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid
        ]
        
        let response = client.invoke("runMApp", withArgs: [entry, params]) as? [[String: Any]] ?? []
        
        return response.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    // Update timestamp to current system time for incoming messages
                    let updatedMessage = ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: Date().timeIntervalSince1970,
                        attachments: message.attachments
                    )
                    return updatedMessage
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
    
    /// Check for app upgrades and update domain in preferences
    private func checkAndUpdateDomain() async {
        print("[checkAndUpdateDomain] Starting background upgrade check")
        
        let entry = "check_upgrade"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "entry": entry
        ]
        
        guard let client = appUser.hproseClient else {
            print("[checkAndUpdateDomain] Client not initialized")
            return
        }
        
        guard let response = client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] else {
            print("[checkAndUpdateDomain] Invalid response format")
            return
        }
        
        guard let domain = response["domain"] as? String else {
            print("[checkAndUpdateDomain] No upgrade domain received")
            return
        }
        
        print("[checkAndUpdateDomain] Received domain: \(domain)")
        
        // Update domain to share and save to preferences
        await MainActor.run {
            _domainToShare = "http://" + domain
        }
    }
    /// Localizes backend error messages
    private func localizeBackendError(_ errorMessage: String) -> String {
        // Common backend error patterns that can be localized
        let errorMappings: [String: String] = [
            "Unknown error occurred": NSLocalizedString("Unknown error occurred", comment: "Backend error"),
            "Unknown tweet deletion error": NSLocalizedString("Unknown tweet deletion error", comment: "Backend error"),
            "Unknown comment upload error": NSLocalizedString("Unknown comment upload error", comment: "Backend error"),
            "Unknown comment deletion error": NSLocalizedString("Unknown comment deletion error", comment: "Backend error"),
            "Unknown upload error": NSLocalizedString("Unknown upload error", comment: "Backend error"),
            "Unknown registration error.": NSLocalizedString("Unknown registration error.", comment: "Backend error"),
            "Unknown error": NSLocalizedString("Unknown error", comment: "Backend error")
        ]
        
        // Check if we have a direct mapping
        if let localizedError = errorMappings[errorMessage] {
            return localizedError
        }
        
        // For unknown errors, return a generic localized message
        return NSLocalizedString("An error occurred. Please try again.", comment: "Generic backend error")
    }
    
    // MARK: - Content Moderation Methods
    
    /// Blocks a user
    func blockUser(userId: String) async throws {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        
        let entry = "block_user"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid,
            "blocked": userId
        ]
        
        client.invoke("runMApp", withArgs: [entry, params])
        print("[blockUser] Backend call completed for user: \(userId)")
    }
    
    /// Deletes the current user's account
    func deleteAccount() async throws -> [String: Any] {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }
        
        let entry = "delete_account"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "userid": appUser.mid
        ]
        return client.invoke("runMApp", withArgs: [entry, params]) as? [String: Any] ?? [:]
    }
    
    /// Reports a tweet for inappropriate content and deletes it from backend
    func reportTweet(tweetId: String, category: String, comments: String) async throws {
        // First, delete the tweet from backend
        if let deletedTweetId = try await deleteTweet(tweetId) {
            print("[reportTweet] Successfully deleted tweet from backend: \(deletedTweetId)")
        } else {
            print("[reportTweet] Failed to delete tweet from backend: \(tweetId)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete reported tweet from backend"])
        }
        
        // Send notification to system admin about the reported and deleted content
        // Note: Admin notification failure won't affect tweet deletion success
        await notifySystemAdmin(tweetId: tweetId, category: category, comments: comments)
    }
    
    /// Send notification to system admin about reported and deleted content
    private func notifySystemAdmin(tweetId: String, category: String, comments: String) async {
        let adminUserId = AppConfig.alphaId // System admin user ID
        
        // Create notification message
        let notificationContent = """
        🚨 CONTENT REPORT & DELETION ALERT 🚨
        
        Tweet ID: \(tweetId) - DELETED
        Category: \(category)
        Reporter: \(appUser.mid)
        Comments: \(comments.isEmpty ? "None" : comments)
        Time: \(Date().formatted())
        
        Tweet has been automatically deleted from the platform due to reported content.
        Please review this action within 24 hours as per App Store compliance requirements.
        """
        
        // Create chat message
        let sessionId = ChatMessage.generateSessionId(userId: appUser.mid, receiptId: adminUserId)
        let notificationMessage = ChatMessage(
            authorId: appUser.mid,
            receiptId: adminUserId,
            chatSessionId: sessionId,
            content: notificationContent
        )
        
        do {
            let result = try await sendMessage(receiptId: adminUserId, message: notificationMessage)
            if result.success == true {
                print("[notifySystemAdmin] Successfully sent notification to admin for tweet: \(tweetId)")
            } else {
                print("[notifySystemAdmin] Failed to send notification to admin: \(result.errorMsg ?? "Unknown error")")
                // Log the failure but don't throw error - admin notification is not critical for tweet deletion
            }
        } catch {
            print("[notifySystemAdmin] Error sending notification to admin: \(error)")
            // Log the error but don't throw - admin notification is not critical for tweet deletion
            // The tweet has already been deleted successfully, so we don't want to fail the entire operation
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
