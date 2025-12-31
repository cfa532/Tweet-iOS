import Foundation
import hprose
import PhotosUI
import AVFoundation
import ffmpegkit

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

// MARK: - IP Cache Entry
private struct IPCacheEntry {
    let ip: String
    let timestamp: Date
    
    var isExpired: Bool {
        // 30 seconds expiry
        return Date().timeIntervalSince(timestamp) > 30
    }
}

// MARK: - HproseInstance
final class HproseInstance: ObservableObject {
    // MARK: - Properties
    static let shared = HproseInstance()
    static var baseUrl: URL = URL(string: AppConfig.baseUrl)!
    private var _domainToShare: String = AppConfig.baseUrl
    
    // IP Cache: Stores validated IPs with 30-minute expiry
    private var ipCache: [String: IPCacheEntry] = [:]
    private let ipCacheLock = NSLock()
    
    // Dedicated URLSession for health checks with optimized connection pool
    private lazy var healthCheckSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 20  // Allow many parallel health checks
        config.timeoutIntervalForRequest = 5.0     // Fast fail for health checks
        config.timeoutIntervalForResource = 10.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil  // No caching for health checks
        return URLSession(configuration: config)
    }()
    
    /// The domain to use for sharing links
    var domainToShare: String {
        get {
#if DEBUG
            // Always share via the debug gateway to avoid polluting production links
            return AppConfig.baseUrl
#else
            if let override = appUser.domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                return override
            }
            return _domainToShare
#endif
        }
        set {
#if DEBUG
            _domainToShare = AppConfig.baseUrl
#else
            _domainToShare = newValue
#endif
        }
    }
    
    /// The backend domain from check_upgrade (for placeholder use)
    var backendDomainToShare: String {
        return _domainToShare
    }
    
    // Store the app user's MID instead of the user object itself
    // This ensures appUser always returns the singleton instance
    @Published private var _appUserId: String = Constants.GUEST_ID
    
    /// The current app user singleton instance
    ///
    /// This computed property provides access to the current user with automatic refresh capabilities:
    ///
    /// **Getter behavior:**
    /// - Always returns the singleton User instance for the current _appUserId
    /// - For logged-in users with incomplete data (nil username):
    ///   - Automatically triggers async refresh from server via fetchUser()
    ///   - Updates baseUrl if server provides a different IP
    ///   - Refresh runs in background (non-blocking)
    /// - For guest users: Returns guest user without refresh
    ///
    /// **Cache expiry handling:**
    /// - User cache expiry is handled when app returns to foreground via AppDelegate
    /// - AppDelegate.handleAppWillEnterForeground() calls refreshAppUserIP() which:
    ///   1. Calls refreshAppUserFromServer()
    ///   2. Uses getProviderIP() for intelligent IP resolution with health checks
    ///   3. Automatically falls back to resolving entryIP if provider IPs are unhealthy
    ///   4. Updates both HproseInstance.baseUrl and appUser.baseUrl
    /// - This ensures stale IPs don't persist after long background periods
    ///
    /// **Setter behavior:**
    /// - Updates the singleton User instance with new values
    /// - Preserves the singleton pattern by updating getInstance(mid) instance
    /// - All property changes are applied on MainActor for thread safety
    ///
    /// - Note: Always use this property instead of creating new User instances
    /// - Note: The singleton pattern ensures all parts of the app see the same user data
    var appUser: User {
        get { 
            // Always return the singleton instance for the current app user ID
            let user = User.getInstance(mid: _appUserId)
            
            // Refresh appUser from server if user data is incomplete - but not for guest users
            // fetchUser will handle invalid users (nil username) automatically
            // Note: This check is async to prevent blocking the getter
            // Cache expiry is now handled when the app returns to foreground via AppDelegate
            if !user.isGuest && user.username == nil {
                Task {
                    do {
                        // Use cached baseUrl for first attempt, retries will force IP re-resolution
                        if let refreshedUser = try await fetchUser(_appUserId, baseUrl: user.baseUrl?.absoluteString ?? "") {
                            // Update appUser's baseUrl to match the refreshed user's baseUrl
                            await MainActor.run {
                                if refreshedUser.baseUrl != user.baseUrl {
                                    user.baseUrl = refreshedUser.baseUrl
                                }
                            }
                        }
                    } catch {
                        print("ERROR: [appUser getter] Failed to refresh appUser: \(error)")
                    }
                }
            }
            return user
        }
        set {
            // Update the singleton instance with new values, then switch to it
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
                
                // Update the reference to point to the singleton instance by storing its ID
                // This ensures appUser getter always returns the same singleton instance
                if self._appUserId != instance.mid {
                    self._appUserId = instance.mid
                    // Notify observers that appUser has changed
                    self.objectWillChange.send()
                }
            }
        }
    }
    
    var appId: String = AppConfig.appId      // Initialize with AppConfig value, will be updated during initAppEntry() if server provides different value
    var preferenceHelper: PreferenceHelper?
    
    // MARK: - Upload Management
    lazy var uploadManager: TweetUploadManager = {
        return TweetUploadManager(hproseInstance: self)
    }()
    
    // MARK: - BlackList Management
    private let blackList = BlackList.shared
    
    // MARK: - Client Pool Management
    lazy var clientPool: HproseClientPool = {
        return HproseClientPool(maxClientsPerURL: 5)
    }()
    
    private var lastInitializationAddresses: String?
    private var lastLoggedUpgradeDomain: String?
    
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
                
                if attempt < maxRetries {
                    let delay = baseDelay * UInt64(attempt) // Exponential backoff
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        
        throw lastError ?? NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("All retry attempts failed", comment: "Network retry error")])
    }
    
    private func applyBaseUrlIfNeeded(_ user: User, url: URL, reason: String) async {
        await MainActor.run {
            let current = user.baseUrl?.absoluteString
            let newValue = url.absoluteString
            guard current != newValue else { return }
            user.baseUrl = url
            user.resetClients()
            print("DEBUG: [updateUserFromServer] Updated baseUrl (\(reason)) to \(newValue) for userId: \(user.mid)")
        }
    }
    
    /// Unwrap v2 API response format
    /// v2 format: {success: true, data: result} or {success: false, message: "...", error: ...}
    /// Also handles Int success values: {success: 1, data: result} or {success: 0, message: "..."}
    /// Returns the unwrapped data if success, throws error if failure
    private static func unwrapV2Response(_ response: Any?) throws -> Any? {
        guard let dict = response as? [String: Any] else {
            return response
        }
        
        // Check if this is a v2 response - handle both Bool and Int success values
        var successValue: Bool? = nil
        
        if let successBool = dict["success"] as? Bool {
            successValue = successBool
        } else if let successInt = dict["success"] as? Int {
            successValue = (successInt != 0)
        }
        
        if let success = successValue {
            if success {
                // Success case - return data field if present, otherwise return the whole dict
                if let data = dict["data"] {
                    return data
                }
                // If no data field, the result might be directly in the dict (e.g., {success: true, mid: "...", count: ...})
                return dict
            } else {
                // Error case
                let message = dict["message"] as? String ?? NSLocalizedString("Unknown error from server", comment: "Server error")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        
        // Not a v2 response, return as-is
        return response
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
        print("Cloud Drive Port: \(appUser.cloudDrivePort)")
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
    /// Private initializer ensures singleton pattern
    private init() {}
    
    // Flag to track if app is still initializing to prevent error dialogs during startup
    var isAppInitializing = true  // Changed from private to internal for TweetUploadManager access
    
    // Global flag to track if app initialization is complete
    @Published private var isInitializationComplete = false
    
    /// Check if app initialization is complete
    var isAppInitialized: Bool {
        return isInitializationComplete
    }
    
    // MARK: - Public Methods
    
    /// Main initialization method for HproseInstance
    /// This method performs the following steps:
    /// 1. Initializes PreferenceHelper for accessing user preferences
    /// 2. Calls `initAppEntry()` to:
    ///    - Resolve backend server IP addresses from app URLs
    ///    - Set HproseInstance.baseUrl to the resolved IP
    ///    - Fetch and update appUser data from server (for logged-in users)
    ///    - Initialize appUser's baseUrl with the resolved provider IP
    ///    - Post .appUserReady notification when initialization completes
    /// 3. Cleans up expired tweets from cache
    /// 4. Clears the isAppInitializing flag to enable error dialogs
    ///
    /// - Note: This method is called during app startup by TweetApp.AppState.initialize()
    /// - Note: Errors during initAppEntry are caught and logged, allowing the app to continue with defaults
    func initialize() async throws {
        print("DEBUG: [HproseInstance] Starting initialization")
        
        // Step 1: Initialize preference helper first
        self.preferenceHelper = PreferenceHelper()
        
        // Step 2: Initialize app user (now handled by TweetApp.AppState.initialize())
        // await initializeAppUser()
        
        // Step 3: Try to initialize app entry and update user if successful (baseUrl will be set once here)
        do {
            try await initAppEntry()
        } catch {
            print("Error initializing app entry: \(error)")
            // Don't throw here, allow the app to continue with default settings
        }
        
        // Step 5: Clean up expired tweets
        TweetCacheManager.shared.deleteExpiredTweets()
        
        print("DEBUG: [HproseInstance] Initialization completed")
        isAppInitializing = false
    }
    
    /// Initialize app user with cached or default values
    func initializeAppUser() async {
        // Get user ID from preferences or use guest ID
        let userId = await MainActor.run {
            preferenceHelper?.getUserId() ?? Constants.GUEST_ID
        }
        
        // Try to load cached user first (async, non-blocking)
        // IMPORTANT: fetchUser() ALWAYS returns a valid User instance (never nil)
        // - If cached: returns User from CoreData
        // - If cache empty: returns User.getInstance(mid) as fallback
        // This ensures safe operation even after cache is completely cleared
        let cachedUser = await TweetCacheManager.shared.fetchUser(mid: userId)
        
        NSLog("🔍 [initializeAppUser] Loaded cached appUser: \(userId), avatar: \(cachedUser.avatar ?? "nil"), baseUrl: \(cachedUser.baseUrl?.absoluteString ?? "nil")")
        
        await MainActor.run {
            // CRITICAL: Update the singleton instance instead of replacing appUser
            // This ensures all references to this user get the cached data
            // Safe to call even after cache clear because fetchUser never returns nil
            User.updateUserInstance(with: cachedUser)
            _appUserId = userId
            
            // Set following list on the singleton instance
            let appUserInstance = User.getInstance(mid: userId)
            appUserInstance.followingList = Gadget.getAlphaIds()
            
            NSLog("✅ [initializeAppUser] AppUser singleton avatar: \(appUser.avatar ?? "nil"), baseUrl: \(appUser.baseUrl?.absoluteString ?? "nil")")
            print("DEBUG: [HproseInstance] Initialized app user: \(userId), baseUrl: \(String(describing: appUser.baseUrl))")
            
            // Mark initialization as complete so error messages can be shown
            // This is safe to do here since the user can now interact with the app
            isAppInitializing = false
            print("DEBUG: [HproseInstance] App initialization flag cleared - errors will now be shown to user")
        }
    }
    
    /// Manually mark initialization as complete (for cases where initialize() is not called)
    func markInitializationComplete() {
        isAppInitializing = false
        isInitializationComplete = true
        print("DEBUG: [HproseInstance] Manually marked initialization as complete")
    }
    
    /// Schedule background tasks
    private func scheduleBackgroundTasks() {
        // Schedule domain update and pending upload recovery
        Task.detached(priority: .background) {
            print("DEBUG: [HproseInstance] Waiting for app initialization to complete...")
            
            // Wait for app initialization to complete by polling the flag
            while true {
                let isComplete = await MainActor.run { self.isInitializationComplete }
                if isComplete {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // Check every 100ms
            }
            
            print("DEBUG: [HproseInstance] App initialized, starting background tasks")
            
            // Check for domain updates
            await self.checkAndUpdateDomain()
            self.blackList.processCandidates()
            
            // NOTE: Pending upload recovery is now handled by ContentView's dialog system
            // This gives users control over retry/discard instead of automatic retry
            // await self.recoverPendingUploads()  // Disabled - now using dialog-based recovery
        }
    }
    
    /// Fetch alphaId user from backend for guest users
    private func fetchAlphaIdUserForGuest() async {
        guard appUser.isGuest else { return }
        
        do {
            // Fetch user data from server
            guard let alphaUserId = Gadget.getAlphaIds().first else {
                print("fetchAlphaIdUserForGuest: alphaUser.mid is null")
                return
            }
            guard let alphaUser = try await fetchUser(alphaUserId, baseUrl: "", forceRefresh: true) else {
                print("fetchAlphaIdUserForGuest: alphaUser is null")
                return
            }
            
            print("DEBUG: [HproseInstance] Successfully fetched alphaId user for guest")
            await MainActor.run {
                User.updateUserInstance(with: alphaUser, true)
                // Notify FollowingsTweetView to refresh
                NotificationCenter.default.post(name: .appUserReady, object: nil)
            }
        } catch {
            print("DEBUG: [HproseInstance] Failed to fetch alphaId user for guest: \(error)")
        }
    }
    
    /// Initialize app entry and resolve backend server IP addresses
    ///
    /// This method is the core initialization routine that:
    /// 1. Fetches HTML from configured app URLs (from PreferenceHelper)
    /// 2. Extracts server IP addresses from the HTML response
    /// 3. Resolves and sets HproseInstance.baseUrl to the first valid IP
    /// 4. For logged-in users:
    ///    - Fetches user data from server with forced IP re-resolution
    ///    - Updates appUser's baseUrl to their provider IP
    ///    - Saves updated user data to cache
    ///    - Posts .appUserReady notification
    ///    - Fetches followings and blacklist in background (non-blocking)
    /// 5. For guest users:
    ///    - Sets appUser baseUrl to resolved IP
    /// Finds and returns an entry IP address from app URLs
    ///
    /// - Returns: A valid IP address string, or nil if none could be resolved
    /// - Note: Updates `appId` and `lastInitializationAddresses` as a side effect
    private func findEntryIP() async throws -> String? {
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let urlWithPrefix = ensureHttpPrefix(url)
                let html = try await fetchHTML(from: urlWithPrefix)
                let paramData = Gadget.shared.extractParamMap(from: html)
                // Update appId from server if provided, otherwise keep AppConfig value
                if let serverAppId = paramData["mid"] as? String, !serverAppId.isEmpty {
                    appId = serverAppId
                    print("DEBUG: [HproseInstance] Updated appId from server: \(appId)")
                } else {
                    print("DEBUG: [HproseInstance] Server did not provide appId, keeping AppConfig value: \(appId)")
                }
                guard let addrs = paramData["addrs"] as? String else { continue }
                if lastInitializationAddresses != addrs {
                    print("DEBUG: [HproseInstance] App addresses resolved: \(addrs)")
                    lastInitializationAddresses = addrs
                }
                
                if let entryIP = Gadget.shared.filterIpAddresses(addrs) {
                    HproseInstance.baseUrl = URL(string: "http://\(entryIP)")!
                    return entryIP
                }
            } catch {
                print("Error processing URL \(url): \(error)")
                continue
            }
        }
        return nil
    }
    
    ///    - Fetches alphaId user data in background
    ///
    /// - Throws: Network or parsing errors (caught by caller)
    /// - Note: Called during app initialization by `initialize()` method
    /// - Note: Sets `isInitializationComplete = true` once baseUrl is resolved
    func initAppEntry() async throws {
        guard let entryIP = try await findEntryIP() else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
        }
        
        if !appUser.isGuest {
            // Always force refresh of appUser's baseURL on app start to ensure we have the latest IP
            // Pass empty string to force IP re-resolution and bypass cache
            let user = try await fetchUser(appUser.mid, baseUrl: "")
            print("✅ [INIT] appUser data fetched: \(String(describing: user))")
            
            if let user = user {
                // App is now initialized with base connectivity
                await MainActor.run {
                    isInitializationComplete = true
                    User.updateUserInstance(with: user, true)
                    _appUserId = user.mid
                    
                    // Notify UI that app is ready (tweets can now render with real IP)
                    NotificationCenter.default.post(name: .appUserReady, object: nil)
                }
                
                // Ensure the refreshed user with updated baseURL is saved to cache
                TweetCacheManager.shared.saveUser(user)
                print("✅ [INIT] App initialized with real IP: \(entryIP)")
                
                // Fetch followings and blacklist in background (non-blocking)
                Task.detached(priority: .background) {
                    let followings = (try? await self.getListByType(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                    print("✅ [INIT] Followings fetched: \(followings.count)")
                    let blackList = (try? await self.getListByType(user: user, entry: .BLACK_LIST)) ?? []
                    print("✅ [INIT] Blacklist fetched: \(blackList.count)")
                    await MainActor.run {
                        user.followingList = followings
                        user.userBlackList = blackList
                        self.printAppUserContent("After background data loaded")
                    }
                }
            } else {
                // Fetch failed but user is logged in - use cached appUser data
                // DO NOT log out user just because their IPs are temporarily unreachable
                print("⚠️ [INIT] fetchUser failed but user is logged in - using cached appUser data")
                print("⚠️ [INIT] User \(appUser.mid) will use cached data until network recovers")
                
                await MainActor.run {
                    // appUser is already loaded from cache in initializeAppUser()
                    // Just set entry IP as fallback and mark initialization as complete
                    if appUser.baseUrl == nil {
                        appUser.baseUrl = URL(string: "http://\(entryIP)")
                    }
                    
                    // Ensure followings list has at least alphaIds
                    if appUser.followingList?.isEmpty ?? true {
                        appUser.followingList = Gadget.getAlphaIds()
                    }
                    
                    isInitializationComplete = true
                    
                    // Notify UI that app is ready (will use cached data)
                    NotificationCenter.default.post(name: .appUserReady, object: nil)
                }
                
                print("✅ [INIT] App initialized with cached data - network will retry in background")
            }
        } else {
            let user = User.getInstance(mid: Constants.GUEST_ID)
            await MainActor.run {
                user.baseUrl = URL(string: "http://\(entryIP)")
                user.followingList = Gadget.getAlphaIds()
                _appUserId = user.mid
                
                // App is now initialized since appUser has IP address
                isInitializationComplete = true
            }
            print("DEBUG: [initAppEntry] Updated appUser singleton baseUrl to IP: \(entryIP)")
            
            // For guest users, fetch the alphaId user from backend now that we have proper IP
            await fetchAlphaIdUserForGuest()
        }
        // Step 6: Schedule background tasks
        scheduleBackgroundTasks()
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
            "version": "v2",
            "tweetid": parentTweet.mid,
            "appuserid": appUser.mid,
            "pn": pageNumber,
            "ps": pageSize,
        ] as [String : Any]
        
        // CRITICAL: Use the parent tweet's author's baseUrl to fetch comments
        // Comments are stored on the tweet author's node, not the appUser's node
        // Fetch author if not already loaded
        let author: User
        if let existingAuthor = parentTweet.author {
            author = existingAuthor
        } else {
            // Fetch author to get their baseUrl
            guard let fetchedAuthor = try? await fetchUser(parentTweet.authorId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch author for comments", comment: "Author fetch error")])
            }
            author = fetchedAuthor
            // Update parentTweet's author for future use
            await MainActor.run {
                parentTweet.author = author
            }
        }
        
        // Use author's client - comments are on author's node
        guard let client = author.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author's client not initialized. baseUrl: \(author.baseUrl?.absoluteString ?? "nil")", comment: "Client initialization error")])
        }
        
        print("DEBUG: [fetchComments] Using author's baseUrl (\(author.baseUrl?.absoluteString ?? "nil")) for tweet \(parentTweet.mid)")
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when tweet has no comments
        let response: [[String: Any]?]
        if let arrayResponse = unwrappedResponse as? [[String: Any]?] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            print("DEBUG: [HproseInstance] fetchComments - Server returned empty array (no comments)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
        }
        
        // Process each item in the response array, preserving nil positions
        var commentsWithAuthors: [Tweet?] = []
        for item in response {
            if let dict = item {
                do {
                    let comment = try await MainActor.run {
                        return try Tweet.from(dict: dict)
                    }
                    // Try to fetch user, fall back to skeleton if fetch fails
                    if let author = try? await fetchUser(comment.authorId) {
                        await MainActor.run {
                            comment.author = author
                        }
                    } else {
                        // Server fetch failed - use skeleton to indicate error
                        await MainActor.run {
                            comment.author = User.getInstance(mid: comment.authorId)
                            print("⚠️ [fetchComments] Server fetch failed, using skeleton for \(comment.authorId) to indicate error")
                        }
                    }
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
        // If app is not initialized, only return cached tweets
        if !isInitializationComplete {
            let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(for: user.mid, page: pageNumber, pageSize: pageSize, currentUserId: appUser.mid)
            return cachedTweets
        }
        
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        var params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "pn": pageNumber,
            "ps": pageSize,
            "userid": !user.isGuest ? user.mid : Gadget.getAlphaIds().first as Any,
            "appuserid": appUser.mid,
        ]
        
        if entry == "update_following_tweets" {
            params["hostid"] = appUser.hostIds?.first
        }
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
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
        
        // Cache original tweets first - cache under their authorId, not appUser.mid
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                    
                    // Use skeleton author immediately - fetch in background to avoid blocking
                    await MainActor.run {
                        originalTweet.author = User.getInstance(mid: originalTweet.authorId)
                    }
                    
                    // Fetch author in background - will update singleton when complete
                    Task.detached(priority: .userInitiated) {
                        do {
                            _ = try await self.fetchUser(originalTweet.authorId)
                            // Author singleton is already set, it will update automatically
                        } catch {
                            print("⚠️ [fetchTweetFeed] Background fetch failed for original author \(originalTweet.authorId): \(error)")
                        }
                    }
                    
                    // CRITICAL: Cache original tweet under its authorId, not appUser.mid
                    // This prevents original tweets from appearing in main feed when their author is different
                    TweetCacheManager.shared.saveTweet(originalTweet, userId: originalTweet.authorId)
                    print("[fetchTweetFeed] Cached original tweet: \(originalTweet.mid) under authorId: \(originalTweet.authorId)")
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
                    
                    // Use skeleton author immediately - fetch in background to avoid blocking
                    await MainActor.run {
                        tweet.author = User.getInstance(mid: tweet.authorId)
                    }
                    
                    // Fetch author in background - will update singleton when complete
                    Task.detached(priority: .userInitiated) {
                        do {
                            _ = try await self.fetchUser(tweet.authorId)
                            // Author singleton is already set, it will update automatically
                        } catch {
                            print("⚠️ [fetchTweetFeed] Background fetch failed for author \(tweet.authorId): \(error)")
                        }
                    }
                    
                    // Skip private tweets in feed
                    if tweet.isPrivate == true {
                        tweets.append(nil)
                        continue
                    }
                    
                    // Cache main feed tweets under appUser.mid for efficient main feed loading
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
    func fetchUserTweets(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweets_by_user"
    ) async throws -> [Tweet?] {
        // If app is not initialized, only return cached tweets
        if !isInitializationComplete {
            print("DEBUG: [fetchUserTweets] App not initialized, returning cached tweets only for user: \(user.mid)")
            let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(for: user.mid, page: pageNumber, pageSize: pageSize, currentUserId: appUser.mid)
            return cachedTweets
        }
        
        guard let client = user.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": user.mid,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUser.mid,
        ] as [String : Any]
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
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
        
        // Cache original tweets first - cache under their authorId, not appUser.mid
        // This applies to all users, not just appUser, to ensure consistent caching
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await MainActor.run { return try Tweet.from(dict: dict) }
                    // Fetch the author - fetchUser returns singleton, which will be updated by background Task if needed
                    // The singleton reference will see updates when fetch completes
                    do {
                        let author = try await fetchUser(originalTweet.authorId)
                        await MainActor.run {
                            originalTweet.author = author
                        }
                    } catch {
                        print("⚠️ [fetchUserTweets] Failed to fetch original author \(originalTweet.authorId) for tweet \(originalTweet.mid): \(error)")
                        // Server fetch failed - use skeleton to indicate error
                        await MainActor.run {
                            originalTweet.author = User.getInstance(mid: originalTweet.authorId)
                            print("⚠️ [fetchUserTweets] Server fetch failed, using skeleton for \(originalTweet.authorId) to indicate error")
                        }
                    }
                    // CRITICAL: Cache original tweet under its authorId, not appUser.mid
                    // This prevents original tweets from appearing in main feed when their author is different
                    TweetCacheManager.shared.saveTweet(originalTweet, userId: originalTweet.authorId)
                    print("[fetchUserTweet] Cached original tweet: \(originalTweet.mid) under authorId: \(originalTweet.authorId)")
                } catch {
                    print("[fetchUserTweet] Error caching original tweet: \(error)")
                }
            }
        }
        
        var tweets: [Tweet?] = []
        for item in tweetsData {
            if let tweetDict = item {
                do {
                    let tweet = try await MainActor.run { 
                        let tweet = try Tweet.from(dict: tweetDict)
                        tweet.author = user  // Set on main thread since author is @Published
                        return tweet
                    }
                    
                    // Only show private tweets if the current user is the author
                    if tweet.isPrivate == true && tweet.authorId != appUser.mid {
                        tweets.append(nil)
                        continue
                    }
                    
                    // Cache tweet under its authorId
                    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
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
    
    /// Get tweet from the current provider of the tweet.
    /// 
    /// This function retrieves tweet data from the current provider node, which may not be the most
    /// up-to-date version. It does NOT sync data from the author's host node. Use this for fetching
    /// original tweets in retweets/quoted tweets where you just need the tweet data quickly.
    /// 
    /// For the latest data, use `refreshTweet` instead, which syncs from the author's host before retrieving.
    ///
    /// - Parameters:
    ///   - tweetId: The ID of the tweet to retrieve
    ///   - authorId: The ID of the tweet's author
    ///   - nodeUrl: Optional node URL (unused)
    /// - Returns: The tweet object, or nil if not found
    func getTweet(
        tweetId: String,
        authorId: String,
        nodeUrl: String? = nil
    ) async throws -> Tweet? {
        // Check if tweet is blacklisted before attempting fetch
        if blackList.isBlacklisted(tweetId) {
            print("DEBUG: [getTweet] tweetId \(tweetId) is blacklisted, returning cached tweet only")
            return await TweetCacheManager.shared.fetchTweet(mid: tweetId)
        }
        
        // Check cache first using TweetCacheManager
        let author = try await fetchUser(authorId)
        if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: tweetId) {
            // Set author if not already set
            if cachedTweet.author == nil {
                await MainActor.run {
                    cachedTweet.author = author
                }
            }
            return cachedTweet
        }
        
        // Fetch from server using get_tweet API (like Android's fetchTweet)
        guard let authorClient = author?.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author client not initialized", comment: "Author client initialization error")])
        }
        
        let entry = "get_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "appuserid": appUser.mid
        ]
        
        do {
            let rawResponse = authorClient.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            if let tweetDict = unwrappedResponse as? [String: Any] {
                // Record successful access
                blackList.recordSuccess(tweetId)
                
                let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                await MainActor.run {
                    tweet.author = author  // Set on main thread since author is @Published
                }
                
                // Cache tweet by authorId, not appUser.mid
                TweetCacheManager.shared.saveTweet(tweet, userId: authorId)
                
                return tweet
            } else {
                // Tweet not found - record failure to blacklist candidates
                print("DEBUG: [getTweet] Tweet not found for tweetId: \(tweetId), recording failure")
                blackList.recordFailure(tweetId)
                return nil
            }
        } catch {
            // Record failed access
            blackList.recordFailure(tweetId)
            print("DEBUG: [getTweet] Error fetching tweet: \(tweetId), author: \(authorId)")
            print("DEBUG: [getTweet] Exception: \(error)")
            throw error
        }
    }
    
    /// Refresh tweet by syncing from author's host and retrieving the latest data.
    /// 
    /// This function not only retrieves the tweet but also updates the current provider's data to match
    /// the host of the author (where the tweet is actually written to). This ensures you get the most
    /// up-to-date version of the tweet, including any recent changes or updates.
    /// 
    /// Use this in detail views where you need the latest data. For quick retrieval of original tweets
    /// in retweets/quoted tweets, use `getTweet` instead.
    ///
    /// - Parameters:
    ///   - tweetId: The ID of the tweet to refresh
    ///   - authorId: The ID of the tweet's author
    /// - Returns: The refreshed tweet object, or nil if not found
    func refreshTweet(
        tweetId: String,
        authorId: String,
    ) async throws -> Tweet? {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let author = try await fetchUser(authorId)
        let entry = "refresh_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "userid": authorId,
            "hostid": author?.hostIds?.first,
            "appuserid": appUser.mid
        ]
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        if let tweetDict = unwrappedResponse as? [String: Any] {
            do {
                let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                if let author = try? await fetchUser(authorId) {
                    await MainActor.run {
                        tweet.author = author  // Set on main thread since author is @Published
                    }
                }
                
                // Cache the tweet under its authorId, not appUser.mid
                // This ensures original tweets are cached under their author, not the current user
                TweetCacheManager.shared.saveTweet(tweet, userId: authorId)
                
                // Record success if tweet was successfully fetched
                blackList.recordSuccess(tweetId)
                
                return tweet
            } catch {
                print("Error processing tweet: \(error)")
                // Record failure for tweet processing error
                blackList.recordFailure(tweetId)
                throw error
            }
        }
        
        // Tweet not found - record failure to blacklist candidates
        print("DEBUG: [refreshTweet] Tweet not found for tweetId: \(tweetId), recording failure")
        blackList.recordFailure(tweetId)
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Tweet not found", comment: "Tweet lookup error")])
    }
    
    func getUserId(_ username: String) async throws -> String? {
        try await withRetry {
            let entry = "get_userid"
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "username": username,
            ]
            guard let client = appUser.hproseClient else {
                print("[getUserId] Invalid hproseClient")
                return nil
            }
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            if let stringResponse = unwrappedResponse as? String {
                return stringResponse
            }
            
            // If unwrapped response is a dict, extract data or return nil
            if let dictResponse = unwrappedResponse as? [String: Any] {
                return dictResponse["data"] as? String
            }
            
            return nil
        }
    }
    
    /// If @baseUrl is an empty string, the function will ignore the cache and try to find a provider's IP for this user
    /// and update cache with the new user.
    /// If @baseUrl is omitted, an user object will be retrieved from cache or the default serving node of appUser.
    /// Otherwise, user object will be retrieved from the node of the given baseUrl.
    ///
    /// - Parameters:
    ///   - userId: The user ID to fetch
    /// Fetches user data with caching, blacklist checking, and concurrent update management
    /// - Parameters:
    ///   - userId: The user ID to fetch
    ///   - baseUrl: Initial baseUrl (use "" to force IP resolution and bypass cache)
    ///   - maxRetries: Maximum number of retry attempts (default: 2)
    ///   - forceRefresh: If true, bypasses cache and fetches fresh data
    ///   - skipRetryAndBlacklist: If true, skips retry logic and blacklist management (for internal use)
    /// - Returns: User object or nil if user cannot be fetched
    func fetchUser(
        _ userId: String,
        baseUrl: String = shared.appUser.baseUrl?.absoluteString ?? "",
        maxRetries: Int = 2,
        forceRefresh: Bool = false,
        skipRetryAndBlacklist: Bool = false
    ) async throws -> User? {
        // Guard against fetching the guest user - GUEST_ID should never make network calls
        // as it represents an unauthenticated state
        guard userId != Constants.GUEST_ID else {
            print("DEBUG: [fetchUser] Null userId, returning nil")
            return nil
        }
        
        // Check if this user has been blacklisted due to repeated failures
        // Skip this check if we're in internal retry logic to prevent double-checking
        if !skipRetryAndBlacklist && blackList.isBlacklisted(userId) {
            print("DEBUG: [fetchUser] User \(userId) is blacklisted, returning nil")
            return nil
        }
        
        // Attempt to return cached data if we're not forcing a fresh fetch
        if !forceRefresh {
            // Fetch the user from the local cache
            let cachedUser = await TweetCacheManager.shared.fetchUser(mid: userId)
            
            // Verify that we have a complete cached user with required fields
            if cachedUser.username != nil && cachedUser.baseUrl != nil {
                let hasExpired = await cachedUser.hasExpired()
                
                // Return cached user if it's still valid and we have a baseUrl
                if !hasExpired && !baseUrl.isEmpty {
                    return cachedUser
                } else if hasExpired {
                    // User data has expired
                    // If baseUrl is empty (forcing fresh IP resolution), don't return stale data
                    // This is critical during login to ensure we get a healthy IP
                    if baseUrl.isEmpty {
                        print("DEBUG: [fetchUser] Cache expired and baseUrl empty (forcing IP resolution), fetching fresh data")
                        // Fall through to fetch fresh data with IP resolution below
                    } else {
                        // For normal fetches, return stale data while refreshing in background for better UX
                        let shouldStartBackgroundRefresh = userUpdateQueue.sync {
                            if !ongoingUserUpdates.contains(userId) {
                                // Mark this user as being updated to prevent duplicate refreshes
                                ongoingUserUpdates.insert(userId)
                                return true
                            }
                            return false
                        }
                        
                        // Kick off background refresh if we're the first to notice expiration
                        if shouldStartBackgroundRefresh {
                            Task {
                                await startBackgroundRefresh(userId, cachedUser: cachedUser, maxRetries: maxRetries, skipRetryAndBlacklist: skipRetryAndBlacklist)
                            }
                        }
                        
                        // Return the stale cached user immediately for better UX (non-login flows)
                        print("DEBUG: [fetchUser] Returning stale cached user while refreshing in background")
                        return cachedUser
                    }
                }
            }
        }
        
        // Check if an update for this user is already in progress to prevent duplicate network calls
        // Use a synchronized queue to safely check and update the ongoing updates set
        let shouldProceed = userUpdateQueue.sync {
            if ongoingUserUpdates.contains(userId) {
                // Another fetch is already in progress
                return false
            }
            // Mark this user as being updated
            ongoingUserUpdates.insert(userId)
            return true
        }
        
        // If another fetch is in progress, wait for it to complete and return the cached result
        if !shouldProceed {
            return try await waitForConcurrentUpdate(userId, baseUrl: baseUrl, maxRetries: maxRetries, forceRefresh: forceRefresh)
        }
        
        // Ensure we always remove this user from the ongoing updates set when we're done
        // This executes regardless of how we exit (success, error, or early return)
        defer {
            _ = userUpdateQueue.sync {
                ongoingUserUpdates.remove(userId)
            }
        }
        
        do {
            // Get or create a User instance for this userId
            let user = User.getInstance(mid: userId)
            
            // Apply the provided baseUrl to the user object if not empty
            // If baseUrl is empty, performUserUpdate will handle IP resolution via resolveAndUpdateBaseUrl
            if !baseUrl.isEmpty {
                if let url = URL(string: baseUrl) {
                    await applyBaseUrlIfNeeded(user, url: url, reason: "fetchUser initial setup")
                }
            }
            
            // Perform the actual user data fetch with retry logic and error handling
            // This will handle IP resolution if baseUrl was empty
            return try await performUserUpdate(user, maxRetries: maxRetries, skipRetryAndBlacklist: skipRetryAndBlacklist, logPrefix: "fetchUser")
        } catch {
            // Catch and log any exceptions during the fetch process
            print("DEBUG: [fetchUser] Exception in fetchUser: userId: \(userId), error: \(error)")
            return nil
        }
    }
    
    // Track ongoing user updates to prevent concurrent calls for the same user
    private var ongoingUserUpdates: Set<String> = []
    private let userUpdateQueue = DispatchQueue(label: "user.update.queue")
    
    // MARK: - Helper Methods
    
    /// Waits for concurrent update to complete and returns cached result
    private func waitForConcurrentUpdate(_ userId: String, baseUrl: String, maxRetries: Int, forceRefresh: Bool) async throws -> User? {
        // Simple implementation: just wait a bit and return cached user
        // In production, you might want to use a condition variable or notification
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        return await TweetCacheManager.shared.fetchUser(mid: userId)
    }
    
    /// Starts background refresh for expired user
    private func startBackgroundRefresh(_ userId: String, cachedUser: User, maxRetries: Int, skipRetryAndBlacklist: Bool) async {
        defer {
            _ = userUpdateQueue.sync {
                ongoingUserUpdates.remove(userId)
            }
        }
        
        do {
            _ = try await performUserUpdate(cachedUser, maxRetries: maxRetries, skipRetryAndBlacklist: skipRetryAndBlacklist, logPrefix: "backgroundRefresh")
        } catch {
            print("DEBUG: [startBackgroundRefresh] Background refresh failed for userId: \(userId): \(error)")
        }
    }
    
    /// Normalizes URL by removing http:// prefix for comparison
    private func normalizeIpFromUrl(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") {
            return String(trimmed.dropFirst(7))
        }
        if trimmed.hasPrefix("https://") {
            return String(trimmed.dropFirst(8))
        }
        return trimmed
    }
    
    /// Ensures URL has http:// prefix
    private func ensureHttpPrefix(_ url: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("http") {
            return url
        }
        return "http://\(url)"
    }
    
    /// Validates user data is complete and valid
    private func isValidUserData(_ user: User) -> Bool {
        return !user.mid.isEmpty && user.username != nil
    }
    
    /// Checks if two normalized IPs represent a redirect loop
    /// Performs the complete user update flow with retry logic
    /// This is the main workhorse method that handles retries and redirects
    private func performUserUpdate(_ user: User, maxRetries: Int, skipRetryAndBlacklist: Bool, logPrefix: String) async throws -> User {
        let originalBaseUrl = user.baseUrl?.absoluteString
        let hasExpired = await user.hasExpired()
        let userHasBaseUrl = user.baseUrl != nil && !(user.baseUrl?.absoluteString.isEmpty ?? true)
        // Only force fresh IP if we don't have a baseUrl at all
        // Don't force fresh IP just because user data expired - that's why we're fetching it!
        let forceFreshIP = originalBaseUrl == nil || originalBaseUrl?.isEmpty == true
        
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                // Resolve and update baseUrl
                try await resolveAndUpdateBaseUrl(
                    user: user,
                    attempt: attempt,
                    maxRetries: maxRetries,
                    forceFreshIP: forceFreshIP,
                    userHasBaseUrl: userHasBaseUrl,
                    hasExpired: hasExpired,
                    originalBaseUrl: originalBaseUrl
                )
                
                // Prepare server request
                let entry = "get_user"
                let params: [String: Any] = [
                    "aid": appId,
                    "ver": "last",
                    "version": "v3",
                    "userid": user.mid
                ]
                
                guard let hproseClient = user.hproseClient else {
                    print("ERROR: [\(logPrefix)] Cannot call get_user: hproseClient is null for userId: \(user.mid), baseUrl: \(user.baseUrl?.absoluteString ?? "nil")")
                    throw HproseError.noClient(userId: user.mid)
                }
                
                // Make server call
                guard let rawResponse = hproseClient.invoke("runMApp", withArgs: [entry, params]) else {
                    throw HproseError.noResponse(userId: user.mid)
                }
                
                // Check if the response is an error object (network failure case)
                if let error = rawResponse as? Error {
                    let nsError = error as NSError
                    print("ERROR: [\(logPrefix)] Network error during get_user: userId: \(user.mid), domain: \(nsError.domain), code: \(nsError.code)")
                    throw error
                }
                
                print("DEBUG: [\(logPrefix)] get_user rawResponse received for \(user.mid)")
                
                // Unwrap and process response
                let response = try Self.unwrapV2Response(rawResponse)
                
                // Process the response
                let success = try await processUserDataResponse(user: user, response: response as Any, skipRetryAndBlacklist: skipRetryAndBlacklist)
                
                if success {
                    return user
                }
                
                // If we get here, response was null - clear baseUrl and let retry loop handle it
                print("DEBUG: [\(logPrefix)] NULL RESPONSE for userId: \(user.mid) on attempt \(attempt)/\(maxRetries)")
                user.baseUrl = nil
                
                // If this was the last attempt, fail
                if attempt >= maxRetries {
                    print("ERROR: [\(logPrefix)] NULL RESPONSE on final attempt for userId: \(user.mid), adding to blacklist")
                    if !skipRetryAndBlacklist {
                        blackList.recordFailure(user.mid)
                    }
                    throw HproseError.userNotFound(userId: user.mid, reason: "User returned null after \(maxRetries) attempts")
                }
                
                // Otherwise, continue to next attempt - resolveAndUpdateBaseUrl will get fresh IP
                print("DEBUG: [\(logPrefix)] Will retry with fresh providerIP on next attempt")
                lastError = HproseError.userNotFound(userId: user.mid, reason: "Null response")
                continue
            } catch {
                // Handle cancellation specially - don't log as failure, don't retry
                if error is CancellationError {
                    print("DEBUG: [\(logPrefix)] Fetch cancelled for userId: \(user.mid), attempt: \(attempt)/\(maxRetries)")
                    throw error // Propagate cancellation immediately
                }
                
                lastError = error
                let nsError = error as NSError
                print("ERROR: [\(logPrefix)] USER UPDATE FAILED: userId: \(user.mid), attempt: \(attempt)/\(maxRetries), domain: \(nsError.domain), code: \(nsError.code)")
                
                if skipRetryAndBlacklist {
                    throw error
                }
                
                // Delay before retry
                if attempt < maxRetries {
                    let delayNs = UInt64(attempt) * 1_000_000_000 // 1 second per attempt
                    try await Task.sleep(nanoseconds: delayNs)
                }
            }
        }
        
        // All retries failed
        print("ERROR: [\(logPrefix)] ALL RETRIES FAILED: userId: \(user.mid), maxRetries: \(maxRetries)")
        if !skipRetryAndBlacklist {
            blackList.recordFailure(user.mid)
        }
        throw lastError ?? HproseError.noResponse(userId: user.mid)
    }
    
    /// Processes user data response from server
    /// Returns true if successful, false if null (needs retry), throws exception for errors
    private func processUserDataResponse(user: User, response: Any, skipRetryAndBlacklist: Bool) async throws -> Bool {
        // Handle dictionary response (user data)
        if let userDict = response as? [String: Any] {
            if !skipRetryAndBlacklist {
                blackList.recordSuccess(user.mid)
            }
            
            try await updateUserFromDict(userDict, for: user, preserveBaseUrl: false)
            
            if isValidUserData(user) {
                // Update NodePool with successful access
                NodePool.shared.updateFromUser(user)
                return true
            } else {
                print("ERROR: [processUserDataResponse] INVALID USER DATA: userId: \(user.mid), mid: \(user.mid), username: \(user.username ?? "nil")")
                throw HproseError.userNotFound(userId: user.mid, reason: "Invalid user data received")
            }
        }
        
        // Handle nil response - return false to indicate retry needed
        if response is NSNull {
            print("DEBUG: [processUserDataResponse] NULL RESPONSE: userId: \(user.mid), will retry with fresh providerIP")
            return false
        }
        
        // Unexpected response type
        print("ERROR: [processUserDataResponse] UNEXPECTED RESPONSE TYPE: userId: \(user.mid), type: \(type(of: response))")
        throw HproseError.unexpectedResponse(response: response)
    }
    /// Resolves and updates user's baseUrl (for first attempt or retries)
    private func resolveAndUpdateBaseUrl(
        user: User,
        attempt: Int,
        maxRetries: Int,
        forceFreshIP: Bool,
        userHasBaseUrl: Bool,
        hasExpired: Bool,
        originalBaseUrl: String?
    ) async throws {
        // On first attempt with existing baseUrl, validate against pool
        if attempt == 1 && !forceFreshIP && userHasBaseUrl && !(user.baseUrl?.absoluteString.isEmpty ?? true) {
            // Check if user's current IP is valid in the pool
            if NodePool.shared.isUserIPValid(for: user) {
                print("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - User's baseUrl validated in pool: \(user.baseUrl?.absoluteString ?? "nil")")
                return
            } else {
                print("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - User's baseUrl NOT in pool, will get IP from pool")
            }
        }
        
        // Try to get IP from user's node in the pool
        if let poolIP = NodePool.shared.getIPFromNode(for: user) {
            print("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - Using IP from pool for userId: \(user.mid): \(poolIP)")
            if let url = URL(string: ensureHttpPrefix(poolIP)) {
                await applyBaseUrlIfNeeded(user, url: url, reason: "from NodePool")
                return
            }
        }
        
        // Fallback: resolve fresh IP via getProviderIP
        let reason: String
        if originalBaseUrl == nil || originalBaseUrl?.isEmpty == true {
            reason = "no cached baseUrl"
        } else if hasExpired {
            reason = "cache expired"
        } else if attempt > 1 {
            reason = "retry after failure"
        } else {
            reason = "not in pool"
        }
        
        print("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - Calling getProviderIP for userId: \(user.mid), reason: \(reason)")
        guard let providerIP = try await getProviderIP(user.mid) else {
            throw HproseError.noResponse(userId: user.mid)
        }
        
        if let url = URL(string: ensureHttpPrefix(providerIP)) {
            await applyBaseUrlIfNeeded(user, url: url, reason: "from getProviderIP (\(reason))")
            
            // Update pool with new IP (replaces old IP list)
            if let hostIds = user.hostIds, !hostIds.isEmpty {
                let nodeMid = hostIds.count > 1 ? hostIds[1] : hostIds[0]
                NodePool.shared.updateNodeIP(nodeMid: nodeMid, newIP: providerIP)
            }
        }
        
        if user.hproseClient == nil {
            print("ERROR: [resolveAndUpdateBaseUrl] hproseClient is null after setting baseUrl: \(user.baseUrl?.absoluteString ?? "nil") for userId: \(user.mid)")
        }
    }
    

    
    /// Get provider IP for a user with health checking and fallback retry
    /// - Parameter mid: User's member ID
    /// - Parameter attemptNumber: Internal parameter to track retry attempts (1 or 2)
    /// - Returns: A healthy provider IP address, or nil if none found
    /// - Throws: Error only after both attempts fail
    func getProviderIP(_ mid: String, v4Only: Bool = false) async throws -> String? {
        // Safety check: never try to get provider IP for GUEST_ID
        if mid == Constants.GUEST_ID {
            print("ERROR: [getProviderIP] Refusing to get provider IP for GUEST_ID")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot get provider IP for GUEST_ID"])
        }
        
        let providerIP = await _getProviderIP(mid, v4Only: v4Only)
        if (providerIP != nil) {
            return providerIP
        }

        if (mid == appUser.mid) {
            guard let entryIP = try await findEntryIP() else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
            }
            return await _getProviderIP(mid, v4Only: v4Only, hproseClient: clientPool.getClientByIP(for: entryIP))
        } else {
            guard let appUserClient = appUser.hproseClient else {
                print("ERROR: [getProviderIP] appUser.hproseClient is nil")
                return nil
            }
            if (await isServerHealthy(appUserClient) != true) {
                // appUser's server is unhealthy, re-initialize via entry IP
                print("DEBUG: [getProviderIP] appUser's server unhealthy, re-initializing via entry IP")
                guard let entryIP = try await findEntryIP() else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
                }
                let ip = await _getProviderIP(appUser.mid, v4Only: v4Only, hproseClient: clientPool.getClientByIP(for: entryIP))
                if let ip = ip {
                    appUser.baseUrl = URL(string: "http://\(ip)")
                }
                return await _getProviderIP(mid, v4Only: v4Only)
            }
            
            // AppUser server is healthy but initial lookup returned nil
            // This means appUser server responded but all IPs for this user failed health checks
            // Entry IP would return the same unhealthy IPs, so no point trying it
            print("DEBUG: [getProviderIP] Initial lookup failed for \(mid) and appUser server is healthy - all user IPs are unhealthy")
            return nil
        }
    }
    
    private func _getProviderIP(
        _ mid: MimeiId,
        v4Only: Bool = false,
        hproseClient: HproseClient? = HproseInstance.shared.appUser.hproseClient
    ) async -> String? {
        let entry = "get_provider_ips"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "mid": mid,
            "v4only": v4Only ? "true" : "false"
        ]
        
        guard let hproseClient = hproseClient else {
            print("DEBUG: [_getProviderIP] No hprose client available")
            return nil
        }
        
        let rawResponse = hproseClient.invoke("runMApp", withArgs: [entry, params])
        guard let response = rawResponse else {
            print("DEBUG: [_getProviderIP] No response from server.")
            return nil
        }
        
        // Unwrap v2 response - handle IP redirects which may be strings
        let unwrappedResponse: Any?
        do {
            unwrappedResponse = try Self.unwrapV2Response(response)
        } catch {
            print("DEBUG: [_getProviderIP] Error unwrapping v2 response: \(error)")
            return nil
        }
        
        if let ipList = unwrappedResponse as? [String] {
            // Filter and trim IP addresses
            let ipAddresses = ipList
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            print("DEBUG: [_getProviderIP] Retrieved \(ipAddresses.count) IP address(es) from get_provider_ips API")
            
            // Test IPs in batches of 4 for faster discovery during high load
            let batchSize = 4
            for batchStart in stride(from: 0, to: ipAddresses.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ipAddresses.count)
                let batch = Array(ipAddresses[batchStart..<batchEnd])
                
                print("DEBUG: [_getProviderIP] Testing batch: IPs \(batchStart + 1)-\(batchEnd) of \(ipAddresses.count)")
                
                // Test this batch in parallel - return as soon as first IP responds successfully
                let healthyIP: String? = await withTaskGroup(of: (String, Bool)?.self) { group in
                    for (index, ip) in batch.enumerated() {
                        let absoluteIndex = batchStart + index + 1
                        group.addTask {
                            // Check for cancellation before starting
                            if Task.isCancelled {
                                return nil
                            }
                            
                            print("DEBUG: [_getProviderIP] Testing IP \(absoluteIndex)/\(ipAddresses.count): \(ip)")
                            
                            let client = self.clientPool.getClientByIP(for: ip)
                            let isHealthy = await self.isServerHealthyWithTimeout(client, timeout: 10.0)
                            self.clientPool.releaseClient(client, for: ip)
                            
                            // Check for cancellation after health check
                            if Task.isCancelled {
                                return nil
                            }
                            
                            if isHealthy {
                                print("DEBUG: [_getProviderIP] ✅ IP test PASSED: \(ip)")
                            } else {
                                print("DEBUG: [_getProviderIP] ❌ IP test FAILED: \(ip)")
                            }
                            
                            return (ip, isHealthy)
                        }
                    }
                    
                    // Return IMMEDIATELY when first healthy IP is found
                    for await result in group {
                        if let (ip, isHealthy) = result, isHealthy {
                            print("DEBUG: [_getProviderIP] Found healthy provider IP: \(ip) - returning immediately")
                            group.cancelAll()  // Cancel remaining checks in this batch
                            return ip as String?
                        }
                    }
                    return nil as String?
                }
                
                // If we found a healthy IP in this batch, return it
                if let ip = healthyIP {
                    return ip
                }
            }
            
            // If no healthy IP found in any batch, return nil to trigger entry IP fallback
            // getProviderIP() will try via entry IP, and if that fails too, it can try the first IP as last resort
            if !ipAddresses.isEmpty {
                print("DEBUG: [_getProviderIP] All health checks failed for \(ipAddresses.count) IP(s), returning nil to trigger fallback")
                return nil
            }
            
            print("DEBUG: [_getProviderIP] No IPs available in response")
            return nil
        }
        print("DEBUG: [_getProviderIP] Invalid IpList response format")
        return nil
    }
    
    // MARK: - IP Cache Methods
    
    /// Check if an IP is in the cache and still valid
    private func getCachedIP(_ ip: String) -> Bool {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        if let entry = ipCache[ip] {
            if !entry.isExpired {
                print("DEBUG: [IPCache] Cache HIT for IP: \(ip) (age: \(Int(Date().timeIntervalSince(entry.timestamp)))s)")
                return true
            } else {
                print("DEBUG: [IPCache] Cache EXPIRED for IP: \(ip)")
                ipCache.removeValue(forKey: ip)
            }
        }
        return false
    }
    
    /// Cache a validated IP
    private func cacheIP(_ ip: String) {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        ipCache[ip] = IPCacheEntry(ip: ip, timestamp: Date())
        print("DEBUG: [IPCache] Cached IP: \(ip)")
    }
    
    /// Clear expired entries from cache
    private func cleanupExpiredCache() {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        let beforeCount = ipCache.count
        ipCache = ipCache.filter { !$0.value.isExpired }
        let removedCount = beforeCount - ipCache.count
        if removedCount > 0 {
            print("DEBUG: [IPCache] Cleaned up \(removedCount) expired entries")
        }
    }
    
    /// Invalidate a specific IP from cache (useful when an IP fails after being cached)
    func invalidateIPCache(for ip: String) {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        if ipCache.removeValue(forKey: ip) != nil {
            print("DEBUG: [IPCache] Invalidated cache for IP: \(ip)")
        }
    }
    
    /// Clear all cached IPs (useful for testing or reset)
    func clearIPCache() {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        let count = ipCache.count
        ipCache.removeAll()
        print("DEBUG: [IPCache] Cleared all \(count) cached IPs")
    }
    
    // MARK: - Health Check Methods
    
    /// Checks if a server is healthy using HTTP HEAD request to base URL
    /// - Parameter hproseClient: The client to check (uses its uri property)
    /// - Returns: true if server responds to HEAD request, false otherwise
    private func isServerHealthy(_ hproseClient: HproseClient) async -> Bool {
        // Extract IP from client URI
        guard let uriString = hproseClient.uri else {
            print("DEBUG: [isServerHealthy] No URI found in client")
            return false
        }
        
        // Extract base URL (without /webapi/ path) for server health check
        // URI format is "http://IP/webapi/" -> we want "http://IP/"
        guard let fullURL = URL(string: uriString),
              let scheme = fullURL.scheme,
              let host = fullURL.host else {
            print("DEBUG: [isServerHealthy] Invalid URI: \(uriString)")
            return false
        }
        
        // Construct base URL for testing the server itself
        // Handle IPv6 addresses which need brackets: [2001:...]:port
        var baseURLString = "\(scheme)://"
        
        // Check if this is an IPv6 address (contains colons but not wrapped in brackets yet)
        if host.contains(":") && !host.hasPrefix("[") {
            baseURLString += "[\(host)]"
        } else {
            baseURLString += host
        }
        
        if let port = fullURL.port {
            baseURLString += ":\(port)"
        }
        baseURLString += "/"
        
        // Check cache first (cache by IP only, not full URL)
        // For IPv6, use the raw host without brackets for caching
        let cacheKey = host + (fullURL.port.map { ":\($0)" } ?? "")
        if getCachedIP(cacheKey) {
            return true
        }
        
        guard let baseURL = URL(string: baseURLString) else {
            print("DEBUG: [isServerHealthy] Failed to construct base URL from: \(uriString)")
            return false
        }
        
        // Perform HTTP HEAD request to base URL (test server, not service endpoint)
        var request = URLRequest(url: baseURL, timeoutInterval: 5.0)
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await healthCheckSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                let isHealthy = (200...299).contains(httpResponse.statusCode)
                
                if isHealthy {
                    print("DEBUG: [isServerHealthy] ✅ HEAD request succeeded: \(baseURLString) (status: \(httpResponse.statusCode))")
                    
                    // Cache the validated IP
                    cacheIP(cacheKey)
                    return true
                } else {
                    print("DEBUG: [isServerHealthy] ❌ HEAD request failed: \(baseURLString) (status: \(httpResponse.statusCode))")
                }
            }
        } catch {
            // Check if this is a cancellation (normal when faster IP found)
            let nsError = error as NSError
            let isCancellation = nsError.code == NSURLErrorCancelled
            
            if isCancellation {
                print("DEBUG: [isServerHealthy] ⏭️  HEAD request cancelled for \(baseURLString) (faster IP found)")
            } else {
                print("DEBUG: [isServerHealthy] ❌ HEAD request error for \(baseURLString): domain=\(nsError.domain), code=\(nsError.code)")
            }
        }
        
        return false
    }
    
    /// Checks if a server is healthy with a timeout
    /// - Parameters:
    ///   - hproseClient: The client to check
    ///   - timeout: Timeout in seconds (default: 10)
    /// - Returns: true if healthy within timeout, false otherwise
    private func isServerHealthyWithTimeout(_ hproseClient: HproseClient, timeout: TimeInterval = 10.0) async -> Bool {
        // Check if already cancelled before starting
        if Task.isCancelled {
            return false
        }
        
        // Periodically clean up expired cache entries
        cleanupExpiredCache()
        
        return await withTaskGroup(of: Bool.self) { group in
            // Task 1: Perform health check (HEAD request)
            group.addTask {
                if Task.isCancelled {
                    return false
                }
                return await self.isServerHealthy(hproseClient)
            }
            
            // Task 2: Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false  // Return false on timeout
            }
            
            // Return first result (either health check or timeout)
            let result = await group.next() ?? false
            group.cancelAll()  // Cancel the other task
            return result
        }
    }
    

    
    /// Updates user from dictionary response
    private func updateUserFromDict(_ dict: [String: Any], for user: User, preserveBaseUrl: Bool = false) async throws {
        try await MainActor.run {
            let originalBaseUrl = user.baseUrl
            let updatedUser = try User.from(dict: dict)
            
            // Preserve baseUrl if needed (e.g., after redirect)
            if preserveBaseUrl || originalBaseUrl != nil {
                updatedUser.baseUrl = originalBaseUrl
            }
            
            print("DEBUG: [updateUserFromDict] Updated user: \(updatedUser.username ?? "nil") (\(updatedUser.mid))")
            
            User.updateUserInstance(with: updatedUser)
            TweetCacheManager.shared.saveUser(updatedUser)
        }
    }
    
    // MARK: - Error Types
    
    private enum HproseError: LocalizedError {
        case noClient(userId: String)
        case noResponse(userId: String)
        case userNotFound(userId: String, reason: String)
        case unexpectedResponse(response: Any)
        
        var errorDescription: String? {
            switch self {
            case .noClient(let userId):
                return "No hprose client available for user: \(userId)"
            case .noResponse(let userId):
                return "No response from server for user: \(userId)"
            case .userNotFound(let userId, let reason):
                return "User \(userId) not found: \(reason)"
            case .unexpectedResponse(let response):
                return "Unexpected response from server: \(String(describing: response))"
            }
        }
        
        var nsError: NSError {
            return NSError(domain: "HproseClient", code: -1, userInfo: [
                NSLocalizedDescriptionKey: errorDescription ?? "Unknown error"
            ])
        }
    }
    
    /// Resyncs a user from the backend and returns the updated user object
    func resyncUser(userId: String) async throws -> User {
        return try await withRetry {
            // Get the user instance first to access their baseUrl
            let user = User.getInstance(mid: userId)
            
            // If user doesn't have a baseUrl, fetch it first
            if user.baseUrl == nil {
                print("DEBUG: [resyncUser] User \(userId) has no baseUrl, fetching user first to resolve IP")
                _ = try await fetchUser(userId, baseUrl: "")
            }
            
            let entry = "resync_user"
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "userid": userId
            ]
            
            // Use the target user's hproseClient (with their baseUrl) instead of appUser's
            guard let client = user.hproseClient else {
                // Fallback to appUser's client if target user's client is not available
                print("DEBUG: [resyncUser] User \(userId) has no hproseClient, falling back to appUser's client")
                guard let fallbackClient = appUser.hproseClient else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
                }
                // Use fallback client but log the issue
                print("DEBUG: [resyncUser] Using appUser's client for user \(userId) - this may use wrong baseUrl")
                let rawResponse = fallbackClient.invoke("runMApp", withArgs: [entry, params])
                let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
                guard let userData = unwrappedResponse as? [String: Any] else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
                }
                
                // Update user properties from the response
                await MainActor.run {
                    user.name = userData["name"] as? String
                    user.username = userData["username"] as? String
                    user.email = userData["email"] as? String
                    user.profile = userData["profile"] as? String
                    user.avatar = userData["avatar"] as? String
                    user.tweetCount = userData["tweetCount"] as? Int
                    user.followingCount = userData["followingCount"] as? Int
                    user.followersCount = userData["followersCount"] as? Int
                    user.bookmarksCount = userData["bookmarksCount"] as? Int
                    user.favoritesCount = userData["favoritesCount"] as? Int
                    user.commentsCount = userData["commentsCount"] as? Int
                    
                    // Update cloudDrivePort if provided
                    if let cloudDrivePort = userData["cloudDrivePort"] as? Int {
                        user.cloudDrivePort = cloudDrivePort
                    }
                }
                TweetCacheManager.shared.saveUser(user)
                return user
            }
            
            print("DEBUG: [resyncUser] Using user's own hproseClient with baseUrl: \(user.baseUrl?.absoluteString ?? "nil") for userId: \(userId)")
            
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let userData = unwrappedResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            // Update user properties from the response
            await MainActor.run {
                user.name = userData["name"] as? String
                user.username = userData["username"] as? String
                user.email = userData["email"] as? String
                user.profile = userData["profile"] as? String
                user.avatar = userData["avatar"] as? String
                user.tweetCount = userData["tweetCount"] as? Int
                user.followingCount = userData["followingCount"] as? Int
                user.followersCount = userData["followersCount"] as? Int
                user.bookmarksCount = userData["bookmarksCount"] as? Int
                user.favoritesCount = userData["favoritesCount"] as? Int
                user.commentsCount = userData["commentsCount"] as? Int
                
                // Update cloudDrivePort if provided
                if let cloudDrivePort = userData["cloudDrivePort"] as? Int {
                    user.cloudDrivePort = cloudDrivePort
                }
            }
            TweetCacheManager.shared.saveUser(user)

            return user
        }
    }
    
    func login(_ loginUser: User) async throws -> [String: Any] {
        let entry = "login"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "username": loginUser.username!,
            "password": loginUser.password!
        ]
        
        guard let baseUrl = loginUser.baseUrl else {
            print("ERROR: [login] Nil user baseUrl")
            return ["reason": NSLocalizedString("Login failed", comment: "Generic login failure message"), "status": "failure"]
        }
        
        print("DEBUG: [login] Starting login API call to baseUrl: \(baseUrl.absoluteString)")
        
        return try await retryOperation(maxRetries: 3) {
            print("DEBUG: [login] Creating client for baseUrl: \(baseUrl.absoluteString)")
            let newClient = self.clientPool.getClientByUrl(for: baseUrl.absoluteString)
            newClient.timeout = 30.0  // 30 seconds (NSTimeInterval is in seconds, not milliseconds!)
            
            // Release client back to pool when done (no need to close)
            defer { 
                // Note: Not releasing back to pool since timeout is configured differently
                // Let the pool manage lifecycle naturally
            }
            
            print("DEBUG: [login] Invoking login API...")
            let rawResponse = newClient.invoke("runMApp", withArgs: [entry, params])
            print("DEBUG: [login] Got raw response, unwrapping...")
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            guard let response = unwrappedResponse as? [String: Any] else {
                print("ERROR: [login] Invalid response format from server")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
            }
            
            print("DEBUG: [login] Response received: \(response)")
            
            // Handle v2 format: check success field first, then status field for backward compatibility
            if let success = response["success"] as? Bool {
                if !success {
                    let message = response["message"] as? String ?? NSLocalizedString("Login failed", comment: "Generic login failure message")
                    let localizedReason = self.localizeLoginError(message)
                    print("DEBUG: [login] Login failed with message: \(message)")
                    return ["reason": localizedReason, "status": "failure"]
                }
                // success is true, check for user data
                if response["user"] != nil || response["data"] != nil {
                    print("DEBUG: [login] Login successful, setting appUser")
                    await MainActor.run {
                        self.preferenceHelper?.setUserId(loginUser.mid)
                        self.appUser = loginUser
                    }
                    Task {
                        await self.populateFellowLists(user: loginUser)
                    }
                    return ["reason": NSLocalizedString("Success", comment: "Success message"), "status": "success"]
                }
            }
            
            // Check for status field (alternate response format)
            if let status = response["status"] as? String {
                if status == "failure" {
                    // Extract and localize the reason from server
                    let serverReason = response["reason"] as? String ?? NSLocalizedString("Login failed", comment: "Generic login failure message")
                    let localizedReason = self.localizeLoginError(serverReason)
                    print("DEBUG: [login] Login failed with status: \(status), reason: \(serverReason)")
                    return ["reason": localizedReason, "status": "failure"]
                } else if status == "success" && response["user"] != nil {
                    print("DEBUG: [login] Login successful (status field), setting appUser")
                    await MainActor.run {
                        self.preferenceHelper?.setUserId(loginUser.mid)
                        self.appUser = loginUser
                    }
                    Task {
                        await self.populateFellowLists(user: loginUser)
                    }
                    return ["reason": NSLocalizedString("Success", comment: "Success message"), "status": "success"]
                }
            }
            
            print("DEBUG: [login] Login failed - no success field or no user data")
            return ["reason": NSLocalizedString("Login failed", comment: "Generic login failure message"), "status": "failure"]
        }
    }
    
    /// Maps backend login error messages to localized versions
    private func localizeLoginError(_ backendError: String) -> String {
        let lowercasedError = backendError.lowercased()
        
        // Common backend error patterns and their localized equivalents
        if lowercasedError.contains("wrong password") || lowercasedError.contains("invalid password") || lowercasedError.contains("incorrect password") {
            return NSLocalizedString("Wrong password", comment: "Wrong password error message")
        }
        
        if lowercasedError.contains("invalid username") || lowercasedError.contains("username not found") {
            return NSLocalizedString("Invalid username", comment: "Invalid username error message")
        }
        
        if lowercasedError.contains("user not found") || lowercasedError.contains("account not found") {
            return NSLocalizedString("User not found", comment: "User not found error message")
        }
        
        if lowercasedError.contains("authentication failed") || lowercasedError.contains("auth failed") {
            return NSLocalizedString("Authentication failed", comment: "Authentication failed error message")
        }
        
        if lowercasedError.contains("login failed") {
            return NSLocalizedString("Login failed", comment: "Login failed error message")
        }
        
        // If no specific pattern matches, return the original error message
        // This allows for custom error messages from the backend to pass through
        return backendError
    }
    
    func logout() async {
        preferenceHelper?.setUserId(nil as String?)
        
        // Don't clear tweet cache on logout - cache persists per user and is cleared periodically or manually
        // Clear chat cache on signout
        ChatCacheManager.shared.clearAllCache()
        
        // Clear all video cache files from disk
        // await CachingPlayerItem.clearAllCache()
        
        // Reset appUser to guest user
        let guestUser = User.getInstance(mid: Constants.GUEST_ID)
        await MainActor.run {
            guestUser.baseUrl = appUser.baseUrl
            guestUser.followingList = Gadget.getAlphaIds()
            self.appUser = guestUser
        }
        
        // Fetch alphaId user for guest and notify FollowingsTweetView
        await fetchAlphaIdUserForGuest()
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
            "version": "v2",
            "userid": user.mid,
        ]
        guard let client = user.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry.rawValue, params])
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when user has no followers/following
        let response: [[String: Any]]
        if let arrayResponse = unwrappedResponse as? [[String: Any]] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            print("DEBUG: [HproseInstance] getListByType - Server returned empty array for \(entry.rawValue)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
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
            "version": "v2",
            "userid": user.mid
        ]
        
        do {
            guard let client = user.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            
            // Unwrap v2 response
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            // Handle empty array case - server returns empty array when user has no followings
            let response: [[String: Any]]
            if let arrayResponse = unwrappedResponse as? [[String: Any]] {
                response = arrayResponse
            } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
                // Server returned empty array - handle gracefully
                response = []
                print("DEBUG: [HproseInstance] getFollowings - Server returned empty array (no followings)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
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
    func populateFellowLists(user: User) async {
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
            "version": "v2",
            "userid": user.mid
        ]
        
        do {
            guard let client = user.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            // Handle empty array case - server returns empty array when user has no fans
            let response: [[String: Any]]
            if let arrayResponse = unwrappedResponse as? [[String: Any]] {
                response = arrayResponse
            } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
                // Server returned empty array - handle gracefully
                response = []
                print("DEBUG: [HproseInstance] getFans - Server returned empty array (no fans)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
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
            "version": "v2",
            "userid": user.mid,
            "type": type.rawValue,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUser.mid
        ] as [String : Any]
        print("DEBUG: [HproseInstance] getUserTweetsByType params: \(params)")
        
        guard let client = user.hproseClient else {
            print("DEBUG: [HproseInstance] getUserTweetsByType - Client not initialized for user: \(user.mid)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        print("DEBUG: [HproseInstance] getUserTweetsByType - Unwrapped response type: \(String(describing: Swift.type(of: unwrappedResponse)))")
        
        // Handle response - can be an array of dictionaries or array of optional dictionaries
        let response: [[String: Any]?]
        if let arrayResponse = unwrappedResponse as? [[String: Any]?] {
            // Array of optional dictionaries
            response = arrayResponse
        } else if let arrayResponse = unwrappedResponse as? [[String: Any]] {
            // Array of dictionaries - convert to array of optional dictionaries
            response = arrayResponse.map { $0 as [String: Any]? }
        } else if let arrayResponse = unwrappedResponse as? [Any] {
            // Array of Any - try to cast each element
            if arrayResponse.isEmpty {
                response = []
                print("DEBUG: [HproseInstance] getUserTweetsByType - Server returned empty array (no bookmarks/favorites)")
            } else {
                response = arrayResponse.map { item in
                    if let dict = item as? [String: Any] {
                        return dict
                    } else {
                        print("DEBUG: [HproseInstance] getUserTweetsByType - Array item is not a dictionary: \(String(describing: Swift.type(of: item)))")
                        return nil
                    }
                }
            }
        } else {
            print("DEBUG: [HproseInstance] getUserTweetsByType - Invalid response format: \(String(describing: unwrappedResponse))")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserTweetsByType"])
        }
        
        print("DEBUG: [HproseInstance] getUserTweetsByType - Got response with \(response.count) items")
        
        var tweetsWithAuthors: [Tweet?] = []
        for (index, dict) in response.enumerated() {
            if let item = dict {
                do {
                    let tweet = try await MainActor.run { return try Tweet.from(dict: item) }
                    if (tweet.author == nil) {
                        if let author = try? await fetchUser(tweet.authorId) {
                            await MainActor.run {
                                tweet.author = author  // Set on main thread since author is @Published
                            }
                        }
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
     * @param userId is the user who is performing the follow/unfollow action (defaults to appUser.mid)
     * */
    func toggleFollowing(
        followingId: MimeiId,
        userId: MimeiId? = nil
    )  async throws -> Bool? {
        let effectiveUserId = userId ?? appUser.mid
        
        // Check if app user is blacklisted by the target user
        guard let targetUser = try await fetchUser(followingId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Target user not found", comment: "User lookup error")])
        }
        if targetUser.isUserBlacklisted(effectiveUserId) {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot follow this user because you are blocked", comment: "Follow blocked error")])
        }
        
        return try await withRetry {
            let entry = "toggle_following"
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "followingid": followingId,
                "userid": effectiveUserId,
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            // For v2 API: server returns {success: true, data: {isFollowing: bool}}
            // After unwrapV2Response, we get {isFollowing: bool}
            if let dataDict = unwrappedResponse as? [String: Any] {
                if let isFollowing = dataDict["isFollowing"] as? Bool {
                    return isFollowing
                }
            }
            
            // Fallback: check if it's a direct Bool (legacy format)
            if let boolResponse = unwrappedResponse as? Bool {
                return boolResponse
            }
            
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
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
                "version": "v2",
                "appuserid": appUser.mid,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let response = unwrappedResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
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
                // Cache the updated tweet under its authorId, not appUser.mid
                // This ensures original tweets are cached under their author, not the current user
                TweetCacheManager.shared.saveTweet(updatedTweet!, userId: updatedTweet!.authorId)
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
                "version": "v2",
                "userid": appUser.mid,
                "tweetid": tweet.mid,
                "authorid": tweet.authorId,
                "userhostid": appUser.hostIds?.first as Any
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let response = unwrappedResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
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
                // Cache the updated tweet under its authorId, not appUser.mid
                // This ensures original tweets are cached under their author, not the current user
                TweetCacheManager.shared.saveTweet(updatedTweet!, userId: updatedTweet!.authorId)
            }
            
            return (updatedTweet, updatedUser)
        }
    }
    
    func retweet(_ tweet: Tweet) async throws -> Tweet? {
        // Create a unique temporary ID for this retweet to avoid singleton collisions
        // Multiple rapid retweets would otherwise share the same GUEST_ID singleton
        let temporaryId = "TEMP_RETWEET_\(UUID().uuidString)"
        print("🔄 [HproseInstance.retweet] Creating retweet with temporary ID: \(temporaryId) for original tweet: \(tweet.mid)")
        
        // Upload the retweet
        guard let retweet = try await uploadTweet(
            await MainActor.run {
                Tweet.getInstance(
                    mid: temporaryId,
                    authorId: appUser.mid,
                    originalTweetId: tweet.mid,
                    originalAuthorId: tweet.authorId,
                    author: appUser
                )
            }
        ) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Retweet upload failed", comment: "Retweet error")])
        }
        
        // Update retweet count of the original tweet and cache the updated tweet
        // Match Android behavior: update count, cache result, then post notification
        if let updatedTweet = await updateRetweetCount(tweet: tweet, retweetId: retweet.mid) {
            // Cache the updated original tweet with its authorId as the cache key
            // This ensures the original tweet is cached under its author's cache, not appUser's
            TweetCacheManager.shared.saveTweet(updatedTweet, userId: updatedTweet.authorId)
        }
        
        // Cache the retweet by its authorId (matches Android behavior)
        // For retweets, authorId equals appUser.mid, so this is consistent with mainfeed caching
        // The retweet will also be cached via .newTweetCreated notification in handleNewTweet,
        // but we cache it here explicitly to ensure it's saved
        TweetCacheManager.shared.saveTweet(retweet, userId: retweet.authorId)
        
        // Clean up the temporary tweet instance to prevent memory leaks
        if temporaryId != retweet.mid {
            Tweet.clearInstance(mid: temporaryId)
            print("🧹 [HproseInstance.retweet] Cleaned up temporary tweet instance: \(temporaryId)")
        }
        
        return retweet
    }
    
    /**
     * Increase the retweetCount of the original tweet mimei.
     * @param tweet is the original tweet
     * @param retweetId of the retweet.
     * @param direction to indicate increase or decrease retweet count.
     * @return updated original tweet.
     * */
    /// Update retweet count of the original tweet
    /// Returns the updated tweet from server, or nil if update fails
    /// Matches Android behavior: returns nil on error instead of throwing
    /// Uses the original tweet's author's client (like Android) to ensure we're calling the correct server
    func updateRetweetCount(
        tweet: Tweet,
        retweetId: String,
        direction: Bool = true   // add/remove retweet
    ) async -> Tweet? {
        let entry = direction ? "retweet_added" : "retweet_removed"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "appuserid": appUser.mid,
            "retweetid": retweetId,
            "tweetid": tweet.mid,
            "authorid": tweet.authorId,
        ]
        
        // Match Android: use original tweet's author's client, fallback to appUser's client
        let client = tweet.author?.hproseClient ?? appUser.hproseClient
        
        guard let client = client else {
            print("⚠️ [updateRetweetCount] Client not initialized")
            return nil
        }
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        guard let unwrappedResponse = try? Self.unwrapV2Response(rawResponse) else {
            print("⚠️ [updateRetweetCount] Failed to unwrap v2 response")
            return nil
        }
        guard let tweetDict = unwrappedResponse as? [String: Any] else {
            print("⚠️ [updateRetweetCount] Nil response from server")
            return nil
        }
        
        do {
            // Update the tweet from server response
            try await MainActor.run {
                try tweet.update(from: tweetDict)
            }
            // Return the updated tweet (same instance, updated in place)
            return tweet
        } catch {
            print("⚠️ [updateRetweetCount] Failed to update tweet from server response: \(error)")
            return nil
        }
    }
    
    /**
     * Update tweet privacy (public/private). Only appUser can update its own tweet.
     * Returns the new privacy status as a boolean.
     * */
    func updateTweetPrivacy(tweetId: String) async throws -> Bool {
        return try await withRetry {
            let entry = "update_tweet_privacy"
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "appuserid": appUser.mid,
                "tweetid": tweetId
            ]
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            print("[updateTweetPrivacy] Raw response: \(String(describing: rawResponse))")
            
            // Unwrap v2 response
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            print("[updateTweetPrivacy] Unwrapped response: \(String(describing: unwrappedResponse))")
            
            // For v2 API: server returns {success: true, data: {isPrivate: bool}}
            // After unwrapV2Response, we get {isPrivate: bool}
            if let dataDict = unwrappedResponse as? [String: Any] {
                if let isPrivate = dataDict["isPrivate"] as? Bool {
                    print("[updateTweetPrivacy] Privacy status from v2 format: \(isPrivate)")
                    return isPrivate
                }
            }
            
            // Fallback: check if it's a direct Bool (legacy format)
            if let isPrivateBool = unwrappedResponse as? Bool {
                print("[updateTweetPrivacy] Direct boolean response: \(isPrivateBool)")
                return isPrivateBool
            }
            
            // Handle numeric responses (0 = false, 1 = true) - legacy format
            if let numericResponse = unwrappedResponse as? NSNumber {
                let isPrivate = numericResponse.boolValue
                print("[updateTweetPrivacy] Numeric response: \(numericResponse) -> boolean: \(isPrivate)")
                return isPrivate
            }
            
            // Handle integer responses (0 = false, 1 = true) - legacy format
            if let intResponse = unwrappedResponse as? Int {
                let isPrivate = intResponse != 0
                print("[updateTweetPrivacy] Integer response: \(intResponse) -> boolean: \(isPrivate)")
                return isPrivate
            }
            
            print("[updateTweetPrivacy] Unexpected response format: \(String(describing: unwrappedResponse))")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
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
            "version": "v2",
            "userid": appUser.mid,
            "tweetid": tweetId
        ]
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        guard let response = unwrappedResponse as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        if success {
            // Success case: return the tweet ID
            guard let deletedTweetId = response["tweetid"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            print("DEBUG: [deleteTweet] Successfully deleted tweet \(deletedTweetId)")
            
            // Immediately update appUser tweet count (like favorites/bookmarks)
            await MainActor.run {
                let currentCount = self.appUser.tweetCount ?? 0
                self.appUser.tweetCount = max(0, currentCount - 1)
                print("DEBUG: [deleteTweet] Updated appUser.tweetCount to \(self.appUser.tweetCount ?? 0)")
            }
            
            // Refresh appUser from server to get updated tweetCount and other properties
            try? await self.refreshAppUserFromServer()
            
            return deletedTweetId
        } else {
            // Failure case: extract error message
            let errorMessage = response["message"] as? String ?? "Unknown tweet deletion error"
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
    
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            // Check if app user is blacklisted by the tweet author
            if let tweetAuthor = tweet.author {
                if tweetAuthor.isUserBlacklisted(appUser.mid) {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot comment on this tweet because you are blocked by the author", comment: "Comment blocked error")])
                }
            }
            
            // Wait for writableUrl to be resolved
            let resolvedUrl = try await appUser.resolveWritableUrl()
            guard resolvedUrl != nil else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Writable URL not available", comment: "URL resolution error")])
            }
            
            guard let uploadClient = appUser.uploadClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            
            comment.author = nil
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "hostid": tweet.author?.hostIds?.first as Any,
                "comment": String(data: try JSONEncoder().encode(comment), encoding: .utf8) ?? "",
                "tweetid": tweet.mid,
                "appuserid": appUser.mid
            ]
            let entry = "add_comment"
            let rawResponse = uploadClient.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        if success {
            // Success case: extract comment ID and count
            guard let commentId = response["mid"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            await MainActor.run {
                comment.mid = commentId
                comment.author = appUser
                tweet.commentCount = count
            }
            // Cache the updated tweet under its authorId, not appUser.mid
            // This ensures original tweets are cached under their author, not the current user
            TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
            
            // Check if retweetid is present and create a new tweet
            if let retweetId = response["retweetid"] as? String, !retweetId.isEmpty {
                print("[HproseInstance] Retweet ID received: \(retweetId)")
                
                // Create a new tweet with the comment's content and original tweet ID using singleton
                // Register it in the singleton cache (even though we return the original comment)
                _ = Tweet.getInstance(
                    mid: retweetId,
                    authorId: appUser.mid,
                    content: comment.content,
                    timestamp: comment.timestamp,
                    originalTweetId: tweet.mid,
                    originalAuthorId: tweet.authorId,
                    author: appUser,
                    attachments: comment.attachments
                )
                
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
    }
    
    // both author and tweet author can delete this comment
    func deleteComment(parentTweet: Tweet, commentId: String) async throws -> [String: Any]? {
        let entry = "delete_comment"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": parentTweet.mid,
            "hostid": parentTweet.author?.hostIds?.first as Any,
            "commentid": commentId,
            "appuserid": appUser.mid
        ]
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        guard let response = unwrappedResponse as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        // Handle the new JSON response format
        guard let success = response["success"] as? Bool else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        if success {
            // Success case: return the response with commentId and count
            guard let deletedCommentId = response["commentId"] as? String else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            guard let count = response["count"] as? Int else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
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
        // Delegate to upload manager
        return try await uploadManager.uploadToIPFS(
            data: data,
            typeIdentifier: typeIdentifier,
            fileName: fileName,
            referenceId: referenceId,
            noResample: noResample,
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
                // Method 1: Try iOS UniformTypeIdentifiers first (most reliable)
                if let mediaType = detectUsingUTType(data) {
                    return mediaType
                }
                
                // Method 2: Try comprehensive file signature detection
                if let mediaType = detectUsingFileSignatures(data) {
                    return mediaType
                }
                
                // Method 3: Try AVFoundation for media files
                if let mediaType = await detectUsingAVFoundation(data) {
                    return mediaType
                }
                
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
                    
                    let resourceValues = try tempURL.resourceValues(forKeys: [.typeIdentifierKey])
                    if let typeIdentifier = resourceValues.typeIdentifier {
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
                    // Silent fail - try next method
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
                        return .image
                    }
                }
                
                // Check for plain text
                if data.count >= 512 {
                    let textCheck = data.prefix(512)
                    if !textCheck.contains(0) && textCheck.allSatisfy({ $0 >= 32 || $0 == 9 || $0 == 10 || $0 == 13 }) {
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
                    
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if !videoTracks.isEmpty {
                        return .video
                    }
                    
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    if !audioTracks.isEmpty {
                        return .audio
                    }
                    
                } catch {
                    // Silent fail
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
        
        /// Process and upload video files with new routing logic:
        /// 1. Normalize to 720p/1000k (preserving original if lower resolution)
        /// 2. Route based on normalized size and resolution:
        ///    - ≤ 32MB: Progressive video route
        ///    - > 32MB: HLS conversion based on resolution
        ///      * resolution > 480p: HLS with 720p + 480p variants
        ///      * resolution ≤ 480p: HLS with 480p variant only
        static func processVideo(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Starting video processing with optimized resolution-based routing logic")
            
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            // Ensure video file has proper .mp4 extension for AVFoundation/FFmpeg compatibility
            let originalFileName = fileName ?? "video.mp4"
            let fileExtension = (originalFileName as NSString).pathExtension.lowercased()
            let baseFileName = (originalFileName as NSString).deletingPathExtension
            
            // Use .mp4 extension if file has wrong extension or no extension
            let properFileName: String
            if fileExtension.isEmpty || fileExtension == "file" || !["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "3gp"].contains(fileExtension) {
                properFileName = "\(baseFileName).mp4"
            } else {
                properFileName = originalFileName
            }
            
            let originalVideoURL = tempDir.appendingPathComponent(properFileName)
            try data.write(to: originalVideoURL)
            
            // Step 1: Get original video resolution to decide if normalization is needed
            progressCallback?("Analyzing video...", 5)
            let originalVideoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: originalVideoURL.path)
            var originalVideoResolution: Int? = nil
            if let info = originalVideoInfo {
                let aspectRatio = Float(info.displayWidth) / Float(info.displayHeight)
                // Video resolution is defined by height for landscape, width for portrait
                if aspectRatio < 1.0 {
                    originalVideoResolution = info.displayWidth
                } else {
                    originalVideoResolution = info.displayHeight
                }
                print("Original video resolution: \(info.displayWidth)x\(info.displayHeight) (\(originalVideoResolution ?? 0)p)")
            }
            
            // Step 2: Always normalize videos (≤720p keeps original resolution with proportional bitrate, >720p scales to 720p)
            print("📹 [VIDEO UPLOAD] Starting video normalization")
            if let origRes = originalVideoResolution {
                if origRes <= 720 {
                    print("📹 [VIDEO UPLOAD] Resolution \(origRes)p ≤ 720p: will normalize with original resolution and proportional bitrate")
                } else {
                    print("📹 [VIDEO UPLOAD] Resolution \(origRes)p > 720p: will normalize to 720p with 1500k bitrate")
                }
            } else {
                print("📹 [VIDEO UPLOAD] Could not detect resolution: will normalize (defaulting to 720p if needed)")
            }
            
            print("========== FIRST NORMALIZATION (Standardization) ==========")
            print("📹 [VIDEO UPLOAD] Original video: \(String(format: "%.1f", Double(data.count) / (1024 * 1024)))MB")
            print("📹 [VIDEO UPLOAD] Purpose: Unified format for 32MB routing decision")
            
            progressCallback?("Normalizing video...", 10)
            let normalizedFileName = "normalized_\(UUID().uuidString).mp4"
            let normalizedVideoURL = tempDir.appendingPathComponent(normalizedFileName)
            
            
            let normalizationSuccess = await MediaProcessor.normalizeTo720p1000k(
                inputURL: originalVideoURL,
                outputURL: normalizedVideoURL,
                progressCallback: progressCallback
            )
            print("==========================================================")
            
            guard normalizationSuccess else {
                print("❌ [VIDEO UPLOAD] Video normalization failed, falling back to original video")
                progressCallback?("Uploading original video...", 10)
                let result = try await MediaProcessor.uploadRegularFile(
                    data: data,
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    referenceId: referenceId,
                    mediaType: .video,
                    appUser: appUser,
                    appId: appId
                )
                return (result, nil)
            }
            
            print("✅ [VIDEO UPLOAD] Video normalization completed successfully")
            let videoData = try Data(contentsOf: normalizedVideoURL)
            let videoSize = Int64(videoData.count)
            
            // Get actual resolution from normalized video
            let normalizedVideoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: normalizedVideoURL.path)
            let videoResolution: Int
            if let info = normalizedVideoInfo {
                let aspectRatio = Float(info.displayWidth) / Float(info.displayHeight)
                if aspectRatio < 1.0 {
                    videoResolution = info.displayWidth
                } else {
                    videoResolution = info.displayHeight
                }
                print("📹 [VIDEO UPLOAD] Normalized video resolution: \(info.displayWidth)x\(info.displayHeight) (\(videoResolution)p)")
            } else {
                // Fallback to original resolution if detection fails
                videoResolution = originalVideoResolution ?? 720
                print("📹 [VIDEO UPLOAD] Could not detect normalized video resolution, using original: \(videoResolution)p")
            }
            
            let videoFileName = normalizedFileName
            print("📹 [VIDEO UPLOAD] Normalized video size: \(String(format: "%.1f", Double(videoSize) / (1024 * 1024)))MB")
            
            // Step 3: Route based on video size
            let videoSizeMB = Double(videoSize) / (1024 * 1024)
            print("📹 [VIDEO UPLOAD] Normalized video size: \(String(format: "%.1f", videoSizeMB))MB (\(videoSize) bytes)")
            
            if videoSize <= Constants.PROGRESSIVE_VIDEO_THRESHOLD_BYTES {
                // ≤ 32MB: progressive video route
                print("📹 [VIDEO UPLOAD] Size ≤ 32MB: using progressive video route (direct MP4 upload)")
                progressCallback?("Uploading video...", 50)
                let result = try await uploadRegularFile(
                    data: videoData,
                    typeIdentifier: "public.mpeg-4",
                    fileName: videoFileName,
                    referenceId: referenceId,
                    mediaType: .video,
                    appUser: appUser,
                    appId: appId
                )
                print("✅ [VIDEO UPLOAD] Progressive video uploaded successfully, CID: \(result.mid)")
                return (result, nil)
            } else {
                // > 32MB: Need HLS conversion - check if cloud drive is available
                print("📹 [VIDEO UPLOAD] Size > 32MB: will use HLS conversion route")
                let cloudPort = appUser.cloudDrivePort
                guard cloudPort > 0 else {
                    print("⚠️ [VIDEO UPLOAD] No cloud drive configured, falling back to progressive video")
                    progressCallback?("Uploading video...", 50)
                    let result = try await uploadRegularFile(
                        data: videoData,
                        typeIdentifier: "public.mpeg-4",
                        fileName: videoFileName,
                        referenceId: referenceId,
                        mediaType: .video,
                        appUser: appUser,
                        appId: appId
                    )
                    return (result, nil)
                }
                
                progressCallback?("Checking video service availability...", 10)
                print("📹 [VIDEO UPLOAD] Checking cloud drive service availability (port: \(cloudPort))...")
                
                // Resolve writableUrl once for all video HTTP operations
                _ = try await appUser.resolveWritableUrl()
                let isCloudDriveAvailable = await MediaProcessor.checkCloudDriveServiceAvailability(appUser: appUser)
                
                guard isCloudDriveAvailable else {
                    print("⚠️ [VIDEO UPLOAD] Cloud drive service not available, falling back to progressive video")
                    progressCallback?("Uploading video...", 50)
                    let result = try await uploadRegularFile(
                        data: videoData,
                        typeIdentifier: "public.mpeg-4",
                        fileName: videoFileName,
                        referenceId: referenceId,
                        mediaType: .video,
                        appUser: appUser,
                        appId: appId
                    )
                    return (result, nil)
                }
                
                // All videos are normalized now
                let wasNormalized = true
                
                // Route based on video resolution
                if videoResolution > 480 {
                    // Resolution > 480p: HLS with high-quality + 480p variants
                    // High-quality variant uses actual resolution (capped at 720p)
                    print("📹 [VIDEO UPLOAD] Resolution \(videoResolution)p > 480p: using HLS with \(min(videoResolution, 720))p + 480p variants")
                    return try await MediaProcessor.uploadVideoWithLocalHLSConversion(
                        data: videoData,
                        fileName: fileName,
                        referenceId: referenceId,
                        noResample: noResample,
                        appUser: appUser,
                        singleVariant480p: false,
                        sourceVideoResolution: videoResolution,
                        isNormalized: wasNormalized,
                        progressCallback: progressCallback
                    )
                } else {
                    // Resolution ≤ 480p: HLS with 480p variant only
                    print("📹 [VIDEO UPLOAD] Resolution \(videoResolution)p ≤ 480p: using HLS with 480p variant only")
                    return try await MediaProcessor.uploadVideoWithLocalHLSConversion(
                        data: videoData,
                        fileName: fileName,
                        referenceId: referenceId,
                        noResample: noResample,
                        appUser: appUser,
                        singleVariant480p: true,
                        sourceVideoResolution: videoResolution,
                        isNormalized: wasNormalized,
                        progressCallback: progressCallback
                    )
                }
            }
        }
        
        
        /// Detect media type from type identifier, filename, and file header
        static func detectMediaType(from typeIdentifier: String, fileName: String?, data: Data) async -> MediaType {
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
                // Analyze file header for unknown types
                let detectedType = await FileTypeDetector.detectFromData(data)
                print("Detected type via file header: \(detectedType.rawValue)")
                return detectedType
            }
        }
        
        /// Upload video with local FFmpeg HLS conversion
        /// - Parameter singleVariant480p: If true, creates only 480p variant. If false, creates high-quality + 480p variants.
        /// - Parameter sourceVideoResolution: Actual video resolution (used to determine high-quality variant resolution, capped at 720p)
        private static func uploadVideoWithLocalHLSConversion(
            data: Data,
            fileName: String?,
            referenceId: String?,
            noResample: Bool,
            appUser: User,
            singleVariant480p: Bool = false,
            sourceVideoResolution: Int,
            isNormalized: Bool = false,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Starting local HLS conversion with FFmpeg (single 480p variant: \(singleVariant480p))")
            progressCallback?("Converting video to HLS...", 10)

            // Log initial memory state
            VideoConversionService.shared.logMemoryUsage("start of HLS conversion")
            
            // Create temporary directory for conversion
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Save original video to temp file - ensure proper .mp4 extension
            let originalFileName = fileName ?? "video.mp4"
            let fileExtension = (originalFileName as NSString).pathExtension.lowercased()
            let baseFileName = (originalFileName as NSString).deletingPathExtension
            
            // Use .mp4 extension if file has wrong extension or no extension
            let properFileName: String
            if fileExtension.isEmpty || fileExtension == "file" || !["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "3gp"].contains(fileExtension) {
                properFileName = "\(baseFileName).mp4"
            } else {
                properFileName = originalFileName
            }
            
            let originalVideoURL = tempDir.appendingPathComponent(properFileName)

            // Log memory before writing temp file
            VideoConversionService.shared.logMemoryUsage("before writing temp video file")

            try data.write(to: originalVideoURL)

            // Log memory after writing temp file (this is where memory usage spikes)
            VideoConversionService.shared.logMemoryUsage("after writing temp video file")
            
            // Get video info using AVFoundation
            let videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: originalVideoURL.path)
            let videoAspectRatio: Float?
            if let info = videoInfo {
                // Calculate aspect ratio from display dimensions (after rotation correction)
                videoAspectRatio = Float(info.displayWidth) / Float(info.displayHeight)
                print("DEBUG: [HLS CONVERSION] FFmpeg detected: \(info.width)x\(info.height), display: \(info.displayWidth)x\(info.displayHeight), rotation: \(info.rotation)°, aspect ratio: \(videoAspectRatio!)")
            } else {
                videoAspectRatio = await MediaProcessor.getVideoAspectRatioWithFallback(from: data)
                print("DEBUG: [HLS CONVERSION] Fallback to AVFoundation, aspect ratio: \(videoAspectRatio ?? 0.0)")
            }
            
            // Convert to HLS using FFmpeg with foreground processing (high priority)
            let conversionResult = await withCheckedContinuation { continuation in
                VideoConversionService.shared.convertVideoToHLS(
                    inputURL: originalVideoURL,
                    outputDirectory: tempDir,
                    fileSizeBytes: Int64(data.count),
                    aspectRatio: videoAspectRatio,
                    singleVariant480p: singleVariant480p,
                    sourceVideoResolution: sourceVideoResolution,
                    isNormalized: isNormalized,
                    progressCallback: { progress in
                        DispatchQueue.main.async {
                            progressCallback?(progress.stage, 10 + Int(Double(progress.progress) * 0.2)) // 10-30% for conversion
                        }
                    }
                ) { result in
                    continuation.resume(returning: result)
                }
            }
            
            guard conversionResult.success,
                  let hlsDirectory = conversionResult.hlsDirectoryURL else {
                print("DEBUG: Video conversion failed: \(conversionResult.errorMessage ?? "Unknown error")")
                progressCallback?(NSLocalizedString("Video conversion failed", comment: "Video processing error"), 0)
                // Clean up temp files
                try? FileManager.default.removeItem(at: tempDir)
                throw NSError(domain: "VideoConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert video to HLS"])
            }

            // Log memory after HLS conversion completes
            VideoConversionService.shared.logMemoryUsage("after HLS conversion complete")

            progressCallback?("Compressing HLS files...", 40)

            // Log memory usage before compression
            VideoConversionService.shared.logMemoryUsage("before HLS compression")

            // Monitor HLS directory size for memory planning
            if let hlsAttributes = try? FileManager.default.attributesOfItem(atPath: hlsDirectory.path),
               let hlsSize = hlsAttributes[.size] as? Int64 {
                print("DEBUG: [MEMORY MONITORING] HLS directory size: \(hlsSize / 1024)KB")
            }

            // Compress the HLS directory
            let compressedURL = try await MediaProcessor.compressHLSDirectory(
                hlsDirectory: hlsDirectory,
                originalFileName: originalFileName,
                progressCallback: progressCallback
            )

            // Force memory cleanup after compression
            autoreleasepool {}

            // Log memory usage after compression
            VideoConversionService.shared.logMemoryUsage("after HLS compression")

            progressCallback?("Uploading HLS zip to server...", 60)

            // Log memory usage before upload
            VideoConversionService.shared.logMemoryUsage("before HLS upload")

            // Upload compressed HLS to server
            let jobId = try await MediaProcessor.uploadCompressedHLS(
                compressedURL: compressedURL,
                fileName: "\(originalFileName)_hls.zip",
                referenceId: referenceId,
                appUser: appUser
            )

            // Force memory cleanup after upload
            autoreleasepool {}

            // Log memory usage after upload
            VideoConversionService.shared.logMemoryUsage("after HLS upload")

            print("✅ [HLS Upload] Uploaded to server, job ID: \(jobId)")
            progressCallback?("Video uploaded to server", 100)
            
            // OPTIMIZATION: Return immediately with job ID instead of waiting for processing
            // The polling will happen in the background via TweetUploadManager
            
            // Create placeholder result with job ID (CID will be filled in later)
            let mimeiFileType = MimeiFileType(
                mid: jobId,  // Temporarily use jobId as mid, will be replaced with CID after processing
                mediaType: .hls_video,
                size: Int64(data.count),
                fileName: fileName,
                timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                aspectRatio: videoAspectRatio,
                url: nil
            )
            
            // Clean up temp files (aggressive cleanup to reduce memory footprint)
            print("DEBUG: [HLS UPLOAD] Cleaning up temporary files...")

            // Force memory cleanup before file deletion
            autoreleasepool {}

            // Remove HLS directory and compressed file
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: compressedURL)

            // Final memory cleanup
            autoreleasepool {}

            print("DEBUG: [HLS UPLOAD] Temporary files cleaned up")
            VideoConversionService.shared.logMemoryUsage("after cleanup")
            
            // Return (placeholder MimeiFileType, jobId)
            // The jobId will be used for background polling
            return (mimeiFileType, jobId)
        }
        
        /// Check if cloud drive service is available at clouddriveport
        private static func checkCloudDriveServiceAvailability(appUser: User) async -> Bool {
            guard !appUser.isGuest else {
                print("Cloud drive check skipped for guest user - using fallback")
                return false
            }
            
            do {
                guard let writableUrl = appUser.writableUrl,
                      let host = writableUrl.host,
                      appUser.cloudDrivePort > 0,
                      let cloudBaseURL = URL(string: "http://\(host):\(HproseInstance.shared.appUser.cloudDrivePort)") else {
                    return false
                }
                
                let healthCheckURL = cloudBaseURL.appendingPathComponent("health")
                
                var request = URLRequest(url: healthCheckURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 3.0
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    print("Cloud drive service unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    return false
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "ok" {
                    print("✅ Cloud drive service available - using HLS conversion")
                    return true
                } else {
                    print("Cloud drive service health check failed - invalid response")
                    return false
                }
            } catch {
                let nsError = error as NSError
                print("Cloud drive service unavailable - using MP4 fallback (domain: \(nsError.domain), code: \(nsError.code))")
                return false
            }
        }
        
        /// Upload video with MP4 resampling fallback when cloud drive service is not available
        private func uploadVideoWithMp4Fallback(
            data: Data,
            fileName: String?,
            referenceId: String?,
            appUser: User,
            appId: String,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            print("Starting MP4 conversion (\(String(format: "%.1f", Double(data.count) / (1024 * 1024)))MB)")
            progressCallback?("Converting video to MP4...", 10)
            
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            let originalFileName = fileName ?? "video.mp4"
            let tempFileName = (originalFileName as NSString).deletingPathExtension + ".mp4"
            let originalVideoURL = tempDir.appendingPathComponent(tempFileName)
            try data.write(to: originalVideoURL)

            let videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: originalVideoURL.path)
            let videoAspectRatio: Float?
            let targetResolution: Int
            
            if let info = videoInfo {
                videoAspectRatio = Float(info.displayWidth) / Float(info.displayHeight)
                let minDimension = min(info.displayWidth, info.displayHeight)
                targetResolution = minDimension > 720 ? 720 : minDimension
                print("Converting \(info.displayWidth)x\(info.displayHeight) → \(targetResolution)p (aspect: \(String(format: "%.2f", videoAspectRatio ?? 0)))")
            } else {
                videoAspectRatio = await MediaProcessor.getVideoAspectRatioWithFallback(from: data)
                targetResolution = 720
                print("Using fallback settings: \(targetResolution)p")
            }
            
            progressCallback?("Converting to MP4 format...", 30)
            
            // Ensure output has .mp4 extension for FFmpeg
            let outputVideoName = "resampled_" + (originalFileName as NSString).deletingPathExtension + ".mp4"
            let outputVideoURL = tempDir.appendingPathComponent(outputVideoName)
            
            // Get width and height for bitrate calculation
            let videoWidth: Int
            let videoHeight: Int
            if let info = videoInfo {
                videoWidth = info.displayWidth
                videoHeight = info.displayHeight
            } else {
                // Fallback: assume square resolution based on targetResolution
                videoWidth = targetResolution
                videoHeight = targetResolution
            }

            let conversionSuccess = await MediaProcessor.convertVideoToMp4(
                inputURL: originalVideoURL,
                outputURL: outputVideoURL,
                targetResolution: targetResolution,
                width: videoWidth,
                height: videoHeight,
                aspectRatio: videoAspectRatio,
                progressCallback: progressCallback
            )
            
            guard conversionSuccess else {
                print("ERROR: Video conversion to MP4 failed")
                progressCallback?(NSLocalizedString("Video conversion failed", comment: "Video processing error"), 0)
                throw NSError(domain: "VideoConversion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert video to MP4"])
            }
            
            progressCallback?("Uploading video via IPFS...", 70)
            
            let convertedData = try Data(contentsOf: outputVideoURL)
            let outputFileName = outputVideoName
            print("Converted: \(String(format: "%.1f", Double(convertedData.count) / (1024 * 1024)))MB → uploading to IPFS...")
            
            let result = try await MediaProcessor.uploadRegularFile(
                data: convertedData,
                typeIdentifier: "public.mpeg-4",
                fileName: outputFileName,
                referenceId: referenceId,
                mediaType: .video,
                appUser: appUser,
                appId: appId
            )
            
            progressCallback?("Video upload completed", 100)
            print("✅ Video uploaded: CID \(result.mid)")
            
            return (result, nil)
        }
        
        /// Convert video to MP4 with target resolution
        private static func convertVideoToMp4(
            inputURL: URL,
            outputURL: URL,
            targetResolution: Int,
            width: Int,
            height: Int,
            aspectRatio: Float?,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async -> Bool {
            return await withCheckedContinuation { continuation in
                // Determine scaling filter based on aspect ratio
                let scaleFilter: String
                if let aspectRatio = aspectRatio {
                    if aspectRatio < 1.0 {
                        // Portrait: scale to target width
                        scaleFilter = "scale=\(targetResolution):-2"
                    } else {
                        // Landscape: scale to target height
                        scaleFilter = "scale=-2:\(targetResolution)"
                    }
                } else {
                    // Fallback to height-based scaling
                    scaleFilter = "scale=-2:\(targetResolution)"
                }

                // Calculate proportional bitrate based on pixel count (720p = 921,600 pixels = 1000k base)
                // Always use calculated bitrate (bitrate detection is unreliable)
                let bitrateKbps: Int
                let REFERENCE_720P_PIXELS = 921600

                if targetResolution >= 720 {
                    // Videos scaled to 720p: use 720p pixel count for bitrate calculation
                    bitrateKbps = Int(VideoConversionService.reference720pBitrate)
                } else {
                    // Videos keeping original resolution: use actual pixel count for bitrate calculation (min minBitrate to avoid inflating low-bitrate videos)
                    let pixelCount = width * height
                    let calculatedBitrate = Int((Double(pixelCount) / Double(REFERENCE_720P_PIXELS)) * VideoConversionService.reference720pBitrate)
                    bitrateKbps = max(VideoConversionService.minBitrate, calculatedBitrate)
                    print("📊 Pixel-based calculation: \(width)×\(height) (\(pixelCount) pixels) = \(calculatedBitrate)k → \(bitrateKbps)k (with \(VideoConversionService.minBitrate)k min)")
                }
                print("📊 Using calculated bitrate for \(targetResolution)p: \(bitrateKbps)k")
                
                let command = """
                    -i "\(inputURL.path)" \
                    -c:v libx264 \
                    -c:a aac \
                    -vf "\(scaleFilter)" \
                    -preset veryfast \
                    -b:v \(bitrateKbps)k \
                    -b:a 128k \
                    -movflags +faststart \
                    -metadata:s:v:0 rotate=0 \
                    "\(outputURL.path)"
                    """
                
                FFmpegKit.executeAsync(command) { session in
                    guard let session = session else {
                        print("ERROR: Failed to create FFmpeg session")
                        continuation.resume(returning: false)
                        return
                    }
                    
                    let returnCode = session.getReturnCode()
                    let success = ReturnCode.isSuccess(returnCode)
                    
                    if success {
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                            print("✅ Converted to \(targetResolution)p MP4 (\(fileSize / 1024)KB)")
                            continuation.resume(returning: true)
                        } else {
                            print("ERROR: Output file missing")
                            continuation.resume(returning: false)
                        }
                    } else {
                        print("ERROR: FFmpeg conversion failed (code: \(String(describing: returnCode)))")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
        
        
        /// Normalize video to 720p/1000k bitrate, preserving original resolution/bitrate if lower
        private static func normalizeTo720p1000k(
            inputURL: URL,
            outputURL: URL,
            progressCallback: ((String, Int) -> Void)? = nil
        ) async -> Bool {
            
            return await withCheckedContinuation { continuation in
                // Get video info to check original resolution and bitrate
                Task(priority: .high) {
                    // Try to get video info with AVFoundation first
                    var videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
                    
                    // If AVFoundation fails, try with a temporary file with proper extension
                    if videoInfo == nil {
                        print("AVFoundation probe failed, trying with temporary file...")
                        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let tempVideoURL = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")
                        
                        do {
                            // Copy file data to temporary location with .mp4 extension
                            let fileData = try Data(contentsOf: inputURL)
                            try fileData.write(to: tempVideoURL)
                            
                            // Try to get video info using AVFoundation
                            let dimensions = await HLSVideoProcessor.shared.getVideoDimensions(filePath: tempVideoURL.path)
                            if dimensions.width > 0 && dimensions.height > 0 {
                                // Get rotation info if available
                                let asset = AVURLAsset(url: tempVideoURL)
                                var rotation = 0
                                if let tracks = try? await asset.loadTracks(withMediaType: .video),
                                   let track = tracks.first {
                                    let transform = try? await track.load(.preferredTransform)
                                    if let transform = transform {
                                        // Calculate rotation from transform
                                        let angle = atan2(transform.b, transform.a) * 180 / .pi
                                        rotation = Int(angle)
                                    }
                                }
                                
                                var displayWidth = Int(dimensions.width)
                                var displayHeight = Int(dimensions.height)
                                
                                // Apply rotation if needed
                                if rotation == 90 || rotation == -90 {
                                    swap(&displayWidth, &displayHeight)
                                }
                                
                                videoInfo = (Int(dimensions.width), Int(dimensions.height), displayWidth, displayHeight, rotation)
                                print("✅ Got video info via AVFoundation: \(displayWidth)x\(displayHeight) (rotation: \(rotation)°)")
                            }
                            
                            // Clean up temp file
                            try? FileManager.default.removeItem(at: tempDir)
                        } catch {
                            print("Failed to get video info via AVFoundation: \(error)")
                            try? FileManager.default.removeItem(at: tempDir)
                        }
                    }
                    
                    // Note: Bitrate detection is unreliable, so we always use calculated bitrate
                    
                    // Get original resolution
                    var originalWidth: Int? = nil
                    var originalHeight: Int? = nil
                    if let info = videoInfo {
                        originalWidth = info.displayWidth
                        originalHeight = info.displayHeight
                    }
                    
                    // Determine if we need to scale and calculate target bitrate
                    let needsScaling: Bool
                    let scaleFilter: String
                    let targetBitrateKbps: Int
                    var videoResolution: Int = 720 // Default to 720p
                    
                    if let width = originalWidth, let height = originalHeight {
                        let aspectRatio = Float(width) / Float(height)
                        
                        // Video resolution is defined by:
                        // - Landscape (aspect >= 1.0): HEIGHT (e.g., 1280x720 is 720p)
                        // - Portrait (aspect < 1.0): WIDTH (e.g., 720x1280 is 720p)
                        if aspectRatio < 1.0 {
                            // Portrait: resolution is width
                            videoResolution = width
                        } else {
                            // Landscape: resolution is height
                            videoResolution = height
                        }
                        
                        needsScaling = videoResolution > 720
                        
                        if needsScaling {
                            // Resolution > 720p: scale to 720p with 1500k bitrate
                            if aspectRatio < 1.0 {
                                // Portrait: scale to target width
                                scaleFilter = "scale=720:-2"
                            } else {
                                // Landscape: scale to target height
                                scaleFilter = "scale=-2:720"
                            }
                            // Always use 1500k bitrate for 720p normalization (bitrate detection is unreliable)
                            targetBitrateKbps = 1500
                            print("📊 Scaling to 720p with 1500k bitrate")
                        } else {
                            // Resolution ≤ 720p: keep original resolution with proportional bitrate (min minBitrate to avoid inflating low-bitrate videos)
                            scaleFilter = ""
                            // Calculate proportional bitrate based on pixel count
                            // Formula: bitrate = max(minBitrate, (pixel_count / REFERENCE_720P_PIXELS) * reference720pBitrate)
                            // REFERENCE_720P_PIXELS = 1280 × 720 = 921,600
                            let pixelCount = width * height
                            let REFERENCE_720P_PIXELS = 921600
                            let calculatedBitrate = Int((Double(pixelCount) / Double(REFERENCE_720P_PIXELS)) * VideoConversionService.reference720pBitrate)
                            targetBitrateKbps = max(VideoConversionService.minBitrate, calculatedBitrate)
                            print("📊 Original resolution \(width)x\(height) (\(videoResolution)p), pixel-based: \(calculatedBitrate)k → \(targetBitrateKbps)k (with \(VideoConversionService.minBitrate)k min)")
                        }
                    } else {
                        // Fallback: assume scaling needed
                        needsScaling = true
                        scaleFilter = "scale=-2:720"
                        targetBitrateKbps = Int(VideoConversionService.reference720pBitrate)
                        print("📊 Could not detect resolution, defaulting to 720p with \(targetBitrateKbps)k bitrate")
                    }
                    
                    print("📹 [NORMALIZE] Original: \(originalWidth ?? 0)x\(originalHeight ?? 0), target bitrate: \(targetBitrateKbps)k, scaling: \(needsScaling ? "YES (to 720p)" : "NO (keep original resolution)")")
                    
                    // Build FFmpeg command
                    var command: String
                    if needsScaling && !scaleFilter.isEmpty {
                        command = """
                            -i "\(inputURL.path)" \
                            -c:v libx264 \
                            -profile:v main \
                            -level 4.0 \
                            -pix_fmt yuv420p \
                            -vf "\(scaleFilter)" \
                            -preset veryfast \
                            -b:v \(targetBitrateKbps)k \
                            -maxrate \(targetBitrateKbps)k \
                            -bufsize \(targetBitrateKbps)k \
                            -c:a aac \
                            -ar 44100 \
                            -b:a 128k \
                            -movflags +faststart \
                            -metadata:s:v:0 rotate=0 \
                            "\(outputURL.path)"
                            """
                    } else {
                        // Keep original resolution but encode with target bitrate
                        command = """
                            -i "\(inputURL.path)" \
                            -c:v libx264 \
                            -profile:v main \
                            -level 4.0 \
                            -pix_fmt yuv420p \
                            -preset veryfast \
                            -b:v \(targetBitrateKbps)k \
                            -maxrate \(targetBitrateKbps)k \
                            -bufsize \(targetBitrateKbps)k \
                            -c:a aac \
                            -ar 44100 \
                            -b:a 128k \
                            -movflags +faststart \
                            -metadata:s:v:0 rotate=0 \
                            "\(outputURL.path)"
                            """
                    }
                    
                    FFmpegKit.executeAsync(command) { session in
                        guard let session = session else {
                            print("ERROR: Failed to create FFmpeg session for normalization")
                            continuation.resume(returning: false)
                            return
                        }
                        
                        let returnCode = session.getReturnCode()
                        let success = ReturnCode.isSuccess(returnCode)
                        
                        if success {
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                                // Determine output resolution for logging
                                let outputResolution: String
                                if needsScaling {
                                    outputResolution = "720p"
                                } else if let width = originalWidth, let height = originalHeight {
                                    outputResolution = "\(width)x\(height) (\(videoResolution)p)"
                                } else {
                                    outputResolution = "unknown"
                                }
                                print("✅ Normalized to \(outputResolution) with \(targetBitrateKbps)k bitrate - \(fileSize / 1024)KB")
                                continuation.resume(returning: true)
                            } else {
                                print("ERROR: Normalized output file missing")
                                continuation.resume(returning: false)
                            }
                        } else {
                            print("ERROR: FFmpeg normalization failed (code: \(String(describing: returnCode)))")
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
        }
        
        /// Compress HLS directory into a zip file (memory-optimized streaming approach)
        private static func compressHLSDirectory(hlsDirectory: URL, originalFileName: String, progressCallback: ((String, Int) -> Void)? = nil) async throws -> URL {
            let zipFileName = "\(originalFileName)_hls.zip"
            let tempDir = hlsDirectory.deletingLastPathComponent()
            let zipURL = tempDir.appendingPathComponent(zipFileName)

            print("DEBUG: [ZIP CREATION] Starting memory-optimized zip creation")
            print("DEBUG: [ZIP CREATION] HLS directory: \(hlsDirectory.path)")
            print("DEBUG: [ZIP CREATION] Zip file will be created at: \(zipURL.path)")

            // Log initial memory usage
            VideoConversionService.shared.logMemoryUsage("before zip creation")

            // Memory-optimized streaming approach: Process files sequentially without loading into memory
            return try await withCheckedThrowingContinuation { continuation in
                Task(priority: .high) {
                    do {
                        // Calculate total size and get file list
                        var totalSize: Int64 = 0
                        var fileURLs: [URL] = []

                        // Use FileManager enumerator to get all files without loading them
                        let enumerator = FileManager.default.enumerator(at: hlsDirectory,
                                                                       includingPropertiesForKeys: [.fileSizeKey],
                                                                       options: [],
                                                                       errorHandler: nil)

                        while let fileURL = enumerator?.nextObject() as? URL {
                            var isDirectory: ObjCBool = false
                            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue {
                                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                                   let size = attributes[.size] as? Int64 {
                                    totalSize += size
                                    fileURLs.append(fileURL)
                                }
                            }
                        }

                        print("DEBUG: [ZIP CREATION] Found \(fileURLs.count) files, total size: \(totalSize / 1024)KB")
                        
                        // Log some file paths for debugging
                        if !fileURLs.isEmpty {
                            let samplePaths = fileURLs.prefix(3).map { $0.lastPathComponent }
                            print("DEBUG: [ZIP CREATION] Sample files: \(samplePaths.joined(separator: ", "))")
                        }

                        // Force memory cleanup before zip creation
                        autoreleasepool {}
                        progressCallback?("Creating ZIP file...", 10)

                        // Create ZIP file directly without copying directory
                        // Use parent directory as base so "hls/" is included in ZIP structure
                        let baseDirectory = hlsDirectory.deletingLastPathComponent()
                        print("DEBUG: [ZIP CREATION] Base directory: \(baseDirectory.path)")
                        print("DEBUG: [ZIP CREATION] HLS directory name: \(hlsDirectory.lastPathComponent)")
                        try MediaProcessor.createZipFile(from: fileURLs, relativeTo: baseDirectory, to: zipURL, progressCallback: progressCallback)

                        // Verify zip file was created and get its size
                        if let zipAttributes = try? FileManager.default.attributesOfItem(atPath: zipURL.path),
                           let zipSize = zipAttributes[.size] as? Int64 {
                            print("DEBUG: [ZIP CREATION] Successfully created zip file at: \(zipURL.path)")
                            print("DEBUG: [ZIP CREATION] Zip file size: \(zipSize / 1024)KB (original: \(totalSize / 1024)KB)")

                            // Log memory usage after zip creation
                            VideoConversionService.shared.logMemoryUsage("after zip creation")

                            continuation.resume(returning: zipURL)
                        } else {
                            throw NSError(domain: "ZipCreation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify zip file creation"])
                        }

                    } catch {
                        print("DEBUG: [ZIP CREATION] Zip creation failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        /// Create ZIP file from array of file URLs using system ZIP functionality (memory efficient)
        private static func createZipFile(from fileURLs: [URL], relativeTo baseURL: URL, to zipURL: URL, progressCallback: ((String, Int) -> Void)? = nil) throws {
            let fileManager = FileManager.default
            var processedCount = 0
            let totalFiles = fileURLs.count

            // Create a temporary directory structure for ZIP creation
            let tempDir = zipURL.deletingLastPathComponent()
            let tempZipDir = tempDir.appendingPathComponent("temp_zip_parts_\(UUID().uuidString)")
            try fileManager.createDirectory(at: tempZipDir, withIntermediateDirectories: true)

            defer {
                try? fileManager.removeItem(at: tempZipDir)
            }

            // Process each file individually to minimize memory usage
            for fileURL in fileURLs {
                autoreleasepool {
                    do {
                        let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                        
                        // Log first few relative paths for debugging
                        if processedCount < 3 {
                            print("DEBUG: [ZIP CREATION] File \(processedCount + 1): relativePath=\(relativePath), fullPath=\(fileURL.path)")
                        }

                        // Create a temporary directory structure that mirrors the relative path
                        let tempFileDir = tempZipDir.appendingPathComponent(relativePath).deletingLastPathComponent()
                        try fileManager.createDirectory(at: tempFileDir, withIntermediateDirectories: true)

                        let tempFileURL = tempZipDir.appendingPathComponent(relativePath)

                        // Copy file to temporary location with correct relative structure
                        try fileManager.copyItem(at: fileURL, to: tempFileURL)
                        
                        // Verify file was copied
                        if !fileManager.fileExists(atPath: tempFileURL.path) {
                            print("DEBUG: [ZIP CREATION] WARNING: File copy verification failed for \(relativePath)")
                        }

                        processedCount += 1
                        if processedCount % 5 == 0 || processedCount == totalFiles {
                            let progressPercent = 10 + Int((Double(processedCount) / Double(totalFiles)) * 15.0)
                            progressCallback?("Preparing files... (\(processedCount)/\(totalFiles))", progressPercent)
                        }

                    } catch {
                        print("DEBUG: [ZIP CREATION] Error processing file \(fileURL.lastPathComponent): \(error)")
                        // Continue with other files rather than failing completely
                    }
                }
            }

            progressCallback?("Creating ZIP archive...", 25)

            // Verify tempZipDir structure before zipping
            print("DEBUG: [ZIP CREATION] Verifying tempZipDir structure: \(tempZipDir.path)")
            let contents = try? fileManager.contentsOfDirectory(at: tempZipDir, includingPropertiesForKeys: [.isDirectoryKey])
            print("DEBUG: [ZIP CREATION] tempZipDir top-level contents: \(contents?.map { $0.lastPathComponent } ?? [])")
            
            // Find the "hls" subdirectory in tempZipDir
            let hlsSubdir = tempZipDir.appendingPathComponent("hls")
            var isDirectory: ObjCBool = false
            let hlsExists = fileManager.fileExists(atPath: hlsSubdir.path, isDirectory: &isDirectory) && isDirectory.boolValue
            
            // Determine which directory to zip
            // If hls subdirectory exists, zip it directly (ZIP will contain hls/720p/, hls/480p/, etc.)
            // If not, zip tempZipDir (structure might be different)
            let dirToZip = hlsExists ? hlsSubdir : tempZipDir
            print("DEBUG: [ZIP CREATION] Zipping directory: \(dirToZip.path) (hls subdir exists: \(hlsExists))")

            // Use NSFileCoordinator to create ZIP from the directory
            // When zipping a directory with .forUploading, the ZIP will contain that directory's name
            // So if we zip "hls", the ZIP will have "hls/" at the root, which is what the server expects
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var localError: NSError?

            coordinator.coordinate(readingItemAt: dirToZip, options: [.forUploading], error: &localError) { (tempZipURL) in
                do {
                    print("DEBUG: [ZIP CREATION] NSFileCoordinator created temporary ZIP at: \(tempZipURL.path)")
                    
                    // Verify temporary ZIP exists and has content
                    if let tempAttributes = try? fileManager.attributesOfItem(atPath: tempZipURL.path),
                       let tempSize = tempAttributes[.size] as? Int64 {
                        print("DEBUG: [ZIP CREATION] Temporary ZIP size: \(tempSize / 1024)KB")
                        
                        if tempSize == 0 {
                            throw NSError(domain: "ZipCreation", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "ZIP file is empty"])
                        }
                    }
                    
                    // The coordinator creates a temporary ZIP file, move it to final location
                    if fileManager.fileExists(atPath: zipURL.path) {
                        try fileManager.removeItem(at: zipURL)
                    }
                    try fileManager.moveItem(at: tempZipURL, to: zipURL)
                    print("DEBUG: [ZIP CREATION] Successfully created zip file at: \(zipURL.path)")
                } catch {
                    print("DEBUG: [ZIP CREATION] Failed to create final zip file: \(error)")
                    coordinatorError = error as NSError
                }
            }

            // Check for errors from the coordinator itself
            if let error = localError ?? coordinatorError {
                // Clean up temporary directory
                try? fileManager.removeItem(at: tempZipDir)
                print("DEBUG: [ZIP CREATION] File coordinator error: \(error)")
                throw error
            }
            
            // Verify ZIP was created successfully
            guard fileManager.fileExists(atPath: zipURL.path) else {
                try? fileManager.removeItem(at: tempZipDir)
                throw NSError(domain: "ZipCreation", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "ZIP file was not created"])
            }

            // Verify ZIP file was created
            if !fileManager.fileExists(atPath: zipURL.path) {
                throw NSError(domain: "ZipCreation", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "ZIP file was not created"])
            }

            // Get final ZIP size and verify it's not empty
            if let zipAttributes = try? fileManager.attributesOfItem(atPath: zipURL.path),
               let zipSize = zipAttributes[.size] as? Int64 {
                print("DEBUG: [ZIP CREATION] Final ZIP size: \(zipSize / 1024)KB")
                
                if zipSize == 0 {
                    throw NSError(domain: "ZipCreation", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "ZIP file is empty"])
                }
                
                // Verify ZIP file is readable (basic validation)
                if zipSize < 100 {
                    print("DEBUG: [ZIP CREATION] WARNING: ZIP file seems too small (\(zipSize) bytes)")
                }
            } else {
                throw NSError(domain: "ZipCreation", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Cannot read ZIP file attributes"])
            }
            
            // Log ZIP file path for server debugging
            print("DEBUG: [ZIP CREATION] ZIP file ready for upload: \(zipURL.lastPathComponent)")

            progressCallback?("ZIP creation completed", 30)
            print("DEBUG: [ZIP CREATION] Memory-efficient zip creation completed")
        }

        /// Upload compressed HLS to server via process-zip route
        private static func uploadCompressedHLS(
            compressedURL: URL,
            fileName: String,
            referenceId: String?,
            appUser: User
        ) async throws -> String {
            guard let writableUrl = appUser.writableUrl else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available"])
            }
            
            // Get host from writableUrl - no fallback, must succeed
            guard let host = writableUrl.host else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not get host from writable URL"])
            }
            
            // Get cloud drive port - no fallback, must be configured
            guard appUser.cloudDrivePort > 0 else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cloud drive port not configured"])
            }
            
            guard let cloudBaseURL = URL(string: "http://\(host):\(HproseInstance.shared.appUser.cloudDrivePort)") else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct cloud drive URL"])
            }
            let uploadURL = cloudBaseURL.appendingPathComponent("process-zip").absoluteString
            
            print("DEBUG: Constructed process-zip URL: \(uploadURL)")
            guard let url = URL(string: uploadURL) else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid process-zip URL"])
            }
            
            // Verify zip file exists and has content
            guard FileManager.default.fileExists(atPath: compressedURL.path) else {
                throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Zip file does not exist at path: \(compressedURL.path)"])
            }

            let fileAttributes = try FileManager.default.attributesOfItem(atPath: compressedURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0

            guard fileSize > 0 else {
                throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Zip file is empty (size: \(fileSize) bytes)"])
            }

            // Additional validation: check if the file is actually a valid zip by checking the first few bytes
            let fileHandle = try FileHandle(forReadingFrom: compressedURL)
            let headerData = fileHandle.readData(ofLength: 4)
            fileHandle.closeFile()

            // ZIP files start with PK\x03\x04 or PK\x05\x06 or PK\x07\x08
            let zipSignatures = [
                Data([0x50, 0x4B, 0x03, 0x04]), // PK\x03\x04
                Data([0x50, 0x4B, 0x05, 0x06]), // PK\x05\x06
                Data([0x50, 0x4B, 0x07, 0x08])  // PK\x07\x08
            ]

            let isValidZip = zipSignatures.contains { signature in
                headerData.starts(with: signature)
            }

            guard isValidZip else {
                throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Zip file appears to be corrupted (invalid header: \(headerData.map { String(format: "%02x", $0) }.joined()))"])
            }

            print("DEBUG: [UPLOAD] Preparing to upload zip file, size: \(fileSize / 1024)KB")

            // For very large files (>50MB), use file-based streaming to avoid memory issues
            let maxMemoryEfficientSize = Int64(50 * 1024 * 1024) // 50MB
            if fileSize > maxMemoryEfficientSize {
                print("DEBUG: [UPLOAD] Large zip file (\(fileSize / (1024 * 1024))MB) - using file-based streaming upload")
                VideoConversionService.shared.logMemoryUsage("before large file upload")
            }

            // Create multipart form data with a simple boundary
            let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            
            // For large files, create multipart form data as a file on disk to avoid loading into memory
            let tempMultipartFile: URL
            let shouldUseFileBasedUpload = fileSize > maxMemoryEfficientSize
            
            if shouldUseFileBasedUpload {
                // Create temporary file for multipart form data
                let tempDir = FileManager.default.temporaryDirectory
                tempMultipartFile = tempDir.appendingPathComponent("multipart_\(UUID().uuidString).tmp")
                
                // Create file handle for writing
                guard FileManager.default.createFile(atPath: tempMultipartFile.path, contents: nil, attributes: nil) else {
                    throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create temporary multipart file"])
                }
                
                guard let multipartFileHandle = FileHandle(forWritingAtPath: tempMultipartFile.path) else {
                    throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to open temporary multipart file for writing"])
                }
                
                // Write multipart form data to file by streaming
                // Add the compressed HLS file FIRST (some servers expect the file field first)
                multipartFileHandle.write("--\(boundary)\r\n".data(using: .utf8)!)
                multipartFileHandle.write("Content-Disposition: form-data; name=\"zipFile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                multipartFileHandle.write("Content-Type: application/zip\r\n".data(using: .utf8)!)
                multipartFileHandle.write("\r\n".data(using: .utf8)!)
                
                // Stream the ZIP file content directly to the multipart file
                let zipFileHandle = try FileHandle(forReadingFrom: compressedURL)
                
                // Read and write in chunks to minimize memory usage
                let chunkSize = 1024 * 1024 // 1MB chunks
                var bytesWritten = 0
                var shouldContinue = true
                while shouldContinue {
                    autoreleasepool {
                        let chunk = zipFileHandle.readData(ofLength: chunkSize)
                        if chunk.isEmpty {
                            shouldContinue = false
                        } else {
                            multipartFileHandle.write(chunk)
                            bytesWritten += chunk.count
                        }
                    }
                }
                zipFileHandle.closeFile()
                
                multipartFileHandle.write("\r\n".data(using: .utf8)!)
                
                // Add filename
                multipartFileHandle.write("--\(boundary)\r\n".data(using: .utf8)!)
                multipartFileHandle.write("Content-Disposition: form-data; name=\"filename\"\r\n".data(using: .utf8)!)
                multipartFileHandle.write("\r\n".data(using: .utf8)!)
                multipartFileHandle.write("\(fileName)\r\n".data(using: .utf8)!)
                
                // Add reference ID if provided
                if let referenceId = referenceId {
                    multipartFileHandle.write("--\(boundary)\r\n".data(using: .utf8)!)
                    multipartFileHandle.write("Content-Disposition: form-data; name=\"referenceId\"\r\n".data(using: .utf8)!)
                    multipartFileHandle.write("\r\n".data(using: .utf8)!)
                    multipartFileHandle.write("\(referenceId)\r\n".data(using: .utf8)!)
                }
                
                // End boundary
                multipartFileHandle.write("--\(boundary)--\r\n".data(using: .utf8)!)
                
                // CRITICAL: Flush and synchronize file before closing
                multipartFileHandle.synchronizeFile()
                multipartFileHandle.closeFile()
                
                // Get final file size after flushing and closing
                let multipartFileSize = (try? FileManager.default.attributesOfItem(atPath: tempMultipartFile.path))?[.size] as? Int64 ?? 0
                print("DEBUG: [UPLOAD] Multipart form file created, size: \(multipartFileSize / (1024 * 1024))MB")
                print("DEBUG: [UPLOAD] ZIP file streamed in chunks, total: \(bytesWritten / (1024 * 1024))MB")
                print("DEBUG: [UPLOAD] Expected multipart size: ~\(fileSize + 500) bytes (ZIP + headers)")
                
                // Verify the multipart file is valid
                guard multipartFileSize > fileSize else {
                    throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Multipart file size (\(multipartFileSize)) is smaller than ZIP file size (\(fileSize))"])
                }
                
                // Lightweight validation - only read small chunks to verify file integrity
                // Wrapped in autoreleasepool to minimize memory footprint
                autoreleasepool {
                    do {
                        // Verify multipart file starts with boundary (small read: ~50 bytes)
                        let verifyHandle = try FileHandle(forReadingFrom: tempMultipartFile)
                        let firstBytes = verifyHandle.readData(ofLength: min(boundary.count + 4, 100))
                        verifyHandle.closeFile()
                        
                        if let firstString = String(data: firstBytes, encoding: .utf8), firstString.hasPrefix("--\(boundary)") {
                            print("DEBUG: [UPLOAD] Multipart file header verified")
                        } else {
                            print("DEBUG: [UPLOAD] WARNING: Multipart file header doesn't match expected boundary")
                        }
                        
                        // Verify ZIP signature is present (read only first 10KB to find ZIP start, then 4 bytes for signature)
                        let verifyHandle2 = try FileHandle(forReadingFrom: tempMultipartFile)
                        let searchData = verifyHandle2.readData(ofLength: min(Int(multipartFileSize), 10000))
                        verifyHandle2.closeFile()
                        
                        if let searchString = String(data: searchData, encoding: .utf8),
                           let zipStartRange = searchString.range(of: "\r\n\r\n", options: []),
                           let zipStartIndex = searchString.index(zipStartRange.upperBound, offsetBy: 0, limitedBy: searchString.endIndex) {
                            let zipStartOffset = searchString.distance(from: searchString.startIndex, to: zipStartIndex)
                            let verifyHandle3 = try FileHandle(forReadingFrom: tempMultipartFile)
                            verifyHandle3.seek(toFileOffset: UInt64(zipStartOffset))
                            let zipHeader = verifyHandle3.readData(ofLength: 4)
                            verifyHandle3.closeFile()
                            
                            let zipSignatures = [
                                Data([0x50, 0x4B, 0x03, 0x04]), // PK\x03\x04
                                Data([0x50, 0x4B, 0x05, 0x06]), // PK\x05\x06
                                Data([0x50, 0x4B, 0x07, 0x08])  // PK\x07\x08
                            ]
                            let isValidZipInMultipart = zipSignatures.contains { signature in
                                zipHeader.starts(with: signature)
                            }
                            if isValidZipInMultipart {
                                print("DEBUG: [UPLOAD] ZIP file signature verified within multipart form at offset \(zipStartOffset)")
                            } else {
                                print("DEBUG: [UPLOAD] ERROR: ZIP file signature NOT found in multipart form at offset \(zipStartOffset)")
                                print("DEBUG: [UPLOAD] First 4 bytes at ZIP start: \(zipHeader.map { String(format: "%02x", $0) }.joined())")
                            }
                        }
                    } catch {
                        print("DEBUG: [UPLOAD] Validation error (non-critical): \(error)")
                        // Don't fail upload if validation has issues - file might still be valid
                    }
                }
                
                if fileSize > maxMemoryEfficientSize {
                    VideoConversionService.shared.logMemoryUsage("after creating multipart file (streaming)")
                }
            } else {
                // For smaller files, use in-memory approach (more efficient for small files)
                let compressedData = try Data(contentsOf: compressedURL)
                guard compressedData.count > 0 else {
                    throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read zip file data"])
                }
                
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"zipFile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/zip\r\n".data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)
                body.append(compressedData)
                body.append("\r\n".data(using: .utf8)!)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"filename\"\r\n".data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)
                body.append("\(fileName)\r\n".data(using: .utf8)!)
                
                if let referenceId = referenceId {
                    body.append("--\(boundary)\r\n".data(using: .utf8)!)
                    body.append("Content-Disposition: form-data; name=\"referenceId\"\r\n".data(using: .utf8)!)
                    body.append("\r\n".data(using: .utf8)!)
                    body.append("\(referenceId)\r\n".data(using: .utf8)!)
                }
                
                body.append("--\(boundary)--\r\n".data(using: .utf8)!)
                
                // Write to temporary file for consistent upload path
                let tempDir = FileManager.default.temporaryDirectory
                tempMultipartFile = tempDir.appendingPathComponent("multipart_\(UUID().uuidString).tmp")
                try body.write(to: tempMultipartFile)
            }
            
            // Clean up temporary file after upload
            defer {
                try? FileManager.default.removeItem(at: tempMultipartFile)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            // Get multipart file size
            let multipartFileSize = (try? FileManager.default.attributesOfItem(atPath: tempMultipartFile.path))?[.size] as? Int64 ?? 0
            request.setValue("\(multipartFileSize)", forHTTPHeaderField: "Content-Length")
            
            // Set timeout for large video uploads (10 minutes)
            request.timeoutInterval = 600
            
            print("DEBUG: [UPLOAD] Sending request to: \(url)")
            print("DEBUG: [UPLOAD] Content-Type: \(request.value(forHTTPHeaderField: "Content-Type") ?? "nil")")
            print("DEBUG: [UPLOAD] Content-Length: \(request.value(forHTTPHeaderField: "Content-Length") ?? "nil")")
            print("DEBUG: [UPLOAD] Using file-based upload: \(shouldUseFileBasedUpload)")

            // Upload from file using uploadTask to avoid loading entire file into memory
            if fileSize > maxMemoryEfficientSize {
                VideoConversionService.shared.logMemoryUsage("before file-based upload")
            }
            
            let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempMultipartFile)

            if fileSize > maxMemoryEfficientSize {
                VideoConversionService.shared.logMemoryUsage("after file-based upload")
            }

            print("DEBUG: [UPLOAD] Received response with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")

            if let httpResponse = response as? HTTPURLResponse {
                print("DEBUG: [UPLOAD] Response headers: \(httpResponse.allHeaderFields)")

                if httpResponse.statusCode == 200 {
                    // Parse response to get job ID
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        print("DEBUG: process-zip upload response: \(responseString)")

                        // Parse JSON response to extract job ID
                        if let jsonData = responseString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let jobId = json["jobId"] as? String {
                            print("DEBUG: Extracted job ID from response: \(jobId)")
                            return jobId
                        } else {
                            // Fallback: try to extract job ID from response string
                            let trimmedResponse = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
                            print("DEBUG: Using fallback job ID extraction: \(trimmedResponse)")
                            return trimmedResponse
                        }
                    } else {
                        print("DEBUG: [UPLOAD] Could not decode response as UTF-8 string")
                        throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
                    }
                } else {
                    // Log the response body for debugging failed requests
                    if let errorResponseString = String(data: responseData, encoding: .utf8) {
                        print("DEBUG: [UPLOAD] Error response body: \(errorResponseString)")
                    }
                    throw NSError(domain: "VideoUpload", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload failed with status code: \(httpResponse.statusCode)"])
                }
            }
            
            throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        /// Poll process-zip status to get CID when processing is complete
        private static func pollProcessZipStatus(jobId: String, appUser: User, progressCallback: ((String, Int) -> Void)?) async throws -> String {
            print("DEBUG: Polling process-zip status for job ID: \(jobId)")
            
            guard let writableUrl = appUser.writableUrl else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available"])
            }
            
            // Get host from writableUrl - no fallback, must succeed
            guard let host = writableUrl.host else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not get host from writable URL"])
            }
            
            // Get cloud drive port - no fallback, must be configured
            guard appUser.cloudDrivePort > 0 else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cloud drive port not configured"])
            }
            
            guard let cloudBaseURL = URL(string: "http://\(host):\(HproseInstance.shared.appUser.cloudDrivePort)") else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct cloud drive URL"])
            }
            let statusURL = cloudBaseURL.appendingPathComponent("process-zip/status/\(jobId)")
            print("DEBUG: Polling status at: \(statusURL)")
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30  // 30 seconds for status checks
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)
            
            var attempts = 0
            let maxAttempts = 2880 // 4 hours with 5-second intervals (4 * 60 * 60 / 5 = 2880)
            let pollInterval: TimeInterval = 5.0
            
            while attempts < maxAttempts {
                attempts += 1
                print("DEBUG: Process-zip status polling attempt \(attempts)/\(maxAttempts)")
                
                do {
                    let (responseData, response) = try await session.data(from: statusURL)
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                print("DEBUG: Process-zip status response: \(responseString)")
                                
                                // Parse JSON response
                                if let jsonData = responseString.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    
                                    if let status = json["status"] as? String {
                                        if status == "completed" {
                                            if let cid = json["cid"] as? String {
                                                print("DEBUG: Process-zip completed with CID: \(cid)")
                                                return cid
                                            } else {
                                                throw NSError(domain: "ProcessZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Process completed but no CID found"])
                                            }
                                        } else if status == "failed" {
                                            let errorMessage = json["error"] as? String ?? "Unknown error"
                                            throw NSError(domain: "ProcessZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Process failed: \(errorMessage)"])
                                        } else if status == "processing" {
                                            // Still processing, continue polling
                                            progressCallback?("Processing HLS video... (\(attempts * 5)s)", 70 + (attempts * 2))
                                            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                                            continue
                                        }
                                    }
                                }
                            }
                        } else if httpResponse.statusCode == 404 {
                            // Job not found, might still be starting
                            print("DEBUG: Job not found yet, continuing to poll...")
                            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                            continue
                        } else {
                            print("DEBUG: Status check failed with status code: \(httpResponse.statusCode)")
                        }
                    }
                } catch {
                    print("DEBUG: Status check error: \(error)")
                }
                
                // Wait before next attempt
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            
            throw NSError(domain: "ProcessZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Process-zip timeout after 4 hours"])
        }
        
        /// Wait for server to return CID via message pull
        private func waitForServerCID(cid: String, appUser: User) async throws -> (MimeiFileType?, String?) {
            print("DEBUG: Waiting for server CID: \(cid)")
            
            // Poll for server response with timeout
            let maxAttempts = 12 // 12 attempts (60 seconds total with 5s intervals)
            let pollInterval: UInt64 = 5_000_000_000 // 5 seconds in nanoseconds
            
            for attempt in 1...maxAttempts {
                print("DEBUG: Polling attempt \(attempt)/\(maxAttempts) for CID: \(cid)")
                
                // Check for server response via message pull
                if let result = try await checkForServerResponse(cid: cid, appUser: appUser) {
                    print("DEBUG: Received server response for CID: \(cid)")
                    return result
                }
                
                // Wait before next attempt
                try await Task.sleep(nanoseconds: pollInterval)
            }
            
            throw NSError(domain: "VideoProcessing", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for server response"])
        }
        
        /// Check for server response via message pull
        private func checkForServerResponse(cid: String, appUser: User, originalVideoDataSize: Int64? = nil) async throws -> (MimeiFileType?, String?)? {
            guard let client = appUser.hproseClient else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            
            let entry = "check_video_processing"
            let params: [String: Any] = [
                "aid": "Tweet",
                "ver": "last",
                "version": "v2",
                "userid": appUser.mid,
                "cid": cid
            ]
            
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try? HproseInstance.unwrapV2Response(rawResponse)
            guard let response = unwrappedResponse as? [String: Any] else {
                return nil // No response yet
            }
            
            if let status = response["status"] as? String, status == "completed" {
                // Parse the completed video result
                if let fileData = response["file"] as? [String: Any] {
                    let mid = fileData["mid"] as? String ?? UUID().uuidString
                    let fileName = fileData["fileName"] as? String ?? "video.m3u8"
                    let serverFileSize = fileData["fileSize"] as? Int ?? 0
                    let aspectRatio = fileData["aspectRatio"] as? Float ?? 16.0/9.0
                    
                    // Use original video data size instead of server response size
                    let finalSize = originalVideoDataSize ?? Int64(serverFileSize)
                    
                    print("DEBUG: [checkForServerResponse] Server response file data:")
                    print("DEBUG: - MID: \(mid)")
                    print("DEBUG: - File name: \(fileName)")
                    print("DEBUG: - Server file size: \(serverFileSize)")
                    print("DEBUG: - Original video data size: \(originalVideoDataSize ?? -1)")
                    print("DEBUG: - Final size used: \(finalSize)")
                    print("DEBUG: - Aspect ratio: \(aspectRatio)")
                    print("DEBUG: - Full fileData: \(fileData)")
                    
                    let mimeiFile = MimeiFileType(
                        mid: mid,
                        mediaType: .hls_video,
                        size: finalSize,
                        fileName: fileName,
                        aspectRatio: aspectRatio
                    )
                    
                    return (mimeiFile, nil)
                }
            }
            
            return nil // Still processing
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
            
            // Get host from writableUrl - no fallback, must succeed
            guard let host = writableUrl.host else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not get host from writable URL"])
            }
            
            // Get cloud drive port - no fallback, must be configured
            guard appUser.cloudDrivePort > 0 else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cloud drive port not configured"])
            }
            
            guard let cloudBaseURL = URL(string: "http://\(host):\(HproseInstance.shared.appUser.cloudDrivePort)") else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct cloud drive URL"])
            }
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
            let aspectRatio = await MediaProcessor.getVideoAspectRatioWithFallback(from: data)
            
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
        private static func getVideoAspectRatioWithFallback(from data: Data) async -> Float? {
            do {
                let aspectRatio = try await getVideoAspectRatio(from: data)
                if let ratio = aspectRatio, ratio > 0 {
                    return ratio
                } else {
                    return 16.0 / 9.0
                }
            } catch {
                return 16.0 / 9.0
            }
        }
        
        /// IPFS doesn't care about file types - they're all data blobs
        static func uploadRegularFile(
            data: Data,
            typeIdentifier: String,
            fileName: String?,
            referenceId: String?,
            mediaType: MediaType,
            appUser: User,
            appId: String
        ) async throws -> MimeiFileType {
            print("Uploading \(mediaType.rawValue): \(String(format: "%.1f", Double(data.count) / (1024 * 1024)))MB")
            
            _ = try await appUser.resolveWritableUrl()
            guard let uploadClient = appUser.uploadClient else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Upload client not available", comment: "Upload error")])
            }
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            var offset: Int64 = 0
            let chunkSize = 1024 * 1024 // 1MB chunks
            var request: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
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
                do {
                    let response = try await MediaProcessor.uploadChunk(
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
                        print("ERROR: Chunk \(chunkCount) upload failed - invalid response type: \(type(of: response))")
                        throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Server returned invalid response", comment: "Upload error")])
                    }
                } catch let error as NSError {
                    // Provide more specific error message based on the error
                    if error.domain == NSURLErrorDomain {
                        switch error.code {
                        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                            print("ERROR: Chunk \(chunkCount) upload failed - network connection lost")
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Network connection lost. Please check your connection and try again.", comment: "Network error")])
                        case NSURLErrorTimedOut:
                            print("ERROR: Chunk \(chunkCount) upload failed - timeout")
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Upload timed out. Please try again.", comment: "Timeout error")])
                        default:
                            let nsError = error as NSError
                            print("ERROR: Chunk \(chunkCount) upload failed - network error: domain: \(nsError.domain), code: \(nsError.code)")
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Network error: %@", comment: "Network error"), ErrorMessageHelper.userFriendlyMessage(from: error))])
                        }
                    } else {
                        // Re-throw other errors
                        throw error
                    }
                }
            }
            
            request["finished"] = "true"
            if let referenceId = referenceId {
                request["referenceid"] = referenceId
            }
            print("Uploaded \(chunkCount) chunks, finalizing...")
            
            let rawFinalResponse = uploadClient.invoke("runMApp", withArgs: ["upload_ipfs", request])
            let finalResponse = try? HproseInstance.unwrapV2Response(rawFinalResponse)
            
            var cid: String? = nil
            if let stringResponse = finalResponse as? String {
                cid = stringResponse
            } else if let dictResponse = finalResponse as? [String: Any] {
                cid = dictResponse["cid"] as? String
            }
            
            guard let cid = cid, !cid.isEmpty else {
                print("ERROR: Upload finalization failed - invalid CID response")
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload file", comment: "Upload error")])
            }
            
            // Get file attributes
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
            
            // Get aspect ratio for videos and images
            var aspectRatio: Float?
            if mediaType == .video {
                aspectRatio = try await MediaProcessor.getVideoAspectRatio(from: data)
            } else if mediaType == .image {
                aspectRatio = try await MediaProcessor.getImageAspectRatio(from: data)
            }
            
            return MimeiFileType(
                mid: cid,
                mediaType: mediaType,
                size: Int64(fileSize),
                fileName: fileName,
                timestamp: fileTimestamp,
                aspectRatio: aspectRatio,
                url: nil
            )
        }
        
        /// Get video aspect ratio from data
        private static func getVideoAspectRatio(from data: Data) async throws -> Float? {
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
        private static func getImageAspectRatio(from data: Data) async throws -> Float? {
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
                    let result = try await MediaProcessor.pollVideoConversionStatus(
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
                    let errorMessage = String(data: responseData, encoding: .utf8) ?? NSLocalizedString("Bad request", comment: "HTTP error message")
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Bad request: %@", comment: "HTTP error message"), errorMessage)])
                } else if httpResponse.statusCode == 413 {
                    // Payload too large - don't retry
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Video file too large for processing", comment: "Video processing error")])
                } else if httpResponse.statusCode >= 500 {
                    // Server error - throw error
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Server error (HTTP %d)", comment: "Server error message"), httpResponse.statusCode)])
                } else {
                    throw NSError(domain: "VideoProcessor", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("HTTP %d error", comment: "HTTP error message"), httpResponse.statusCode)])
                }
            } else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid HTTP response", comment: "HTTP error message")])
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
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to process data. Please try again.", comment: "Parse error")])
            }
        }
        
        /// Poll video conversion status until completion
        static func pollVideoConversionStatus(
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
            
            // Get host from baseURL - no fallback, must succeed
            guard let host = baseURL.host else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not get host from base URL"])
            }
            
            // Get cloud drive port - no fallback, must be configured
            guard HproseInstance.shared.appUser.cloudDrivePort > 0 else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cloud drive port not configured"])
            }
            
            guard let cloudBaseURL = URL(string: "http://\(host):\(HproseInstance.shared.appUser.cloudDrivePort)") else {
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct cloud drive URL"])
            }
            let statusURL = cloudBaseURL.appendingPathComponent("process-zip/status/\(jobId)")
            print("DEBUG: Polling status at: \(statusURL)")
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30  // 30 seconds for status checks
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)
            
            var attempts = 0
            let maxAttempts = 2880 // 4 hours with 5-second intervals (4 * 60 * 60 / 5 = 2880)
            let pollInterval: TimeInterval = 5.0
            
            while attempts < maxAttempts {
                attempts += 1
                print("DEBUG: Status check attempt \(attempts)/\(maxAttempts)")
                
                do {
                    let (responseData, response) = try await session.data(from: statusURL)
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            let statusResult = try MediaProcessor.parseVideoStatusResponse(responseData: responseData)
                            
                            switch statusResult.status {
                            case "completed":
                                print("DEBUG: Video conversion completed, CID: \(statusResult.cid ?? "unknown")")
                                print("DEBUG: [pollVideoConversionStatus] Creating MimeiFileType with:")
                                print("DEBUG: - CID: \(statusResult.cid ?? "unknown")")
                                print("DEBUG: - Original data size: \(data.count) bytes")
                                print("DEBUG: - File name: \(fileName ?? "unknown")")
                                print("DEBUG: - Aspect ratio: \(aspectRatio ?? 0)")
                                progressCallback?("Video conversion completed!", 100)
                                return MimeiFileType(
                                    mid: statusResult.cid ?? "",
                                    mediaType: .hls_video,
                                    size: Int64(data.count),
                                    fileName: fileName,
                                    timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970), // Use current time as Date object (will be encoded as Unix timestamp in milliseconds)
                                    aspectRatio: aspectRatio,
                                    url: nil
                                )
                                
                            case "failed":
                                let errorMessage = statusResult.message ?? NSLocalizedString("Video conversion failed", comment: "Video processing error")
                                print("DEBUG: Video conversion failed: \(errorMessage)")
                                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video conversion failed: \(errorMessage)"])
                                
                            case "uploading", "processing":
                                let message = statusResult.message ?? NSLocalizedString("Processing...", comment: "Processing status")
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
            
            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video conversion timed out after 4 hours"])
        }
        
        /// Parse video status response
        private static func parseVideoStatusResponse(responseData: Data) throws -> VideoConversionStatus {
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
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to process data. Please try again.", comment: "Parse error")])
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
                            timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970), // Use current time as Date object (will be encoded as Unix timestamp in milliseconds)
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
                throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to process data. Please try again.", comment: "Parse error")])
            }
        }
        
        /// Upload chunk for regular files (no retry)
        private static func uploadChunk(
            uploadClient: HproseClient,
            request: [String: Any],
            data: NSData,
            chunkNumber: Int
        ) async throws -> Any {
            // Add 3 minute timeout for each chunk upload (handles slow connections)
            return try await withThrowingTaskGroup(of: Any.self) { group in
                group.addTask {
                    let rawResponse = uploadClient.invoke("runMApp", withArgs: ["upload_ipfs", request, [data]])
                    return try HproseInstance.unwrapV2Response(rawResponse) as Any
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 180_000_000_000) // 180 seconds (3 minutes)
                    throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload timeout - chunk \(chunkNumber) took too long"])
                }
                
                // Return the first result (either success or timeout)
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
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
    
    /// Start periodic processing of blacklist candidates
    /// Checks every hour if candidates should be moved to blacklist (14+ failures over 1+ week)
    func startPeriodicBlackListProcessing() {
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            
            print("DEBUG: [HproseInstance] Started periodic blacklist candidate processing (every hour)")
            
            while true {
                // Wait 1 hour
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                
                // Process candidates - move eligible ones to blacklist
                self.blackList.processCandidates()
            }
        }
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
        var attempt = 0
        let maxAttempts = 2 // Initial attempt + 1 retry
        
        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await block()
            } catch {
                print("DEBUG: [withRetry] Attempt \(attempt)/\(maxAttempts) failed: \(error)")
                
                if attempt < maxAttempts {
                    // Wait 1 second before retry
                    let delay: UInt64 = 1_000_000_000 // 1 second
                    print("DEBUG: [withRetry] Retrying in 1 second...")
                    try await Task.sleep(nanoseconds: delay)
                    
                    // Refresh appUser from server instead of full app reinitialization
                    // IP re-resolution is automatically handled by fetchUser's internal retry mechanism
                    try await refreshAppUserFromServer()
                }
            }
        }
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error: All retries failed."])
    }
    
    /// Refresh appUser data from server without full app reinitialization
    ///
    /// This method updates the current appUser with fresh data from the backend server:
    /// 1. Skips refresh for guest users (returns early)
    /// 2. Resolves the provider IP for the current user
    /// 3. Calls `fetchUser()` to fetch latest user data
    /// 4. Updates HproseInstance.baseUrl if the provider IP has changed
    /// 5. Updates the appUser singleton instance with refreshed data
    ///
    /// Use cases:
    /// - Called after successful tweet upload/delete to update tweet counts
    /// - Called during retry operations
    /// - Called by AppDelegate when app returns from background
    ///
    /// - Throws: Network or parsing errors (errors are logged but not thrown to caller)
    /// - Note: This is a lightweight refresh that doesn't reinitialize the entire app
    /// - Note: Changes to appUser are applied on MainActor to ensure thread safety
    /// - Note: IP re-resolution is automatically handled by fetchUser's internal retry mechanism
    func refreshAppUserFromServer() async throws {
        guard !appUser.isGuest else {
            print("DEBUG: [HproseInstance] Skipping refresh for guest user")
            return
        }
        
        print("DEBUG: [HproseInstance] Refreshing appUser from server...")
        do {
            // fetchUser's internal retry mechanism (maxRetries: 2) automatically re-resolves IP on second attempt if first fails.
            // This means:
            // - Attempt 1: Uses existing appUser.baseUrl (may be stale)
            // - If attempt 1 fails: Attempt 2 automatically calls getProviderIP() for fresh IP
            
            // Call fetchUser to fetch from server (force refresh bypasses cache)
            if let refreshedUser = try await fetchUser(appUser.mid, forceRefresh: true) {
                
                // Update appUser with refreshed data
                await MainActor.run {
                    self.appUser = refreshedUser
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
    // NOTE: PendingTweetUpload is now defined in TweetUploadManager.swift
    // Keeping type alias for compatibility
    typealias PendingTweetUpload = TweetUploadManager.PendingTweetUpload
    
    func uploadTweet(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            // Create a clean upload payload with only allowed fields (excluding nil values)
            var uploadPayload: [String: Any] = [
                "mid": tweet.mid,
                "authorId": tweet.authorId,
                "timestamp": tweet.timestamp.timeIntervalSince1970 * 1000 // milliseconds
            ]
            
            // Add optional fields only if they are not nil
            if let content = tweet.content {
                uploadPayload["content"] = content
            }
            if let title = tweet.title {
                uploadPayload["title"] = title
            }
            if let originalTweetId = tweet.originalTweetId {
                uploadPayload["originalTweetId"] = originalTweetId
            }
            if let originalAuthorId = tweet.originalAuthorId {
                uploadPayload["originalAuthorId"] = originalAuthorId
            }
            if let attachments = tweet.attachments, !attachments.isEmpty {
                uploadPayload["attachments"] = attachments.map { attachment in
                    var attachmentDict: [String: Any] = [
                        "mid": attachment.mid,
                        "type": attachment.type.rawValue
                    ]
                    attachmentDict["timestamp"] = attachment.timestamp.timeIntervalSince1970 * 1000
                    
                    // Add optional fields
                    if let size = attachment.size {
                        attachmentDict["size"] = size
                    }
                    if let fileName = attachment.fileName {
                        attachmentDict["fileName"] = fileName
                    }
                    if let aspectRatio = attachment.aspectRatio {
                        attachmentDict["aspectRatio"] = aspectRatio
                    }
                    
                    return attachmentDict
                }
            }
            if let isPrivate = tweet.isPrivate {
                uploadPayload["isPrivate"] = isPrivate
            }
            if let downloadable = tweet.downloadable {
                uploadPayload["downloadable"] = downloadable
            }
            
            // Convert to JSON string
            let jsonData = try JSONSerialization.data(withJSONObject: uploadPayload, options: [])
            let tweetJSON = String(data: jsonData, encoding: .utf8) ?? ""
            
            // Capture appUser properties on main thread to avoid publishing warnings
            let hostId = await MainActor.run {
                self.appUser.hostIds?.first
            }
            let client = await MainActor.run {
                self.appUser.hproseClient
            }
            
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "hostid": hostId as Any,
                "tweet": tweetJSON
            ]
            
            print("DEBUG: [uploadTweet] Complete params: \(params)")
            print("DEBUG: [uploadTweet] Tweet JSON: \(tweetJSON)")
            print("DEBUG: [uploadTweet] Tweet authorId: \(tweet.authorId), content: \(tweet.content ?? "nil"), attachments count: \(tweet.attachments?.count ?? 0)")
            
            let rawResponse = client?.invoke("runMApp", withArgs: ["add_tweet", params])
            
            print("DEBUG: [uploadTweet] Raw response: \(String(describing: rawResponse))")
            
            // Unwrap v2 response
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            // Handle the JSON response format
            guard let responseDict = unwrappedResponse as? [String: Any] else {
                print("DEBUG: [uploadTweet] ERROR: Invalid response format - not a dictionary")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server"])
            }
            
            print("DEBUG: [uploadTweet] Response dictionary keys: \(responseDict.keys)")
            
            guard let success = responseDict["success"] as? Bool else {
                print("DEBUG: [uploadTweet] ERROR: Missing or invalid 'success' field in response")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format: missing success field"])
            }
            
            if success {
                // Success case: extract the tweet ID
                guard let newTweetId = responseDict["mid"] as? String else {
                    print("DEBUG: [uploadTweet] ERROR: Success response missing tweet ID")
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Success response missing tweet ID"])
                }
                
                print("DEBUG: [uploadTweet] Successfully uploaded tweet with ID: \(newTweetId)")
                let uploadedTweet = tweet
                
                // Fetch author off-main, but assign @Published properties on main.
                let author = try? await self.fetchUser(tweet.authorId)
                await MainActor.run {
                    // Tweet is an ObservableObject; avoid publishing from background threads.
                    uploadedTweet.mid = newTweetId
                    uploadedTweet.author = author
                }
                
                // Immediately update appUser tweet count (like favorites/bookmarks)
                await MainActor.run {
                    let currentCount = self.appUser.tweetCount ?? 0
                    self.appUser.tweetCount = currentCount + 1
                    print("DEBUG: [uploadTweet] Updated appUser.tweetCount to \(self.appUser.tweetCount ?? 0)")
                }
                
                // Refresh appUser from server to get updated tweetCount and other properties
                try? await self.refreshAppUserFromServer()
                
                return uploadedTweet
            } else {
                // Failure case: extract error message
                print("DEBUG: [uploadTweet] Server returned success=false, full response: \(responseDict)")
                let errorMessage = responseDict["message"] as? String ?? responseDict["msg"] as? String ?? responseDict["error"] as? String ?? "Unknown upload error"
                print("DEBUG: [uploadTweet] Error message: \(errorMessage)")
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
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
            }
            
            return uploadResults.compactMap { $0 }
        }
    }
    
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        // Delegate to upload manager
        uploadManager.scheduleTweetUpload(tweet: tweet, itemData: itemData)
    }
    
    func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        // Delegate to upload manager
        uploadManager.scheduleChatMessageUpload(message: message, itemData: itemData)
    }
    
    private func uploadTweetWithPersistenceAndRetry(tweet: Tweet, itemData: [PendingTweetUpload.ItemData], retryCount: Int = 0, videoJobId: String? = nil) async {
        print("DEBUG: [uploadTweetWithPersistenceAndRetry] Starting upload with retry count: \(retryCount)")
        
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
                
                // Post notification (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload tweet", comment: "Tweet upload error")])
            }
        } catch {
            print("Error uploading tweet: \(error)")
            
            // Check if we've reached max retries
            let maxRetries = 2
            
            print("DEBUG: [Error handling] retryCount=\(retryCount), maxRetries=\(maxRetries), will show error: \(retryCount >= maxRetries)")
            
            if retryCount >= maxRetries {
                // All retries exhausted - show error to user
                print("DEBUG: [Error handling] MAX RETRIES REACHED - Showing error to user and removing pending upload")
                let userFriendlyMessage = NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Tweet upload failed error")
                
                await MainActor.run {
                    if !self.isAppInitializing {
                        print("DEBUG: [Error handling] Posting backgroundUploadFailed notification")
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": userFriendlyMessage]
                        )
                    } else {
                        print("DEBUG: [Error handling] App still initializing, NOT showing error")
                    }
                }
                
                // Remove pending upload since we're giving up
                await removePendingUpload()
            } else {
                // Will retry in background - don't show error yet
                print("DEBUG: [Error handling] Retry \(retryCount + 1) of \(maxRetries + 1) failed, scheduling background retry")
                
                // Schedule immediate background retry
                let delay = UInt64(retryCount + 1) * 2_000_000_000 // 2, 4 seconds exponential backoff
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: delay)
                    await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData, retryCount: retryCount + 1)
                }
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
            print(NSLocalizedString("Chat message upload failed", comment: "Chat upload error"))
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
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
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
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to process data. Please try again.", comment: "Parse error")])
        }
    }
    
    private func checkVideoJobStatus(jobId: String, baseURL: URL?) async -> VideoConversionStatus? {
        guard let baseURL = baseURL else { return nil }
        
        let statusURL = baseURL.appendingPathComponent("process-zip/status/\(jobId)")
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
                // Calculate aspect ratio from original video data
                var aspectRatio: Float?
                do {
                    // Create temporary file to extract aspect ratio
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                    try item.data.write(to: tempURL)
                    aspectRatio = try await HLSVideoProcessor.shared.getVideoAspectRatio(filePath: tempURL.path)
                    try? FileManager.default.removeItem(at: tempURL)
                } catch {
                    print("DEBUG: Could not determine video aspect ratio: \(error), using default 16:9")
                    aspectRatio = 16.0 / 9.0 // Default to 16:9 aspect ratio
                }
                
                // Create Date object from current time (this will be properly encoded as Unix timestamp in milliseconds)
                let currentDate = Date()
                
                print("DEBUG: [handleCompletedVideoJob] Creating MimeiFileType for video:")
                print("DEBUG: - CID: \(cid)")
                print("DEBUG: - Original video data size: \(item.data.count) bytes")
                print("DEBUG: - File name: \(item.fileName)")
                print("DEBUG: - Aspect ratio: \(aspectRatio ?? 0)")
                print("DEBUG: - Current timestamp: \(currentDate)")
                print("DEBUG: - Unix timestamp (ms): \(Int64(currentDate.timeIntervalSince1970 * 1000))")
                
                let videoFile = MimeiFileType(
                    mid: cid,
                    mediaType: .hls_video,
                    size: Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: currentDate,
                    aspectRatio: aspectRatio,
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
                    
                    // Post notification (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .newTweetCreated,
                            object: nil,
                            userInfo: ["tweet": uploadedTweet]
                        )
                    }
                } else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload tweet", comment: "Tweet upload error")])
                }
            } catch {
                print("Error uploading tweet: \(error)")
                
                // Notify failure but keep pending upload for manual retry (only if app is initialized)
                await MainActor.run {
                    if !self.isAppInitializing {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": ErrorMessageHelper.userFriendlyMessage(from: error)]
                        )
                    } else {
                        print("DEBUG: Skipping background upload error dialog during app initialization: \(error)")
                    }
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
        
        // Get host - must succeed
        guard let host = originalBaseURL?.host else {
            print("ERROR: No host available for video job polling")
            return
        }
        
        // Get cloud drive port - must be configured
        guard appUser.cloudDrivePort > 0 else {
            print("ERROR: Cloud drive port not configured for video job polling")
            return
        }
        
        guard let baseURL = URL(string: "http://\(host):\(appUser.cloudDrivePort)") else {
            print("ERROR: Failed to construct cloud drive URL")
            return
        }
        
        // Find the video item to get its data
        guard let videoItem = pendingUpload.itemData.first(where: { 
            $0.typeIdentifier.contains("video") || $0.typeIdentifier.contains("movie") 
        }) else {
            print("DEBUG: No video item found for polling resume")
            return
        }
        
        // Resume polling with the stored job ID
        do {
            let result = try await HproseInstance.MediaProcessor.pollVideoConversionStatus(
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
    
    // REMOVED: cleanupProblematicPendingUploads(), recoverPendingUploads(), recoverPendingUploads_old()
    // Pending upload recovery is now handled by ContentView's dialog system
    
    // The old recoverPendingUploads_old function code removed (was 130+ lines)
    // All retry logic is preserved in uploadTweetWithPersistenceAndRetry()
    // New system: User sees dialog with retry/discard options instead of auto-retry
    
    
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        isQuoting: Bool = false
    ) {
        // Delegate to upload manager
        uploadManager.scheduleCommentUpload(comment: comment, to: tweet, itemData: itemData, isQuoting: isQuoting)
    }
    
    /**
     * Return the current tweet list that is pinned to top.
     */
    func togglePinnedTweet(tweetId: String) async throws -> Bool? {
        let entry = "toggle_pinned_tweet"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "appuserid": appUser.mid,
        ]
        let rawResponse = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // For v2 API: server returns {success: true, data: {isPinned: bool}}
        // After unwrapV2Response, we get {isPinned: bool}
        if let dataDict = unwrappedResponse as? [String: Any] {
            if let isPinned = dataDict["isPinned"] as? Bool {
                return isPinned
            }
        }
        
        // Fallback: check if it's a direct Bool (legacy format)
        if let boolResponse = unwrappedResponse as? Bool {
            return boolResponse
        }
        
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to update pinned tweet", comment: "Pin tweet error")])
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
            "version": "v2",
            "userid": user.mid,
            "appuserid": appUser.mid
        ]
        
        guard let client = user.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when user has no pinned tweets
        let response: [[String: Any]]
        if let arrayResponse = unwrappedResponse as? [[String: Any]] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            print("DEBUG: [HproseInstance] getPinnedTweets - Server returned empty array (no pinned tweets)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to get pinned tweets", comment: "Get pinned tweets error")])
        }
        
        var result: [[String: Any]] = []
        for dict in response {
            if let tweetDict = dict["tweet"] as? [String: Any] {
                let tweet = try await MainActor.run { return try Tweet.from(dict: tweetDict) }
                if let author = try? await fetchUser(tweet.authorId) {
                    await MainActor.run {
                        tweet.author = author  // Set on main thread since author is @Published
                    }
                }
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
        cloudDrivePort: Int = 0
    ) async throws -> Bool {
        print("DEBUG: [registerUser] Starting registration")
        print("DEBUG: [registerUser] hostId parameter: \(hostId ?? "nil")")
        
        var hosts: [String]? = nil
        if let hostId = hostId, !hostId.isEmpty {
            hosts = [hostId]
            print("DEBUG: [registerUser] Setting hosts to [\(hostId)]")
        } else {
            print("DEBUG: [registerUser] No hostId provided, hosts will be nil")
        }
        
        let newUser = User(mid: appUser.mid, name: alias, username: username, password: password,
                           profile: profile, cloudDrivePort: cloudDrivePort, hostIds: hosts)
        print("DEBUG: [registerUser] Created User object with hostIds: \(newUser.hostIds ?? [])")
        
        let entry = "register"
        
        // Configure encoder to use milliseconds for timestamps
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        
        let userJsonData = try encoder.encode(newUser)
        let userJsonString = String(data: userJsonData, encoding: .utf8) ?? ""
        print("DEBUG: [registerUser] Encoded user JSON: \(userJsonString)")
        
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "user": userJsonString
        ]
        
        // Use the current appUser's client for all backend calls
        guard let client = appUser.hproseClient else {
            print("DEBUG: [registerUser] ERROR: appUser.hproseClient is nil")
            print("DEBUG: [registerUser] appUser.baseUrl: \(appUser.baseUrl?.absoluteString ?? "nil")")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized. Please check your connection.", comment: "Client initialization error")])
        }
        let targetUrl = appUser.baseUrl?.absoluteString ?? "unknown"
        
        print("DEBUG: [registerUser] Sending registration request to server")
        print("DEBUG: [registerUser] Using target URL: \(targetUrl)")
        
        let unwrappedResponse: Any
        do {
            let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
            print("DEBUG: [registerUser] Raw response received: \(String(describing: rawResponse))")
            
            unwrappedResponse = try Self.unwrapV2Response(rawResponse) as Any
            print("DEBUG: [registerUser] Unwrapped response: \(unwrappedResponse)")
        } catch {
            print("DEBUG: [registerUser] ERROR: Exception during API call: \(error)")
            print("DEBUG: [registerUser] Error details: \(error.localizedDescription)")
            throw error
        }
        
        guard let response = unwrappedResponse as? [String: Any] else {
            print("DEBUG: [registerUser] ERROR: Response is not a dictionary")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
        }
        
        // v2 format: {success: true, user: <parsed user object>}
        guard let success = response["success"] as? Bool else {
            print("DEBUG: [registerUser] ERROR: 'success' field not found in response")
            print("DEBUG: [registerUser] Response keys: \(response.keys)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
        }
        
        print("DEBUG: [registerUser] Registration success status: \(success)")
        if success {
            // Extract the newly created user's ID from the response
            guard let userDict = response["user"] as? [String: Any],
                  let registeredUserId = userDict["mid"] as? String else {
                // If user object is missing, still return success but log warning
                print("DEBUG: [registerUser] Warning: User object not found in registration response")
                return true
            }
            
            // Make the newly registered user follow each user in getAlphaIds()
            let alphaIds = Gadget.getAlphaIds()
            for alphaId in alphaIds {
                do {
                    _ = try await self.toggleFollowing(followingId: alphaId, userId: registeredUserId)
                } catch {
                    let nsError = error as NSError
                    print("DEBUG: [registerUser] Failed to follow alphaId \(alphaId): domain: \(nsError.domain), code: \(nsError.code)")
                    // Continue with other users even if one fails
                }
            }
            return true
        } else {
            let message = response["message"] as? String ?? response["reason"] as? String ?? NSLocalizedString("Unknown registration error.", comment: "Unknown registration error")
            print("DEBUG: [registerUser] ERROR: Registration failed with message: \(message)")
            print("DEBUG: [registerUser] Full response: \(response)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    
    func updateUserCore(
        password: String? = nil,
        alias: String? = nil,
        profile: String? = nil,
        hostId: String? = nil,
        cloudDrivePort: Int = 0,
        domainToShare: String? = nil
    ) async throws -> Bool {
        print("DEBUG: updateUserCore called with - alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort), domainToShare: \(domainToShare ?? "nil")")
        
        let sanitizedDomain = domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalShareDomain = sanitizedDomain?.isEmpty == true ? nil : sanitizedDomain
        
        // Determine domainToShare value: if explicitly provided (even if empty/nil), use it; otherwise preserve existing
        // Empty string "" is converted to nil, which will exclude the field from JSON (encodeIfPresent)
        let domainToShareValue: String?
        if domainToShare != nil {
            // Parameter was explicitly provided (even if empty string), use finalShareDomain (nil if empty)
            domainToShareValue = finalShareDomain
        } else {
            // Parameter was not provided, preserve existing value
            domainToShareValue = appUser.domainToShare
        }
        
        // Create a copy of the user object with all existing properties
        let updatedUser = User(
            mid: appUser.mid,
            name: alias ?? appUser.name,
            password: password ?? appUser.password,
            profile: profile ?? appUser.profile,
            cloudDrivePort: cloudDrivePort,
            domainToShare: domainToShareValue
        )
        // Copy other properties from appUser
        updatedUser.baseUrl = appUser.baseUrl
        updatedUser.writableUrl = appUser.writableUrl
        updatedUser.username = appUser.username
        updatedUser.avatar = appUser.avatar
        updatedUser.email = appUser.email
        updatedUser.timestamp = appUser.timestamp
        updatedUser.lastLogin = appUser.lastLogin
        updatedUser.tweetCount = appUser.tweetCount
        updatedUser.followingCount = appUser.followingCount
        updatedUser.followersCount = appUser.followersCount
        updatedUser.bookmarksCount = appUser.bookmarksCount
        updatedUser.favoritesCount = appUser.favoritesCount
        updatedUser.commentsCount = appUser.commentsCount
        updatedUser.publicKey = appUser.publicKey
        updatedUser.fansList = appUser.fansList
        updatedUser.followingList = appUser.followingList
        
        // Only set hostIds if hostId is provided and not empty
        // If hostId is nil or empty, preserve existing hostIds (don't modify)
        if let hostId = hostId, !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedUser.hostIds = [hostId]
        } else {
            // Preserve existing hostIds when hostId is not provided
            updatedUser.hostIds = appUser.hostIds
        }
        
        // Configure encoder to use milliseconds for timestamps
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        
        let entry = "set_author_core_data"
        let userJsonData = try encoder.encode(updatedUser)
        let userJsonString = String(data: userJsonData, encoding: .utf8) ?? ""
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "user": userJsonString
        ]
        
        print("DEBUG: updateUserCore - sending request to server with user data")
        print("DEBUG: updateUserCore - domainToShare in User object: \(finalShareDomain ?? "nil")")
        print("DEBUG: updateUserCore - encoded user JSON contains domainToShare: \(userJsonString.contains("domainToShare"))")
        // Print a snippet of the JSON to verify domainToShare is included
        if let domainRange = userJsonString.range(of: "\"domainToShare\"") {
            let startIndex = userJsonString.index(domainRange.lowerBound, offsetBy: -50, limitedBy: userJsonString.startIndex) ?? userJsonString.startIndex
            let endIndex = userJsonString.index(domainRange.upperBound, offsetBy: 50, limitedBy: userJsonString.endIndex) ?? userJsonString.endIndex
            let snippet = String(userJsonString[startIndex..<endIndex])
            print("DEBUG: updateUserCore - JSON snippet around domainToShare: ...\(snippet)...")
        }
        
        let rawResponse = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            print("DEBUG: updateUserCore - failed to get response from server")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Profile update failed", comment: "Profile update error")])
        }
        
        print("DEBUG: updateUserCore - server response: \(response)")
        
        // Handle v2 format: check success field first
        if let success = response["success"] as? Bool {
            if !success {
                let message = response["message"] as? String ?? NSLocalizedString("Profile update failed", comment: "Profile update error")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            // success is true, continue with status check for backward compatibility
        }
        
        if let result = response["status"] as? String {
            if result == "success" {
                print("DEBUG: updateUserCore - server returned success")
                
                // Update in-memory appUser with new values on MainActor (User has @Published properties)
                await MainActor.run {
                    if let alias = alias {
                        self.appUser.name = alias
                    }
                    if let profile = profile {
                        self.appUser.profile = profile
                    }
                    // Update hostIds: if hostId is provided, set it; if nil/empty, preserve existing hostIds
                    if let hostId = hostId, !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.appUser.hostIds = [hostId]
                    }
                    // If hostId is nil/empty, don't modify appUser.hostIds - preserve existing value
                    // CRITICAL: Update cloudDrivePort
                    self.appUser.cloudDrivePort = cloudDrivePort
                    if let sanitizedDomain = sanitizedDomain, !sanitizedDomain.isEmpty {
                        self.appUser.domainToShare = sanitizedDomain
                    } else {
                        self.appUser.domainToShare = nil
                    }
                    print("DEBUG: updateUserCore - updated in-memory appUser, cloudDrivePort: \(cloudDrivePort), domainToShare: \(self.appUser.domainToShare ?? "nil")")
                }
                
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
    /// Sets the user's avatar on the server and returns confirmed avatar
    func setUserAvatar(user: User, avatar: MimeiId) async throws -> String {
        let entry = "set_user_avatar"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": user.mid,
            "avatar": avatar
        ]
        
        let rawResponse = appUser.hproseClient?.invoke("runMApp", withArgs: [entry, params])
        guard rawResponse != nil else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server did not respond"])
        }
        
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Server returns avatar MimeiId directly as a String or wrapped in v2 format
        if let confirmedAvatar = unwrappedResponse as? String {
            return confirmedAvatar
        } else if let dictResponse = unwrappedResponse as? [String: Any] {
            if let avatar = dictResponse["avatar"] as? String ?? dictResponse["data"] as? String {
                return avatar
            }
        }
        
        throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected server response"])
    }
    
    /// Find IP addresses of given nodeId
    func getHostIP(_ nodeId: String, v4Only: Bool = false) async -> String? {
        let entry = "get_node_ips"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "nodeid": nodeId,
            "v4only": v4Only ? "true" : "false"
        ]
        
        guard let hproseClient = appUser.hproseClient else {
            print("DEBUG: [getHostIP] No hprose client available")
            return nil
        }
        
        let rawResponse = hproseClient.invoke("runMApp", withArgs: [entry, params])
        guard let response = rawResponse else {
            print("DEBUG: [getHostIP] No response from server.")
            return nil
        }
        
        // Unwrap v2 response
        let unwrappedResponse: Any?
        do {
            unwrappedResponse = try Self.unwrapV2Response(response)
        } catch {
            let nsError = error as NSError
            print("DEBUG: [getHostIP] Error unwrapping v2 response: domain: \(nsError.domain), code: \(nsError.code)")
            return nil
        }
        
        if let ipList = unwrappedResponse as? [String] {
            // Filter and trim IP addresses
            let ipAddresses = ipList
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            print("DEBUG: [getHostIP] Retrieved \(ipAddresses.count) IP address(es) from get_node_ips API")
            
            // Test IPs in batches of 4 for faster discovery during high load
            let batchSize = 4
            for batchStart in stride(from: 0, to: ipAddresses.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ipAddresses.count)
                let batch = Array(ipAddresses[batchStart..<batchEnd])
                
                print("DEBUG: [getHostIP] Testing batch: IPs \(batchStart + 1)-\(batchEnd) of \(ipAddresses.count)")
                
                // Test this batch in parallel - return as soon as first IP responds successfully
                let healthyIP: String? = await withTaskGroup(of: (String, Bool)?.self) { group in
                    for (index, ip) in batch.enumerated() {
                        let absoluteIndex = batchStart + index + 1
                        group.addTask {
                            // Check for cancellation before starting
                            if Task.isCancelled {
                                return nil
                            }
                            
                            print("DEBUG: [getHostIP] Testing IP \(absoluteIndex)/\(ipAddresses.count): \(ip)")
                            
                            let client = self.clientPool.getClientByIP(for: ip)
                            let isHealthy = await self.isServerHealthyWithTimeout(client, timeout: 10.0)
                            self.clientPool.releaseClient(client, for: ip)
                            
                            // Check for cancellation after health check
                            if Task.isCancelled {
                                return nil
                            }
                            
                            if isHealthy {
                                print("DEBUG: [getHostIP] ✅ IP test PASSED: \(ip)")
                            } else {
                                print("DEBUG: [getHostIP] ❌ IP test FAILED: \(ip)")
                            }
                            
                            return (ip, isHealthy)
                        }
                    }
                    
                    // Return IMMEDIATELY when first healthy IP is found
                    for await result in group {
                        if let (ip, isHealthy) = result, isHealthy {
                            print("DEBUG: [getHostIP] Found healthy node IP: \(ip) - returning immediately")
                            group.cancelAll()  // Cancel remaining checks in this batch
                            return ip as String?
                        }
                    }
                    return nil as String?
                }
                
                // If we found a healthy IP in this batch, return it
                if let ip = healthyIP {
                    return ip
                }
            }
            
            // If no healthy IP found in any batch, return nil
            // The caller should handle the nil case appropriately
            if !ipAddresses.isEmpty {
                print("DEBUG: [getHostIP] All health checks failed for \(ipAddresses.count) IP(s), returning nil")
                return nil
            }
            
            print("DEBUG: [getHostIP] No IPs available in response")
            return nil
        }
        print("DEBUG: [getHostIP] Invalid IpList response format")
        return nil
    }
    
    // MARK: - Chat Functions
    
    /// Helper result struct for message sending operations
    private struct MessageSendResult {
        let success: Bool
        let errorMessage: ChatMessage?
    }
    
    /// Helper function to send message_outgoing to sender's own node with retry and baseUrl refresh
    private func sendToSenderNodeWithRetry(
        receiptId: String,
        message: ChatMessage,
        maxRetries: Int = 2
    ) async throws -> MessageSendResult {
        var lastError: String?
        
        for attempt in 0...maxRetries {
            // On retry, force refresh appUser's baseUrl by passing empty string
            let forceRefresh = attempt > 0
            if forceRefresh {
                print("[sendMessage] 🔄 Retry attempt \(attempt): Refreshing sender's baseUrl")
            }
            
            // Refresh appUser's baseUrl if needed
            if forceRefresh {
                if let refreshedUser = try await fetchUser(appUser.mid, baseUrl: "") {
                    await MainActor.run {
                        if refreshedUser.baseUrl != appUser.baseUrl {
                            appUser.baseUrl = refreshedUser.baseUrl
                            print("[sendMessage] ✅ Updated sender's baseUrl to: \(refreshedUser.baseUrl?.absoluteString ?? "nil")")
                        }
                    }
                }
            }
            
            let entry = "message_outgoing"
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "userid": appUser.mid,
                "receiptid": receiptId,
                "msg": message.toJSONString()
            ]
            
            guard let senderClient = appUser.hproseClient else {
                let errorMsg = "Failed to create client for sender node"
                print("[sendMessage] ❌ \(errorMsg) - baseUrl: \(appUser.baseUrl?.absoluteString ?? "nil")")
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                    continue
                }
                return MessageSendResult(
                    success: false,
                    errorMessage: ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: message.timestamp,
                        attachments: message.attachments,
                        success: false,
                        errorMsg: errorMsg
                    )
                )
            }
            
            print("[sendMessage] 📤 Sending to sender node (attempt \(attempt + 1)/\(maxRetries + 1)) - baseUrl: \(appUser.baseUrl?.absoluteString ?? "nil")")
            
            let rawResponse = senderClient.invoke("runMApp", withArgs: [entry, params])
            let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
            let response = unwrappedResponse ?? rawResponse
            
            // Handle new response format: {success: false, error: e.message}
            if let responseDict = response as? [String: Any] {
                if let success = responseDict["success"] as? Bool, !success {
                    let errorMessage = responseDict["error"] as? String ?? "Unknown error"
                    lastError = errorMessage
                    print("[sendMessage] ❌ Failed to send to sender node (attempt \(attempt + 1)/\(maxRetries + 1)): \(errorMessage)")
                    
                    if attempt < maxRetries {
                        let delay = UInt64(attempt + 1) * 2_000_000_000 // 2, 4 seconds
                        print("[sendMessage] ⏳ Waiting \(delay / 1_000_000_000) seconds before retry...")
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    
                    return MessageSendResult(
                        success: false,
                        errorMessage: ChatMessage(
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
                    )
                } else {
                    // Success!
                    print("[sendMessage] ✅ Successfully sent to sender node (attempt \(attempt + 1))")
                    return MessageSendResult(success: true, errorMessage: nil)
                }
            } else {
                // Handle legacy boolean response
                let isSuccess = response as? Bool ?? false
                if isSuccess {
                    print("[sendMessage] ✅ Successfully sent to sender node (attempt \(attempt + 1), legacy format)")
                    return MessageSendResult(success: true, errorMessage: nil)
                } else {
                    let errorMessage = "Failed to send to sender node (legacy format)"
                    lastError = errorMessage
                    print("[sendMessage] ❌ \(errorMessage) (attempt \(attempt + 1)/\(maxRetries + 1))")
                    
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                        continue
                    }
                }
            }
        }
        
        // All retries exhausted
        let finalError = lastError ?? "Failed to send message to sender node after \(maxRetries + 1) attempts"
        print("[sendMessage] ❌ All retry attempts exhausted for sender node: \(finalError)")
        return MessageSendResult(
            success: false,
            errorMessage: ChatMessage(
                id: message.id,
                authorId: message.authorId,
                receiptId: message.receiptId,
                chatSessionId: message.chatSessionId,
                content: message.content,
                timestamp: message.timestamp,
                attachments: message.attachments,
                success: false,
                errorMsg: finalError
            )
        )
    }
    
    /// Helper function to send message to recipient's node with retry and baseUrl refresh
    private func sendToRecipientNodeWithRetry(
        receiptId: String,
        message: ChatMessage,
        maxRetries: Int = 2
    ) async throws -> MessageSendResult {
        var receiptUser: User?
        var lastError: String?
        
        for attempt in 0...maxRetries {
            // On retry, force refresh recipient's baseUrl by passing empty string
            let forceRefresh = attempt > 0
            if forceRefresh {
                print("[sendMessage] 🔄 Retry attempt \(attempt): Refreshing recipient's baseUrl for userId: \(receiptId)")
            }
            
            // Fetch recipient user (with forced refresh on retry)
            receiptUser = try await fetchUser(receiptId, baseUrl: forceRefresh ? "" : "")
            
            guard let recipient = receiptUser else {
                let errorMsg = "Recipient user not found"
                print("[sendMessage] ❌ \(errorMsg) for userId: \(receiptId)")
                return MessageSendResult(
                    success: false,
                    errorMessage: ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: message.timestamp,
                        attachments: message.attachments,
                        success: false,
                        errorMsg: errorMsg
                    )
                )
            }
            
            let receiptEntry = "message_incoming"
            let receiptParams: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "senderid": appUser.mid,
                "receiptid": receiptId,
                "msg": message.toJSONString()
            ]
            
            // Get fresh client (will be recreated if baseUrl changed)
            guard let recipientClient = recipient.hproseClient else {
                let errorMsg = "Failed to create client for recipient node"
                print("[sendMessage] ❌ \(errorMsg) - baseUrl: \(recipient.baseUrl?.absoluteString ?? "nil")")
                if attempt < maxRetries {
                    // Wait before retry
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                    continue
                }
                return MessageSendResult(
                    success: false,
                    errorMessage: ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: message.timestamp,
                        attachments: message.attachments,
                        success: false,
                        errorMsg: errorMsg
                    )
                )
            }
            
            print("[sendMessage] 📤 Sending to recipient node (attempt \(attempt + 1)/\(maxRetries + 1)) - baseUrl: \(recipient.baseUrl?.absoluteString ?? "nil")")
            
            let rawReceiptResponse = recipientClient.invoke("runMApp", withArgs: [receiptEntry, receiptParams])
            let receiptResponseUnwrapped = try? Self.unwrapV2Response(rawReceiptResponse)
            let receiptResponse = receiptResponseUnwrapped ?? rawReceiptResponse
            
            // Handle new response format for message_incoming
            if let receiptResponseDict = receiptResponse as? [String: Any] {
                if let success = receiptResponseDict["success"] as? Bool, !success {
                    let errorMessage = receiptResponseDict["error"] as? String ?? "Failed to send to recipient node"
                    lastError = errorMessage
                    print("[sendMessage] ❌ Failed to send to recipient node (attempt \(attempt + 1)/\(maxRetries + 1)): \(errorMessage)")
                    
                    if attempt < maxRetries {
                        // Wait before retry with exponential backoff
                        let delay = UInt64(attempt + 1) * 2_000_000_000 // 2, 4 seconds
                        print("[sendMessage] ⏳ Waiting \(delay / 1_000_000_000) seconds before retry...")
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    
                    return MessageSendResult(
                        success: false,
                        errorMessage: ChatMessage(
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
                    )
                } else {
                    // Success!
                    print("[sendMessage] ✅ Successfully sent to recipient node (attempt \(attempt + 1))")
                    return MessageSendResult(success: true, errorMessage: nil)
                }
            } else {
                // Legacy boolean response
                let receiptSuccess = receiptResponse as? Bool ?? false
                if receiptSuccess {
                    print("[sendMessage] ✅ Successfully sent to recipient node (attempt \(attempt + 1), legacy format)")
                    return MessageSendResult(success: true, errorMessage: nil)
                } else {
                    let errorMessage = "Failed to send to recipient node (legacy format)"
                    lastError = errorMessage
                    print("[sendMessage] ❌ \(errorMessage) (attempt \(attempt + 1)/\(maxRetries + 1))")
                    
                    if attempt < maxRetries {
                        // Wait before retry
                        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                        continue
                    }
                }
            }
        }
        
        // All retries exhausted
        let finalError = lastError ?? "Failed to send message after \(maxRetries + 1) attempts"
        print("[sendMessage] ❌ All retry attempts exhausted: \(finalError)")
        return MessageSendResult(
            success: false,
            errorMessage: ChatMessage(
                id: message.id,
                authorId: message.authorId,
                receiptId: message.receiptId,
                chatSessionId: message.chatSessionId,
                content: message.content,
                timestamp: message.timestamp,
                attachments: message.attachments,
                success: false,
                errorMsg: finalError
            )
        )
    }
    
    /// Send a chat message to a recipient
    /// This function performs two steps:
    /// 1. Send message_outgoing to sender's own node (with retry and baseUrl refresh)
    /// 2. Send message_incoming to recipient's node (with retry and baseUrl refresh)
    func sendMessage(receiptId: String, message: ChatMessage) async throws -> ChatMessage {
        // Check if app user is blacklisted by the recipient
        guard let recipient = try await fetchUser(receiptId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Recipient user not found", comment: "User lookup error")])
        }
        if recipient.isUserBlacklisted(appUser.mid) {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot send a message to this user because you are blocked", comment: "Message blocked error")])
        }
        
        // Step 1: Send to sender's own node (message_outgoing) with retry
        print("[sendMessage] 📤 Step 1: Sending message_outgoing to sender's node")
        let senderSendResult = try await sendToSenderNodeWithRetry(
            receiptId: receiptId,
            message: message,
            maxRetries: 2
        )
        
        if !senderSendResult.success {
            guard let errorMessage = senderSendResult.errorMessage else {
                return ChatMessage(
                    id: message.id,
                    authorId: message.authorId,
                    receiptId: message.receiptId,
                    chatSessionId: message.chatSessionId,
                    content: message.content,
                    timestamp: message.timestamp,
                    attachments: message.attachments,
                    success: false,
                    errorMsg: "Failed to send message to sender node"
                )
            }
            return errorMessage
        }
        
        print("[sendMessage] ✅ Step 1 completed: Successfully sent to sender's node")
        
        // Step 2: Send to recipient's node (message_incoming) with retry
        print("[sendMessage] 📤 Step 2: Sending message_incoming to recipient's node")
        let recipientSendResult = try await sendToRecipientNodeWithRetry(
            receiptId: receiptId,
            message: message,
            maxRetries: 2
        )
        
        if !recipientSendResult.success {
            guard let errorMessage = recipientSendResult.errorMessage else {
                return ChatMessage(
                    id: message.id,
                    authorId: message.authorId,
                    receiptId: message.receiptId,
                    chatSessionId: message.chatSessionId,
                    content: message.content,
                    timestamp: message.timestamp,
                    attachments: message.attachments,
                    success: false,
                    errorMsg: "Failed to send message to recipient node"
                )
            }
            return errorMessage
        }
        
        print("[sendMessage] ✅ Step 2 completed: Successfully sent to recipient's node")
        
        // Both steps succeeded
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
    }
    
    /// Fetch recent unread messages from a sender (incoming messages only)
    func fetchMessages(senderId: String) async throws -> [ChatMessage] {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let entry = "message_fetch"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUser.mid,
            "senderid": senderId
        ]
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle new response format: {success: false, error: e.message}
        if let responseDict = unwrappedResponse as? [String: Any] {
            if let success = responseDict["success"] as? Bool, !success {
                let errorMessage = responseDict["error"] as? String ?? responseDict["message"] as? String ?? "Unknown error"
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        // Handle legacy array format or successful response
        let messageArray = unwrappedResponse as? [[String: Any]] ?? []
        
        return messageArray.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    // Return message with server's timestamp preserved
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
        
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let entry = "message_check"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUser.mid
        ]
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        
        let response = unwrappedResponse as? [[String: Any]] ?? []
        
        return response.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUser.mid {
                    // Return message with server's timestamp preserved
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
    
    /// Check for app upgrades and update domain in preferences
    private func checkAndUpdateDomain() async {
        print("[checkAndUpdateDomain] Starting background upgrade check")
        
        let entry = "check_upgrade"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "entry": entry
        ]
        
        guard let client = appUser.hproseClient else {
            print("[checkAndUpdateDomain] Client not initialized")
            return
        }
        
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            print("[checkAndUpdateDomain] Invalid response format")
            return
        }
        
        // Check for domain in response or data field
        var domain: String? = response["domain"] as? String
        if domain == nil {
            if let data = response["data"] as? [String: Any] {
                domain = data["domain"] as? String
            }
        }
        
        guard let domain = domain else {
            print("[checkAndUpdateDomain] No upgrade domain received")
            return
        }
        
        if lastLoggedUpgradeDomain != domain {
            print("[checkAndUpdateDomain] Received domain: \(domain)")
            lastLoggedUpgradeDomain = domain
        }
        
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
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let entry = "block_user"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUser.mid,
            "blocked": userId
        ]
        
        client.invoke("runMApp", withArgs: [entry, params])
        print("[blockUser] Backend call completed for user: \(userId)")
    }
    
    /// Deletes the current user's account
    func deleteAccount() async throws -> [String: Any] {
        guard let client = appUser.hproseClient else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        
        let entry = "delete_account"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUser.mid
        ]
        let rawResponse = client.invoke("runMApp", withArgs: [entry, params])
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        return unwrappedResponse as? [String: Any] ?? [:]
    }
    
    /// Reports a tweet for inappropriate content and deletes it from backend
    func reportTweet(tweetId: String, category: String, comments: String) async throws {
        // First, delete the tweet from backend
        if let deletedTweetId = try await deleteTweet(tweetId) {
            print("[reportTweet] Successfully deleted tweet from backend: \(deletedTweetId)")
        } else {
            print("[reportTweet] Failed to delete tweet from backend: \(tweetId)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to report tweet", comment: "Report tweet error")])
        }
        
        // Send notification to system admin about the reported and deleted content
        // Note: Admin notification failure won't affect tweet deletion success
        await notifySystemAdmin(tweetId: tweetId, category: category, comments: comments)
    }
    
    /// Send notification to system admin about reported and deleted content
    private func notifySystemAdmin(tweetId: String, category: String, comments: String) async {
        let adminUserId = Gadget.getAlphaIds().first ?? "" // System admin user ID
        
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

// NOTE: Array.chunked extension is now in TweetUploadManager.swift

