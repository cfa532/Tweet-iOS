import Foundation
import OSLog
@preconcurrency import hprose
import PhotosUI
import AVFoundation

private let hproseLogger = Logger(subsystem: "com.zz", category: "HproseInstance")

private func hproseDebug(_ message: @autoclosure () -> String) {
#if DEBUG
    let renderedMessage = message()
    hproseLogger.debug("\(renderedMessage, privacy: .private)")
#endif
}

private func hproseInfo(_ message: @autoclosure () -> String) {
    let renderedMessage = message()
    hproseLogger.info("\(renderedMessage, privacy: .private)")
}

private func hproseWarning(_ message: @autoclosure () -> String) {
    let renderedMessage = message()
    hproseLogger.warning("\(renderedMessage, privacy: .private)")
}

private func hproseError(_ message: @autoclosure () -> String) {
    let renderedMessage = message()
    hproseLogger.error("\(renderedMessage, privacy: .private)")
}

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

// MARK: - IP Cache Entry
private struct IPCacheEntry {
    let ip: String
    let isHealthy: Bool
    let timestamp: Date
    
    var isExpired: Bool {
        // 30 seconds expiry
        return Date().timeIntervalSince(timestamp) > 30
    }
}

// MARK: - HproseInstance
// Phase B: the class is nonisolated so RPC methods run off the main actor. Members that
// touch @Published/appUser/UI state are individually marked @MainActor; the remaining
// mutable stored state is either write-once (nonisolated(unsafe)) or lock-guarded, which
// is why the class is @unchecked Sendable rather than actor-isolated.
final class HproseInstance: ObservableObject, @unchecked Sendable {
    // MARK: - Properties
    static let shared = HproseInstance()
    nonisolated(unsafe) static var baseUrl: URL = URL(string: AppConfig.baseUrl)!
    private static let updateFollowingTweetsEntry = "update_following_tweets"
    private static let heavyCallInterval: TimeInterval = 5 * 60
    @MainActor private var _domainToShare: String = AppConfig.shareDomain
    
    /// Timeout for every route liveness probe. One value app-wide: `findEntryIP`
    /// walks candidates one at a time, so this is also the per-candidate cost of a
    /// node that is down.
    private static let routeProbeTimeout: TimeInterval = 5.0

    // IP Cache: Stores short-lived HEAD health results with 30-second expiry
    private var ipCache: [String: IPCacheEntry] = [:]
    private let ipCacheLock = NSLock()
    private var heavyCallLastAttemptAt: [String: Date] = [:]
    private let heavyCallLock = NSLock()

    private static let appManifestRefreshKey = "refresh_app_manifest"

    /// True when the node rejected the request because it does not publish the app
    /// manifest id we sent as `aid`.
    ///
    /// Matched on the message as well as the domain because `HproseErrorDomain` code 3 is
    /// the transport's generic application error — the text is the only thing that
    /// distinguishes "your app id is stale" from any other server-side failure.
    private static func isMissingAppManifest(_ response: Any?) -> Bool {
        guard let error = response as? NSError, error.domain == "HproseErrorDomain" else {
            return false
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("no manifest for app")
    }

    private func invokeRunMApp(
        using client: HproseClient,
        entry: String,
        params: [String: Any],
        priority: DispatchQoS.QoSClass = .userInitiated
    ) async -> Any? {
        let response = await HproseTransport.invokeRunMApp(
            using: client,
            entry: entry,
            params: params,
            priority: priority
        )

        // Every runMApp carries `aid`, the app's manifest id, so a stale one fails all of
        // them — feed, node/provider discovery, user refresh, writes — with the same
        // error, and nothing else in the app re-reads it. Recovering here rather than at
        // ~45 call sites is the only place that covers them all. findEntryIP() re-reads
        // the id from the app URL over plain HTTP, so this cannot recurse back into
        // runMApp. Debounced through the shared heavy-call cooldown: a stale id fails
        // every in-flight call at once and one refresh serves all of them.
        guard Self.isMissingAppManifest(response),
              shouldAttemptHeavyCall(Self.appManifestRefreshKey, interval: 30) else {
            return response
        }

        let previousAppId = appId
        _ = try? await findEntryIP()
        guard appId != previousAppId else {
            hproseError("DEBUG: [invokeRunMApp] Node rejects app id \(appId) and discovery returned the same id; \(entry) cannot proceed")
            return response
        }

        hproseWarning("DEBUG: [invokeRunMApp] App manifest id changed \(previousAppId) -> \(appId); retrying \(entry)")
        var retryParams = params
        retryParams["aid"] = appId
        return await HproseTransport.invokeRunMApp(
            using: client,
            entry: entry,
            params: retryParams,
            priority: priority
        )
    }
    
    /// The domain to use for sharing links
    @MainActor var domainToShare: String {
        get {
            if let override = appUser.domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                return override
            }
            return _domainToShare
        }
        set {
            _domainToShare = newValue
        }
    }
    
    /// The backend domain from check_upgrade (for placeholder use)
    @MainActor var backendDomainToShare: String {
        return _domainToShare
    }

    // Store the app user's MID instead of the user object itself
    // This ensures appUser always returns the singleton instance
    @MainActor @Published private var _appUserId: String = Constants.GUEST_ID
    
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
    @MainActor var appUser: User {
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
                        _ = try await fetchUser(_appUserId, baseUrl: user.baseUrl?.absoluteString ?? "")
                    } catch {
                        hproseError("ERROR: [appUser getter] Failed to refresh appUser: \(error)")
                    }
                }
            }
            return user
        }
        set {
            // Update the singleton instance with new values, then switch to it
            let instance = User.getInstance(mid: newValue.mid)
            Task { @MainActor in
                // Update the singleton instance with new values. The route is not copied:
                // it is keyed by mid in UserRoutes, which both objects already share.
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
    
    // Set once during initAppEntry() (on the main actor) and read from many nonisolated
    // RPC methods thereafter; effectively immutable after startup.
    nonisolated(unsafe) var appId: String = AppConfig.appId
    // Set once in initialize() and read from a few nonisolated call sites; PreferenceHelper
    // wraps thread-safe UserDefaults, so nonisolated(unsafe) is safe here.
    nonisolated(unsafe) var preferenceHelper: PreferenceHelper?
    
    // MARK: - Upload Management
    // TweetUploadManager is @MainActor, so this lazy var is too; accessed from @MainActor
    // schedulers and (with an await hop) from the nonisolated uploadToIPFS delegate.
    @MainActor lazy var uploadManager: TweetUploadManager = {
        return TweetUploadManager(hproseInstance: self)
    }()
    
    // MARK: - BlackList Management
    private let blackList = BlackList.shared
    private var blacklistProcessingTask: Task<Void, Never>?

    // MARK: - Client Pool Management
    let clientPool = HproseClientPool.shared
    
    private var lastInitializationAddresses: String?
    @MainActor private var lastLoggedUpgradeDomain: String?
    
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
            hproseDebug("DEBUG: [updateUserFromServer] Updated baseUrl (\(reason)) to \(newValue) for userId: \(user.mid)")
            NotificationCenter.default.post(name: .userDidUpdate, object: nil, userInfo: ["userId": user.mid])
        }
    }

    /// Point a user's reads at the node that just took a write for them.
    ///
    /// Writes land on hostIds[0] (the root host) while reads are served by the access
    /// node hostIds[1], which copies from the root host on its own schedule. A read in
    /// that window returns the pre-write state, and the user cannot tell whether their
    /// like, comment or tweet went through. Writes are rare, so moving the read route
    /// costs little. This is a route hint and nothing more: any later resolution
    /// (NodePool, health repair, an access-node change) may replace it right away.
    func adoptWriteRouteForReads(_ user: User, reason: String) async {
        let (existingWritableUrl, writeHostId) = await MainActor.run {
            (user.writableUrl, user.hostIds?.first)
        }
        guard let writeHostId, !writeHostId.isEmpty else { return }

        // Mutations resolve this immediately before sending. Resolving here covers the
        // writes that reach the root host by other means (add_tweet routes by hostid).
        var resolvedUrl = existingWritableUrl
        if resolvedUrl == nil {
            resolvedUrl = try? await user.resolveWritableUrl()
        }
        guard let writableUrl = resolvedUrl else { return }

        NodePool.shared.updateNodeIP(
            nodeMid: writeHostId,
            newIP: normalizeHostPort(writableUrl.absoluteString)
        )

        let userMid = await MainActor.run { user.mid }
        let previousRoute = await MainActor.run { user.baseUrl?.absoluteString ?? "nil" }
        let changed = await MainActor.run { UserRoutes.shared.readFromWriteHost(for: userMid) }
        guard changed else { return }

        // Printed, not logged at debug level: every other route change is invisible in a
        // device console, which is what made two of these reports impossible to settle.
        print("DEBUG: [writeRoute] \(reason): user \(userMid) \(previousRoute) -> \(writableUrl.absoluteString)")
        await MainActor.run {
            user.resetClients()
            NotificationCenter.default.post(name: .userDidUpdate, object: nil, userInfo: ["userId": userMid])
        }
    }

    private func shouldAttemptHeavyCall(
        _ key: String,
        interval: TimeInterval = HproseInstance.heavyCallInterval,
        ignoreDebounce: Bool = false
    ) -> Bool {
        heavyCallLock.lock()
        defer { heavyCallLock.unlock() }

        let now = Date()
        if ignoreDebounce {
            heavyCallLastAttemptAt[key] = now
            return true
        }
        if let lastAttempt = heavyCallLastAttemptAt[key],
           now.timeIntervalSince(lastAttempt) < interval {
            let remaining = Int(interval - now.timeIntervalSince(lastAttempt))
            hproseWarning("DEBUG: [\(key)] Skipping heavy call, cooldown remaining \(remaining)s")
            return false
        }

        heavyCallLastAttemptAt[key] = now
        return true
    }
    
    /// If the transport layer returned a JSON object as a string, parse it so v2 unwrapping works.
    /// Render a boolean for an RPC parameter.
    ///
    /// The Leither transport carries strings only, so a boolean sent from a client
    /// reaches the backend already stringified — which is why handlers compare against
    /// "true", and why get_tweet's `fromdetailview` accepts nothing else. Send the
    /// string the backend actually receives rather than leaning on that coercion, so
    /// the wire format is visible at the call site. Matches TweetWeb and Android.
    nonisolated static func rpcBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    nonisolated private static func jsonObjectIfEncodedAsString(_ value: Any?) -> Any? {
        guard let s = value as? String,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return value }
        return obj
    }

    /// Recursively convert Foundation containers returned by Hprose into their Swift
    /// equivalents. Do not decode nested strings as JSON: tweet content and other text
    /// fields must retain their original types even when they contain JSON-looking text.
    nonisolated private static func normalizeHproseContainers(_ value: Any?) -> Any? {
        guard let value else { return nil }

        if let dict = value as? [String: Any] {
            var normalized: [String: Any] = [:]
            normalized.reserveCapacity(dict.count)
            for (key, child) in dict {
                normalized[key] = normalizeHproseContainers(child) ?? child
            }
            return normalized
        }

        if let dict = value as? NSDictionary {
            var normalized: [String: Any] = [:]
            normalized.reserveCapacity(dict.count)
            for (key, child) in dict {
                guard let stringKey = key as? String else { continue }
                normalized[stringKey] = normalizeHproseContainers(child) ?? child
            }
            return normalized
        }

        if let array = value as? [Any] {
            return array.map { normalizeHproseContainers($0) ?? $0 }
        }

        if let array = value as? NSArray {
            return array.map { normalizeHproseContainers($0) ?? $0 }
        }

        return value
    }

    /// `NSDictionary` / JSON sometimes fail to cast directly to `[String: Any]`; normalize for parsing.
    nonisolated private static func asStringKeyedDictionary(_ value: Any?) -> [String: Any]? {
        normalizeHproseContainers(jsonObjectIfEncodedAsString(value)) as? [String: Any]
    }

    nonisolated private static func stringValues(in value: Any?) -> [String] {
        let normalized = jsonObjectIfEncodedAsString(value)
        if let string = normalized as? String {
            return [string]
        }
        if let string = normalized as? NSString {
            return [string as String]
        }
        if let dict = asStringKeyedDictionary(normalized) {
            return dict.values.flatMap { stringValues(in: $0) }
        }
        if let array = normalized as? [Any] {
            return array.flatMap { stringValues(in: $0) }
        }
        return []
    }

    nonisolated private static func isTweetNotFoundMessage(_ message: String) -> Bool {
        let normalized = message
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return normalized.contains("tweet not found")
            || normalized.contains("cannot find the tweet")
            || normalized.contains("cannot find tweet")
            || normalized.contains("tweet does not exist")
            || (normalized.contains("tweet") && normalized.contains("not found"))
    }

    nonisolated private static func isTweetNotFoundDeleteFailure(_ error: Error, response: Any?) -> Bool {
        if isTweetNotFoundMessage(error.localizedDescription) {
            return true
        }
        return stringValues(in: response).contains(where: isTweetNotFoundMessage)
    }
    
    /// Pull a string field from a server dict (NSString bridging, optional `commentId` vs `mid`).
    nonisolated private static func stringField(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String, !s.isEmpty { return s }
            if let s = dict[key] as? NSString, s.length > 0 { return s as String }
        }
        return nil
    }
    
    /// Parse integer-valued fields from Hprose / JSON. Relationship timestamps
    /// may arrive as integers, floating-point numbers, or numeric strings.
    nonisolated private static func intField(_ dict: [String: Any], key: String) -> Int? {
        if let v = dict[key] as? Int { return v }
        if let v = dict[key] as? Int64 { return Int(v) }
        if let v = dict[key] as? NSNumber { return v.intValue }
        if let v = dict[key] as? Double { return Int(v) }
        if let v = dict[key] as? String { return Int(v) }
        if let v = dict[key] as? NSString { return Int(v as String) }
        return nil
    }
    
    /// Unwrap v2 API response format
    /// v2 format: {success: true, data: result} or {success: false, message: "...", error: ...}
    /// Also handles Int success values: {success: 1, data: result} or {success: 0, message: "..."}
    /// Returns the unwrapped data if success, throws error if failure
    nonisolated private static func unwrapV2Response(_ response: Any?) throws -> Any? {
        let normalizedRoot = normalizeHproseContainers(jsonObjectIfEncodedAsString(response))

        // The transport hands back a server-side failure as an NSError *value* rather than
        // throwing it. Returning that as data meant every caller then reported its own
        // generic "invalid response format", which is what hid the real message —
        // "no manifest for app <appId> ver last" — behind a parse error at ~8 call sites.
        if let error = normalizedRoot as? NSError {
            throw error
        }

        guard let dict = normalizedRoot as? [String: Any] else {
            return normalizedRoot
        }
        
        // Check if this is a v2 response - handle both Bool and Int success values
        var successValue: Bool? = nil
        
        if let successBool = dict["success"] as? Bool {
            successValue = successBool
        } else if let successInt = dict["success"] as? Int {
            successValue = (successInt != 0)
        } else if let successNum = dict["success"] as? NSNumber {
            successValue = successNum.boolValue
        }
        
        if let success = successValue {
            if success {
                // Success case - return data field if present, otherwise return the whole dict
                if let data = dict["data"] {
                    return normalizeHproseContainers(jsonObjectIfEncodedAsString(data))
                }
                // If no data field, the result might be directly in the dict (e.g., {success: true, mid: "...", count: ...})
                return dict
            } else {
                // Error case
                let message = dict["message"] as? String ?? NSLocalizedString("Unknown error from server", comment: "Server error")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        
        // Not a v2 response — return normalized payload (handles JSON-as-string and NSDictionary).
        return dict
    }
    
    /// Print detailed app user content for debugging
    @MainActor private func printAppUserContent(_ context: String) {
        hproseDebug("=== APP USER CONTENT [\(context)] ===")
        hproseDebug("MID: \(appUser.mid)")
        hproseDebug("Username: \(appUser.username ?? "nil")")
        hproseDebug("Name: \(appUser.name ?? "nil")")
        hproseDebug("Profile: \(appUser.profile ?? "nil")")
        hproseDebug("Avatar: \(appUser.avatar ?? "nil")")
        hproseDebug("Base URL: \(appUser.baseUrl?.absoluteString ?? "nil")")
        hproseDebug("Writable URL: \(appUser.writableUrl?.absoluteString ?? "nil")")
        hproseDebug("Cloud Drive Port: \(appUser.cloudDrivePort)")
        hproseDebug("Host IDs: \(appUser.hostIds ?? [])")
        hproseDebug("Tweet Count: \(appUser.tweetCount?.description ?? "nil")")
        hproseDebug("Following Count: \(appUser.followingCount?.description ?? "nil")")
        hproseDebug("Followers Count: \(appUser.followersCount?.description ?? "nil")")
        hproseDebug("Bookmarks Count: \(appUser.bookmarksCount?.description ?? "nil")")
        hproseDebug("Favorites Count: \(appUser.favoritesCount?.description ?? "nil")")
        hproseDebug("Comments Count: \(appUser.commentsCount?.description ?? "nil")")
        hproseDebug("Following List: \(appUser.followingList ?? [])")
        hproseDebug("Fans List: \(appUser.fansList ?? [])")
        hproseDebug("User Black List: \(appUser.userBlackList ?? [])")
        hproseDebug("Bookmarked Tweets: \(appUser.bookmarkedTweets ?? [])")
        hproseDebug("Favorite Tweets: \(appUser.favoriteTweets ?? [])")
        hproseDebug("Replied Tweets: \(appUser.repliedTweets ?? [])")
        hproseDebug("Comments List: \(appUser.commentsList ?? [])")
        hproseDebug("Top Tweets: \(appUser.topTweets ?? [])")
        hproseDebug("Has Accepted Terms: \(appUser.hasAcceptedTerms)")
        hproseDebug("Is Guest: \(appUser.isGuest)")
        hproseDebug("Timestamp: \(appUser.timestamp)")
        hproseDebug("Last Login: \(appUser.lastLogin?.description ?? "nil")")
        hproseDebug("=====================================")
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
    @MainActor func initialize() async throws {
        
        // Step 1: Initialize preference helper first
        self.preferenceHelper = PreferenceHelper()
        
        // Step 2: Initialize app user (now handled by TweetApp.AppState.initialize())
        // await initializeAppUser()
        
        // Step 3: Try to initialize app entry and update user if successful (baseUrl will be set once here)
        do {
            try await initAppEntry()
        } catch {
            hproseError("Error initializing app entry: \(error)")
            // Don't throw here, allow the app to continue with default settings
        }
        
        // Step 5: Clean up expired tweets
        TweetCacheManager.shared.deleteExpiredTweets()
        
        isAppInitializing = false
    }
    
    /// Initialize app user with cached or default values
    @MainActor func initializeAppUser() async {
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
        
        
        await MainActor.run {
            // CRITICAL: Update the singleton instance instead of replacing appUser
            // This ensures all references to this user get the cached data
            // Safe to call even after cache clear because fetchUser never returns nil
            User.updateUserInstance(with: cachedUser)
            _appUserId = userId
            
            // Set following list on the singleton instance
            let appUserInstance = User.getInstance(mid: userId)
            appUserInstance.followingList = Gadget.getAlphaIds()
            
            hproseDebug("DEBUG: [HproseInstance] Initialized app user: \(userId), baseUrl: \(String(describing: appUser.baseUrl))")
            
            // Pre-populate NodePool with appUser's access node so it's available immediately
            NodePool.shared.updateFromUser(appUser)
            LocalHTTPServer.shared.updateInitializationSnapshot(
                isAppInitialized: isInitializationComplete,
                appUserBaseURL: appUser.baseUrl
            )

            // Mark initialization as complete so error messages can be shown
            // This is safe to do here since the user can now interact with the app
            isAppInitializing = false
            hproseDebug("DEBUG: [HproseInstance] App initialization flag cleared - errors will now be shown to user")
        }
    }
    
    /// Manually mark initialization as complete (for cases where initialize() is not called)
    @MainActor func markInitializationComplete() {
        let wasAlreadyComplete = isInitializationComplete
        isAppInitializing = false
        isInitializationComplete = true
        LocalHTTPServer.shared.updateInitializationSnapshot(
            isAppInitialized: true,
            appUserBaseURL: appUser.baseUrl
        )
        
        // Keep startup hooks consistent with initAppEntry() paths.
        // Post only on the transition to "complete" to avoid duplicate work.
        if !wasAlreadyComplete {
            hproseDebug("DEBUG: [HproseInstance] Posting .appUserReady from markInitializationComplete()")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appUserReady, object: nil)
            }
        } else {
        }
        
        hproseDebug("DEBUG: [HproseInstance] Manually marked initialization as complete")
    }
    
    /// Schedule background tasks
    private func scheduleBackgroundTasks() {
        // Schedule domain update and pending upload recovery
        Task.detached(priority: .background) {
            
            // Wait for app initialization to complete by polling the flag (max 30s timeout)
            var waitCount = 0
            while waitCount < 300 {
                let isComplete = await MainActor.run { self.isInitializationComplete }
                if isComplete {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // Check every 100ms
                waitCount += 1
            }
            
            
            // Check for domain updates
            await self.checkAndUpdateDomain()
            self.blackList.processCandidates()
            
            // NOTE: Pending upload recovery is now handled by ContentView's dialog system
            // This gives users control over retry/discard instead of automatic retry
            // await self.recoverPendingUploads()  // Disabled - now using dialog-based recovery
        }
    }
    
    /// Fetch alphaId user from backend for guest users
    @MainActor private func fetchAlphaIdUserForGuest() async {
        guard appUser.isGuest else { return }
        
        do {
            // Fetch user data from server
            guard let alphaUserId = Gadget.getAlphaIds().first else {
                hproseDebug("fetchAlphaIdUserForGuest: alphaUser.mid is null")
                return
            }
            guard let alphaUser = try await fetchUser(alphaUserId, baseUrl: "", forceRefresh: true) else {
                hproseDebug("fetchAlphaIdUserForGuest: alphaUser is null")
                return
            }
            
            await MainActor.run {
                User.updateUserInstance(with: alphaUser, true)
                // Notify FollowingsTweetView to refresh
                NotificationCenter.default.post(name: .appUserReady, object: nil)
            }
        } catch {
            hproseWarning("DEBUG: [HproseInstance] Failed to fetch alphaId user for guest: \(error)")
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
                    hproseDebug("DEBUG: [HproseInstance] Updated appId from server: \(appId)")
                } else {
                    hproseDebug("DEBUG: [HproseInstance] Server did not provide appId, keeping AppConfig value: \(appId)")
                }
                guard let addrs = paramData["addrs"] as? String else { continue }
                if lastInitializationAddresses != addrs {
                    hproseDebug("DEBUG: [HproseInstance] App addresses resolved: \(addrs)")
                    lastInitializationAddresses = addrs
                }
                
                let candidates = entryIPCandidates(from: addrs)
                for entryIP in candidates {
                    let normalizedEntryIP = normalizeHostPort(entryIP)
                    hproseDebug("DEBUG: [findEntryIP] Testing entry IP: \(normalizedEntryIP)")
                    if await isRouteAlive(normalizedEntryIP, forceFresh: true) {
                        HproseInstance.baseUrl = URL(string: "http://\(normalizedEntryIP)")!
                        return normalizedEntryIP
                    }
                    hproseWarning("DEBUG: [findEntryIP] Entry IP failed health check: \(normalizedEntryIP)")
                }
            } catch {
                hproseError("Error processing URL \(url): \(error)")
                continue
            }
        }
        return nil
    }

    /// Entry candidates ordered so that consecutive ones belong to different nodes.
    ///
    /// `addrs` groups its addresses BY NODE — one node appears several times in
    /// its own group because it is reachable on several interfaces — and ranks
    /// each node's addresses by how fast that interface answers for it. Sorting
    /// every address into one flat list by that rank throws the grouping away,
    /// and two addresses of the same machine can then sit next to each other.
    /// `findEntryIP` probes candidates one at a time with a 5s timeout, so a
    /// node that is down costs that timeout once per interface it published
    /// before a different node is tried at all.
    ///
    /// Take one address per node per round instead — every node's fastest, then
    /// every node's second fastest — so the candidate after a failure is always
    /// a different machine. TweetWeb applies the same ordering to the same data
    /// in `src/utils/entryRoutes.ts`.
    private func entryIPCandidates(from nodeList: Any) -> [String] {
        guard let raw = nodeList as? String else { return [] }

        let nodes = nodeGroups(in: raw)
            .map { addressPairs(in: $0).sorted { $0.responseTime < $1.responseTime } }
            .filter { !$0.isEmpty }

        if nodes.isEmpty, let legacyCandidate = Gadget.shared.filterIpAddresses(nodeList) {
            return [normalizeHostPort(legacyCandidate)]
        }

        var ordered: [String] = []
        var seen = Set<String>()
        let deepest = nodes.map(\.count).max() ?? 0
        for rank in 0..<deepest {
            // One address from every node that still has one, quickest first.
            // Rank decides who is in the round — that is what keeps consecutive
            // candidates on different machines — and the published metric
            // decides the order within it.
            let round = nodes
                .compactMap { rank < $0.count ? $0[rank] : nil }
                .sorted { $0.responseTime < $1.responseTime }

            for candidate in round {
                // One address can be published by two nodes behind a single
                // NAT. It is one way in either way, and belongs at its first
                // position.
                if seen.insert(candidate.ip).inserted {
                    ordered.append(candidate.ip)
                }
            }
        }
        return ordered
    }

    /// Split the raw `addrs` text into one substring per node.
    ///
    /// Quoted spans are skipped rather than counted: an IPv6 address is written
    /// `"[2001:db8::1]:8080"`, and its brackets would otherwise read as nesting
    /// and split a node's group in the middle.
    private func nodeGroups(in raw: String) -> [Substring] {
        var groups: [Substring] = []
        var depth = 0
        var groupStart: String.Index?
        var inQuotes = false

        for index in raw.indices {
            let character = raw[index]
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            guard !inQuotes else { continue }

            if character == "[" {
                depth += 1
                // Depth 1 is the list of nodes; depth 2 is one node's addresses.
                if depth == 2 { groupStart = index }
            } else if character == "]" {
                if depth == 2, let start = groupStart {
                    groups.append(raw[start...index])
                    groupStart = nil
                }
                depth -= 1
            }
        }
        return groups
    }

    /// The usable `"host:port", metric` pairs inside one node's group.
    ///
    /// The metric is read as a decimal: nodes publish it either as an integer
    /// or in the fractional form the Android client documents, and an
    /// integer-only pattern would truncate the latter to its leading digits and
    /// rank the addresses by a number that is mostly gone.
    private func addressPairs(in group: Substring) -> [(ip: String, responseTime: Double)] {
        let pattern = #""([^"]+)"\s*,\s*(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let text = String(group)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var pairs: [(ip: String, responseTime: Double)] = []

        for match in regex.matches(in: text, options: [], range: range) {
            guard let ipRange = Range(match.range(at: 1), in: text),
                  let timeRange = Range(match.range(at: 2), in: text),
                  let responseTime = Double(text[timeRange]) else {
                continue
            }

            let ip = normalizeHostPort(String(text[ipRange]))
            guard let port = portNumber(from: ip),
                  (8000...9000).contains(port),
                  Gadget.isValidPublicIpAddress(ip) else {
                continue
            }

            pairs.append((ip: ip, responseTime: responseTime))
        }
        return pairs
    }

    private func portNumber(from hostPort: String) -> Int? {
        let normalized = normalizeHostPort(hostPort)
        if normalized.hasPrefix("["),
           let bracketEnd = normalized.firstIndex(of: "]") {
            let suffix = normalized[normalized.index(after: bracketEnd)...]
            guard suffix.hasPrefix(":") else { return nil }
            return Int(suffix.dropFirst())
        }

        guard let portPart = normalized.split(separator: ":").last else {
            return nil
        }
        return Int(portPart)
    }

    private func normalizeHostPort(_ hostPort: String) -> String {
        return Gadget.normalizeHostPort(hostPort)
    }
    
    ///    - Fetches alphaId user data in background
    ///
    /// - Throws: Network or parsing errors (caught by caller)
    /// - Note: Called during app initialization by `initialize()` method
    /// - Note: Sets `isInitializationComplete = true` once baseUrl is resolved
    @MainActor func initAppEntry() async throws {
        var entryIP: String? = nil
        var fetchedUser: User? = nil  // Store fetched user from cached baseUrl verification

        // Try using cached baseUrl first — only for logged-in users.
        // Guest users always resolve a fresh IP so the port is guaranteed correct.
        if !appUser.isGuest,
           let cachedBaseUrl = appUser.baseUrl,
           let cachedHost = cachedBaseUrl.host {
            hproseDebug("🔄 [INIT] Attempting to use cached baseUrl: \(cachedBaseUrl.absoluteString)")

            // Set HproseInstance.baseUrl to cached value temporarily
            HproseInstance.baseUrl = cachedBaseUrl
            entryIP = cachedBaseUrl.port.map { "\(cachedHost):\($0)" } ?? cachedHost

            do {
                // Try fetching user data with cached baseUrl (don't force re-resolution)
                let user = try await fetchUser(appUser.mid, baseUrl: cachedBaseUrl.absoluteString)
                if let user = user {
                    hproseInfo("✅ [INIT] Cached baseUrl is valid - skipping findEntryIP()")
                    fetchedUser = user  // Save for later use

                    // The cached route answers, so the entry node isn't needed for
                    // connectivity — but findEntryIP() is also the ONLY place `appId` (the
                    // app's manifest id, sent as `aid` on every runMApp) is re-read from
                    // the server. Skipping it entirely meant a logged-in client with a
                    // working cached baseUrl kept sending the id it was compiled with, and
                    // once the server stopped publishing that id every single RPC came
                    // back "no manifest for app <id>" — permanently, across relaunches,
                    // because the cached baseUrl kept on looking valid. Refresh it in the
                    // background so this path keeps its startup speed.
                    Task.detached(priority: .utility) { [weak self] in
                        _ = try? await self?.findEntryIP()
                    }
                } else {
                    hproseWarning("⚠️ [INIT] Cached baseUrl returned nil user - falling back to findEntryIP()")
                    entryIP = nil
                }
            } catch {
                hproseWarning("⚠️ [INIT] Cached baseUrl failed with error: \(error) - falling back to findEntryIP()")
                entryIP = nil
            }
        }

        // Fallback to findEntryIP if cached baseUrl not available or failed
        if entryIP == nil {
            guard let freshIP = try await findEntryIP() else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
            }
            entryIP = freshIP
        }

        // Ensure we have a valid entryIP at this point
        guard let finalEntryIP = entryIP else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
        }

        if !appUser.isGuest {
            // Use already-fetched user if we verified cached baseUrl successfully
            // Otherwise, fetch user data with the resolved IP
            var user: User? = fetchedUser

            if user == nil {
                // Need to fetch user data since we didn't use cached baseUrl or it failed
                // Pass empty string to force IP re-resolution
                user = try await fetchUser(appUser.mid, baseUrl: "")
            } else {
            }

            if let user = user {
                // App is now initialized with base connectivity
                await MainActor.run {
                    isInitializationComplete = true
                    User.updateUserInstance(with: user, true)
                    _appUserId = user.mid
                    LocalHTTPServer.shared.updateInitializationSnapshot(
                        isAppInitialized: true,
                        appUserBaseURL: appUser.baseUrl
                    )

                    // Notify UI that app is ready (tweets can now render with real IP)
                    NotificationCenter.default.post(name: .appUserReady, object: nil)
                }

                // Ensure the refreshed user with updated baseURL is saved to cache
                TweetCacheManager.shared.saveUser(user)
                if fetchedUser != nil {
                } else {
                }

                // Fetch followings and blacklist in background (non-blocking)
                Task.detached(priority: .background) {
                    let followings = (try? await self.getListByType(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                    let blackList = (try? await self.getListByType(user: user, entry: .BLACK_LIST)) ?? []
                    await MainActor.run {
                        user.followingList = followings
                        user.userBlackList = blackList
                        self.printAppUserContent("After background data loaded")
                    }
                }
            } else {
                // Fetch failed but user is logged in - use cached appUser data
                // DO NOT log out user just because their IPs are temporarily unreachable
                hproseWarning("⚠️ [INIT] fetchUser failed but user is logged in - using cached appUser data")
                hproseWarning("⚠️ [INIT] User \(appUser.mid) will use cached data until network recovers")

                await MainActor.run {
                    // appUser is already loaded from cache in initializeAppUser()
                    // Just set entry IP as fallback and mark initialization as complete
                    if appUser.baseUrl == nil {
                        appUser.baseUrl = URL(string: "http://\(finalEntryIP)")
                    }

                    // Ensure followings list has at least alphaIds
                    if appUser.followingList?.isEmpty ?? true {
                        appUser.followingList = Gadget.getAlphaIds()
                    }

                    isInitializationComplete = true
                    LocalHTTPServer.shared.updateInitializationSnapshot(
                        isAppInitialized: true,
                        appUserBaseURL: appUser.baseUrl
                    )

                    // Notify UI that app is ready (will use cached data)
                    NotificationCenter.default.post(name: .appUserReady, object: nil)
                }

                hproseInfo("✅ [INIT] App initialized with cached data - network will retry in background")
            }
        } else {
            let user = User.getInstance(mid: Constants.GUEST_ID)
            await MainActor.run {
                user.baseUrl = URL(string: "http://\(finalEntryIP)")
                user.followingList = Gadget.getAlphaIds()
                _appUserId = user.mid

                // App is now initialized since appUser has IP address
                isInitializationComplete = true
                LocalHTTPServer.shared.updateInitializationSnapshot(
                    isAppInitialized: true,
                    appUserBaseURL: appUser.baseUrl
                )
            }
            hproseDebug("DEBUG: [initAppEntry] Updated appUser singleton baseUrl to IP: \(finalEntryIP)")

            // For guest users, fetch the alphaId user from backend now that we have proper IP
            await fetchAlphaIdUserForGuest()
        }
        // Step 6: Schedule background tasks
        scheduleBackgroundTasks()
    }
    
    @MainActor
    func fetchComments(
        _ parentTweet: Tweet,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        let result = try await fetchComments(
            forTweetId: parentTweet.mid,
            authorId: parentTweet.authorId,
            pageNumber: pageNumber,
            pageSize: pageSize
        )
        if parentTweet.author == nil {
            let author = await TweetCacheManager.shared.fetchUser(mid: parentTweet.authorId)
            if author.username != nil {
                parentTweet.author = author
            }
        }
        return result
    }

    func fetchComments(
        forTweetId tweetId: MimeiId,
        authorId: MimeiId,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        let entry = "get_comments"
        // Phase A (demotion prep): snapshot @MainActor appUser.mid.
        let appUserMid = await MainActor.run { self.appUser.mid }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "appuserid": appUserMid,
            "pn": pageNumber,
            "ps": pageSize,
        ] as [String : Any]

        // CRITICAL: Use the parent tweet's author's baseUrl to fetch comments
        // Comments are stored on the tweet author's node, not the appUser's node
        // Fetch author if not already loaded
        let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: authorId)
        // Phase A (demotion prep): snapshot @MainActor User reads together.
        let cachedAuthorValid = await MainActor.run { cachedAuthor.username != nil && cachedAuthor.baseUrl != nil }
        let author: User
        if cachedAuthorValid {
            author = cachedAuthor
        } else if let fetchedAuthor = try? await fetchUser(authorId) {
            author = fetchedAuthor
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch author for comments", comment: "Author fetch error")])
        }

        // Use author's client - comments are on author's node
        let authorSnap = await MainActor.run { UserRecord(user: author) }
        guard let authorBaseUrl = authorSnap.baseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author's client not initialized. baseUrl: nil", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: authorBaseUrl.absoluteString, timeout: 15)

        hproseDebug("DEBUG: [fetchComments] Using author's baseUrl (\(authorBaseUrl.absoluteString)) for tweet \(tweetId)")

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when tweet has no comments
        let response: [[String: Any]?]
        if let arrayResponse = unwrappedResponse as? [[String: Any]?] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            hproseDebug("DEBUG: [HproseInstance] fetchComments - Server returned empty array (no comments)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
        }
        
        // Process each item in the response array, preserving nil positions.
        // A malformed/unparseable entry means the comment either hasn't synced
        // from the author's write node to the read node yet, or is genuinely
        // gone — either way, the server (`get_comments`) now handles cleaning
        // up IDs it can confirm are stale, so the client no longer needs to
        // sync or retry individual comment IDs itself.
        var commentsWithAuthors: [Tweet?] = []
        for item in response {
            if let dict = item {
                do {
                    let comment = try await mergeTweetFromDict(dict)

                    // Check if there's cached author data (expired or not)
                    let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: comment.authorId)

                    // If we have cached data with username and baseUrl, use it regardless of expiration
                    let commentCachedAuthorValid = await MainActor.run { cachedAuthor.username != nil && cachedAuthor.baseUrl != nil }
                    if commentCachedAuthorValid {
                        await MainActor.run {
                            comment.author = cachedAuthor
                        }
                        hproseWarning("DEBUG: [fetchComments] Using cached author for \(comment.authorId), skipping network fetch")
                    } else {
                        // Only fetch from network if there's no cached data
                        if let author = try? await fetchUser(comment.authorId) {
                            await MainActor.run {
                                comment.author = author
                            }
                        } else {
                            // Server fetch failed - use skeleton to indicate error
                            await MainActor.run {
                                comment.author = User.getInstance(mid: comment.authorId)
                                hproseWarning("⚠️ [fetchComments] Server fetch failed, using skeleton for \(comment.authorId) to indicate error")
                            }
                        }
                    }
                    commentsWithAuthors.append(comment)
                } catch {
                    hproseError("Error processing comment: \(error)")
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
        entry: String = "get_tweet_feed",
        ignoreFollowingTweetsDebounce: Bool = false,
        onFollowingTweetsRpcStarted: (@Sendable () async -> Bool)? = nil
    ) async throws -> [Tweet?] {
        let isFollowingTweetUpdate = entry == HproseInstance.updateFollowingTweetsEntry

        // Phase A (demotion prep): snapshot @MainActor appUser + user into Sendable records.
        let (appSnap, userSnap) = await MainActor.run {
            (UserRecord(user: self.appUser), UserRecord(user: user))
        }

        // If app is not initialized, only return cached tweets
        if !isInitializationComplete {
            let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: appSnap.mid)
            let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                for: cacheKey,
                page: pageNumber,
                pageSize: pageSize,
                currentUserId: appSnap.mid
            )
            if !cachedTweets.isEmpty {
                return cachedTweets
            }
            // Legacy fallback for cache rows written before the main feed had its own cache key.
            let legacyCachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                for: userSnap.mid,
                page: pageNumber,
                pageSize: pageSize,
                currentUserId: appSnap.mid
            )
            return legacyCachedTweets
        }

        // Gate the following-tweets sync BEFORE resolving its client.
        // followingTweetsHomeClient() resolves hostIds[0] fresh on every call — the write
        // route is deliberately never pooled — so it costs a get_node_ips round trip plus
        // health checks, and it throws outright when the node can't be resolved. Running
        // it ahead of this gate meant the debounce could never prevent that work: every
        // caller paid the round trip, and while the write host was unresolvable every
        // caller also surfaced "Upload server not responding", once per attempt, with no
        // cooldown ever applying. Gating first also lets a failed attempt start the
        // cooldown, which is what stops the retry storm.
        if isFollowingTweetUpdate {
            guard appSnap.mid != Constants.GUEST_ID,
                  await onFollowingTweetsRpcStarted?() != false,
                  shouldAttemptHeavyCall(
                    HproseInstance.updateFollowingTweetsEntry,
                    ignoreDebounce: ignoreFollowingTweetsDebounce
                  ) else {
                return []
            }
        }

        let client: HproseClient?
        if isFollowingTweetUpdate {
            client = try await followingTweetsHomeClient()
        } else {
            client = appSnap.baseUrl.map { clientPool.getClientByUrl(for: $0.absoluteString, timeout: 15) }
        }

        guard let client = client else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }

        var params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "pn": pageNumber,
            "ps": pageSize,
            "userid": userSnap.mid != Constants.GUEST_ID ? userSnap.mid : Gadget.getAlphaIds().first as Any,
            "appuserid": appSnap.mid,
        ]

        if isFollowingTweetUpdate {
            params["hostid"] = appSnap.hostIds?.first
        }
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            hproseWarning("DEBUG: [fetchTweetFeed] Unexpected response for entry \(entry): \(responseShapeDescription(unwrappedResponse))")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchTweetFeed"])
        }
        
        // unwrapV2Response already threw for success=false
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        
        if isFollowingTweetUpdate {
            hproseDebug("[fetchTweetFeed] Got \(tweetsData.count) tweets and \(originalTweetsData.count) original tweets from server")
            await syncFollowingTweetsToAccessHostIfNeeded(homeResponse: response, requestParams: params)
        }

        var scheduledBackgroundAuthorFetches = Set<String>()
        func scheduleBackgroundAuthorFetch(authorId: String, context: String) {
            guard scheduledBackgroundAuthorFetches.insert(authorId).inserted else { return }

            Task.detached(priority: .userInitiated) {
                do {
                    _ = try await self.fetchUser(authorId)
                    // Author singleton is already set, it will update automatically.
                } catch {
                    hproseWarning("⚠️ [fetchTweetFeed] Background fetch failed for \(context) \(authorId): \(error)")
                }
            }
        }
        
        // Cache original tweets first - cache under their authorId, not appUser.mid
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await mergeTweetFromDict(dict, attachAuthor: true)
                    
                    // Fetch author in background - will update singleton when complete
                    scheduleBackgroundAuthorFetch(authorId: originalTweet.authorId, context: "original author")
                    
                    // CRITICAL: Cache original tweet under its authorId, not appUser.mid
                    // This prevents original tweets from appearing in main feed when their author is different
                    await MainActor.run {
                        TweetCacheManager.shared.saveTweet(originalTweet, userId: originalTweet.authorId)
                        hproseDebug("[fetchTweetFeed] Cached original tweet: \(originalTweet.mid) under authorId: \(originalTweet.authorId)")
                    }
                } catch {
                    hproseError("[fetchTweetFeed] Error caching original tweet: \(error)")
                }
            }
        }
        
        // Process main tweets
        var tweets: [Tweet?] = []
        for item in tweetsData {
            if let tweetDict = item {
                do {
                    let tweet = try await mergeTweetFromDict(tweetDict, attachAuthor: true)
                    
                    // Fetch author in background - will update singleton when complete
                    scheduleBackgroundAuthorFetch(authorId: tweet.authorId, context: "author")

                    // Skip private tweets in feed; cache the rest under the main-feed list key
                    // (not the app user's profile key). @MainActor read + cache write in one hop.
                    let keep = await MainActor.run { () -> Bool in
                        if tweet.isPrivate == true { return false }
                        TweetCacheManager.shared.saveTweet(
                            tweet,
                            userId: TweetCacheManager.mainFeedCacheKey(appUserId: appSnap.mid)
                        )
                        return true
                    }
                    if !keep {
                        tweets.append(nil)
                        continue
                    }
                    tweets.append(tweet)
                } catch {
                    hproseError("[fetchTweetFeed] Error processing tweet: \(error)")
                    tweets.append(nil)
                }
            } else {
                tweets.append(nil)
            }
        }

        hproseDebug("[fetchTweetFeed] Returning \(tweets.count) tweets")
        await MainActor.run { NodePool.shared.updateFromUser(user) }
        return tweets
    }

    private func followingTweetsHomeClient() async throws -> HproseClient {
        // appUser is a @MainActor class instance (implicitly Sendable); resolve its
        // writable client on the main actor.
        let appUserInstance = await MainActor.run { self.appUser }
        let writableUrl = try await appUserInstance.resolveWritableUrl()
        guard let client = await appUserInstance.writableClient(timeout: 30) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Writable client not available for \(writableUrl.absoluteString)"
            ])
        }
        return client
    }

    private func syncFollowingTweetsToAccessHostIfNeeded(homeResponse: [String: Any], requestParams: [String: Any]) async {
        let newTweetCount = (homeResponse["tweets"] as? [Any])?.filter { !($0 is NSNull) }.count ?? 0
        guard newTweetCount > 0 else { return }

        let appHostIds = await MainActor.run { self.appUser.hostIds }
        guard let hostIds = appHostIds,
              let homeHostId = hostIds.first,
              hostIds.count > 1 else {
            return
        }

        let accessHostId = hostIds[1]
        guard accessHostId != homeHostId else { return }

        // IPv6 routes are fine for RPC; only share URLs need a v4 literal.
        guard let accessIP = await getHostIP(accessHostId, v4Only: false) else {
            hproseError("ERROR: [update_following_tweets] Unable to resolve access host \(accessHostId)")
            return
        }

        var accessParams = requestParams
        accessParams["homeupdated"] = Self.rpcBool(true)

        let accessClient = clientPool.getClientByIP(for: accessIP, timeout: 30)

        do {
            let rawResponse = await invokeRunMApp(using: accessClient, entry: HproseInstance.updateFollowingTweetsEntry, params: accessParams)
            _ = try Self.unwrapV2Response(rawResponse)
            hproseDebug("DEBUG: [update_following_tweets] Synced \(newTweetCount) tweets from home host \(homeHostId) to access host \(accessHostId)")
        } catch {
            hproseError("ERROR: [update_following_tweets] Failed to sync access host \(accessHostId): \(error)")
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
    func fetchUserTweets(
        user: User,
        pageNumber: UInt = 0,
        pageSize: UInt = 20,
        entry: String = "get_tweets_by_user"
    ) async throws -> [Tweet?] {
        // Phase A (demotion prep): snapshot @MainActor User + appUser reads used below (cache key + logs).
        let (userMid, userBaseUrlStr, appUserMid) = await MainActor.run {
            (user.mid, user.baseUrl?.absoluteString, self.appUser.mid)
        }
        // If app is not initialized, only return cached tweets
        if !isInitializationComplete {
            let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(for: userMid, page: pageNumber, pageSize: pageSize, currentUserId: appUserMid)
            return cachedTweets
        }

        do {
            return try await fetchUserTweetsFromCurrentRoute(
                user: user,
                pageNumber: pageNumber,
                pageSize: pageSize,
                entry: entry
            )
        } catch {
            guard !Task.isCancelled else { throw error }
            if hasTimeoutCause(error) {
                hproseWarning("DEBUG: [fetchUserTweets] Timeout via \(userBaseUrlStr ?? "nil"); retrying same route once for \(userMid): \(error)")
                do {
                    return try await fetchUserTweetsFromCurrentRoute(
                        user: user,
                        pageNumber: pageNumber,
                        pageSize: pageSize,
                        entry: entry
                    )
                } catch {
                    guard !Task.isCancelled, hasTimeoutCause(error) else { throw error }

                    // The address answers health probes but cannot serve this read.
                    // Move to the next advertised address of the same access node
                    // rather than hammering the one that just timed out twice.
                    hproseWarning("DEBUG: [fetchUserTweets] Timeout again via \(userBaseUrlStr ?? "nil"); looking for an alternate address of the same access node")
                    guard await switchToAlternateRoute(
                        for: user,
                        attemptedBaseUrl: userBaseUrlStr,
                        logPrefix: "fetchUserTweets"
                    ) else {
                        hproseWarning("DEBUG: [fetchUserTweets] No alternate address for \(userMid); not retrying the same address")
                        throw error
                    }
                    return try await fetchUserTweetsFromCurrentRoute(
                        user: user,
                        pageNumber: pageNumber,
                        pageSize: pageSize,
                        entry: entry
                    )
                }
            }
            hproseWarning("DEBUG: [fetchUserTweets] Failed via \(userBaseUrlStr ?? "nil"); refreshing route and retrying once for \(userMid): \(error)")
            let refreshedUser = try await freshReadUser(for: user, reason: "tweet load retry")
            return try await fetchUserTweetsFromCurrentRoute(
                user: refreshedUser,
                pageNumber: pageNumber,
                pageSize: pageSize,
                entry: entry
            )
        }
    }

    private func freshReadUser(for user: User, reason: String) async throws -> User {
        let userMid = await MainActor.run { user.mid }
        guard let refreshedUser = try await fetchUser(
            userMid,
            baseUrl: "",
            refreshExpiredCacheInBackground: false
        ) else {
            throw HproseError.userNotFound(userId: userMid, reason: "Unable to refresh provider IP for \(reason)")
        }
        return refreshedUser
    }

    private func fetchUserTweetsFromCurrentRoute(
        user: User,
        pageNumber: UInt,
        pageSize: UInt,
        entry: String
    ) async throws -> [Tweet?] {
        // Phase A (demotion prep): snapshot @MainActor User + appUser.mid.
        let snap = await MainActor.run { UserRecord(user: user) }
        let appUserMid = await MainActor.run { self.appUser.mid }
        guard let baseUrl = snap.baseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUserMid,
        ] as [String : Any]

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in fetchUserTweets"])
        }
        
        // unwrapV2Response already threw for success=false
        // Extract tweets and originalTweets from the new response format
        let tweetsData = response["tweets"] as? [[String: Any]?] ?? []
        let originalTweetsData = response["originalTweets"] as? [[String: Any]?] ?? []
        
        // Cache original tweets first - cache under their authorId, not appUser.mid
        // This applies to all users, not just appUser, to ensure consistent caching
        for originalTweetDict in originalTweetsData {
            if let dict = originalTweetDict {
                do {
                    let originalTweet = try await mergeTweetFromDict(dict)
                    let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: originalTweet.authorId)
                    // CRITICAL: Cache original tweet under its authorId, not appUser.mid
                    // This prevents original tweets from appearing in main feed when their author is different
                    await MainActor.run {
                        originalTweet.author = cachedAuthor
                        TweetCacheManager.shared.saveTweet(originalTweet, userId: originalTweet.authorId)
                    }
                } catch {
                }
            }
        }
        
        var tweets: [Tweet?] = []
        for item in tweetsData {
            if let tweetDict = item {
                do {
                    let tweet = try await mergeTweetFromDict(tweetDict, attachAuthorMid: snap.mid)

                    // Only show private tweets if the current user is the author.
                    // Cache tweet under its authorId. Both the @MainActor Tweet read and the
                    // @MainActor cache write happen in one hop.
                    let keep = await MainActor.run { () -> Bool in
                        if tweet.isPrivate == true && tweet.authorId != appUserMid {
                            return false
                        }
                        TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                        return true
                    }
                    if !keep {
                        tweets.append(nil)
                        continue
                    }
                    tweets.append(tweet)
                } catch {
                    tweets.append(nil)
                }
            } else {
                tweets.append(nil)
            }
        }

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
    ///   - fromDetailView: When true, tells the server this is a detail-view read so it can
    ///     sync/provide the tweet on its end if this node isn't already a DHT provider for it.
    ///     Also passes along the author's write hostId (if known) so the server doesn't have
    ///     to look it up itself.
    /// - Returns: The tweet object, or nil if not found
    func getTweet(
        tweetId: String,
        authorId: String,
        nodeUrl: String? = nil,
        bypassCache: Bool = false,
        fromDetailView: Bool = false
    ) async throws -> Tweet? {
        guard !TweetDeletionRegistry.shared.isDeleted(tweetId) else { return nil }

        // Check if tweet is blacklisted before attempting fetch
        if blackList.isBlacklisted(tweetId) {
            hproseDebug("DEBUG: [getTweet] tweetId \(tweetId) is blacklisted, returning cached tweet only")
            return await TweetCacheManager.shared.fetchTweet(mid: tweetId)
        }

        // Check cache first using TweetCacheManager
        let author = try await fetchUser(authorId)
        if !bypassCache, let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: tweetId) {
            // Set author if not already set (check + assign on the main actor in one hop)
            await MainActor.run {
                if cachedTweet.author == nil {
                    cachedTweet.author = author
                }
            }
            return cachedTweet
        }

        // Fetch from server using get_tweet API (like Android's fetchTweet)
        // Phase A (demotion prep): snapshot @MainActor author + appUser reads in one hop.
        let (authorBaseUrl, authorHostId, appUserMid) = await MainActor.run {
            (author?.baseUrl, author?.hostIds?.first, self.appUser.mid)
        }
        guard let authorBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author client not initialized", comment: "Author client initialization error")])
        }
        let authorClient = clientPool.getClientByUrl(for: authorBaseUrl.absoluteString, timeout: 15)

        let entry = "get_tweet"
        var params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "appuserid": appUserMid
        ]
        if fromDetailView {
            params["fromdetailview"] = Self.rpcBool(true)
            if let authorHostId {
                params["authorhostid"] = authorHostId
            }
        }

        do {
            let rawResponse = await invokeRunMApp(using: authorClient, entry: entry, params: params)
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            
            if let tweetDict = unwrappedResponse as? [String: Any] {
                guard !TweetDeletionRegistry.shared.isDeleted(tweetId) else { return nil }

                // Record successful access
                blackList.recordSuccess(tweetId)
                
                let tweet = try await mergeTweetFromDict(tweetDict, attachAuthorMid: authorId)

                // Cache tweet by authorId, not appUser.mid
                await MainActor.run { TweetCacheManager.shared.saveTweet(tweet, userId: authorId) }

                return tweet
            } else {
                // Tweet not found - record failure to blacklist candidates
                hproseError("DEBUG: [getTweet] Tweet not found for tweetId: \(tweetId), recording failure")
                blackList.recordFailure(tweetId)
                return nil
            }
        } catch {
            // Record failed access
            blackList.recordFailure(tweetId)
            hproseError("DEBUG: [getTweet] Error fetching tweet: \(tweetId), author: \(authorId)")
            hproseDebug("DEBUG: [getTweet] Exception: \(error)")
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
        guard !TweetDeletionRegistry.shared.isDeleted(tweetId) else { return nil }

        let author = try await fetchUser(authorId)
        // Refresh is tied to the tweet author. Never substitute an unrelated
        // app-user/provider node when the author's route is unavailable.
        let (authorBaseUrl, authorHostId, appUserMid) = await MainActor.run {
            (author?.baseUrl, author?.hostIds?.first, self.appUser.mid)
        }
        guard let baseUrl = authorBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let entry = "refresh_tweet"
        var params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "userid": authorId,
            "appuserid": appUserMid
        ]
        if let hostId = authorHostId {
            params["hostid"] = hostId
        }
        hproseDebug("DEBUG: [refreshTweet] Calling refresh_tweet for tweetId: \(tweetId), authorId: \(authorId), baseUrl: \(baseUrl.absoluteString)")
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        if let tweetDict = unwrappedResponse as? [String: Any] {
            do {
                guard !TweetDeletionRegistry.shared.isDeleted(tweetId) else { return nil }
                let tweet = try await mergeTweetFromDict(tweetDict)
                if let author = try? await fetchUser(authorId) {
                    await MainActor.run {
                        tweet.author = author  // Set on main thread since author is @Published
                    }
                }
                
                // Cache the tweet under its authorId, not appUser.mid
                // This ensures original tweets are cached under their author, not the current user
                await MainActor.run { TweetCacheManager.shared.saveTweet(tweet, userId: authorId) }

                // Record success if tweet was successfully fetched
                blackList.recordSuccess(tweetId)
                
                return tweet
            } catch {
                hproseError("Error processing tweet: \(error)")
                // Record failure for tweet processing error
                blackList.recordFailure(tweetId)
                throw error
            }
        }
        
        // Tweet not found - record failure to blacklist candidates
        hproseError("DEBUG: [refreshTweet] Tweet not found for tweetId: \(tweetId), recording failure")
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
            // get_userid is a discovery operation — always use the entry node,
            // not appUser.hproseClient which may point to a provider node after logout
            guard let entryIP = try await findEntryIP() else {
                hproseWarning("[getUserId] Cannot resolve entry IP - will retry")
                throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Entry IP not available"])
            }
            let client = clientPool.getClientByIP(for: entryIP)

            let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)

            if let stringResponse = unwrappedResponse as? String {
                return stringResponse
            }

            if let dictResponse = unwrappedResponse as? [String: Any] {
                if let data = dictResponse["data"] as? String {
                    return data
                }
            }

            hproseWarning("[getUserId] Unexpected response format for username: \(username)")
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from get_userid"])
        }
    }
    
    /// If @baseUrl is an empty string, cached user data is bypassed, but NodePool
    /// still wins route selection when it has an entry for the user's access node.
    /// If NodePool has no entry, the user's cached baseUrl or provider lookup is used.
    /// Otherwise, the supplied baseUrl is used as the fallback route after NodePool.
    ///
    /// - Parameters:
    ///   - userId: The user ID to fetch
    /// Fetches user data with caching, blacklist checking, and concurrent update management
    /// - Parameters:
    ///   - userId: The user ID to fetch
    ///   - baseUrl: Explicit fallback route for this user. Pass nil to use this
    ///     user's cached route/NodePool/provider lookup, or "" to bypass the
    ///     cached user return while still letting NodePool win route selection.
    ///   - maxRetries: Maximum number of retry attempts (default: 2)
    ///   - forceRefresh: If true, bypasses cache and fetches fresh data
    ///   - skipRetryAndBlacklist: If true, skips retry logic and blacklist management (for internal use)
    /// - Returns: User object, or nil for non-network terminal states such as guest/blacklisted users
    func fetchUser(
        _ userId: String,
        baseUrl: String? = nil,
        maxRetries: Int = 2,
        forceRefresh: Bool = false,
        skipRetryAndBlacklist: Bool = false,
        v4Only: Bool = false,
        refreshExpiredCacheInBackground: Bool = true
    ) async throws -> User? {
        // Guard against fetching the guest user - GUEST_ID should never make network calls
        // as it represents an unauthenticated state
        guard userId != Constants.GUEST_ID else {
            hproseDebug("DEBUG: [fetchUser] Null userId, returning nil")
            return nil
        }
        
        let explicitBaseUrl = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        var forceFreshIPResolution = explicitBaseUrl == ""

        // Check if this user has been blacklisted due to repeated failures
        // Skip this check if we're in internal retry logic to prevent double-checking
        if !skipRetryAndBlacklist && blackList.isBlacklisted(userId) {
            let cachedUser = await TweetCacheManager.shared.fetchUser(mid: userId)
            let cachedHasUsername = await MainActor.run { cachedUser.username != nil }
            if cachedHasUsername {
                hproseDebug("DEBUG: [fetchUser] User \(userId) is blacklisted, returning cached=true")
                return cachedUser
            }
            hproseDebug("DEBUG: [fetchUser] User \(userId) is blacklisted, returning cached=false")
            return nil
        }
        
        // Attempt to return cached data if we're not forcing a fresh fetch
        if !forceRefresh {
            // Fetch the user from the local cache
            let cachedUser = await TweetCacheManager.shared.fetchUser(mid: userId)

            // Verify that we have a complete cached user with required fields
            let cachedComplete = await MainActor.run { cachedUser.username != nil && cachedUser.baseUrl != nil }
            if cachedComplete {
                let hasExpired = await cachedUser.hasExpired()
                
                // Return cached user if it's still valid and the caller did
                // not explicitly ask us to re-resolve the provider route.
                if !hasExpired && !forceFreshIPResolution {
                    _ = await applyNodePoolBaseUrlIfAvailable(for: cachedUser, reason: "fresh cache NodePool")
                    await MainActor.run {
                        cachedUser.cacheStatus = .fresh
                    }
                    return cachedUser
                } else if hasExpired {
                    await MainActor.run {
                        cachedUser.cacheStatus = .stale
                    }
                    // User data has expired.
                    // If baseUrl is empty, don't return stale data; route selection
                    // below still checks NodePool before falling back to cached baseUrl
                    // or provider discovery.
                    if forceFreshIPResolution {
                        hproseDebug("DEBUG: [fetchUser] Cache expired and baseUrl empty (forcing IP resolution), fetching fresh data")
                        forceFreshIPResolution = true
                        // Fall through to fetch fresh data with IP resolution below
                    } else {
                        if refreshExpiredCacheInBackground {
                            // For normal fetches, return stale data while refreshing in background for better UX
                            let shouldStartBackgroundRefresh = userUpdateQueue.sync {
                                if !ongoingUserUpdates.contains(userId) {
                                    // Mark this user as being updated to prevent duplicate refreshes
                                    _ = ongoingUserUpdates.insert(userId)
                                    return true
                                }
                                return false
                            }

                            // Kick off background refresh if we're the first to notice expiration
                            if shouldStartBackgroundRefresh {
                                await MainActor.run {
                                    cachedUser.cacheStatus = .refreshing
                                }
                                Task {
                                    await startBackgroundRefresh(
                                        userId,
                                        cachedUser: cachedUser,
                                        maxRetries: maxRetries,
                                        skipRetryAndBlacklist: skipRetryAndBlacklist,
                                        v4Only: v4Only
                                    )
                                }
                            }
                        } else {
                            hproseDebug("DEBUG: [fetchUser] Returning expired cached user without background refresh for userId: \(userId)")
                        }
                        
                        // Return the stale cached user immediately for better UX (non-login flows)
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
            _ = userUpdateErrors.removeValue(forKey: userId)
            // Mark this user as being updated
            _ = ongoingUserUpdates.insert(userId)
            return true
        }
        
        // If another fetch is in progress, wait for its result instead of
        // launching a duplicate request.
        if !shouldProceed {
            return try await waitForConcurrentUpdate(userId, baseUrl: explicitBaseUrl, forceRefresh: forceRefresh)
        }
        
        // Ensure we always remove this user from the ongoing updates set when we're done
        // This executes regardless of how we exit (success, error, or early return)
        defer {
            userUpdateQueue.sync {
                _ = ongoingUserUpdates.remove(userId)
            }
        }
        
        do {
            // Get or create a User instance for this userId (on the main actor;
            // User is a @MainActor class instance).
            let user = await MainActor.run { () -> User in
                let u = User.getInstance(mid: userId)
                u.cacheStatus = .refreshing
                return u
            }
            
            // Validate an explicitly supplied route, but do not write it to the
            // shared User yet. Candidate routes are committed only after get_user
            // returns valid user data.
            if let explicitBaseUrl, !explicitBaseUrl.isEmpty {
                guard URL(string: ensureHttpPrefix(explicitBaseUrl)) != nil else {
                    throw HproseError.userNotFound(userId: userId, reason: "Invalid explicit baseUrl: \(explicitBaseUrl)")
                }
            }
            
            // Perform the actual user data fetch with retry logic and error handling
            // This will handle IP resolution if baseUrl was empty
            let updatedUser = try await performUserUpdate(
                user,
                maxRetries: maxRetries,
                skipRetryAndBlacklist: skipRetryAndBlacklist,
                logPrefix: "fetchUser",
                v4Only: v4Only,
                forceFreshIP: forceFreshIPResolution,
                routeHint: explicitBaseUrl
            )
            userUpdateQueue.sync {
                _ = userUpdateErrors.removeValue(forKey: userId)
            }
            await MainActor.run {
                updatedUser.cacheStatus = .fresh
            }
            return updatedUser
        } catch {
            // Catch and log any exceptions during the fetch process
            hproseError("DEBUG: [fetchUser] Exception in fetchUser: userId: \(userId), error: \(error)")
            userUpdateQueue.sync {
                userUpdateErrors[userId] = error as NSError
            }
            await MainActor.run {
                User.getInstance(mid: userId).cacheStatus = .refreshFailed
            }
            // Backstop: ensure repeated fetchUser failures drive the 2-strike session block,
            // even if the inner performUserUpdate path didn't record this attempt.
            if !skipRetryAndBlacklist {
                blackList.recordFailure(userId)
            }
            throw error
        }
    }
    
    // Track ongoing user updates to prevent concurrent calls for the same user
    private var ongoingUserUpdates: Set<String> = []
    private var userUpdateErrors: [String: NSError] = [:]
    private let userUpdateQueue = DispatchQueue(label: "user.update.queue")
    
    // MARK: - Helper Methods
    
    /// Waits for a concurrent update to complete. If it appears stuck, surface
    /// an error instead of returning stale cached data.
    private func waitForConcurrentUpdate(_ userId: String, baseUrl: String?, forceRefresh: Bool) async throws -> User? {
        // A provider lookup can spend the full health-check timeout on a bad IP.
        // Give the owner task enough room to finish so waiters do not start
        // reporting false failures while the lookup is still legitimately running.
        let timeoutNs: UInt64 = (forceRefresh || baseUrl == "") ? 15_000_000_000 : 6_000_000_000
        let pollIntervalNs: UInt64 = 200_000_000
        var waitedNs: UInt64 = 0

        while waitedNs < timeoutNs {
            try await Task.sleep(nanoseconds: pollIntervalNs)
            waitedNs += pollIntervalNs

            let updateState = userUpdateQueue.sync {
                (ongoingUserUpdates.contains(userId), userUpdateErrors[userId])
            }
            if !updateState.0 {
                if let error = updateState.1 {
                    throw error
                }
                return await TweetCacheManager.shared.fetchUser(mid: userId)
            }
        }

        hproseWarning("DEBUG: [fetchUser] Timed out waiting for concurrent refresh of \(userId); throwing instead of returning stale cache")
        throw HproseError.userNotFound(userId: userId, reason: "Timed out waiting for concurrent refresh")
    }
    
    /// Starts background refresh for expired user
    private func startBackgroundRefresh(
        _ userId: String,
        cachedUser: User,
        maxRetries: Int,
        skipRetryAndBlacklist: Bool,
        v4Only: Bool = false,
        forceFreshIP: Bool = false
    ) async {
        await MainActor.run {
            cachedUser.cacheStatus = .refreshing
        }
        defer {
            userUpdateQueue.sync {
                _ = ongoingUserUpdates.remove(userId)
            }
        }
        
        do {
            _ = try await performUserUpdate(
                cachedUser,
                maxRetries: maxRetries,
                skipRetryAndBlacklist: skipRetryAndBlacklist,
                logPrefix: "backgroundRefresh",
                v4Only: v4Only,
                forceFreshIP: forceFreshIP
            )
            userUpdateQueue.sync {
                _ = userUpdateErrors.removeValue(forKey: userId)
            }
            await MainActor.run {
                cachedUser.cacheStatus = .fresh
            }
        } catch {
            userUpdateQueue.sync {
                userUpdateErrors[userId] = error as NSError
            }
            await MainActor.run {
                cachedUser.cacheStatus = .refreshFailed
            }
            hproseWarning("DEBUG: [startBackgroundRefresh] Background refresh failed for userId: \(userId): \(error)")
        }
    }
    
    private func invalidateIPCacheForBaseUrl(_ baseUrlString: String?) {
        guard let baseUrlString, !baseUrlString.isEmpty else { return }
        let normalized = normalizeHostPort(baseUrlString)
        invalidateIPCache(for: normalized)

        guard let url = URL(string: ensureHttpPrefix(normalized)),
              let host = url.host else {
            return
        }

        if let port = url.port {
            let hostPort = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            invalidateIPCache(for: hostPort)
        } else {
            invalidateIPCache(for: host)
        }
    }

    private func hasTimeoutCause(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0

        while let nsError = current, depth < 8 {
            if nsError.code == NSURLErrorTimedOut {
                return true
            }

            let description = nsError.localizedDescription.lowercased()
            if description.contains("timeout") || description.contains("timed out") {
                return true
            }

            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
            } else if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                current = underlying as NSError
            } else {
                current = nil
            }
            depth += 1
        }

        return false
    }

    /// Validates the route currently displayed by a profile without delaying cached rendering.
    /// Returns true when the current route is healthy or an unhealthy route was replaced.
    func validateAndRepairProfileRoute(for user: User) async -> Bool {
        let (userMid, currentBaseUrl, accessNodeMid) = await MainActor.run {
            (
                user.mid,
                user.baseUrl?.absoluteString,
                user.hostIds.flatMap { $0.count > 1 ? $0[1] : nil }
            )
        }

        var failedHostPort: String?
        if let currentBaseUrl, !currentBaseUrl.isEmpty {
            let currentHostPort = normalizeHostPort(currentBaseUrl)
            hproseDebug("DEBUG: [ProfileRoute] Fresh health check for user \(userMid) at \(currentHostPort)")
            let routeIsHealthy = await isRouteAlive(currentHostPort, forceFresh: true)
            if routeIsHealthy {
                hproseDebug("DEBUG: [ProfileRoute] Current route is healthy for user \(userMid); refreshing profile data")
                return true
            }
            guard !Task.isCancelled else { return false }

            hproseWarning("DEBUG: [ProfileRoute] Current route is unhealthy for user \(userMid): \(currentHostPort)")
            // Reads go back to the access node; the root host stopped answering.
            UserRoutes.shared.stopReadingFromWriteHost(for: userMid)
            failedHostPort = currentHostPort
            invalidateIPCacheForBaseUrl(currentBaseUrl)
            if let accessNodeMid,
               let pooledIP = NodePool.shared.getIPForNode(nodeMid: accessNodeMid),
               normalizeHostPort(pooledIP) == currentHostPort {
                // Evict only when the pool still points at the address that just
                // failed. A newer entry describes a different, untested route.
                NodePool.shared.removeIPFromNode(nodeMid: accessNodeMid, ip: pooledIP)
            }
            clientPool.clear(for: "\(ensureHttpPrefix(currentHostPort))/webapi/")
        }

        // Fall back to the next advertised address of the same access node before
        // widening the search to provider discovery.
        var replacementIP: String?
        if let accessNodeMid {
            replacementIP = await getHostIP(
                accessNodeMid,
                v4Only: false,
                forceHealthCheck: true,
                excludedIP: failedHostPort
            )
        }
        if replacementIP == nil {
            replacementIP = try? await getProviderIP(userMid, v4Only: false, forceFresh: true)
        }

        guard let replacementIP,
              let replacementURL = URL(string: ensureHttpPrefix(replacementIP)),
              !Task.isCancelled else {
            hproseWarning("DEBUG: [ProfileRoute] Could not resolve a healthy replacement route for user \(userMid)")
            return false
        }

        await applyBaseUrlIfNeeded(user, url: replacementURL, reason: "profile health repair")
        if let accessNodeMid {
            NodePool.shared.updateNodeIP(nodeMid: accessNodeMid, newIP: normalizeHostPort(replacementIP))
        }
        await MainActor.run { TweetCacheManager.shared.saveUser(user) }
        hproseDebug("DEBUG: [ProfileRoute] Repaired route for user \(userMid): \(replacementURL.absoluteString)")
        return true
    }

    /// A successful health probe does not prove that every RPC is usable on that
    /// address. After a read fails on the current route, try another advertised
    /// and reachable address for the same access node. The attempted address is only
    /// excluded from this lookup; it is not marked unhealthy or blacklisted.
    ///
    /// This is the companion to `validateAndRepairProfileRoute`: that one handles a route
    /// that stopped answering at all, this one handles a route that answers the probe and
    /// still cannot serve the read — the only evidence of which is the read failing.
    /// - Returns: true when the user was moved to a different address.
    func switchToAlternateRoute(
        for user: User,
        attemptedBaseUrl: String?,
        logPrefix: String
    ) async -> Bool {
        guard let attemptedBaseUrl, !attemptedBaseUrl.isEmpty else { return false }
        let (userMid, userHostIds) = await MainActor.run { (user.mid, user.hostIds) }
        UserRoutes.shared.stopReadingFromWriteHost(for: userMid)
        guard let accessNodeMid = userHostIds.flatMap({ $0.count > 1 ? $0[1] : nil }) else { return false }

        let attemptedHostPort = normalizeHostPort(attemptedBaseUrl)
        guard let alternateIP = await getHostIP(
            accessNodeMid,
            v4Only: false,
            forceHealthCheck: true,
            excludedIP: attemptedHostPort
        ) else {
            hproseWarning("DEBUG: [\(logPrefix)] No alternate address for access node \(accessNodeMid) of user \(userMid)")
            return false
        }

        let alternateHostPort = normalizeHostPort(alternateIP)
        guard alternateHostPort != attemptedHostPort,
              let alternateURL = URL(string: ensureHttpPrefix(alternateIP)) else {
            return false
        }

        await applyBaseUrlIfNeeded(user, url: alternateURL, reason: "\(logPrefix) alternate route")
        NodePool.shared.updateNodeIP(nodeMid: accessNodeMid, newIP: alternateHostPort)
        await MainActor.run { TweetCacheManager.shared.saveUser(user) }
        hproseWarning("DEBUG: [\(logPrefix)] Switched route for user \(userMid): \(attemptedHostPort) -> \(alternateHostPort)")
        return true
    }

    private func evictNodeRouteAfterFailure(
        user: User,
        attemptedBaseUrl: String?,
        logPrefix: String
    ) async {
        // Phase A (demotion prep): snapshot @MainActor user.hostIds.
        let userHostIds = await MainActor.run { user.hostIds }
        guard let baseUrlString = attemptedBaseUrl,
              let hostIds = userHostIds,
              hostIds.count > 1 else {
            return
        }

        let accessNodeMid = hostIds[1]

        // Health check is the source of truth for route invalidation. Bypass
        // cached health so this failure is judged by a fresh probe.
        hproseWarning("DEBUG: [\(logPrefix)] Fetch-user timeout to \(baseUrlString); checking route health before changing NodePool")
        invalidateIPCacheForBaseUrl(baseUrlString)
        let routeHostPort = normalizeHostPort(baseUrlString)
        let routeStillHealthy = await isRouteAlive(routeHostPort, forceFresh: true)
        if !routeStillHealthy {
            hproseWarning("DEBUG: [\(logPrefix)] Removing unhealthy node \(accessNodeMid) from pool after failed health check")
            await MainActor.run {
                NodePool.shared.removeIPFromNode(nodeMid: accessNodeMid, ip: baseUrlString)
                UserRoutes.shared.stopReadingFromWriteHost(for: user.mid)
            }
            return
        }

        hproseDebug("DEBUG: [\(logPrefix)] Keeping node \(accessNodeMid) in pool; health check passed after failure to \(baseUrlString)")
    }

    func applyNodePoolBaseUrlIfAvailable(for user: User, reason: String) async -> URL? {
        // Phase A (demotion prep): snapshot @MainActor NodePool + User reads.
        let (poolIP, userMid, userHostIds) = await MainActor.run {
            (NodePool.shared.getIPFromNode(for: user), user.mid, user.hostIds)
        }
        guard let poolIP else {
            return nil
        }

        guard let url = URL(string: ensureHttpPrefix(poolIP)) else {
            hproseWarning("DEBUG: [NodePool] Ignoring invalid pooled IP for userId: \(userMid): \(poolIP)")
            if let hostIds = userHostIds, hostIds.count > 1 {
                await MainActor.run { NodePool.shared.removeIPFromNode(nodeMid: hostIds[1], ip: poolIP) }
            }
            return nil
        }

        await applyBaseUrlIfNeeded(user, url: url, reason: reason)
        return url
    }

    func applyReadNodeBaseUrlIfAvailable(for user: User, reason: String) async -> URL? {
        if let pooledUrl = await applyNodePoolBaseUrlIfAvailable(for: user, reason: reason) {
            return pooledUrl
        }

        // Phase A (demotion prep): snapshot @MainActor User reads.
        let (userHostIds, userMid) = await MainActor.run { (user.hostIds, user.mid) }
        guard let accessNodeMid = userHostIds.flatMap({ $0.count > 1 ? $0[1] : nil }) else {
            return nil
        }

        hproseDebug("DEBUG: [read route] Resolving read node \(accessNodeMid) for userId: \(userMid), reason: \(reason)")
        guard let accessIP = await getHostIP(accessNodeMid),
              let url = URL(string: ensureHttpPrefix(accessIP)) else {
            hproseDebug("DEBUG: [read route] Could not resolve read node \(accessNodeMid) for userId: \(userMid)")
            return nil
        }

        await applyBaseUrlIfNeeded(user, url: url, reason: reason)
        return url
    }
    
    /// Ensures URL has http:// prefix
    private func ensureHttpPrefix(_ url: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("http") {
            return url
        }
        return "http://\(url)"
    }
    
    /// Checks if two normalized IPs represent a redirect loop
    /// Performs the complete user update flow with retry logic
    /// This is the main workhorse method that handles retries and redirects
    private func performUserUpdate(
        _ user: User,
        maxRetries: Int,
        skipRetryAndBlacklist: Bool,
        logPrefix: String,
        v4Only: Bool = false,
        forceFreshIP: Bool = false,
        routeHint: String? = nil
    ) async throws -> User {
        // Phase A (demotion prep): snapshot @MainActor user.mid + baseUrl (used in params + logs throughout).
        let (userMid, userBaseUrlString) = await MainActor.run { (user.mid, user.baseUrl?.absoluteString) }
        let trimmedRouteHint = routeHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalBaseUrl = (trimmedRouteHint?.isEmpty == false) ? trimmedRouteHint : userBaseUrlString
        let hasExpired = await user.hasExpired()
        // NodePool is checked before every network attempt. If it has no route,
        // the user's baseUrl is used once before falling back to provider discovery.
        let shouldForceFreshIP = forceFreshIP || trimmedRouteHint == "" || originalBaseUrl == nil || originalBaseUrl?.isEmpty == true
        
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            var attemptedBaseUrl: String?
            do {
                // Resolve a candidate route without mutating the cached User.
                let candidateBaseUrl = try await resolveCandidateBaseUrl(
                    user: user,
                    attempt: attempt,
                    maxRetries: maxRetries,
                    forceFreshIP: shouldForceFreshIP,
                    hasExpired: hasExpired,
                    originalBaseUrl: originalBaseUrl,
                    v4Only: v4Only
                )
                attemptedBaseUrl = candidateBaseUrl.absoluteString
                let previousAccessNodeMid = await MainActor.run { user.hostIds.flatMap { $0.count > 1 ? $0[1] : nil } }

                // Prepare server request
                let entry = "get_user"
                let params: [String: Any] = [
                    "aid": appId,
                    "ver": "last",
                    "version": "v3",
                    "userid": userMid,
                    "v4only": v4Only ? "true" : "false"
                ]

                let hproseClient = clientPool.getClientByUrl(for: candidateBaseUrl.absoluteString, timeout: 15)

                // Make server call
                guard let rawResponse = await invokeRunMApp(using: hproseClient, entry: entry, params: params) else {
                    throw HproseError.noResponse(userId: userMid)
                }

                // Check if the response is an error object (network failure case)
                if let error = rawResponse as? Error {
                    let nsError = error as NSError
                    hproseError("ERROR: [\(logPrefix)] Network error during get_user: userId: \(userMid), domain: \(nsError.domain), code: \(nsError.code)")
                    throw error
                }

                
                // Unwrap and process response
                let response = try Self.unwrapV2Response(rawResponse)
                
                // Process the response
                let success = try await processUserDataResponse(
                    user: user,
                    response: response as Any,
                    skipRetryAndBlacklist: skipRetryAndBlacklist,
                    confirmedBaseUrl: candidateBaseUrl,
                    previousAccessNodeMid: previousAccessNodeMid
                )
                
                if success {
                    return user
                }
                
                // Null get_user data means the user's data is missing or broken.
                // It is not evidence that the node IP is stale.
                hproseError("ERROR: [\(logPrefix)] NULL USER DATA RESPONSE for userId: \(userMid) on attempt \(attempt)/\(maxRetries)")
                if !skipRetryAndBlacklist {
                    blackList.recordFailure(userMid)
                }
                throw HproseError.invalidUserData(userId: userMid, reason: "Null user data response")
            } catch {
                // Handle cancellation specially - don't log as failure, don't retry
                if error is CancellationError {
                    hproseDebug("DEBUG: [\(logPrefix)] Fetch cancelled for userId: \(userMid), attempt: \(attempt)/\(maxRetries)")
                    throw error // Propagate cancellation immediately
                }

                if let typedError = error as? HproseError,
                   case .invalidUserData = typedError {
                    hproseError("ERROR: [\(logPrefix)] USER DATA INVALID: userId: \(userMid), error: \(error)")
                    throw error
                }

                lastError = error
                let nsError = error as NSError
                hproseError("ERROR: [\(logPrefix)] USER UPDATE FAILED: userId: \(userMid), attempt: \(attempt)/\(maxRetries), domain: \(nsError.domain), code: \(nsError.code)")

                if hasTimeoutCause(error) {
                    await evictNodeRouteAfterFailure(
                        user: user,
                        attemptedBaseUrl: attemptedBaseUrl,
                        logPrefix: logPrefix
                    )
                }
                
                if skipRetryAndBlacklist {
                    throw error
                }
                
                if attempt < maxRetries {
                    hproseWarning("DEBUG: [\(logPrefix)] Retrying get_user after failure; route health will decide whether IP changes")
                    continue
                }
            }
        }
        
        // All retries failed - remove node from pool, clear stale baseUrl, and
        // surface the error. Leave the cached User object untouched so profile
        // screens can keep rendering stale-but-useful cached data.
        hproseError("ERROR: [\(logPrefix)] ALL RETRIES FAILED: userId: \(userMid), maxRetries: \(maxRetries)")
        if !skipRetryAndBlacklist {
            blackList.recordFailure(userMid)
        }
        throw lastError ?? HproseError.noResponse(userId: userMid)
    }
    
    /// Processes user data response from server
    /// Returns true if successful, false if null (needs retry), throws exception for errors
    private func processUserDataResponse(
        user: User,
        response: Any,
        skipRetryAndBlacklist: Bool,
        confirmedBaseUrl: URL?,
        previousAccessNodeMid: String?
    ) async throws -> Bool {
        // Phase A (demotion prep): snapshot @MainActor user.mid (used in logs + records throughout).
        let userMid = await MainActor.run { user.mid }
        // Handle dictionary response (user data)
        if let userDict = response as? [String: Any] {
            // Validate response data BEFORE updating the singleton to avoid overwriting
            // a valid user object with invalid data from the server
            guard let mid = userDict["mid"] as? String, !mid.isEmpty,
                  let username = userDict["username"] as? String,
                  !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hproseError("ERROR: [processUserDataResponse] INVALID USER DATA in response: mid missing or username empty for userId: \(userMid)")
                if !skipRetryAndBlacklist {
                    blackList.recordFailure(userMid)
                }
                throw HproseError.invalidUserData(userId: userMid, reason: "Missing mid or empty username")
            }

            if !skipRetryAndBlacklist {
                blackList.recordSuccess(userMid)
            }

            try await updateUserFromDict(userDict, for: user, preserveBaseUrl: false, confirmedBaseUrl: confirmedBaseUrl)

            // NodePool is authoritative for the access node. After a confirmed
            // fetch, replace the pool entry only when the user's route differs
            // from what the pool already knows.
            let fetchedUser = await MainActor.run { User.getInstance(mid: userMid) }
            let (currentAccessNodeMid, fetchedBaseUrlString, fetchedHostIds) = await MainActor.run {
                (fetchedUser.hostIds.flatMap { $0.count > 1 ? $0[1] : nil },
                 UserRoutes.shared.accessRoute(for: fetchedUser.mid)?.absoluteString,
                 fetchedUser.hostIds)
            }
            if let previousAccessNodeMid,
               let currentAccessNodeMid,
               previousAccessNodeMid != currentAccessNodeMid {
                hproseDebug("DEBUG: [processUserDataResponse] Access node changed for \(userMid): \(previousAccessNodeMid) -> \(currentAccessNodeMid); resolving new node before updating NodePool")

                // IPv6 routes are fine for RPC; only share URLs need a v4 literal.
                if let accessIP = await getHostIP(currentAccessNodeMid, v4Only: false),
                   let accessUrl = URL(string: ensureHttpPrefix(accessIP)) {
                    await applyBaseUrlIfNeeded(fetchedUser, url: accessUrl, reason: "access node changed")
                    await MainActor.run { NodePool.shared.updateNodeIP(nodeMid: currentAccessNodeMid, newIP: accessUrl.absoluteString) }
                } else {
                    hproseDebug("DEBUG: [processUserDataResponse] Could not resolve changed access node \(currentAccessNodeMid); leaving NodePool unchanged")
                }
                return true
            }

            let ipValid = await MainActor.run { NodePool.shared.isUserIPValid(for: fetchedUser) }
            if let baseUrlString = fetchedBaseUrlString,
               let hostIds = fetchedHostIds, hostIds.count > 1,
               !ipValid {
                let accessNodeMid = hostIds[1]
                await MainActor.run { NodePool.shared.updateNodeIP(nodeMid: accessNodeMid, newIP: baseUrlString) }
            }
            return true
        }

        // Handle nil response - return false to indicate retry needed
        if response is NSNull {
            hproseError("ERROR: [processUserDataResponse] NULL USER DATA RESPONSE: userId: \(userMid)")
            if !skipRetryAndBlacklist {
                blackList.recordFailure(userMid)
            }
            throw HproseError.invalidUserData(userId: userMid, reason: "Null user data response")
        }

        // Unexpected response type
        hproseError("ERROR: [processUserDataResponse] UNEXPECTED RESPONSE TYPE: userId: \(userMid), type: \(type(of: response))")
        throw HproseError.unexpectedResponse(description: String(describing: response))
    }
    /// Resolves a candidate baseUrl (for first attempt or retries) without
    /// mutating the cached User. The candidate is committed only after get_user
    /// returns valid user data.
    private func resolveCandidateBaseUrl(
        user: User,
        attempt: Int,
        maxRetries: Int,
        forceFreshIP: Bool,
        hasExpired: Bool,
        originalBaseUrl: String?,
        v4Only: Bool = false
    ) async throws -> URL {
        // Phase A (demotion prep): snapshot @MainActor user reads (mid for logs, hostIds for read-node fallback).
        let (userMid, userHostIds) = await MainActor.run { (user.mid, user.hostIds) }
        // Forced resolution must validate a pooled route through getHostIP below.
        // That health check removes an unreachable IP before discovering a replacement.
        if !forceFreshIP,
           let url = await applyNodePoolBaseUrlIfAvailable(for: user, reason: "NodePool route") {
            hproseDebug("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - Using NodePool IP: \(url.absoluteString) for userId: \(userMid)")
            return url
        }

        if attempt == 1, let originalBaseUrl, !originalBaseUrl.isEmpty {
            hproseDebug("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - No NodePool entry; using user baseUrl once: \(originalBaseUrl) for userId: \(userMid)")
            guard let url = URL(string: ensureHttpPrefix(originalBaseUrl)) else {
                throw HproseError.userNotFound(userId: userMid, reason: "Invalid cached baseUrl: \(originalBaseUrl)")
            }
            return url
        }

        // Direct read-node discovery is the strongest fallback for known users:
        // baseUrl may be stale, while hostIds[1] identifies the node that serves reads.
        let reason: String
        if attempt > 1 {
            reason = "retry after failure"
        } else if originalBaseUrl == nil || originalBaseUrl?.isEmpty == true {
            reason = "no baseUrl"
        } else if hasExpired {
            reason = "cache expired"
        } else if forceFreshIP {
            reason = "forcing fresh IP"
        } else {
            reason = "provider discovery"
        }
        
        if let accessNodeMid = userHostIds.flatMap({ $0.count > 1 ? $0[1] : nil }) {
            hproseDebug("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - Resolving read node \(accessNodeMid) for userId: \(userMid), reason: \(reason)")
            if let accessIP = await getHostIP(
                accessNodeMid,
                v4Only: v4Only,
                forceHealthCheck: forceFreshIP
            ),
               let url = URL(string: ensureHttpPrefix(accessIP)) {
                return url
            }
            hproseWarning("WARNING: [resolveAndUpdateBaseUrl] getHostIP returned nil for read node \(accessNodeMid), falling back to provider IP for userId: \(userMid)")
        }

        hproseDebug("DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT \(attempt)/\(maxRetries) - Resolving provider IP for userId: \(userMid), reason: \(reason)")

        do {
            guard let providerIP = try await getProviderIP(userMid, v4Only: v4Only) else {
                // getProviderIP returned nil (not exception) - user not found or no IPs available
                hproseWarning("WARNING: [resolveAndUpdateBaseUrl] getProviderIP returned nil for userId: \(userMid) - user not found or no IPs available")
                throw HproseError.userNotFound(userId: userMid, reason: "No healthy provider IP found")
            }

            if let url = URL(string: ensureHttpPrefix(providerIP)) {
                return url
            }

            throw HproseError.userNotFound(userId: userMid, reason: "Invalid provider IP: \(providerIP)")
        } catch {
            // getProviderIP threw exception - network error, should trigger retry
            hproseWarning("WARNING: [resolveAndUpdateBaseUrl] Network error calling getProviderIP for userId: \(userMid), attempt: \(attempt)/\(maxRetries)")
            throw error  // Re-throw to trigger retry logic
        }
    }
    

    
    /// Get provider IP for a user with health checking.
    /// - Parameters:
    ///   - mid: User's member ID
    ///   - v4Only: Whether to request IPv4 addresses only
    ///   - forceFresh: Re-probe every candidate instead of trusting a cached verdict.
    ///     Discovery that follows a failure must pass this: the failing route is often
    ///     in that same list, cached healthy from minutes ago.
    /// - Returns: A healthy provider IP address, or nil if none found
    /// - Throws: Error if entry discovery itself fails
    func getProviderIP(_ mid: String, v4Only: Bool = false, forceFresh: Bool = false) async throws -> String? {
        // Safety check: never try to get provider IP for GUEST_ID
        if mid == Constants.GUEST_ID {
            hproseError("ERROR: [getProviderIP] Refusing to get provider IP for GUEST_ID")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot get provider IP for GUEST_ID"])
        }

        // get_provider_ips is a discovery operation — use the app entry node, not
        // appUser.hproseClient which may point to a stale provider after login/logout.
        guard let entryIP = try await findEntryIP() else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize app entry with any URL", comment: "App initialization error")])
        }
        let entryClient = clientPool.getClientByIP(for: entryIP)

        let providerIP = try await _getProviderIP(mid, v4Only: v4Only, hproseClient: entryClient, forceFresh: forceFresh)
        if providerIP == nil {
            hproseWarning("DEBUG: [getProviderIP] No provider IP found for \(mid) - user not found or all IPs unhealthy")
        }
        return providerIP
    }
    
    private func _getProviderIP(
        _ mid: MimeiId,
        v4Only: Bool = false,
        hproseClient: HproseClient? = nil,
        forceFresh: Bool = false
    ) async throws -> String? {
        let entry = "get_provider_ips"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "mid": mid,
            "v4only": v4Only ? "true" : "false"
        ]

        // Phase A (demotion prep): the default client (appUser's) can't be a @MainActor
        // default argument once the class is nonisolated — resolve it here instead.
        let resolvedClient: HproseClient?
        if let hproseClient {
            resolvedClient = hproseClient
        } else {
            resolvedClient = await MainActor.run { HproseInstance.shared.appUser.hproseClient }
        }
        guard let hproseClient = resolvedClient else {
            hproseDebug("DEBUG: [_getProviderIP] No hprose client available")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No hprose client available"])
        }
        
        // Let network errors propagate as exceptions
        let rawResponse = await invokeRunMApp(using: hproseClient, entry: entry, params: params)
        guard let response = rawResponse else {
            hproseDebug("DEBUG: [_getProviderIP] No response from server - network error")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from server"])
        }
        
        // Unwrap v2 response - let exceptions propagate for network/format errors
        let unwrappedResponse = try Self.unwrapV2Response(response)
        hproseDebug("DEBUG: [_getProviderIP][RAW] mid=\(mid), unwrappedResponse=\(providerIPDebugDescription(unwrappedResponse))")
        
        if let ipList = unwrappedResponse as? [String] {

            // Filter and trim IP addresses, excluding private/reserved ranges
            let ipAddresses = ipList
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { Gadget.isValidPublicIpAddress($0) }

            hproseDebug("DEBUG: [_getProviderIP][RAW] mid=\(mid), filteredPublicIPs=\(providerIPDebugDescription(ipAddresses))")
            hproseDebug("DEBUG: [_getProviderIP] Retrieved \(ipAddresses.count) IP address(es) from get_provider_ips API")
            
            // Test IPs two at a time to match Android and avoid stampeding weak nodes.
            let batchSize = 2
            for batchStart in stride(from: 0, to: ipAddresses.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ipAddresses.count)
                let batch = Array(ipAddresses[batchStart..<batchEnd])
                
                
                // Test this batch in parallel - return as soon as first IP responds successfully
                let healthyIP: String? = await withTaskGroup(of: (String, Bool)?.self) { group in
                    for ip in batch {
                        group.addTask {
                            // Check for cancellation before starting
                            if Task.isCancelled {
                                return nil
                            }
                            
                            
                            let isHealthy = await self.isRouteAlive(ip, forceFresh: forceFresh, logFailures: false)

                            if Task.isCancelled { return nil }

                            return (ip, isHealthy)
                        }
                    }
                    
                    // Return IMMEDIATELY when first healthy IP is found
                    for await result in group {
                        if let (ip, isHealthy) = result, isHealthy {
                            hproseDebug("DEBUG: [_getProviderIP] Found healthy provider IP: \(ip) - returning immediately")
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
            
            // If no healthy IP is found, return nil. The caller must fail or
            // explicitly retry discovery; it must not silently reuse a stale URL.
            if !ipAddresses.isEmpty {
                hproseError("DEBUG: [_getProviderIP] All health checks failed for \(ipAddresses.count) IP(s)")
                return nil
            }
            
            return nil
        }
        hproseWarning("DEBUG: [_getProviderIP] Invalid IpList response format for mid \(mid): \(responseShapeDescription(unwrappedResponse))")
        return nil
    }

    /// Compact, length-capped rendering of an unexpected response, for failure logs.
    /// Names the runtime type first — that alone usually separates "the node sent an
    /// error dict" from "the list came back JSON-encoded as a string".
    private func responseShapeDescription(_ value: Any?) -> String {
        guard let value else { return "nil" }
        var body: String
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            body = string
        } else {
            body = String(describing: value)
        }
        if body.count > 500 {
            body = String(body.prefix(500)) + "…(truncated)"
        }
        return "\(Swift.type(of: value)): \(body)"
    }

    private func providerIPDebugDescription(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
    
    // MARK: - IP Cache Methods
    
    /// Check if an IP health result is in the cache and still valid.
    private func getCachedIPHealth(_ ip: String, logFailures _: Bool = true) -> Bool? {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        let key = normalizeHostPort(ip)
        
        if let entry = ipCache[key] {
            if !entry.isExpired {
                return entry.isHealthy
            } else {
                ipCache.removeValue(forKey: key)
            }
        }
        return nil
    }
    
    /// Cache a HEAD health result.
    private func cacheIP(_ ip: String, isHealthy: Bool, logFailures _: Bool = true) {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        let key = normalizeHostPort(ip)
        
        ipCache[key] = IPCacheEntry(ip: key, isHealthy: isHealthy, timestamp: Date())
    }
    
    /// Clear expired entries from cache
    private func cleanupExpiredCache() {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        
        let beforeCount = ipCache.count
        ipCache = ipCache.filter { !$0.value.isExpired }
        let removedCount = beforeCount - ipCache.count
        if removedCount > 0 {
            hproseDebug("DEBUG: [IPCache] Cleaned up \(removedCount) expired entries")
        }
    }
    
    /// Invalidate a specific IP from cache (useful when an IP fails after being cached)
    func invalidateIPCache(for ip: String) {
        ipCacheLock.lock()
        defer { ipCacheLock.unlock() }
        let key = normalizeHostPort(ip)
        
        if ipCache.removeValue(forKey: key) != nil {
            hproseWarning("DEBUG: [IPCache] Invalidated cache for IP: \(key)")
        }
    }
    
    // MARK: - Health Check Methods

    /// Every route liveness question in the app goes through here, so one policy
    /// decides them all: a 5s HEAD against `http://<host:port>/`, keyed in the shared
    /// 30s health cache by the canonical address. Mirrors TweetWeb `isServerHealthy` —
    /// any HTTP response means reachable; only a network-level error (refused, timeout,
    /// cancelled) means it is not. The timeout goes straight to URLRequest, so there is
    /// no extra Task layer.
    ///
    /// The address is normalized once, up front, and that one string is used for both
    /// the request URL and the cache key. Callers hand this both shapes — a
    /// `baseUrl.absoluteString` carries `http://` while a server address list does not —
    /// and probing the raw string while caching the normalized one would file a verdict
    /// for `1.2.3.4:8002` that came from a request which never reached it.
    ///
    /// - Parameter forceFresh: skip the cached verdict. Pass it wherever a route is being
    ///   judged *after* something failed on it: the cached "healthy" is exactly what the
    ///   failure calls into question.
    private func isRouteAlive(_ address: String, forceFresh: Bool = false, logFailures: Bool = true) async -> Bool {
        cleanupExpiredCache()

        let hostPort = normalizeHostPort(address)
        if !forceFresh, let cachedHealth = getCachedIPHealth(hostPort, logFailures: logFailures) {
            return cachedHealth
        }

        guard let url = URL(string: "http://\(hostPort)/") else {
            cacheIP(hostPort, isHealthy: false, logFailures: logFailures)
            return false
        }

        var request = URLRequest(url: url, timeoutInterval: Self.routeProbeTimeout)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            _ = try await URLSession.shared.data(for: request)
            // Any response (any status code) means the server is reachable.
            cacheIP(hostPort, isHealthy: true)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                if logFailures {
                    hproseError("DEBUG: [isRouteAlive] ❌ \(hostPort): \(nsError.domain) \(nsError.code)")
                }
                cacheIP(hostPort, isHealthy: false, logFailures: logFailures)
            }
            return false
        }
    }

    private func mergeTweetFromDict(
        _ dict: [String: Any],
        attachAuthor: Bool = false,
        attachAuthorMid: MimeiId? = nil
    ) async throws -> Tweet {
        let record = try TweetRecord.fromDictionary(dict)
        return await MainActor.run {
            let authorMid = attachAuthor ? record.authorId : attachAuthorMid
            let author = authorMid.map { UserStore.shared.user(mid: $0) }
            return TweetStore.shared.merge(record, author: author)
        }
    }

    private func mergeUserFromDict(
        _ dict: [String: Any],
        shouldUpdateBaseUrl: Bool = false
    ) async throws -> User {
        let decoded = try UserRecord.fromDictionary(dict)
        return await MainActor.run {
            UserStore.shared.merge(decoded, shouldUpdateBaseUrl: shouldUpdateBaseUrl)
        }
    }
    

    
    /// Updates user from dictionary response
    private func updateUserFromDict(
        _ dict: [String: Any],
        for user: User,
        preserveBaseUrl: Bool = false,
        confirmedBaseUrl: URL? = nil
    ) async throws {
        var decodedUser = try UserRecord.fromDictionary(dict)
        let originalBaseUrl = await MainActor.run { user.baseUrl }

        if let confirmedBaseUrl {
            decodedUser.record.baseUrl = confirmedBaseUrl
        } else if preserveBaseUrl || originalBaseUrl != nil {
            decodedUser.record.baseUrl = originalBaseUrl
        }

        let decodedUserForMerge = decodedUser
        await MainActor.run {
            // Commit a newly-tested route only after the response has been
            // validated. Failed/null refreshes leave the cached object alone.
            let updatedUser = UserStore.shared.merge(decodedUserForMerge, shouldUpdateBaseUrl: confirmedBaseUrl != nil)
            updatedUser.cacheStatus = .fresh

            hproseDebug("DEBUG: [updateUserFromDict] Updated user: \(updatedUser.username ?? "nil") (\(updatedUser.mid))")

            TweetCacheManager.shared.saveUser(updatedUser)
            NotificationCenter.default.post(name: .userDidUpdate, object: nil, userInfo: ["userId": updatedUser.mid])
        }
    }
    
    // MARK: - Error Types
    
    private enum HproseError: LocalizedError {
        case noClient(userId: String)
        case noResponse(userId: String)
        case userNotFound(userId: String, reason: String)
        case invalidUserData(userId: String, reason: String)
        case unexpectedResponse(description: String)
        
        var errorDescription: String? {
            switch self {
            case .noClient(let userId):
                return "No hprose client available for user: \(userId)"
            case .noResponse(let userId):
                return "No response from server for user: \(userId)"
            case .userNotFound(let userId, let reason):
                return "User \(userId) not found: \(reason)"
            case .invalidUserData(let userId, let reason):
                return "Invalid user data for \(userId): \(reason)"
            case .unexpectedResponse(let description):
                return "Unexpected response from server: \(description)"
            }
        }
        
        var nsError: NSError {
            return NSError(domain: "HproseClient", code: -1, userInfo: [
                NSLocalizedDescriptionKey: errorDescription ?? "Unknown error"
            ])
        }
    }
    
    struct ResyncUserResult {
        let user: User
        let tweets: [Tweet]
    }

    /// Resyncs a user from the backend and returns the updated user plus newly synced tweets.
    func resyncUser(userId: String) async throws -> ResyncUserResult {
        // Phase A (demotion prep): snapshot @MainActor User.getInstance baseUrl + appUser.mid.
        let (userBaseUrl, appUserMid) = await MainActor.run {
            (User.getInstance(mid: userId).baseUrl, self.appUser.mid)
        }

        let route = userBaseUrl?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard !route.isEmpty else {
            throw NSError(
                domain: "HproseClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Route unavailable for resync user \(userId)"]
            )
        }

        let entry = "resync_user"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v3",
            "userid": userId,
            "appuserid": appUserMid
        ]

        // 300s: resync can be a long server-side operation. Pooled per (URL, timeout).
        let client = clientPool.getClientByUrl(for: route, timeout: 300)

        hproseDebug("DEBUG: [resyncUser] Calling resync_user for userId: \(userId) with baseUrl: \(route)")

        guard let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from resync_user for user \(userId)"])
        }

        guard let responseData = Self.asStringKeyedDictionary(rawResponse) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }

        guard let userData = Self.asStringKeyedDictionary(responseData["user"])
                ?? (responseData["username"] != nil ? responseData : nil) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid resync_user response for user \(userId): missing user data"])
        }

        let syncedUser = try await mergeUserFromDict(userData)
        let (syncedMid, syncedUsername) = await MainActor.run { (syncedUser.mid, syncedUser.username) }
        guard syncedMid == userId, !(syncedUsername?.isEmpty ?? true) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid resync_user data for user \(userId)"])
        }

        let tweetDataList = Self.tweetDataDictionaries(from: responseData["tweets"])
        var syncedTweets: [Tweet] = []
        for tweetData in tweetDataList {
            do {
                let tweet = try await mergeTweetFromDict(
                    tweetData,
                    attachAuthorMid: tweetData["authorId"] as? String == syncedMid ? syncedMid : nil
                )
                await MainActor.run {
                    if tweet.author == nil {
                        tweet.author = UserStore.shared.user(mid: tweet.authorId)
                    }
                    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                }
                syncedTweets.append(tweet)
            } catch {
                hproseWarning("WARN: [resyncUser] Ignoring invalid synced tweet for user \(userId): \(error)")
            }
        }

        await MainActor.run { TweetCacheManager.shared.saveUser(syncedUser) }

        return ResyncUserResult(user: syncedUser, tweets: syncedTweets)
    }

    private static func tweetDataDictionaries(from value: Any?) -> [[String: Any]] {
        if let dict = asStringKeyedDictionary(value) {
            return [dict]
        }

        if let array = value as? [Any] {
            return array.flatMap { tweetDataDictionaries(from: $0) }
        }

        if let array = value as? NSArray {
            return array.flatMap { tweetDataDictionaries(from: $0) }
        }

        return []
    }
    
    func login(_ loginUser: User) async throws -> [String: Any] {
        let entry = "login"
        // Phase A (demotion prep): snapshot @MainActor loginUser credential + route reads.
        let (loginUsername, loginPassword, loginBaseUrl) = await MainActor.run {
            (loginUser.username, loginUser.password, loginUser.baseUrl)
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "username": loginUsername!,
            "password": loginPassword!
        ]

        // Match TweetWeb: authenticate through the resolved read/provider route.
        // hostIds[0] is the writable home node and is resolved lazily for writes.
        guard let loginUrl = loginBaseUrl else {
            hproseError("ERROR: [login] No URL available for login")
            return ["reason": NSLocalizedString("Login failed", comment: "Generic login failure message"), "status": "failure"]
        }
        hproseDebug("DEBUG: [login] Using provider URL for authentication: \(loginUrl.absoluteString)")


        return try await retryOperation(maxRetries: 3) {
            hproseDebug("DEBUG: [login] Creating client for: \(loginUrl.absoluteString)")
            let newClient = self.clientPool.getClientByUrl(for: loginUrl.absoluteString, timeout: 30)

            hproseDebug("DEBUG: [login] Invoking login API...")
            let rawResponse = await self.invokeRunMApp(using: newClient, entry: entry, params: params)

            // Check if the response is nil (network error)
            guard rawResponse != nil else {
                hproseError("ERROR: [login] Network request failed - nil response (timeout or connection error)")
                throw NSError(domain: "NSURLErrorDomain", code: -1001, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Request timed out", comment: "Network timeout error")])
            }

            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)

            guard let response = unwrappedResponse as? [String: Any] else {
                hproseError("ERROR: [login] Invalid response format from server")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
            }

            hproseDebug("DEBUG: [login] Response received: \(response)")

            // Handle v2 format: check success field first, then status field for backward compatibility
            if let success = response["success"] as? Bool {
                if !success {
                    let message = response["message"] as? String ?? NSLocalizedString("Login failed", comment: "Generic login failure message")
                    let localizedReason = self.localizeLoginError(message)
                    hproseError("DEBUG: [login] Login failed with message: \(message)")
                    return ["reason": localizedReason, "status": "failure"]
                }
                // success is true, check for user data
                if response["user"] != nil || response["data"] != nil {
                    hproseDebug("DEBUG: [login] Login successful, setting appUser")
                    await MainActor.run {
                        self.preferenceHelper?.setUserId(loginUser.mid)
                        self.appUser = loginUser
                        NodePool.shared.updateFromUser(loginUser)
                    }
                    Task {
                        await self.populateFellowLists(user: loginUser)
                    }
                    Task {
                        _ = try? await loginUser.resolveWritableUrl()
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
                    hproseError("DEBUG: [login] Login failed with status: \(status), reason: \(serverReason)")
                    return ["reason": localizedReason, "status": "failure"]
                } else if status == "success" && response["user"] != nil {
                    hproseDebug("DEBUG: [login] Login successful (status field), setting appUser")
                    await MainActor.run {
                        self.preferenceHelper?.setUserId(loginUser.mid)
                        self.appUser = loginUser
                        NodePool.shared.updateFromUser(loginUser)
                    }
                    Task {
                        await self.populateFellowLists(user: loginUser)
                    }
                    Task {
                        _ = try? await loginUser.resolveWritableUrl()
                    }
                    return ["reason": NSLocalizedString("Success", comment: "Success message"), "status": "success"]
                }
            }

            hproseError("DEBUG: [login] Login failed - no success field or no user data")
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
        // Don't clear tweet cache on logout - cache persists per user and is cleared periodically or manually
        // Clear chat cache on signout
        await ChatCacheManager.shared.clearAllCache()

        // Clear all video cache files from disk
        // await CachingPlayerItem.clearAllCache()

        // Clear stale HTTP clients from previous user session
        clientPool.clear()

        // Reset appUser to guest user with entry baseUrl (not the old user's node)
        await MainActor.run {
            self.preferenceHelper?.setUserId(nil)

            let guestUser = User.getInstance(mid: Constants.GUEST_ID)
            guestUser.baseUrl = HproseInstance.baseUrl
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
        // Phase A (HproseInstance demotion prep): snapshot the @MainActor User into a Sendable
        // UserRecord so this function no longer reads user.X directly. The class is still
        // @MainActor so this compiles and ships; once demoted the function runs off-main and
        // this is its one main-actor hop. invokeRunMApp is retained until Phase C.
        let snap = await MainActor.run { UserRecord(user: user) }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid,
        ]
        guard let baseUrl = snap.baseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let rawResponse = await invokeRunMApp(using: client, entry: entry.rawValue, params: params)
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when user has no followers/following
        let response: [[String: Any]]
        if let arrayResponse = unwrappedResponse as? [[String: Any]] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            hproseDebug("DEBUG: [HproseInstance] getListByType - Server returned empty array for \(entry.rawValue)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
        }
        
        let sorted = response.sorted {
            (lhs, rhs) in
            let lval = Self.intField(lhs, key: "value") ?? 0
            let rval = Self.intField(rhs, key: "value") ?? 0
            return lval > rval
        }
        return sorted.compactMap { $0["field"] as? String }
    }

    /// Removes a row that has just crossed the permanent reliability blacklist
    /// threshold. The backend rechecks the relationship timestamp on hostIds[0]
    /// so a relationship added after this failure streak began is never removed.
    func removePermanentlyBlacklistedUser(
        _ blacklistedUserId: MimeiId,
        from relationship: UserContentType,
        owner: User,
        failureStartedAt: TimeInterval
    ) async throws -> (removed: Bool, reason: String?) {
        let relationshipName: String
        switch relationship {
        case .FOLLOWER:
            relationshipName = "followers"
        case .FOLLOWING:
            relationshipName = "followings"
        default:
            throw NSError(
                domain: "HproseClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported relationship cleanup type"]
            )
        }

        let ownerRecord = await MainActor.run { UserRecord(user: owner) }
        guard let ownerHostId = ownerRecord.hostIds?.first, !ownerHostId.isEmpty else {
            throw NSError(
                domain: "HproseClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Profile owner has no writable host"]
            )
        }

        let writableUrl = try await owner.resolveWritableUrl()
        let client = clientPool.getClientByUrl(for: writableUrl.absoluteString, timeout: 30)
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": ownerRecord.mid,
            "otherid": blacklistedUserId,
            "relationship": relationshipName,
            "userid_hostid": ownerHostId,
            "failurestartedat": Int64(failureStartedAt * 1_000),
            "failurecount": 14
        ]
        let rawResponse = await invokeRunMApp(
            using: client,
            entry: "remove_blacklisted_relationship",
            params: params
        )
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        guard let response = unwrappedResponse as? [String: Any],
              let removed = response["removed"] as? Bool else {
            throw NSError(
                domain: "HproseClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid relationship cleanup response"]
            )
        }
        return (removed, response["reason"] as? String)
    }
    
    /**
     * Get a list of users that the given user is following, sorted by timestamp when followed.
     * For guest users, returns alpha IDs as fallback.
     */
    func getFollowings(user: User) async throws -> [MimeiId] {
        let entry = "get_followings_sorted"
        // Phase A (demotion prep): snapshot @MainActor User → Sendable UserRecord.
        let snap = await MainActor.run { UserRecord(user: user) }
        let attemptedBaseUrl = snap.baseUrl?.absoluteString
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid
        ]

        do {
            guard let baseUrl = snap.baseUrl else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
            let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)

            // Unwrap v2 response
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)

            // Handle empty array case - server returns empty array when user has no followings
            let response: [[String: Any]]
            if let arrayResponse = unwrappedResponse as? [[String: Any]] {
                response = arrayResponse
            } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
                // Server returned empty array - handle gracefully
                response = []
                hproseDebug("DEBUG: [HproseInstance] getFollowings - Server returned empty array (no followings)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
            }
            
            let sorted = response.sorted { (lhs, rhs) in
                let lval = Self.intField(lhs, key: "value") ?? 0
                let rval = Self.intField(rhs, key: "value") ?? 0
                return lval > rval
            }
            await MainActor.run { NodePool.shared.updateFromUser(user) }
            return sorted.compactMap { $0["field"] as? String }
        } catch {
            hproseError("DEBUG: [HproseInstance] getFollowings error: \(error) (baseUrl: \(attemptedBaseUrl ?? "nil"))")
            return Gadget.getAlphaIds()
        }
    }
    
    /**
     * Check if the app user is in the target user's blacklist
     * @param targetUserId The user ID to check against
     * @return true if app user is blacklisted, false otherwise
     */
    
    /**
     * Populate fans and following lists for a given user
     */
    func populateFellowLists(user: User) async {
        // Phase A (demotion prep): snapshot @MainActor user.mid for logging.
        let userMid = await MainActor.run { user.mid }
        do {
            // Get followings (users that the user is following)
            let followings = try await getFollowings(user: user)
            await MainActor.run {
                user.followingList = followings
            }
            hproseDebug("DEBUG: [HproseInstance] Populated followingList for user \(userMid) with \(followings.count) users")

            // Get fans (users who are following the user)
            if let fans = try await getFans(user: user) {
                await MainActor.run {
                    user.fansList = fans
                }
                hproseDebug("DEBUG: [HproseInstance] Populated fansList for user \(userMid) with \(fans.count) users")
            } else {
                hproseDebug("DEBUG: [HproseInstance] No fans found for user \(userMid)")
            }
        } catch {
            hproseError("DEBUG: [HproseInstance] Error populating fans/following lists for user \(userMid): \(error)")
        }
    }
    
    /**
     * Get a list of users who are following the given user, sorted by timestamp when they started following.
     * Returns nil for guest users.
     */
    func getFans(user: User) async throws -> [MimeiId]? {
        let entry = "get_followers_sorted"
        // Phase A (demotion prep): snapshot @MainActor User → Sendable UserRecord.
        let snap = await MainActor.run { UserRecord(user: user) }
        let attemptedBaseUrl = snap.baseUrl?.absoluteString
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid
        ]

        do {
            guard let baseUrl = snap.baseUrl else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
            let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)

            // Handle empty array case - server returns empty array when user has no fans
            let response: [[String: Any]]
            if let arrayResponse = unwrappedResponse as? [[String: Any]] {
                response = arrayResponse
            } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
                // Server returned empty array - handle gracefully
                response = []
                hproseDebug("DEBUG: [HproseInstance] getFans - Server returned empty array (no fans)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
            }
            
            let sorted = response.sorted { (lhs, rhs) in
                let lval = Self.intField(lhs, key: "value") ?? 0
                let rval = Self.intField(rhs, key: "value") ?? 0
                return lval > rval
            }
            await MainActor.run { NodePool.shared.updateFromUser(user) }
            return sorted.compactMap { $0["field"] as? String }
        } catch {
            hproseError("DEBUG: [HproseInstance] getFans error: \(error) (baseUrl: \(attemptedBaseUrl ?? "nil"))")
            return nil
        }
    }
    
    func getUserTweetsByType(
        user: User,
        type: UserContentType,
        pageNumber: UInt = 0,
        pageSize: UInt = 20
    ) async throws -> [Tweet?] {
        // Phase A (demotion prep): snapshot @MainActor User + appUser.mid.
        let snap = await MainActor.run { UserRecord(user: user) }
        let appUserMid = await MainActor.run { self.appUser.mid }
        let entry = "get_user_meta"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid,
            "type": type.rawValue,
            "pn": pageNumber,
            "ps": pageSize,
            "appuserid": appUserMid
        ] as [String : Any]
        hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType params: \(params)")
        
        guard let baseUrl = snap.baseUrl else {
            hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Client not initialized for user: \(snap.mid)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        
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
                hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Server returned empty array (no bookmarks/favorites)")
            } else {
                response = arrayResponse.map { item in
                    if let dict = item as? [String: Any] {
                        return dict
                    } else {
                        hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Array item is not a dictionary: \(String(describing: Swift.type(of: item)))")
                        return nil
                    }
                }
            }
        } else {
            hproseWarning("DEBUG: [HproseInstance] getUserTweetsByType - Invalid response format: \(String(describing: unwrappedResponse))")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server in getUserTweetsByType"])
        }
        
        hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Got response with \(response.count) items")
        
        // For bookmarks/favorites, preserve server order by using a stable rank timestamp.
        // The rank must include the page offset; using Date() per page lets later-fetched
        // pages outrank page 0 on the next cached first paint.
        let isBookmarkOrFavorite = type == .BOOKMARKS || type == .FAVORITES
        let savedListCacheKey = type == .BOOKMARKS
            ? TweetCacheManager.bookmarkCacheKey(userId: snap.mid)
            : TweetCacheManager.favoriteCacheKey(userId: snap.mid)
        if isBookmarkOrFavorite {
            // The response is authoritative for this ranked page. Clear only that
            // page before repopulating it so nil/deleted rows cannot survive in
            // cache or pull records from the next page into the first paint.
            await TweetCacheManager.shared.clearSavedListCachePage(
                cacheKey: savedListCacheKey,
                page: pageNumber,
                pageSize: pageSize
            )
        }
        var scheduledBackgroundAuthorFetches = Set<String>()
        func scheduleBackgroundAuthorFetch(authorId: String) {
            guard scheduledBackgroundAuthorFetches.insert(authorId).inserted else { return }

            Task(priority: .utility) { [weak self] in
                await Task.yield()
                do {
                    _ = try await self?.fetchUser(authorId)
                } catch {
                    hproseError("DEBUG: [HproseInstance] getUserTweetsByType - Background author fetch failed for \(authorId): \(error)")
                }
            }
        }
        
        var tweetsWithAuthors: [Tweet?] = []
        for (index, dict) in response.enumerated() {
            if let item = dict {
                do {
                    let tweet = try await mergeTweetFromDict(item)
                    let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: tweet.authorId)
                    await MainActor.run {
                        tweet.author = cachedAuthor
                        // Membership in these server-owned lists is authoritative even
                        // when the access-node copy has stale viewer interaction flags.
                        if type == .BOOKMARKS {
                            tweet.isBookmarked = true
                        } else if type == .FAVORITES {
                            tweet.isFavorite = true
                        }
                    }
                    scheduleBackgroundAuthorFetch(authorId: tweet.authorId)

                    // Saved comments need their immediate parent available before the
                    // bookmark/favorite cell can render it as embedded context. This is
                    // an ordinary access-node read; it does not force synchronization.
                    if isBookmarkOrFavorite,
                       let parentTweetId = await MainActor.run(body: { tweet.parentTweetId }) {
                        let cachedParent = await TweetCacheManager.shared.fetchTweet(mid: parentTweetId)
                        if case nil = cachedParent {
                            let parentRawResponse = await invokeRunMApp(
                                using: client,
                                entry: "get_tweet",
                                params: [
                                    "aid": appId,
                                    "ver": "last",
                                    "version": "v2",
                                    "tweetid": parentTweetId,
                                    "appuserid": appUserMid
                                ]
                            )

                            if let parentPayload = try? Self.unwrapV2Response(parentRawResponse),
                               let parentDict = Self.asStringKeyedDictionary(parentPayload),
                               let parentTweet = try? await mergeTweetFromDict(parentDict) {
                                let parentAuthor = await TweetCacheManager.shared.fetchUser(mid: parentTweet.authorId)
                                await MainActor.run {
                                    parentTweet.author = parentAuthor
                                    TweetCacheManager.shared.saveTweet(parentTweet, userId: parentTweet.authorId)
                                }
                                scheduleBackgroundAuthorFetch(authorId: parentTweet.authorId)
                            }
                        }
                    }

                    // Cache tweets from bookmarks/favorites with prefixed key to avoid mixing with feed.
                    // Use format: "bookmark_list_userId" or "favorite_list_userId".
                    // saveTweet will automatically mark media as permanent based on the prefix
                    let timeCached: Date?
                    if isBookmarkOrFavorite {
                        timeCached = TweetCacheManager.savedListCacheTime(
                            page: pageNumber,
                            index: index,
                            pageSize: pageSize
                        )
                    } else {
                        // For other types, use current time
                        timeCached = nil
                    }
                    
                    // Reduced logging to prevent console buffer overflow
                    await MainActor.run {
                        TweetCacheManager.shared.saveTweet(tweet, userId: savedListCacheKey, timeCached: timeCached)
                    }

                    tweetsWithAuthors.append(tweet)
                } catch {
                    hproseError("DEBUG: [HproseInstance] getUserTweetsByType - Error processing tweet \(index): \(error)")
                    tweetsWithAuthors.append(nil)
                }
            } else {
                hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Item \(index) is nil")
                tweetsWithAuthors.append(nil)
            }
        }
        
        // For bookmarks and favorites, preserve the server's order (already sorted by bookmark/favorite time)
        // For other types, sort by tweet creation timestamp (most recent first)
        let sortedTweets: [Tweet?]
        if type == .BOOKMARKS || type == .FAVORITES {
            // Preserve server order - don't sort
            sortedTweets = tweetsWithAuthors
            hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Returning \(sortedTweets.count) tweets, valid: \(sortedTweets.compactMap { $0 }.count), preserving server order (bookmarks/favorites)")
        } else {
            // Sort tweets in descending order by timestamp (most recent first).
            // tweet.timestamp is @MainActor state — sort on the main actor.
            sortedTweets = await MainActor.run {
                tweetsWithAuthors.sorted { tweet1, tweet2 in
                    guard let t1 = tweet1, let t2 = tweet2 else {
                        // Put non-nil tweets before nil tweets
                        return tweet1 != nil && tweet2 == nil
                    }
                    return t1.timestamp > t2.timestamp
                }
            }
            hproseDebug("DEBUG: [HproseInstance] getUserTweetsByType - Returning \(sortedTweets.count) tweets, valid: \(sortedTweets.compactMap { $0 }.count), sorted by timestamp (descending)")
        }
        
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
        // Phase A (demotion prep): snapshot @MainActor appUser.mid.
        let appUserMid = await MainActor.run { self.appUser.mid }
        let effectiveUserId = userId ?? appUserMid

        // Check if app user is blacklisted by the target user
        guard let targetUser = try await fetchUser(followingId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Target user not found", comment: "User lookup error")])
        }
        let isBlocked = await MainActor.run { targetUser.isUserBlacklisted(effectiveUserId) }
        if isBlocked {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot follow this user because you are blocked", comment: "Follow blocked error")])
        }

        // toggle_following is NOT idempotent — never retry. A timed-out request
        // may still be processed server-side; a retry would flip the state back.
        let entry = "toggle_following"
        let followingHostId = await MainActor.run { User.getInstance(mid: followingId).hostIds?.first }
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "followingid": followingId,
            "userid": effectiveUserId,
            "followingid_hostid": followingHostId as Any,
        ]
        // Route the call directly to the acting user's primary host (hostIds[0]) so the
        // backend's `userHostId === nodeId` check fires and the local handler
        // runs. The cross-node delegation path in toggle_following.js drops the
        // response payload (Java-Map-backed bridge object whose keys are not
        // JS-enumerable), making a clearly successful operation look like a
        // failure on the client. By calling the home node directly we bypass it.
        let actingUser: User
        if effectiveUserId == appUserMid {
            actingUser = await MainActor.run { self.appUser }
        } else {
            guard let fetchedUser = try await fetchUser(effectiveUserId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Acting user not found", comment: "User lookup error")])
            }
            actingUser = fetchedUser
        }
        let writableUrl = try await actingUser.resolveWritableUrl()
        let client = HproseInstance.shared.clientPool.getClientByUrl(for: writableUrl.absoluteString, timeout: 60)
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        await adoptWriteRouteForReads(actingUser, reason: entry)

        if let dataDict = unwrappedResponse as? [String: Any],
           let isFollowing = dataDict["isFollowing"] as? Bool {
            return isFollowing
        }
        if let boolResponse = unwrappedResponse as? Bool {
            return boolResponse
        }
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Nil response from server", comment: "Server response error")])
    }
    
    /*
     Return an updated tweet object after toggling favorite status of the tweet by appUser.
     */
    private enum SavedTweetList {
        case favorites
        case bookmarks
    }

    @MainActor
    private func stageLocalSavedTweetRemoval(
        tweetId: String,
        list: SavedTweetList
    ) -> Bool {
        switch list {
        case .favorites:
            let containedTweet = appUser.favoriteTweets?.contains(tweetId) == true
            appUser.favoriteTweets?.removeAll { $0 == tweetId }
            return containedTweet
        case .bookmarks:
            let containedTweet = appUser.bookmarkedTweets?.contains(tweetId) == true
            appUser.bookmarkedTweets?.removeAll { $0 == tweetId }
            return containedTweet
        }
    }

    @MainActor
    private func restoreLocalSavedTweetRemoval(
        tweetId: String,
        list: SavedTweetList,
        wasListed: Bool
    ) {
        guard wasListed else { return }

        switch list {
        case .favorites:
            if appUser.favoriteTweets == nil {
                appUser.favoriteTweets = []
            }
            if appUser.favoriteTweets?.contains(tweetId) == false {
                appUser.favoriteTweets?.append(tweetId)
            }
        case .bookmarks:
            if appUser.bookmarkedTweets == nil {
                appUser.bookmarkedTweets = []
            }
            if appUser.bookmarkedTweets?.contains(tweetId) == false {
                appUser.bookmarkedTweets?.append(tweetId)
            }
        }
    }

    private func finishSavedTweetRemoval(
        tweetId: String,
        list: SavedTweetList,
        appUserId: String
    ) async {
        let cacheKey: String
        switch list {
        case .favorites:
            cacheKey = TweetCacheManager.favoriteCacheKey(userId: appUserId)
        case .bookmarks:
            cacheKey = TweetCacheManager.bookmarkCacheKey(userId: appUserId)
        }
        await TweetCacheManager.shared.deleteTweet(mid: tweetId, from: cacheKey)
    }

    private func savedTweetStorageAuthor(for tweet: Tweet) async throws -> User {
        let (parentTweetId, directAuthor, directAuthorId) = await MainActor.run {
            (tweet.parentTweetId, tweet.author, tweet.authorId)
        }

        if let parentTweetId {
            guard let parentTweet = await TweetCacheManager.shared.fetchTweet(mid: parentTweetId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("Parent tweet is not available", comment: "Saved comment storage error")
                ])
            }
            let (parentAuthor, parentAuthorId) = await MainActor.run {
                (parentTweet.author, parentTweet.authorId)
            }
            if let parentAuthor {
                return parentAuthor
            }
            guard let fetchedParentAuthor = try await fetchUser(parentAuthorId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("Parent tweet author is not available", comment: "Saved comment storage error")
                ])
            }
            return fetchedParentAuthor
        }

        if let directAuthor {
            return directAuthor
        }
        guard let fetchedAuthor = try await fetchUser(directAuthorId) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Author not available", comment: "Writable client error")
            ])
        }
        return fetchedAuthor
    }

    func toggleFavorite(_ tweet: Tweet, isFavorite: Bool) async throws -> (Tweet?, User?) {
        // Saved-tweet mutations must succeed on the exact storage owner.
        let storageAuthor = try await savedTweetStorageAuthor(for: tweet)
        let (tweetMid, storageAuthorId, appUserMid, appHostId) = await MainActor.run {
            (tweet.mid, storageAuthor.mid, self.appUser.mid, self.appUser.hostIds?.first)
        }
        let wasListed = isFavorite
            ? false
            : await MainActor.run {
                stageLocalSavedTweetRemoval(tweetId: tweetMid, list: .favorites)
            }

        do {
            _ = try await storageAuthor.resolveWritableUrl()
            guard let client = await storageAuthor.writableClient(timeout: 60) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "appuserid": appUserMid,
                "tweetid": tweetMid,
                "authorid": storageAuthorId,
                "userhostid": appHostId as Any,
                "isfavorite": Self.rpcBool(isFavorite)
            ]
            let rawResponse = await invokeRunMApp(using: client, entry: "toggle_favorite", params: params)
            // Hprose syncInvoke returns the error object (not throws) on failure
            if let error = rawResponse as? NSError {
                throw error
            }
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let response = unwrappedResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }

            // unwrapV2Response already threw for success=false
            var updatedUser: User?
            var updatedTweet: Tweet?

            if let userDict = response["user"] as? [String: Any] {
                updatedUser = try await mergeUserFromDict(userDict)
            }
            if let tweetDict = response["tweet"] as? [String: Any] {
                updatedTweet = try await mergeTweetFromDict(tweetDict)
            }

            if !isFavorite {
                await finishSavedTweetRemoval(tweetId: tweetMid, list: .favorites, appUserId: appUserMid)
            }
            // The tweet's counters live on the author's host; the app user's favorites
            // list lives on its own (userhostid). Both sides were written.
            await adoptWriteRouteForReads(storageAuthor, reason: "toggle_favorite")
            await adoptWriteRouteForReads(await MainActor.run { self.appUser }, reason: "toggle_favorite")
            return (updatedTweet, updatedUser)
        } catch {
            if !isFavorite {
                await MainActor.run {
                    restoreLocalSavedTweetRemoval(
                        tweetId: tweetMid,
                        list: .favorites,
                        wasListed: wasListed
                    )
                }
            }
            throw error
        }
    }

    func toggleBookmark(_ tweet: Tweet, isBookmarked: Bool) async throws -> (Tweet?, User?) {
        // Saved-tweet mutations must succeed on the exact storage owner.
        let storageAuthor = try await savedTweetStorageAuthor(for: tweet)
        let (tweetMid, storageAuthorId, appUserMid, appHostId) = await MainActor.run {
            (tweet.mid, storageAuthor.mid, self.appUser.mid, self.appUser.hostIds?.first)
        }
        let wasListed = isBookmarked
            ? false
            : await MainActor.run {
                stageLocalSavedTweetRemoval(tweetId: tweetMid, list: .bookmarks)
            }

        do {
            _ = try await storageAuthor.resolveWritableUrl()
            guard let client = await storageAuthor.writableClient(timeout: 60) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
            }
            let params = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "userid": appUserMid,
                "tweetid": tweetMid,
                "authorid": storageAuthorId,
                "userhostid": appHostId as Any,
                "isbookmarked": Self.rpcBool(isBookmarked)
            ]
            let rawResponse = await invokeRunMApp(using: client, entry: "toggle_bookmark", params: params)
            // Hprose syncInvoke returns the error object (not throws) on failure
            if let error = rawResponse as? NSError {
                throw error
            }
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let response = unwrappedResponse as? [String: Any] else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }

            // unwrapV2Response already threw for success=false
            var updatedUser: User?
            var updatedTweet: Tweet?

            if let userDict = response["user"] as? [String: Any] {
                updatedUser = try await mergeUserFromDict(userDict)
            }
            if let tweetDict = response["tweet"] as? [String: Any] {
                updatedTweet = try await mergeTweetFromDict(tweetDict)
            }

            if !isBookmarked {
                await finishSavedTweetRemoval(tweetId: tweetMid, list: .bookmarks, appUserId: appUserMid)
            }
            // Same split as toggle_favorite: author's host for the tweet, app user's
            // host for the bookmark list.
            await adoptWriteRouteForReads(storageAuthor, reason: "toggle_bookmark")
            await adoptWriteRouteForReads(await MainActor.run { self.appUser }, reason: "toggle_bookmark")
            return (updatedTweet, updatedUser)
        } catch {
            if !isBookmarked {
                await MainActor.run {
                    restoreLocalSavedTweetRemoval(
                        tweetId: tweetMid,
                        list: .bookmarks,
                        wasListed: wasListed
                    )
                }
            }
            throw error
        }
    }

    func retweet(_ tweet: Tweet) async throws -> Tweet? {
        // Create a unique temporary ID for this retweet to avoid singleton collisions
        // Multiple rapid retweets would otherwise share the same GUEST_ID singleton
        let temporaryId = "TEMP_RETWEET_\(UUID().uuidString)"
        // Phase A (demotion prep): snapshot @MainActor tweet.mid for logging.
        let tweetMid = await MainActor.run { tweet.mid }
        hproseDebug("🔄 [HproseInstance.retweet] Creating retweet with temporary ID: \(temporaryId) for original tweet: \(tweetMid)")
        
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
        
        // Phase A (demotion prep): snapshot @MainActor retweet reads.
        let (retweetMid, retweetAuthorId) = await MainActor.run { (retweet.mid, retweet.authorId) }

        // Update retweet count of the original tweet and cache the updated tweet
        // Match Android behavior: update count, cache result, then post notification
        if let updatedTweet = await updateRetweetCount(tweet: tweet, retweetId: retweetMid) {
            // Cache the updated original tweet with its authorId as the cache key
            // This ensures the original tweet is cached under its author's cache, not appUser's
            await MainActor.run { TweetCacheManager.shared.saveTweet(updatedTweet, userId: updatedTweet.authorId) }
        }

        // Cache the retweet by its authorId (matches Android behavior)
        // For retweets, authorId equals appUser.mid, so this is consistent with mainfeed caching
        // The retweet will also be cached via .newTweetCreated notification in handleNewTweet,
        // but we cache it here explicitly to ensure it's saved
        await MainActor.run { TweetCacheManager.shared.saveTweet(retweet, userId: retweetAuthorId) }

        // Clean up the temporary tweet instance to prevent memory leaks
        if temporaryId != retweetMid {
            await MainActor.run { Tweet.clearInstance(mid: temporaryId) }
            hproseDebug("🧹 [HproseInstance.retweet] Cleaned up temporary tweet instance: \(temporaryId)")
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
    /// Matches Android behavior: returns nil on error instead of throwing.
    /// Uses the original tweet author's client to ensure we're calling the correct server.
    func updateRetweetCount(
        tweet: Tweet,
        retweetId: String,
        direction: Bool = true   // add/remove retweet
    ) async -> Tweet? {
        let entry = direction ? "retweet_added" : "retweet_removed"
        // Phase A (demotion prep): snapshot @MainActor Tweet + appUser reads.
        let (appUserMid, tweetMid, tweetAuthorId) = await MainActor.run { (self.appUser.mid, tweet.mid, tweet.authorId) }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "appuserid": appUserMid,
            "retweetid": retweetId,
            "tweetid": tweetMid,
            "authorid": tweetAuthorId,
        ]

        let existingAuthor = await MainActor.run { tweet.author }
        let author: User?
        if let existingAuthor {
            author = existingAuthor
        } else {
            author = try? await fetchUser(tweetAuthorId, baseUrl: "")
        }
        guard let author else {
            hproseWarning("⚠️ [updateRetweetCount] Original tweet author not available")
            return nil
        }
        do {
            _ = try await author.resolveWritableUrl()
        } catch {
            hproseError("⚠️ [updateRetweetCount] Failed to resolve original author root: \(error)")
            return nil
        }
        guard let client = await author.writableClient(timeout: 15) else {
            hproseWarning("⚠️ [updateRetweetCount] Original author writable client not initialized")
            return nil
        }

        // Both entries key the original tweet's retweet list by retweetId (Hset / Hdel),
        // so they are idempotent and safe to retry. Without a retry a single dropped RPC
        // silently loses the count change — the retweet exists but the original never
        // learns about it, and the next refresh reverts the optimistic UI update.
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
            if let unwrappedResponse = try? Self.unwrapV2Response(rawResponse),
               let tweetDict = unwrappedResponse as? [String: Any] {
                do {
                    // Update the tweet from server response
                    try await MainActor.run {
                        try tweet.update(from: tweetDict)
                    }
                    await adoptWriteRouteForReads(author, reason: entry)
                    // Return the updated tweet (same instance, updated in place)
                    return tweet
                } catch {
                    hproseError("⚠️ [updateRetweetCount] Failed to update tweet from server response: \(error)")
                    return nil
                }
            }

            hproseWarning("⚠️ [updateRetweetCount] \(entry) attempt \(attempt)/\(maxAttempts) failed for tweet \(tweetMid)")
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return nil
    }
    
    /**
     * Toggle tweet privacy (public/private). Only appUser can update its own tweet.
     * Returns the new privacy status as a boolean.
     * */
    func toggleTweetPrivacy(tweetId: String) async throws -> Bool {
        // toggle_tweet_privacy is NON-idempotent — never retry. A timed-out
        // request may still be processed server-side; a retry would flip it back.
        let entry = "toggle_tweet_privacy"
        // Phase A (demotion prep): snapshot @MainActor appUser.mid.
        let appUserMid = await MainActor.run { self.appUser.mid }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "appuserid": appUserMid,
            "tweetid": tweetId
        ]
        // Mutation: send directly to the user's writable node. The server-side
        // delegation path was returning empty objects; routing here avoids it.
        // writableUrl is lazy-resolved — make sure it's populated first.
        let appUserInstance = await MainActor.run { self.appUser }
        _ = try await appUserInstance.resolveWritableUrl()
        guard let client = await appUserInstance.writableClient(timeout: 30) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Writable client not available", comment: "Writable client error")])
        }

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)

        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        await adoptWriteRouteForReads(appUserInstance, reason: entry)
        hproseDebug("[toggleTweetPrivacy] Unwrapped response: \(String(describing: unwrappedResponse))")

        // For v2 API: server returns {success: true, data: {isPrivate: bool}}
        // After unwrapV2Response, we get {isPrivate: bool}.
        // Hprose bridges JS booleans to NSNumber, so accept both Bool and NSNumber.
        if let dataDict = unwrappedResponse as? [String: Any],
           let isPrivate = (dataDict["isPrivate"] as? Bool) ?? (dataDict["isPrivate"] as? NSNumber)?.boolValue {
            hproseDebug("[toggleTweetPrivacy] Privacy status from v2 format: \(isPrivate)")
            return isPrivate
        }

        // Fallback: check if it's a direct Bool (legacy format)
        if let isPrivateBool = unwrappedResponse as? Bool {
            hproseDebug("[toggleTweetPrivacy] Direct boolean response: \(isPrivateBool)")
            return isPrivateBool
        }

        // Handle numeric responses (0 = false, 1 = true) - legacy format
        if let numericResponse = unwrappedResponse as? NSNumber {
            let isPrivate = numericResponse.boolValue
            hproseDebug("[toggleTweetPrivacy] Numeric response: \(numericResponse) -> boolean: \(isPrivate)")
            return isPrivate
        }

        // Handle integer responses (0 = false, 1 = true) - legacy format
        if let intResponse = unwrappedResponse as? Int {
            let isPrivate = intResponse != 0
            hproseDebug("[toggleTweetPrivacy] Integer response: \(intResponse) -> boolean: \(isPrivate)")
            return isPrivate
        }

        hproseWarning("[toggleTweetPrivacy] Unexpected response format: \(String(describing: unwrappedResponse))")
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
    }
    
    /**
     * Delete a tweet.
     * Sends the current app user as the requester and the tweet author as owner metadata.
     * The backend decides whether to permanently delete the tweet or only remove it
     * from the requester's personal lists.
     */
    func deleteTweet(_ tweetId: String, tweetAuthorId: String) async throws -> String {
        let entry = "delete_tweet"
        // Phase A (demotion prep): snapshot @MainActor appUser.mid + admin check.
        let (appUserMid, isAdminDeletingAnotherUsersTweet) = await MainActor.run {
            (self.appUser.mid, tweetAuthorId != self.appUser.mid && Gadget.isResearchAdminUser(self.appUser))
        }
        // Snapshot the retweet link BEFORE deleting: removeDeletedTweetLocally() clears the
        // singleton and the cache row, so afterwards there is no way to find the original.
        // The backend's delete_tweet does not touch the original tweet's retweet list, so
        // the client is what keeps the original's retweetCount honest.
        let retweetOrigin = await MainActor.run { () -> (String, String)? in
            let tweet = Tweet.getInstance(for: tweetId)
                ?? TweetCacheManager.shared.fetchTweetSync(mid: tweetId)
            guard let originalTweetId = tweet?.originalTweetId,
                  let originalAuthorId = tweet?.originalAuthorId else { return nil }
            return (originalTweetId, originalAuthorId)
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v3",
            // The backend permanently deletes only when userid == authorid. Admin
            // deletes are already gated client-side and routed to the author's host.
            "userid": isAdminDeletingAnotherUsersTweet ? tweetAuthorId : appUserMid,
            "appuserid": isAdminDeletingAnotherUsersTweet ? tweetAuthorId : appUserMid,
            "authorid": tweetAuthorId,
            "tweetid": tweetId
        ]

        let requestUser: User
        if isAdminDeletingAnotherUsersTweet {
            guard let author = try await fetchUser(tweetAuthorId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch tweet author", comment: "Author fetch error")])
            }
            requestUser = author
        } else {
            requestUser = await MainActor.run { self.appUser }
        }

        // Delete is a mutation, so it must run directly against the current
        // writable/root host. resolveWritableUrl() always resolves hostIds[0]
        // fresh rather than reusing the last writable URL.
        let writableUrl = try await requestUser.resolveWritableUrl()
        guard let client = await requestUser.writableClient(timeout: 30) else {
            throw NSError(domain: "HproseClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Writable client not available", comment: "Writable client error")])
        }

        hproseDebug("DEBUG: [deleteTweet] Using writable client at \(writableUrl.absoluteString) for tweet \(tweetId)")
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse: Any?
        do {
            unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        } catch {
            if Self.isTweetNotFoundDeleteFailure(error, response: rawResponse) {
                hproseDebug("DEBUG: [deleteTweet] Tweet \(tweetId) is already missing on server; clearing local cache")
                await removeDeletedTweetLocally(tweetId)
                // retweet_removed is an idempotent Hdel, so it is safe to send even when
                // another client already unlinked this retweet.
                if let retweetOrigin {
                    await decrementRetweetCountOfOriginal(
                        originalTweetId: retweetOrigin.0,
                        originalAuthorId: retweetOrigin.1,
                        retweetId: tweetId
                    )
                }
                try? await self.refreshAppUserFromServer()
                return tweetId
            }
            throw error
        }

        // unwrapV2Response already threw for success=false. For delete, also require
        // a concrete tweet id so malformed success responses are not silently accepted.
        var resolvedDeletedTweetId: String?
        if let response = unwrappedResponse as? [String: Any] {
            if let tid = response["tweetid"] as? String, !tid.isEmpty {
                resolvedDeletedTweetId = tid
            } else if let tid = response["tweetid"] as? NSString, tid.length > 0 {
                resolvedDeletedTweetId = tid as String
            }
        }
        guard let deletedTweetId = resolvedDeletedTweetId else {
            throw NSError(domain: "HproseClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid delete response from server", comment: "Server response error")])
        }

        await adoptWriteRouteForReads(requestUser, reason: entry)

        await removeDeletedTweetLocally(deletedTweetId)

        // Deleting a retweet/quote must unlink it from the original tweet's retweet list,
        // otherwise the original keeps counting a retweet that no longer exists.
        if let retweetOrigin {
            await decrementRetweetCountOfOriginal(
                originalTweetId: retweetOrigin.0,
                originalAuthorId: retweetOrigin.1,
                retweetId: deletedTweetId
            )
        }

        // Only decrement tweetCount if appUser is the author
        // When deleting others' tweets from main feed, it's a local copy removal — not own tweet
        if tweetAuthorId == appUserMid {
            await MainActor.run {
                let currentCount = self.appUser.tweetCount ?? 0
                self.appUser.tweetCount = max(0, currentCount - 1)
                hproseDebug("DEBUG: [deleteTweet] Updated appUser.tweetCount to \(self.appUser.tweetCount ?? 0)")
            }
        } else {
            hproseWarning("DEBUG: [deleteTweet] Skipping tweetCount decrement — tweet authored by \(tweetAuthorId), not appUser")
        }

        // Refresh appUser from server to get updated tweetCount and other properties
        try? await self.refreshAppUserFromServer()

        return deletedTweetId
    }

    /// Unlink a deleted retweet from its original tweet and bring the original's
    /// retweetCount back in line with the server.
    ///
    /// The original tweet may not be in memory (its retweet can be shown in a feed the
    /// original never appeared in), so it is fetched when needed. The live singleton is
    /// updated in place so every view bound to it — feed cell, detail view, profile —
    /// reflects the new count.
    private func decrementRetweetCountOfOriginal(
        originalTweetId: String,
        originalAuthorId: String,
        retweetId: String
    ) async {
        let originalTweet: Tweet?
        if let inMemory = await MainActor.run(body: { Tweet.getInstance(for: originalTweetId) }) {
            originalTweet = inMemory
        } else {
            originalTweet = try? await getTweet(tweetId: originalTweetId, authorId: originalAuthorId)
        }
        guard let originalTweet else {
            hproseWarning("⚠️ [deleteTweet] Original tweet \(originalTweetId) unavailable — retweetCount not decremented")
            return
        }

        // Optimistic decrement so the UI reacts immediately; the server response below
        // overwrites it with the authoritative count.
        let previousCount = await MainActor.run { () -> Int? in
            let previous = originalTweet.retweetCount
            originalTweet.retweetCount = max(0, (previous ?? 0) - 1)
            return previous
        }

        guard let updatedTweet = await updateRetweetCount(
            tweet: originalTweet,
            retweetId: retweetId,
            direction: false
        ) else {
            // Server never unlinked the retweet — put the count back rather than leave
            // the UI showing a decrement that did not happen.
            await MainActor.run { originalTweet.retweetCount = previousCount }
            hproseWarning("⚠️ [deleteTweet] retweet_removed failed for original \(originalTweetId) — restored retweetCount")
            return
        }

        await MainActor.run {
            TweetCacheManager.shared.saveTweet(updatedTweet, userId: updatedTweet.authorId)
            hproseDebug("DEBUG: [deleteTweet] Original \(originalTweetId) retweetCount now \(updatedTweet.retweetCount ?? 0)")
        }
    }

    @MainActor
    private func removeDeletedTweetLocally(_ tweetId: String) {
        TweetDeletionRegistry.shared.markDeleted(tweetId)
        let inMemoryPureRetweetIds = Tweet.getAllInstances().values.compactMap { tweet -> String? in
            guard tweet.originalTweetId == tweetId,
                  tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                  tweet.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                  tweet.attachments?.isEmpty ?? true else {
                return nil
            }
            return tweet.mid
        }
        let deletedTweetIds = Set(
            TweetCacheManager.shared.deleteTweet(mid: tweetId) + inMemoryPureRetweetIds
        )
        for deletedTweetId in deletedTweetIds {
            TweetDeletionRegistry.shared.markDeleted(deletedTweetId)
            Tweet.clearInstance(mid: deletedTweetId)
            NotificationCenter.default.post(
                name: .tweetDeleted,
                object: nil,
                userInfo: ["tweetId": deletedTweetId, "confirmed": true]
            )
        }
    }

    /// TweetWeb passes `appuserid: target author` so the server author check passes.
    func updateTweetContent(tweetId: String, content: String, tweetAuthorId: String) async throws {
        // Phase A (demotion prep): snapshot @MainActor admin check + appUser.mid.
        let (isAdmin, appUserMid) = await MainActor.run { (Gadget.isResearchAdminUser(self.appUser), self.appUser.mid) }
        guard isAdmin else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not available in this distribution"])
        }
        // Execute mutation using the original author's writable client context so
        // the update is performed in the author's name, not the admin's.
        let requestUser: User
        if tweetAuthorId == appUserMid {
            requestUser = await MainActor.run { self.appUser }
        } else {
            guard let author = try await fetchUser(tweetAuthorId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch tweet author", comment: "Author fetch error")])
            }
            requestUser = author
        }

        let entry = "update_tweet"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "appuserid": tweetAuthorId,
            "tweetid": tweetId,
            "content": content
        ]
        // Mutation path should use writable client, same as other write APIs.
        _ = try await requestUser.resolveWritableUrl()
        guard let client = await requestUser.writableClient(timeout: 30) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Writable client not available", comment: "Writable client error")])
        }

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        _ = try Self.unwrapV2Response(rawResponse)
        await adoptWriteRouteForReads(requestUser, reason: entry)
    }
    
    func addComment(_ comment: Tweet, to tweet: Tweet) async throws -> Tweet? {
        // add_comment is non-idempotent: a retry after a lost/late response can create
        // a second comment even though the first request already succeeded on the node.
        // Surface ambiguous failures to the caller instead of automatically resubmitting.
            // Comments are stored on the tweet author's node (same as get_comments / fetchComments).
            let existingAuthor = await MainActor.run { tweet.author }
            let author: User
            if let existingAuthor {
                author = existingAuthor
            } else {
                guard let fetchedAuthor = try await self.fetchUser(tweet.authorId) else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch author to post comment", comment: "Comment author error")])
                }
                author = fetchedAuthor
                await MainActor.run {
                    tweet.author = author
                }
            }

            // Phase A (demotion prep): snapshot @MainActor author + appUser reads.
            let appUserMid = await MainActor.run { self.appUser.mid }
            let isBlocked = await MainActor.run { author.isUserBlacklisted(appUserMid) }
            if isBlocked {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot comment on this tweet because you are blocked by the author", comment: "Comment blocked error")])
            }

            let authorSnap = await MainActor.run { UserRecord(user: author) }
            let writableUrl = try await author.resolveWritableUrl()
            guard let commentClient = await author.writableClient(timeout: 15) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author's writable client not initialized", comment: "Client initialization error")])
            }

            hproseDebug("DEBUG: [addComment] add_comment via parent's author writableUrl (\(writableUrl.absoluteString)), tweet hostid: \(authorSnap.hostIds?.first ?? "nil")")

            // Encode the comment and read tweet.mid on the main actor (Tweet is @MainActor).
            let (commentJSON, tweetMid): (String, String) = try await MainActor.run {
                comment.author = nil
                let data = try JSONEncoder().encode(comment)
                return (String(data: data, encoding: .utf8) ?? "", tweet.mid)
            }
            let params: [String: Any] = [
                "aid": self.appId,
                "ver": "last",
                "version": "v2",
                "hostid": authorSnap.hostIds?.first as Any,
                "comment": commentJSON,
                "tweetid": tweetMid,
                "tweetauthorid": authorSnap.mid
            ]
            let entry = "add_comment"
            let rawResponse = await self.invokeRunMApp(using: commentClient, entry: entry, params: params)
            
            if let err = rawResponse as? Error {
                hproseError("DEBUG: [addComment] invoke returned error: \(err)")
                throw err
            }
            
            let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            guard let response = Self.asStringKeyedDictionary(unwrappedResponse) else {
                hproseWarning("DEBUG: [addComment] Unexpected response type: \(Swift.type(of: unwrappedResponse)) value: \(String(describing: unwrappedResponse))")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            guard let commentId = Self.stringField(response, keys: ["mid", "commentId"]) else {
                hproseDebug("DEBUG: [addComment] Missing mid/commentId in response keys: \(Array(response.keys))")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            guard let count = Self.intField(response, key: "count") else {
                hproseDebug("DEBUG: [addComment] Missing or unparsable count in response keys: \(Array(response.keys))")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
            }
            
            await adoptWriteRouteForReads(author, reason: entry)
            await MainActor.run {
                comment.mid = commentId
                comment.author = appUser
                tweet.commentCount = count
            }
            // Cache the updated tweet under its authorId, not appUser.mid
            // This ensures original tweets are cached under their author, not the current user
            await MainActor.run { TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId) }

            // Check if retweetid is present and create a new tweet
            if let retweetId = response["retweetid"] as? String, !retweetId.isEmpty {
                hproseDebug("[HproseInstance] Retweet ID received: \(retweetId)")

                // Create a new tweet with the comment's content and original tweet ID using singleton
                // Register it in the singleton cache (even though we return the original comment)
                _ = await MainActor.run {
                    Tweet.getInstance(
                        mid: retweetId,
                        authorId: self.appUser.mid,
                        content: comment.content,
                        timestamp: comment.timestamp,
                        originalTweetId: tweet.mid,
                        originalAuthorId: tweet.authorId,
                        author: self.appUser,
                        attachments: comment.attachments
                    )
                }
                
                // add_comment.js creates this quote tweet itself when the submitted comment
                // carries originalTweetId, and that path never touches the original's retweet
                // list. Count it here so a quote is counted no matter which side created it —
                // the key is the quote's own mid, matching what deleteTweet later removes.
                if let updatedOriginal = await updateRetweetCount(
                    tweet: tweet,
                    retweetId: retweetId,
                    direction: true
                ) {
                    await MainActor.run {
                        TweetCacheManager.shared.saveTweet(updatedOriginal, userId: updatedOriginal.authorId)
                    }
                }

                // For comments, we should NOT post newTweetCreated notification
                // Comments should only appear in comment sections, not in the main feed
                hproseDebug("[HproseInstance] Comment created with retweetId: \(retweetId), but NOT posting newTweetCreated notification")
                
                // Only post the comment notification on main thread
                await MainActor.run {
                    hproseDebug("[HproseInstance] Posting newCommentAdded notification")
                    hproseDebug("[HproseInstance] New comment mid: \(comment.mid)")
                    hproseDebug("[HproseInstance] New retweet ID: \(retweetId)")
                    hproseDebug("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                    
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
                    hproseDebug("[HproseInstance] No retweet ID, posting only newCommentAdded notification")
                    hproseDebug("[HproseInstance] New comment mid: \(comment.mid)")
                    hproseDebug("[HproseInstance] Parent tweet mid: \(tweet.mid)")
                    
                    NotificationCenter.default.post(
                        name: .newCommentAdded,
                        object: nil,
                        userInfo: ["comment": comment, "parentTweetId": tweet.mid]
                    )
                }
                
                return comment
            }
    }

    // both author and tweet author can delete this comment
    func deleteComment(parentTweet: Tweet, commentId: String) async throws -> [String: Any]? {
        // Phase A (demotion prep): snapshot @MainActor parentTweet.author.
        let existingAuthor = await MainActor.run { parentTweet.author }
        let author: User
        if let existingAuthor {
            author = existingAuthor
        } else {
            guard let fetchedAuthor = try await fetchUser(parentTweet.authorId) else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot fetch author to delete comment", comment: "Author fetch error")])
            }
            author = fetchedAuthor
            await MainActor.run {
                parentTweet.author = author
            }
        }

        let entry = "delete_comment"
        let (authorSnap, appUserMid, parentTweetMid) = await MainActor.run {
            (UserRecord(user: author), self.appUser.mid, parentTweet.mid)
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": parentTweetMid,
            "hostid": authorSnap.hostIds?.first as Any,
            "commentid": commentId,
            "appuserid": appUserMid
        ]
        let writableUrl = try await author.resolveWritableUrl()
        guard let client = await author.writableClient(timeout: 15) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Author's writable client not initialized", comment: "Client initialization error")])
        }
        hproseDebug("DEBUG: [deleteComment] delete_comment via parent's author writableUrl (\(writableUrl.absoluteString))")
        
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        if let err = rawResponse as? Error {
            throw err
        }
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        guard let response = Self.asStringKeyedDictionary(unwrappedResponse) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        guard let deletedCommentId = Self.stringField(response, keys: ["commentId"]) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }
        
        guard let count = Self.intField(response, key: "count") else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid response format from server", comment: "Server response error")])
        }

        await adoptWriteRouteForReads(author, reason: entry)
        return [
            "commentId": deletedCommentId,
            "count": count
        ]
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil,
        noResample: Bool = false,
        progressCallback: (@Sendable (String, Int) -> Void)? = nil
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
        /// 1. Normalize to 720p reference bitrate (preserving original resolution if lower)
        /// 2. Route based on normalized size and resolution:
        ///    - ≤ 50MB: Progressive video route
        ///    - > 50MB: HLS conversion based on resolution
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
            progressCallback: (@Sendable (String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
            
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
                hproseDebug("Original video resolution: \(info.displayWidth)x\(info.displayHeight) (\(originalVideoResolution ?? 0)p)")
            }
            
            // Step 2: Always normalize videos (>720p scales to 720p; bitrate is never raised above the source)
            if let origRes = originalVideoResolution {
                if origRes <= 720 {
                    hproseDebug("📹 [VIDEO UPLOAD] Resolution \(origRes)p ≤ 720p: will normalize with original resolution")
                } else {
                    hproseDebug("📹 [VIDEO UPLOAD] Resolution \(origRes)p > 720p: will normalize to 720p without raising source bitrate")
                }
            } else {
                hproseDebug("📹 [VIDEO UPLOAD] Could not detect resolution: will normalize (defaulting to 720p if needed)")
            }
            
            hproseDebug("========== FIRST NORMALIZATION (Standardization) ==========")
            hproseDebug("📹 [VIDEO UPLOAD] Original video: \(String(format: "%.1f", Double(data.count) / (1024 * 1024)))MB")
            hproseDebug("📹 [VIDEO UPLOAD] Purpose: Unified format for 50MB routing decision")
            
            progressCallback?("Normalizing video...", 10)
            let normalizedFileName = "normalized_\(UUID().uuidString).mp4"
            let normalizedVideoURL = tempDir.appendingPathComponent(normalizedFileName)
            
            
            let normalizationSuccess = await MediaProcessor.normalizeToReferenceBitrate(
                inputURL: originalVideoURL,
                outputURL: normalizedVideoURL,
                progressCallback: progressCallback
            )
            hproseDebug("==========================================================")
            
            guard normalizationSuccess else {
                hproseError("❌ [VIDEO UPLOAD] Video normalization failed, falling back to original video")
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
                hproseDebug("📹 [VIDEO UPLOAD] Normalized video resolution: \(info.displayWidth)x\(info.displayHeight) (\(videoResolution)p)")
            } else {
                // Fallback to original resolution if detection fails
                videoResolution = originalVideoResolution ?? 720
                hproseDebug("📹 [VIDEO UPLOAD] Could not detect normalized video resolution, using original: \(videoResolution)p")
            }
            
            let videoFileName = normalizedFileName
            hproseDebug("📹 [VIDEO UPLOAD] Normalized video size: \(String(format: "%.1f", Double(videoSize) / (1024 * 1024)))MB")
            
            // Step 3: Route based on video size
            let videoSizeMB = Double(videoSize) / (1024 * 1024)
            hproseDebug("📹 [VIDEO UPLOAD] Normalized video size: \(String(format: "%.1f", videoSizeMB))MB (\(videoSize) bytes)")
            
            if videoSize <= Constants.PROGRESSIVE_VIDEO_THRESHOLD_BYTES {
                // ≤ 50MB: progressive video route
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
            } else {
                // > 50MB: Need HLS conversion - check if cloud drive is available
                hproseDebug("📹 [VIDEO UPLOAD] Size > 50MB: will use HLS conversion route")
                let cloudPort = await MainActor.run { appUser.cloudDrivePort }
                guard cloudPort > 0 else {
                    hproseWarning("⚠️ [VIDEO UPLOAD] No cloud drive configured, falling back to progressive video")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .videoUploadFormatWarning,
                            object: nil,
                            userInfo: [
                                "message": NSLocalizedString(
                                    "Cloud drive is not configured. This video will be uploaded as a regular progressive video.",
                                    comment: "Warning shown when HLS upload falls back to progressive video"
                                )
                            ]
                        )
                    }
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
                hproseDebug("📹 [VIDEO UPLOAD] Checking cloud drive service availability (port: \(cloudPort))...")
                
                // Resolve writableUrl once for all video HTTP operations
                _ = try await appUser.resolveWritableUrl()
                let isCloudDriveAvailable = await MediaProcessor.checkCloudDriveServiceAvailability(appUser: appUser)
                
                guard isCloudDriveAvailable else {
                    hproseWarning("⚠️ [VIDEO UPLOAD] Cloud drive service not available, falling back to progressive video")
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
                    hproseDebug("📹 [VIDEO UPLOAD] Resolution \(videoResolution)p > 480p: using HLS with \(min(videoResolution, 720))p + 480p variants")
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
                    hproseDebug("📹 [VIDEO UPLOAD] Resolution \(videoResolution)p ≤ 480p: using HLS with 480p variant only")
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
            let typeId = typeIdentifier.lowercased()

            // Check type identifier first
            if typeId.hasPrefix("public.image") || typeId.contains("image") {
                return .image
            } else if typeId.hasPrefix("public.movie") ||
                        typeId.hasPrefix("public.video") ||
                        typeId.contains("video") ||
                        typeId.contains("movie") ||
                        typeId.contains("quicktime") ||
                        typeId.contains("mpeg-4") ||
                        typeId.contains("mpeg4") ||
                        typeId.contains("mp4") ||
                        typeId.contains("m4v") ||
                        typeId.contains("mov") ||
                        typeId.contains("avi") ||
                        typeId.contains("mkv") ||
                        typeId.contains("webm") {
                return .video
            } else if typeId.hasPrefix("public.audio") || typeId.contains("audio") {
                return .audio
            } else if typeId == "public.composite-content" {
                return .pdf
            } else if typeId == "public.zip-archive" {
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
                hproseDebug("Detected type via file header: \(detectedType.rawValue)")
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
            progressCallback: (@Sendable (String, Int) -> Void)? = nil
        ) async throws -> (MimeiFileType?, String?) {
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
                hproseDebug("DEBUG: [HLS CONVERSION] FFmpeg detected: \(info.width)x\(info.height), display: \(info.displayWidth)x\(info.displayHeight), rotation: \(info.rotation)°, aspect ratio: \(videoAspectRatio!)")
            } else {
                videoAspectRatio = await MediaProcessor.getVideoAspectRatioWithFallback(from: data)
                hproseWarning("DEBUG: [HLS CONVERSION] Fallback to AVFoundation, aspect ratio: \(videoAspectRatio ?? 0.0)")
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
                hproseError("DEBUG: Video conversion failed: \(conversionResult.errorMessage ?? "Unknown error")")
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
                hproseDebug("DEBUG: [MEMORY MONITORING] HLS directory size: \(hlsSize / 1024)KB")
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

            // Upload compressed HLS to server with retry logic
            var lastError: Error?
            var jobId: String?
            let maxRetries = 2
            
            for attempt in 1...maxRetries {
                do {
                    // Resolve writableUrl (may use cached or resolve fresh)
                    _ = try await appUser.resolveWritableUrl()
                    let writableUrlDescription = await MainActor.run {
                        appUser.writableUrl?.absoluteString ?? "nil"
                    }
                    hproseDebug("DEBUG: [HLS Upload] Attempt \(attempt)/\(maxRetries) - writableUrl: \(writableUrlDescription)")
                    
                    jobId = try await MediaProcessor.uploadCompressedHLS(
                        compressedURL: compressedURL,
                        fileName: "\(originalFileName)_hls.zip",
                        referenceId: referenceId,
                        appUser: appUser
                    )
                    break // Success - exit retry loop
                    
                } catch let error {
                    lastError = error
                    let nsError = error as NSError
                    hproseError("ERROR: [HLS Upload] Attempt \(attempt)/\(maxRetries) failed - domain: \(nsError.domain), code: \(nsError.code)")
                    
                    if attempt >= maxRetries {
                        hproseError("ERROR: [HLS Upload] All retry attempts exhausted")
                        throw error
                    }
                    
                    // Drop the last resolved URL before retrying; the next attempt resolves hostIds[0] again.
                    await MainActor.run {
                        hproseWarning("DEBUG: [HLS Upload] Clearing last writableUrl before retry")
                        appUser.writableUrl = nil
                    }
                    
                    // Small delay before retry
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
            
            guard let jobId = jobId else {
                throw lastError ?? NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "HLS upload failed"])
            }

            // Force memory cleanup after upload
            autoreleasepool {}

            // Log memory usage after upload
            VideoConversionService.shared.logMemoryUsage("after HLS upload")

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
            hproseDebug("DEBUG: [HLS UPLOAD] Cleaning up temporary files...")

            // Force memory cleanup before file deletion
            autoreleasepool {}

            // Remove HLS directory and compressed file
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: compressedURL)

            // Final memory cleanup
            autoreleasepool {}

            hproseDebug("DEBUG: [HLS UPLOAD] Temporary files cleaned up")
            VideoConversionService.shared.logMemoryUsage("after cleanup")
            
            // Return (placeholder MimeiFileType, jobId)
            // The jobId will be used for background polling
            return (mimeiFileType, jobId)
        }
        
        /// Check if cloud drive service is available at clouddriveport
        private static func checkCloudDriveServiceAvailability(appUser: User) async -> Bool {
            let userSnapshot = await MainActor.run {
                (isGuest: appUser.isGuest, writableUrl: appUser.writableUrl, cloudDrivePort: appUser.cloudDrivePort)
            }
            guard !userSnapshot.isGuest else {
                hproseWarning("Cloud drive check skipped for guest user - using fallback")
                return false
            }
            
            do {
                guard let writableUrl = userSnapshot.writableUrl,
                      let host = writableUrl.host,
                      userSnapshot.cloudDrivePort > 0,
                      let cloudBaseURL = URL(string: "http://\(host):\(userSnapshot.cloudDrivePort)") else {
                    return false
                }
                
                let healthCheckURL = cloudBaseURL.appendingPathComponent("health")
                
                var request = URLRequest(url: healthCheckURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 3.0
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    hproseDebug("Cloud drive service unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    return false
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "ok" {
                    return true
                } else {
                    hproseError("Cloud drive service health check failed - invalid response")
                    return false
                }
            } catch {
                let nsError = error as NSError
                hproseWarning("Cloud drive service unavailable - using MP4 fallback (domain: \(nsError.domain), code: \(nsError.code))")
                return false
            }
        }
        
        
        /// Normalize video to 720p reference bitrate, preserving original resolution if lower
        private static func normalizeToReferenceBitrate(
            inputURL: URL,
            outputURL: URL,
            progressCallback: (@Sendable (String, Int) -> Void)? = nil
        ) async -> Bool {
            
            return await withCheckedContinuation { continuation in
                // Get video info to check original resolution and bitrate
                Task(priority: .high) {
                    // Try to get video info with AVFoundation first
                    var videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
                    
                    // If AVFoundation fails, try with a temporary file with proper extension
                    if videoInfo == nil {
                        hproseError("AVFoundation probe failed, trying with temporary file...")
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
                            }
                            
                            // Clean up temp file
                            try? FileManager.default.removeItem(at: tempDir)
                        } catch {
                            hproseError("Failed to get video info via AVFoundation: \(error)")
                            try? FileManager.default.removeItem(at: tempDir)
                        }
                    }
                    
                    let sourceBitrateKbps = try? await HLSVideoProcessor.shared.getSourceVideoBitrate(filePath: inputURL.path)
                    
                    // Get original resolution
                    let originalWidth: Int?
                    let originalHeight: Int?
                    if let info = videoInfo {
                        originalWidth = info.displayWidth
                        originalHeight = info.displayHeight
                    } else {
                        originalWidth = nil
                        originalHeight = nil
                    }
                    
                    // Determine if we need to scale and calculate target bitrate
                    let needsScaling: Bool
                    let scaleFilter: String
                    let targetBitrateKbps: Int
                    let videoResolution: Int
                    
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
                            // Resolution > 720p: scale to 720p, capped at the source bitrate.
                            if aspectRatio < 1.0 {
                                // Portrait: scale to target width
                                scaleFilter = "scale=720:-2"
                            } else {
                                // Landscape: scale to target height
                                scaleFilter = "scale=-2:720"
                            }
                            let referenceBitrateKbps = Int(VideoConversionService.reference720pBitrate)
                            if let sourceBitrateKbps, sourceBitrateKbps > 0, sourceBitrateKbps < referenceBitrateKbps {
                                targetBitrateKbps = sourceBitrateKbps
                            } else {
                                targetBitrateKbps = referenceBitrateKbps
                            }
                        } else if videoResolution < 720, let sourceBitrateKbps, sourceBitrateKbps > 0 {
                            // Sub-720p sources stay at their original bitrate instead of being raised by the 720p reference curve.
                            scaleFilter = ""
                            targetBitrateKbps = sourceBitrateKbps
                        } else {
                            // 720p sources keep the reference curve; bitrate detection can vary across formats.
                            // If source bitrate is unavailable for sub-720p, fall back to the previous pixel-based estimate.
                            scaleFilter = ""
                            // Calculate proportional bitrate based on pixel count
                            // Formula: bitrate = max(minBitrate, (pixel_count / REFERENCE_720P_PIXELS) * reference720pBitrate)
                            // REFERENCE_720P_PIXELS = 1280 × 720 = 921,600
                            let pixelCount = width * height
                            let REFERENCE_720P_PIXELS = 921600
                            let calculatedBitrate = Int((Double(pixelCount) / Double(REFERENCE_720P_PIXELS)) * VideoConversionService.reference720pBitrate)
                            let estimatedBitrateKbps = max(VideoConversionService.minBitrate, calculatedBitrate)
                            if let sourceBitrateKbps, sourceBitrateKbps > 0, sourceBitrateKbps < estimatedBitrateKbps {
                                targetBitrateKbps = sourceBitrateKbps
                            } else {
                                targetBitrateKbps = estimatedBitrateKbps
                            }
                        }
                    } else {
                        // Fallback: assume scaling needed
                        videoResolution = 720
                        needsScaling = true
                        scaleFilter = "scale=-2:720"
                        targetBitrateKbps = Int(VideoConversionService.reference720pBitrate)
                    }
                    
                    hproseDebug("📹 [NORMALIZE] Original: \(originalWidth ?? 0)x\(originalHeight ?? 0), target bitrate: \(targetBitrateKbps)k, scaling: \(needsScaling ? "YES (to 720p)" : "NO (keep original resolution)")")
                    
                    // Build FFmpeg command
                    var command: String
                    if needsScaling && !scaleFilter.isEmpty {
                        command = """
                            -i "\(inputURL.path)" \
                            -c:v h264_videotoolbox \
                            -allow_sw 1 \
                            -profile:v main \
                            -level 4.0 \
                            -pix_fmt yuv420p \
                            -vf "\(scaleFilter)" \
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
                            -c:v h264_videotoolbox \
                            -allow_sw 1 \
                            -profile:v main \
                            -level 4.0 \
                            -pix_fmt yuv420p \
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
                    
                    DynamicFFmpegKit.shared.executeAsync(command) { session in
                        guard let session = session else {
                            hproseError("ERROR: Failed to create FFmpeg session for normalization")
                            continuation.resume(returning: false)
                            return
                        }
                        
                        let success = session.isSuccess
                        
                        if success {
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                continuation.resume(returning: true)
                            } else {
                                hproseError("ERROR: Normalized output file missing")
                                continuation.resume(returning: false)
                            }
                        } else {
                            hproseError("ERROR: FFmpeg normalization failed (code: \(session.returnCodeDescription))")
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
        }
        
        /// Compress HLS directory into a zip file (memory-optimized streaming approach)
        private static func compressHLSDirectory(hlsDirectory: URL, originalFileName: String, progressCallback: (@Sendable (String, Int) -> Void)? = nil) async throws -> URL {
            let zipFileName = "\(originalFileName)_hls.zip"
            let tempDir = hlsDirectory.deletingLastPathComponent()
            let zipURL = tempDir.appendingPathComponent(zipFileName)

            hproseDebug("DEBUG: [ZIP CREATION] HLS directory: \(hlsDirectory.path)")
            hproseDebug("DEBUG: [ZIP CREATION] Zip file will be created at: \(zipURL.path)")

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

                        hproseDebug("DEBUG: [ZIP CREATION] Found \(fileURLs.count) files, total size: \(totalSize / 1024)KB")
                        
                        // Force memory cleanup before zip creation
                        autoreleasepool {}
                        progressCallback?("Creating ZIP file...", 10)

                        // Create ZIP file directly without copying directory
                        // Use parent directory as base so "hls/" is included in ZIP structure
                        let baseDirectory = hlsDirectory.deletingLastPathComponent()
                        hproseDebug("DEBUG: [ZIP CREATION] Base directory: \(baseDirectory.path)")
                        hproseDebug("DEBUG: [ZIP CREATION] HLS directory name: \(hlsDirectory.lastPathComponent)")
                        try MediaProcessor.createZipFile(from: fileURLs, relativeTo: baseDirectory, to: zipURL, progressCallback: progressCallback)

                        // Verify zip file was created and get its size
                        if let zipAttributes = try? FileManager.default.attributesOfItem(atPath: zipURL.path),
                           let zipSize = zipAttributes[.size] as? Int64 {
                            hproseDebug("DEBUG: [ZIP CREATION] Zip file size: \(zipSize / 1024)KB (original: \(totalSize / 1024)KB)")

                            // Log memory usage after zip creation
                            VideoConversionService.shared.logMemoryUsage("after zip creation")

                            continuation.resume(returning: zipURL)
                        } else {
                            throw NSError(domain: "ZipCreation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify zip file creation"])
                        }

                    } catch {
                        hproseError("DEBUG: [ZIP CREATION] Zip creation failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        /// Create ZIP file from array of file URLs using system ZIP functionality (memory efficient)
        private static func createZipFile(from fileURLs: [URL], relativeTo baseURL: URL, to zipURL: URL, progressCallback: (@Sendable (String, Int) -> Void)? = nil) throws {
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
                            hproseDebug("DEBUG: [ZIP CREATION] File \(processedCount + 1): relativePath=\(relativePath), fullPath=\(fileURL.path)")
                        }

                        // Create a temporary directory structure that mirrors the relative path
                        let tempFileDir = tempZipDir.appendingPathComponent(relativePath).deletingLastPathComponent()
                        try fileManager.createDirectory(at: tempFileDir, withIntermediateDirectories: true)

                        let tempFileURL = tempZipDir.appendingPathComponent(relativePath)

                        // Copy file to temporary location with correct relative structure
                        try fileManager.copyItem(at: fileURL, to: tempFileURL)
                        
                        // Verify file was copied
                        if !fileManager.fileExists(atPath: tempFileURL.path) {
                            hproseError("DEBUG: [ZIP CREATION] WARNING: File copy verification failed for \(relativePath)")
                        }

                        processedCount += 1
                        if processedCount % 5 == 0 || processedCount == totalFiles {
                            let progressPercent = 10 + Int((Double(processedCount) / Double(totalFiles)) * 15.0)
                            progressCallback?("Preparing files... (\(processedCount)/\(totalFiles))", progressPercent)
                        }

                    } catch {
                        hproseError("DEBUG: [ZIP CREATION] Error processing file \(fileURL.lastPathComponent): \(error)")
                        // Continue with other files rather than failing completely
                    }
                }
            }

            progressCallback?("Creating ZIP archive...", 25)

            // Verify tempZipDir structure before zipping
            hproseDebug("DEBUG: [ZIP CREATION] Verifying tempZipDir structure: \(tempZipDir.path)")
            let contents = try? fileManager.contentsOfDirectory(at: tempZipDir, includingPropertiesForKeys: [.isDirectoryKey])
            hproseDebug("DEBUG: [ZIP CREATION] tempZipDir top-level contents: \(contents?.map { $0.lastPathComponent } ?? [])")
            
            // Find the "hls" subdirectory in tempZipDir
            let hlsSubdir = tempZipDir.appendingPathComponent("hls")
            var isDirectory: ObjCBool = false
            let hlsExists = fileManager.fileExists(atPath: hlsSubdir.path, isDirectory: &isDirectory) && isDirectory.boolValue
            
            // Determine which directory to zip
            // If hls subdirectory exists, zip it directly (ZIP will contain hls/720p/, hls/480p/, etc.)
            // If not, zip tempZipDir (structure might be different)
            let dirToZip = hlsExists ? hlsSubdir : tempZipDir
            hproseDebug("DEBUG: [ZIP CREATION] Zipping directory: \(dirToZip.path) (hls subdir exists: \(hlsExists))")

            // Use NSFileCoordinator to create ZIP from the directory
            // When zipping a directory with .forUploading, the ZIP will contain that directory's name
            // So if we zip "hls", the ZIP will have "hls/" at the root, which is what the server expects
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var localError: NSError?

            coordinator.coordinate(readingItemAt: dirToZip, options: [.forUploading], error: &localError) { (tempZipURL) in
                do {
                    hproseDebug("DEBUG: [ZIP CREATION] NSFileCoordinator created temporary ZIP at: \(tempZipURL.path)")
                    
                    // Verify temporary ZIP exists and has content
                    if let tempAttributes = try? fileManager.attributesOfItem(atPath: tempZipURL.path),
                       let tempSize = tempAttributes[.size] as? Int64 {
                        hproseDebug("DEBUG: [ZIP CREATION] Temporary ZIP size: \(tempSize / 1024)KB")
                        
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
                } catch {
                    hproseError("DEBUG: [ZIP CREATION] Failed to create final zip file: \(error)")
                    coordinatorError = error as NSError
                }
            }

            // Check for errors from the coordinator itself
            if let error = localError ?? coordinatorError {
                // Clean up temporary directory
                try? fileManager.removeItem(at: tempZipDir)
                hproseError("DEBUG: [ZIP CREATION] File coordinator error: \(error)")
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
                hproseDebug("DEBUG: [ZIP CREATION] Final ZIP size: \(zipSize / 1024)KB")
                
                if zipSize == 0 {
                    throw NSError(domain: "ZipCreation", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "ZIP file is empty"])
                }
                
                // Verify ZIP file is readable (basic validation)
                if zipSize < 100 {
                    hproseWarning("DEBUG: [ZIP CREATION] WARNING: ZIP file seems too small (\(zipSize) bytes)")
                }
            } else {
                throw NSError(domain: "ZipCreation", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Cannot read ZIP file attributes"])
            }
            
            // Log ZIP file path for server debugging
            hproseDebug("DEBUG: [ZIP CREATION] ZIP file ready for upload: \(zipURL.lastPathComponent)")

            progressCallback?("ZIP creation completed", 30)
        }

        /// Upload compressed HLS to server via process-zip route
        private static func uploadCompressedHLS(
            compressedURL: URL,
            fileName: String,
            referenceId: String?,
            appUser: User
        ) async throws -> String {
            let userSnapshot = await MainActor.run {
                (writableUrl: appUser.writableUrl, cloudDrivePort: appUser.cloudDrivePort)
            }
            guard let writableUrl = userSnapshot.writableUrl else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Writable URL not available"])
            }
            
            // Get host from writableUrl - no fallback, must succeed
            guard let host = writableUrl.host else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not get host from writable URL"])
            }
            
            // Get cloud drive port - no fallback, must be configured
            guard userSnapshot.cloudDrivePort > 0 else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cloud drive port not configured"])
            }
            
            guard let cloudBaseURL = URL(string: "http://\(host):\(userSnapshot.cloudDrivePort)") else {
                throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct cloud drive URL"])
            }
            let uploadURL = cloudBaseURL.appendingPathComponent("process-zip").absoluteString
            
            hproseDebug("DEBUG: Constructed process-zip URL: \(uploadURL)")
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

            hproseDebug("DEBUG: [UPLOAD] Preparing to upload zip file, size: \(fileSize / 1024)KB")

            // For very large files (>50MB), use file-based streaming to avoid memory issues
            let maxMemoryEfficientSize = Int64(50 * 1024 * 1024) // 50MB
            if fileSize > maxMemoryEfficientSize {
                hproseDebug("DEBUG: [UPLOAD] Large zip file (\(fileSize / (1024 * 1024))MB) - using file-based streaming upload")
                VideoConversionService.shared.logMemoryUsage("before large file upload")
            }

            // Create multipart form data with a simple boundary
            let boundary = "----WebKitFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let safeMultipartFileName = fileName
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            
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
                multipartFileHandle.write("Content-Disposition: form-data; name=\"zipFile\"; filename=\"\(safeMultipartFileName)\"\r\n".data(using: .utf8)!)
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
                hproseDebug("DEBUG: [UPLOAD] Multipart form file created, size: \(multipartFileSize / (1024 * 1024))MB")
                hproseDebug("DEBUG: [UPLOAD] ZIP file streamed in chunks, total: \(bytesWritten / (1024 * 1024))MB")
                hproseDebug("DEBUG: [UPLOAD] Expected multipart size: ~\(fileSize + 500) bytes (ZIP + headers)")
                
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
                        } else {
                            hproseWarning("DEBUG: [UPLOAD] WARNING: Multipart file header doesn't match expected boundary")
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
                            } else {
                                hproseError("DEBUG: [UPLOAD] ERROR: ZIP file signature NOT found in multipart form at offset \(zipStartOffset)")
                                hproseDebug("DEBUG: [UPLOAD] First 4 bytes at ZIP start: \(zipHeader.map { String(format: "%02x", $0) }.joined())")
                            }
                        }
                    } catch {
                        hproseDebug("DEBUG: [UPLOAD] Validation error (non-critical): \(error)")
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
                body.append("Content-Disposition: form-data; name=\"zipFile\"; filename=\"\(safeMultipartFileName)\"\r\n".data(using: .utf8)!)
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
            
            // Match the server upload window; /process-zip now responds after the ZIP upload finishes.
            request.timeoutInterval = 6 * 60 * 60
            
            hproseDebug("DEBUG: [UPLOAD] Sending request to: \(url)")
            hproseDebug("DEBUG: [UPLOAD] Using file-based upload: \(shouldUseFileBasedUpload)")

            // Upload from file using uploadTask to avoid loading entire file into memory
            if fileSize > maxMemoryEfficientSize {
                VideoConversionService.shared.logMemoryUsage("before file-based upload")
            }
            
            let uploadConfig = URLSessionConfiguration.default
            uploadConfig.timeoutIntervalForRequest = 6 * 60 * 60
            uploadConfig.timeoutIntervalForResource = 6 * 60 * 60
            let uploadSession = URLSession(configuration: uploadConfig)
            let (responseData, response) = try await uploadSession.upload(for: request, fromFile: tempMultipartFile)

            if fileSize > maxMemoryEfficientSize {
                VideoConversionService.shared.logMemoryUsage("after file-based upload")
            }

            hproseDebug("DEBUG: [UPLOAD] Received response with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")

            if let httpResponse = response as? HTTPURLResponse {
                hproseDebug("DEBUG: [UPLOAD] Response headers: \(httpResponse.allHeaderFields)")

                if httpResponse.statusCode == 200 {
                    // Parse response to get job ID
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        hproseDebug("DEBUG: process-zip upload response: \(responseString)")

                        // Parse JSON response to extract job ID
                        if let jsonData = responseString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let jobId = json["jobId"] as? String {
                            hproseDebug("DEBUG: Extracted job ID from response: \(jobId)")
                            return jobId
                        } else {
                            // Fallback: try to extract job ID from response string
                            let trimmedResponse = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
                            hproseWarning("DEBUG: Using fallback job ID extraction: \(trimmedResponse)")
                            return trimmedResponse
                        }
                    } else {
                        hproseDebug("DEBUG: [UPLOAD] Could not decode response as UTF-8 string")
                        throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
                    }
                } else {
                    // Log the response body for debugging failed requests
                    if let errorResponseString = String(data: responseData, encoding: .utf8) {
                        hproseError("DEBUG: [UPLOAD] Error response body: \(errorResponseString)")
                    }
                    throw NSError(domain: "VideoUpload", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload failed with status code: \(httpResponse.statusCode)"])
                }
            }
            
            throw NSError(domain: "VideoUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
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
            hproseDebug("Uploading \(mediaType.rawValue): \(String(format: "%.1f", Double(data.count) / (1024 * 1024)))MB")
            
            // Retry logic: resolve the writable host for each attempt.
            var lastError: Error?
            let maxRetries = 2
            
            for attempt in 1...maxRetries {
                do {
                    // Resolve the writable host for this attempt.
                    let writableUrl = try await appUser.resolveWritableUrl()
                    hproseDebug("DEBUG: [uploadRegularFile] Attempt \(attempt)/\(maxRetries) - Using writableUrl: \(writableUrl.absoluteString)")
                    
                    guard let uploadClient = await MainActor.run(body: { appUser.writableClient(timeout: 240) }) else {
                        throw NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Upload client not available", comment: "Upload error")])
                    }
                    
                    // Try to upload with current writableUrl
                    return try await performUpload(
                        data: data,
                        fileName: fileName,
                        referenceId: referenceId,
                        mediaType: mediaType,
                        uploadClient: uploadClient,
                        appId: appId
                    )
                    
                } catch let error as NSError {
                    lastError = error
                    hproseError("ERROR: [uploadRegularFile] Attempt \(attempt)/\(maxRetries) failed - domain: \(error.domain), code: \(error.code)")
                    
                    // If this was the last attempt, throw the error
                    if attempt >= maxRetries {
                        hproseError("ERROR: [uploadRegularFile] All retry attempts exhausted")
                        throw error
                    }
                    
                    // Drop the last resolved URL before retrying.
                    await MainActor.run {
                        hproseWarning("DEBUG: [uploadRegularFile] Clearing last writableUrl before retry")
                        appUser.writableUrl = nil
                    }
                    
                    // Small delay before retry
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
            
            // Should never reach here, but throw last error if we do
            throw lastError ?? NSError(domain: "MediaProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
        
        /// Performs the actual upload with the given client
        private static func performUpload(
            data: Data,
            fileName: String?,
            referenceId: String?,
            mediaType: MediaType,
            uploadClient: HproseClient,
            appId: String
        ) async throws -> MimeiFileType {
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
                        hproseError("ERROR: Chunk \(chunkCount) upload failed - invalid response type: \(type(of: response))")
                        throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Server returned invalid response", comment: "Upload error")])
                    }
                } catch let error as NSError {
                    // Provide more specific error message based on the error
                    if error.domain == NSURLErrorDomain {
                        switch error.code {
                        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                            hproseError("ERROR: Chunk \(chunkCount) upload failed - network connection lost")
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Network connection lost. Please check your connection and try again.", comment: "Network error")])
                        case NSURLErrorTimedOut:
                            hproseError("ERROR: Chunk \(chunkCount) upload failed - timeout")
                            throw NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Upload timed out. Please try again.", comment: "Timeout error")])
                        default:
                            let nsError = error as NSError
                            hproseError("ERROR: Chunk \(chunkCount) upload failed - network error: domain: \(nsError.domain), code: \(nsError.code)")
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
            hproseDebug("Uploaded \(chunkCount) chunks, finalizing...")
            
            let rawFinalResponse = await HproseTransport.invokeRunMApp(
                using: uploadClient,
                entry: "upload_ipfs",
                params: request
            )
            guard rawFinalResponse != nil else {
                hproseError("ERROR: Upload finalization failed - nil response")
                throw uploadTimeoutError("Upload finalization timed out")
            }
            let finalResponse = try HproseInstance.unwrapV2Response(rawFinalResponse)
            
            var cid: String? = nil
            if let stringResponse = finalResponse as? String {
                cid = stringResponse
            } else if let dictResponse = finalResponse as? [String: Any] {
                cid = dictResponse["cid"] as? String
            }
            
            guard let cid = cid, !cid.isEmpty else {
                hproseError("ERROR: Upload finalization failed - invalid CID response")
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
                    hproseWarning("Warning: Temporary video file was not created successfully")
                    return nil
                }
                
                // Get file size to ensure it's not empty
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let fileSize = fileAttributes[.size] as? UInt64 ?? 0
                
                if fileSize == 0 {
                    hproseWarning("Warning: Temporary video file is empty")
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }
                
                // Try to get aspect ratio with proper error handling
                let aspectRatio = try await HLSVideoProcessor.shared.getVideoAspectRatio(filePath: tempURL.path)
                
                // Clean up the temporary file after successful processing
                try? FileManager.default.removeItem(at: tempURL)
                
                return aspectRatio
            } catch {
                hproseWarning("Warning: Could not determine video aspect ratio: \(error)")
                // Clean up any temporary files that might have been created
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        }
        
        /// Get image aspect ratio from data
        private static func getImageAspectRatio(from data: Data) async throws -> Float? {
            guard let image = UIImage(data: data) else {
                hproseWarning("Warning: Could not create UIImage from data")
                return nil
            }
            
            let size = image.size
            guard size.height > 0 else {
                hproseWarning("Warning: Image height is zero")
                return nil
            }
            
            let aspectRatio = Float(size.width / size.height)
            hproseDebug("DEBUG: Image aspect ratio: \(aspectRatio) (size: \(size))")
            return aspectRatio
            
        }
        
        /// Upload chunk for regular files (no retry)
        private struct UploadChunkResponse: @unchecked Sendable {
            let value: Any
        }

        private struct UploadChunkInvocation: @unchecked Sendable {
            let uploadClient: HproseClient
            let request: [String: Any]
            let data: NSData
            let chunkNumber: Int
        }

        private static func uploadChunk(
            uploadClient: HproseClient,
            request: [String: Any],
            data: NSData,
            chunkNumber: Int
        ) async throws -> Any {
            // Keep this safety timeout slightly above the Hprose client timeout so
            // the blocking invoke normally returns first and does not leave work behind.
            let invocation = UploadChunkInvocation(
                uploadClient: uploadClient,
                request: request,
                data: data,
                chunkNumber: chunkNumber
            )
            return try await withThrowingTaskGroup(of: UploadChunkResponse.self) { group in
                group.addTask { [invocation] in
                    let rawResponse = await HproseTransport.invoke(
                        "runMApp",
                        using: invocation.uploadClient,
                        args: ["upload_ipfs", invocation.request, [invocation.data]]
                    )
                    guard rawResponse != nil else {
                        throw uploadTimeoutError("Upload timed out on chunk \(invocation.chunkNumber)")
                    }
                    guard let response = try HproseInstance.unwrapV2Response(rawResponse) else {
                        throw uploadTimeoutError("Upload returned no response on chunk \(invocation.chunkNumber)")
                    }
                    return UploadChunkResponse(value: response as Any)
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 270_000_000_000) // 270 seconds
                    throw uploadTimeoutError("Upload timeout - chunk \(chunkNumber) took too long")
                }
                
                // Return the first result (either success or timeout)
                let result = try await group.next()!
                group.cancelAll()
                return result.value
            }
        }

        private static func uploadTimeoutError(_ message: String) -> NSError {
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: message])
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
    
    /// Start periodic processing of blacklist candidates
    /// Checks every hour if candidates should be moved to blacklist (14+ failures over 1+ week)
    func startPeriodicBlackListProcessing() {
        guard blacklistProcessingTask == nil else {
            return
        }
        blacklistProcessingTask = Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            
            hproseDebug("DEBUG: [HproseInstance] Started periodic blacklist candidate processing (every hour)")
            
            while !Task.isCancelled {
                // Wait 1 hour
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                
                // Process candidates - move eligible ones to blacklist
                self.blackList.processCandidates()
            }
        }
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
                hproseWarning("DEBUG: [withRetry] Attempt \(attempt)/\(maxAttempts) failed: \(error)")
                
                if attempt < maxAttempts {
                    // Wait 1 second before retry
                    let delay: UInt64 = 1_000_000_000 // 1 second
                    hproseWarning("DEBUG: [withRetry] Retrying in 1 second...")
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
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserIsGuest) = await MainActor.run { (self.appUser.mid, self.appUser.isGuest) }
        guard !appUserIsGuest else {
            hproseWarning("DEBUG: [HproseInstance] Skipping refresh for guest user")
            return
        }

        hproseDebug("DEBUG: [HproseInstance] Refreshing appUser from server...")
        do {
            // fetchUser's internal retry mechanism (maxRetries: 2) automatically re-resolves IP on second attempt if first fails.
            // This means:
            // - Attempt 1: Uses existing appUser.baseUrl (may be stale)
            // - If attempt 1 fails: Attempt 2 automatically calls getProviderIP() for fresh IP
            
            // Call fetchUser to fetch from server (force refresh bypasses cache)
            if let refreshedUser = try await fetchUser(appUserMid, forceRefresh: true) {
                
                // Update appUser with refreshed data
                await MainActor.run {
                    self.appUser = refreshedUser
                }
                
            } else {
                hproseError("DEBUG: [HproseInstance] Failed to refresh user from server")
            }
        } catch {
            hproseError("DEBUG: [HproseInstance] Error refreshing appUser: \(error)")
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
        // add_tweet is non-idempotent on the backend: it creates a fresh server
        // tweet id on every accepted request. Do not automatically retry this
        // call after a timeout; only media/attachment upload is safe to retry.
        // Use a longer timeout so tweets with large attachment references can
        // finish without triggering duplicate creates.
        // Create a clean upload payload with only allowed fields (excluding nil values).
        // Phase A (demotion prep): the whole payload is @MainActor Tweet state — build it on the main actor.
        let (tweetJSON, tweetAuthorId, logContent, logAttachCount): (String, String, String, Int) = try await MainActor.run {
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
        if let parentTweetId = tweet.parentTweetId {
            uploadPayload["parentTweetId"] = parentTweetId
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
        let json = String(data: jsonData, encoding: .utf8) ?? ""
        return (json, tweet.authorId, tweet.content ?? "nil", tweet.attachments?.count ?? 0)
        }

        // Capture appUser properties on main thread to avoid publishing warnings
        let hostId = await MainActor.run {
            self.appUser.hostIds?.first
        }
        // Non-idempotent add_tweet can be slow server-side: use a dedicated 240s
        // timeout class instead of mutating the shared 15s client.
        guard let client = await MainActor.run(body: { self.appUser.baseUrl.map { self.clientPool.getClientByUrl(for: $0.absoluteString, timeout: 240) } }) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Upload client not available", comment: "Upload error")])
        }
            
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "hostid": hostId as Any,
            "tweet": tweetJSON
        ]
            
        hproseDebug("DEBUG: [uploadTweet] Tweet authorId: \(tweetAuthorId), content: \(logContent), attachments count: \(logAttachCount)")
        
        let rawResponse = await invokeRunMApp(using: client, entry: "add_tweet", params: params)
            
        
        guard rawResponse != nil else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Tweet submission timed out. Please refresh before retrying to avoid duplicate posts.", comment: "Tweet upload timeout")])
        }
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle the JSON response format
        guard let responseDict = unwrappedResponse as? [String: Any] else {
            hproseError("DEBUG: [uploadTweet] ERROR: Invalid response format - not a dictionary")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from server"])
        }
        
        hproseDebug("DEBUG: [uploadTweet] Response dictionary keys: \(responseDict.keys)")
        
        // unwrapV2Response already threw for success=false
        guard let newTweetId = responseDict["mid"] as? String else {
            hproseError("DEBUG: [uploadTweet] ERROR: Success response missing tweet ID")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Success response missing tweet ID"])
        }

        // add_tweet is stored on hostIds[0]; read the new tweet back from there rather
        // than from an access node that has not copied it yet.
        await adoptWriteRouteForReads(await MainActor.run { self.appUser }, reason: "add_tweet")
                
        // Immediately update appUser tweet count (like favorites/bookmarks)
        await MainActor.run {
            let currentCount = self.appUser.tweetCount ?? 0
            self.appUser.tweetCount = currentCount + 1
            hproseDebug("DEBUG: [uploadTweet] Updated appUser.tweetCount to \(self.appUser.tweetCount ?? 0)")
        }
                
        // Refresh appUser from server to get updated tweetCount and other properties
        try? await self.refreshAppUserFromServer()
                
        // IMPORTANT: Fetch the complete tweet from server to avoid showing partial data
        // This ensures all server-generated fields are populated correctly
        hproseDebug("DEBUG: [uploadTweet] Fetching complete tweet from server: \(newTweetId)")
        if let completeTweet = try? await self.getTweet(tweetId: newTweetId, authorId: tweetAuthorId) {
            return completeTweet
        } else {
            hproseWarning("DEBUG: [uploadTweet] Warning: Failed to fetch complete tweet, returning partial")
            // Fallback: return partial tweet if fetch fails
            let uploadedTweet = tweet
            let author = try? await self.fetchUser(tweetAuthorId)
            await MainActor.run {
                uploadedTweet.mid = newTweetId
                uploadedTweet.author = author
            }
            return uploadedTweet
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
    
    @MainActor func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        // Delegate to upload manager
        uploadManager.scheduleTweetUpload(tweet: tweet, itemData: itemData)
    }
    
    @MainActor func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        // Delegate to upload manager
        uploadManager.scheduleChatMessageUpload(message: message, itemData: itemData)
    }
    
    private func uploadTweetWithPersistenceAndRetry(tweet: Tweet, itemData: [PendingTweetUpload.ItemData], retryCount: Int = 0, videoJobId: String? = nil) async {
        hproseWarning("DEBUG: [uploadTweetWithPersistenceAndRetry] Starting upload with retry count: \(retryCount)")
        
        // Save pending upload to disk for persistence
        let pendingUpload = PendingTweetUpload(tweet: tweet, itemData: itemData, retryCount: retryCount, videoJobId: videoJobId)
        await savePendingUpload(pendingUpload)
        
        do {
            // Upload attachments first (no retry)
            let (uploadedAttachments, _) = try await uploadAttachments(itemData: itemData)
            
            // Update tweet with uploaded attachments
            await MainActor.run { tweet.attachments = uploadedAttachments }
            
            // Upload the tweet - this will handle retries internally via withRetry
            if let uploadedTweet = try await self.uploadTweet(tweet) {
                // Success - remove pending upload and notify
                await removePendingUpload()
                
                // Post notification (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                await MainActor.run {
                    hproseDebug("DEBUG: [HproseInstance] Posting .newTweetCreated notification for tweet: \(uploadedTweet.mid), isPrivate: \(uploadedTweet.isPrivate ?? false)")
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
            hproseError("Error uploading tweet: \(error)")
            
            // Check if we've reached max retries
            let maxRetries = 2
            
            hproseDebug("DEBUG: [Error handling] retryCount=\(retryCount), maxRetries=\(maxRetries), will show error: \(retryCount >= maxRetries)")
            
            if retryCount >= maxRetries {
                // All retries exhausted - show error to user
                hproseError("DEBUG: [Error handling] MAX RETRIES REACHED - Showing error to user and removing pending upload")
                let userFriendlyMessage = NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Tweet upload failed error")
                
                await MainActor.run {
                    if !self.isAppInitializing {
                        hproseError("DEBUG: [Error handling] Posting backgroundUploadFailed notification")
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": userFriendlyMessage]
                        )
                    } else {
                        hproseError("DEBUG: [Error handling] App still initializing, NOT showing error")
                    }
                }
                
                // Remove pending upload since we're giving up
                await removePendingUpload()
            } else {
                // Will retry in background - don't show error yet
                hproseWarning("DEBUG: [Error handling] Retry \(retryCount + 1) of \(maxRetries + 1) failed, scheduling background retry")
                
                // Schedule immediate background retry
                let delay = UInt64(retryCount + 1) * 2_000_000_000 // 2, 4 seconds exponential backoff
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: delay)
                    await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData, retryCount: retryCount + 1)
                }
            }
        }
    }

    private func isVideoUploadTypeIdentifier(_ typeIdentifier: String) -> Bool {
        let value = typeIdentifier.lowercased()
        return value.hasPrefix("public.movie") ||
            value.hasPrefix("public.video") ||
            value.contains("video") ||
            value.contains("movie") ||
            value.contains("quicktime") ||
            value.contains("mpeg-4") ||
            value.contains("mpeg4") ||
            value.contains("mp4") ||
            value.contains("m4v") ||
            value.contains("mov") ||
            value.contains("avi") ||
            value.contains("mkv") ||
            value.contains("webm")
    }
    
    private func uploadAttachments(itemData: [PendingTweetUpload.ItemData]) async throws -> ([MimeiFileType], String?) {
        var uploadedAttachments: [MimeiFileType] = []
        var videoJobId: String? = nil
        
        // Check if we have any video items that need job ID tracking
        let hasVideoItems = itemData.contains { item in
            isVideoUploadTypeIdentifier(item.typeIdentifier)
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
                        }
                    )
                    
                    if let fileType = result {
                        uploadedAttachments.append(fileType)
                    }
                    
                    // Store the job ID for video items
                    if let jobId = jobId {
                        videoJobId = jobId
                        hproseDebug("DEBUG: Stored video job ID: \(jobId)")
                    }
                } catch {
                    hproseError("Error uploading item \(item.fileName): \(error)")
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
                    hproseError("Error uploading pair \(pairIndex + 1): \(error)")
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
            hproseDebug("Saved pending upload to disk")
        } catch {
            hproseError("Failed to save pending upload: \(error)")
        }
    }
    
    private func removePendingUpload() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        try? FileManager.default.removeItem(at: fileURL)
        hproseDebug("Removed pending upload from disk")
    }
    
    // MARK: - Video Job Status Checking
    
    // MARK: - Recovery Methods
    
    // REMOVED: cleanupProblematicPendingUploads(), recoverPendingUploads(), recoverPendingUploads_old()
    // Pending upload recovery is now handled by ContentView's dialog system
    
    // The old recoverPendingUploads_old function code removed (was 130+ lines)
    // All retry logic is preserved in uploadTweetWithPersistenceAndRetry()
    // New system: User sees dialog with retry/discard options instead of auto-retry
    
    
    @MainActor func scheduleCommentUpload(
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
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserInstance) = await MainActor.run { (self.appUser.mid, self.appUser) }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "tweetid": tweetId,
            "appuserid": appUserMid,
        ]

        // Pinning mutates the app user's data, so route directly to its writable node.
        _ = try await appUserInstance.resolveWritableUrl()
        guard let pinClient = await appUserInstance.writableClient(timeout: 15) else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Writable client not available", comment: "Writable client error")])
        }
        let rawResponse = await invokeRunMApp(using: pinClient, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        await adoptWriteRouteForReads(appUserInstance, reason: entry)
        
        // For v2 API: server returns {success: true, data: {isPinned: bool}}
        // After unwrapV2Response, we get {isPinned: bool}
        if let dataDict = Self.asStringKeyedDictionary(unwrappedResponse),
           let isPinned = (dataDict["isPinned"] as? Bool)
            ?? (dataDict["isPinned"] as? NSNumber)?.boolValue {
            return isPinned
        }
        
        // Fallback: check if it's a direct Bool (legacy format)
        if let boolResponse = unwrappedResponse as? Bool {
            return boolResponse
        }
        if let numericResponse = unwrappedResponse as? NSNumber {
            return numericResponse.boolValue
        }

        hproseWarning("[togglePinnedTweet] Unexpected response type: \(Swift.type(of: unwrappedResponse)) value: \(String(describing: unwrappedResponse))")
        
        throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to update pinned tweet", comment: "Pin tweet error")])
    }
    
    /**
     * Return a list of {tweetId, timestamp} for each pinned Tweet. The timestamp is when
     * the tweet is pinned.
     */
    func getPinnedTweets(user: User) async throws -> [Tweet] {
        let entry = "get_pinned_tweets"
        // Phase A (demotion prep): snapshot @MainActor User + appUser.mid.
        let snap = await MainActor.run { UserRecord(user: user) }
        let appUserMid = await MainActor.run { self.appUser.mid }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": snap.mid,
            "appuserid": appUserMid
        ]

        guard let baseUrl = snap.baseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        
        // Unwrap v2 response
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        // Handle empty array case - server returns empty array when user has no pinned tweets
        let response: [[String: Any]]
        if let arrayResponse = unwrappedResponse as? [[String: Any]] {
            response = arrayResponse
        } else if let emptyArray = unwrappedResponse as? [Any], emptyArray.isEmpty {
            // Server returned empty array - handle gracefully
            response = []
            hproseDebug("DEBUG: [HproseInstance] getPinnedTweets - Server returned empty array (no pinned tweets)")
        } else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to get pinned tweets", comment: "Get pinned tweets error")])
        }
        
        var result: [Tweet] = []
        var scheduledBackgroundAuthorFetches = Set<String>()
        func scheduleBackgroundAuthorFetch(authorId: String) {
            guard scheduledBackgroundAuthorFetches.insert(authorId).inserted else { return }

            Task(priority: .utility) { [weak self] in
                do {
                    _ = try await self?.fetchUser(authorId)
                } catch {
                    hproseError("DEBUG: [getPinnedTweets] Background author fetch failed for \(authorId): \(error)")
                }
            }
        }

        for dict in response {
            if let tweetDict = dict["tweet"] as? [String: Any] {
                let tweet = try await mergeTweetFromDict(tweetDict)
                let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: tweet.authorId)
                await MainActor.run {
                    tweet.author = cachedAuthor
                }
                scheduleBackgroundAuthorFetch(authorId: tweet.authorId)
                result.append(tweet)
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
        hproseDebug("DEBUG: [registerUser] hostId parameter: \(hostId ?? "nil")")
        
        var hosts: [String]? = nil
        if let hostId = hostId, !hostId.isEmpty {
            hosts = [hostId]
            hproseDebug("DEBUG: [registerUser] Setting hosts to [\(hostId)]")
        } else {
            hproseDebug("DEBUG: [registerUser] No hostId provided, hosts will be nil")
        }
        
        // Phase A (demotion prep): User is a @MainActor type — create + encode it on the main actor.
        let (userJsonString, newUserHostIdsLog): (String, [String]) = try await MainActor.run {
            let newUser = User(mid: self.appUser.mid, name: alias, username: username, password: password,
                               profile: profile, cloudDrivePort: cloudDrivePort, hostIds: hosts)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(newUser)
            return (String(data: data, encoding: .utf8) ?? "", newUser.hostIds ?? [])
        }
        hproseDebug("DEBUG: [registerUser] Created User object with hostIds: \(newUserHostIdsLog)")
        hproseDebug("DEBUG: [registerUser] Encoded user JSON: \(userJsonString)")

        let entry = "register"
        
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "user": userJsonString
        ]
        
        // Use the current appUser's client for all backend calls
        let appUserBaseUrl = await MainActor.run { self.appUser.baseUrl }
        guard let baseUrl = appUserBaseUrl else {
            hproseError("DEBUG: [registerUser] ERROR: appUser.baseUrl is nil")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized. Please check your connection.", comment: "Client initialization error")])
        }
        // `register` is not an ordinary RPC and must not share their 15s budget. Creating an
        // account costs two MMCreate calls, a DHT `get_provider_ip` lookup for the username
        // uniqueness check, an MMBackup, a MiMeiPublish and a node_update_score — all
        // network-bound and highly variable: 4s to 25s in the entry node's own logs. When the
        // client gave up first the server still finished, so the account was created while the
        // app reported a timeout, and the retry then failed with "Username is taken".
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 30)
        let targetUrl = baseUrl.absoluteString
        
        hproseDebug("DEBUG: [registerUser] Sending registration request to server")
        hproseDebug("DEBUG: [registerUser] Using target URL: \(targetUrl)")
        
        let unwrappedResponse: Any?
        do {
            let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
            unwrappedResponse = try Self.unwrapV2Response(rawResponse)
            hproseDebug("DEBUG: [registerUser] Unwrapped response: \(String(describing: unwrappedResponse))")
        } catch {
            hproseError("DEBUG: [registerUser] ERROR: Exception during API call: \(error)")
            hproseError("DEBUG: [registerUser] Error details: \(error.localizedDescription)")
            throw error
        }
        
        guard let response = unwrappedResponse as? [String: Any] else {
            hproseError("DEBUG: [registerUser] ERROR: Response is not a dictionary")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
        }
        
        // v2 format: {success: true, user: <parsed user object>}
        guard let success = response["success"] as? Bool else {
            hproseError("DEBUG: [registerUser] ERROR: 'success' field not found in response")
            hproseDebug("DEBUG: [registerUser] Response keys: \(response.keys)")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
        }
        
        hproseDebug("DEBUG: [registerUser] Registration success status: \(success)")
        if success {
            // Extract the newly created user's ID from the response
            guard let userDict = response["user"] as? [String: Any],
                  let registeredUserId = userDict["mid"] as? String else {
                // If user object is missing, still return success but log warning
                hproseWarning("DEBUG: [registerUser] Warning: User object not found in registration response")
                return true
            }
            
            // Make the newly registered user follow each user in getAlphaIds()
            // Run this in a detached task so we can return success immediately
            let alphaIds = Gadget.getAlphaIds()
            
            Task.detached { [weak self] in
                guard let self = self else { return }
                
                for alphaId in alphaIds {
                    do {
                        // First verify the alphaId user exists before attempting to follow
                        hproseDebug("DEBUG: [registerUser:background] Checking if alphaId user exists: \(alphaId)")
                        guard let _ = try await self.fetchUser(alphaId, forceRefresh: false) else {
                            hproseWarning("DEBUG: [registerUser:background] AlphaId user \(alphaId) not found, skipping auto-follow")
                            continue
                        }
                        
                        hproseDebug("DEBUG: [registerUser:background] AlphaId user exists, attempting to follow: \(alphaId)")
                        _ = try await self.toggleFollowing(followingId: alphaId, userId: registeredUserId)
                    } catch {
                        let nsError = error as NSError
                        hproseError("DEBUG: [registerUser:background] Failed to follow alphaId \(alphaId): domain: \(nsError.domain), code: \(nsError.code), description: \(error.localizedDescription)")
                        // Continue with other users even if one fails
                    }
                }
                
            }
            
            // Return success immediately without waiting for auto-follow to complete
            hproseDebug("DEBUG: [registerUser] Returning success immediately, auto-follow running in background")
            return true
        } else {
            let message = response["message"] as? String ?? response["reason"] as? String ?? NSLocalizedString("Unknown registration error.", comment: "Unknown registration error")
            hproseError("DEBUG: [registerUser] ERROR: Registration failed with message: \(message)")
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
        
        let sanitizedDomain = domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalShareDomain = sanitizedDomain?.isEmpty == true ? nil : sanitizedDomain
        
        let entry = "set_author_core_data"

        // Phase A (demotion prep): the copy of appUser and its encoding are @MainActor state —
        // build updatedUser and encode it on the main actor.
        let userJsonString: String = try await MainActor.run {
            // Determine domainToShare value: if explicitly provided (even if empty/nil), use it; otherwise preserve existing.
            // Empty string "" is converted to nil, which will exclude the field from JSON (encodeIfPresent).
            let domainToShareValue: String?
            if domainToShare != nil {
                domainToShareValue = finalShareDomain
            } else {
                domainToShareValue = self.appUser.domainToShare
            }

            // Create a copy of the user object with all existing properties
            let updatedUser = User(
                mid: self.appUser.mid,
                name: alias ?? self.appUser.name,
                password: password ?? self.appUser.password,
                profile: profile ?? self.appUser.profile,
                cloudDrivePort: cloudDrivePort,
                domainToShare: domainToShareValue
            )
            // Copy other properties from appUser. Routes are not copied: this object
            // shares appUser's mid, so it already reads the same entry in UserRoutes.
            updatedUser.username = self.appUser.username
            updatedUser.avatar = self.appUser.avatar
            updatedUser.email = self.appUser.email
            updatedUser.timestamp = self.appUser.timestamp
            updatedUser.lastLogin = self.appUser.lastLogin
            updatedUser.tweetCount = self.appUser.tweetCount
            updatedUser.followingCount = self.appUser.followingCount
            updatedUser.followersCount = self.appUser.followersCount
            updatedUser.bookmarksCount = self.appUser.bookmarksCount
            updatedUser.favoritesCount = self.appUser.favoritesCount
            updatedUser.commentsCount = self.appUser.commentsCount
            updatedUser.publicKey = self.appUser.publicKey
            updatedUser.fansList = self.appUser.fansList
            updatedUser.followingList = self.appUser.followingList

            // Only set hostIds if hostId is provided and not empty; otherwise preserve existing.
            if let hostId = hostId, !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updatedUser.hostIds = [hostId]
            } else {
                updatedUser.hostIds = self.appUser.hostIds
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(updatedUser)
            return String(data: data, encoding: .utf8) ?? ""
        }
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "user": userJsonString
        ]
        
        hproseDebug("DEBUG: updateUserCore - sending request to server with user data")
        hproseDebug("DEBUG: updateUserCore - domainToShare in User object: \(finalShareDomain ?? "nil")")
        hproseDebug("DEBUG: updateUserCore - encoded user JSON contains domainToShare: \(userJsonString.contains("domainToShare"))")
        // Print a snippet of the JSON to verify domainToShare is included
        if let domainRange = userJsonString.range(of: "\"domainToShare\"") {
            let startIndex = userJsonString.index(domainRange.lowerBound, offsetBy: -50, limitedBy: userJsonString.startIndex) ?? userJsonString.startIndex
            let endIndex = userJsonString.index(domainRange.upperBound, offsetBy: 50, limitedBy: userJsonString.endIndex) ?? userJsonString.endIndex
            let snippet = String(userJsonString[startIndex..<endIndex])
            hproseDebug("DEBUG: updateUserCore - JSON snippet around domainToShare: ...\(snippet)...")
        }

        let appUserBaseUrl = await MainActor.run { self.appUser.baseUrl }
        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let updateClient = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 30)
        let rawResponse = await invokeRunMApp(using: updateClient, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            hproseError("DEBUG: updateUserCore - failed to get response from server")
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Profile update failed", comment: "Profile update error")])
        }
        
        hproseDebug("DEBUG: updateUserCore - server response: \(response)")
        
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
                hproseDebug("DEBUG: updateUserCore - server returned success")
                
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
                    hproseDebug("DEBUG: updateUserCore - updated in-memory appUser, cloudDrivePort: \(cloudDrivePort), domainToShare: \(self.appUser.domainToShare ?? "nil")")
                }
                
                let savedMid = await MainActor.run { () -> String in
                    TweetCacheManager.shared.saveUser(self.appUser)
                    return self.appUser.mid
                }
                hproseDebug("DEBUG: updateUserCore - saved updated user cache for: \(savedMid)")

                await adoptWriteRouteForReads(await MainActor.run { self.appUser }, reason: entry)
                return true
            } else {
                let errorMessage = response["reason"] as? String ?? "Unknown registration error."
                hproseError("DEBUG: updateUserCore - server returned error: \(errorMessage)")
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        hproseWarning("DEBUG: updateUserCore - unexpected response format")
        return false
    }
    
    // MARK: - Agent Token
    
    /// Generates a new agent token for AI agents to post on behalf of the user.
    /// The public key is stored on the server for verification.
    /// Returns the exportable token string that should be given to the AI agent.
    func generateAgentToken() async throws -> String {
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserIsGuest) = await MainActor.run { (self.appUser.mid, self.appUser.isGuest) }
        guard !appUserIsGuest else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Must be logged in to generate agent token", comment: "Agent token error")
            ])
        }

        // Generate new token with keypair
        guard let tokenResult = AgentTokenManager.shared.createAndExportToken(
            for: appUserMid,
            scope: ["post", "comment"]
        ) else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Failed to generate agent token", comment: "Agent token error")
            ])
        }

        // Save public key to server
        try await updateAgentPublicKey(tokenResult.publicKey)

        // Update local user object
        await MainActor.run {
            self.appUser.agentPublicKey = tokenResult.publicKey
        }

        hproseDebug("DEBUG: [generateAgentToken] Generated new agent token for user \(appUserMid)")
        return tokenResult.tokenString
    }
    
    /// Updates the user's agent public key on the server
    private func updateAgentPublicKey(_ publicKey: String) async throws {
        let entry = "set_author_core_data"

        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserBaseUrl) = await MainActor.run { (self.appUser.mid, self.appUser.baseUrl) }

        // Create minimal user object with just the fields we need to update
        let userUpdate: [String: Any] = [
            "mid": appUserMid,
            "agentPublicKey": publicKey
        ]

        guard let userJsonData = try? JSONSerialization.data(withJSONObject: userUpdate),
              let userJsonString = String(data: userJsonData, encoding: .utf8) else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to serialize user data"
            ])
        }

        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "user": userJsonString
        ]

        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let profileClient = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let rawResponse = await invokeRunMApp(using: profileClient, entry: entry, params: params)
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Failed to update agent public key", comment: "Agent token error")
            ])
        }
        
        // Check for success in v2 format
        if let success = response["success"] as? Bool, !success {
            let message = response["message"] as? String ?? "Unknown error"
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        if let status = response["status"] as? String, status != "success" {
            let reason = response["reason"] as? String ?? "Unknown error"
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        
    }
    
    // MARK: - User Avatar
    /// Sets the user's avatar on the server and returns confirmed avatar
    func setUserAvatar(user: User, avatar: MimeiId) async throws -> String {
        let entry = "set_user_avatar"
        // Phase A (demotion prep): snapshot @MainActor user.mid + appUser.baseUrl (client is appUser's).
        let (userMid, appUserBaseUrl) = await MainActor.run { (user.mid, self.appUser.baseUrl) }
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": userMid,
            "avatar": avatar
        ]

        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server did not respond"])
        }
        let avatarClient = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)
        let rawResponse = await invokeRunMApp(using: avatarClient, entry: entry, params: params)
        guard rawResponse != nil else {
            throw NSError(domain: "HproseInstance", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server did not respond"])
        }
        
        let unwrappedResponse = try Self.unwrapV2Response(rawResponse)
        await adoptWriteRouteForReads(user, reason: entry)
        
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
    
    /// Find IP addresses of given nodeId with retry and appUser health checking
    /// - Parameters:
    ///   - nodeId: The node ID to resolve IPs for
    ///   - v4Only: Whether to request IPv4 addresses only
    ///   - forceHealthCheck: Whether to bypass a cached health result for a pooled IP
    ///   - excludedIP: An address to leave out of this lookup. A successful health probe
    ///     does not prove that every RPC is usable on that address, so a caller whose RPC
    ///     just failed passes the attempted address here to get the *next* advertised
    ///     address for the same node. The excluded address is only skipped for this
    ///     lookup; it is not marked unhealthy and not removed from NodePool.
    ///   - usePool: Whether NodePool may serve and record this resolution. The pool
    ///     caches read-access nodes only, so write-route resolution passes `false`:
    ///     it never reuses a pooled entry and never writes one back. Mutations are
    ///     rare compared to reads, so resolving hostIds[0] fresh costs nothing.
    /// - Returns: A healthy IP address for the node, or nil if none found
    func getHostIP(
        _ nodeId: String,
        v4Only: Bool = false,
        forceHealthCheck: Bool = false,
        excludedIP: String? = nil,
        usePool: Bool = true
    ) async -> String? {
        hproseDebug("DEBUG: [getHostIP] Resolving IPs for node \(nodeId)")
        let excludedKey = excludedIP.map { normalizeHostPort($0) }

        // Step 0: Check NodePool first for cached IP
        if usePool, let pooledIP = NodePool.shared.getIPForNode(nodeMid: nodeId) {
            if let excludedKey, normalizeHostPort(pooledIP) == excludedKey {
                hproseDebug("DEBUG: [getHostIP] Skipping pooled IP \(pooledIP) for node \(nodeId) during alternate-route lookup")
            } else {
                hproseDebug("DEBUG: [getHostIP] 🎯 Found pooled IP for node \(nodeId): \(pooledIP), testing health...")

                // Test if pooled IP is still healthy
                let isHealthy = await isRouteAlive(pooledIP, forceFresh: forceHealthCheck)

                if isHealthy {
                    return pooledIP
                } else {
                    hproseError("DEBUG: [getHostIP] ❌ Pooled IP \(pooledIP) is unhealthy, removing from pool")
                    NodePool.shared.removeIPFromNode(nodeMid: nodeId, ip: pooledIP)
                }
            }
        }

        hproseDebug("DEBUG: [getHostIP] Attempt 1: Resolving IPs from API for node \(nodeId)")

        // First attempt with current appUser client
        if let ip = await _getHostIP(nodeId, v4Only: v4Only, hproseClient: appUser.hproseClient, excludedIP: excludedIP, forceFresh: forceHealthCheck) {
            if usePool { NodePool.shared.updateNodeIP(nodeMid: nodeId, newIP: ip) }
            return ip
        }

        hproseError("DEBUG: [getHostIP] Attempt 1 failed, checking appUser health...")

        // First attempt failed - check if appUser is healthy
        // Phase A (demotion prep): snapshot @MainActor appUser.baseUrl.
        let appUserBaseUrl = await MainActor.run { self.appUser.baseUrl }
        guard let baseUrl = appUserBaseUrl, let host = baseUrl.host else {
            hproseWarning("DEBUG: [getHostIP] No appUser base URL, cannot retry")
            return nil
        }
        let appUserIP = baseUrl.port.map { "\(host):\($0)" } ?? host
        let isAppUserHealthy = await isRouteAlive(appUserIP, forceFresh: forceHealthCheck)
        
        if isAppUserHealthy {
            // AppUser answered but gave us no usable address for this node. That is not
            // proof the node is gone — the entry node keeps its own registry and answers
            // without depending on appUser owning a usable route. Returning nil here (as
            // this used to) skipped that perfectly good lookup whenever appUser merely
            // looked healthy, which is what left writes failing with "Upload server not
            // responding" — resolveWritableUrl has no other way to reach hostIds[0].
            hproseWarning("DEBUG: [getHostIP] AppUser is healthy but returned no usable IPs for node \(nodeId) - falling back to entry node")
            return await hostIPFromEntryNode(
                nodeId,
                v4Only: v4Only,
                excludedIP: excludedIP,
                usePool: usePool,
                entryClient: nil,
                forceFresh: forceHealthCheck
            )
        }
        
        // AppUser is unhealthy - refresh it and retry
        hproseWarning("DEBUG: [getHostIP] ⚠️ AppUser is unhealthy, refreshing via entry IP...")
        
        do {
            guard let entryIP = try await findEntryIP() else {
                hproseError("DEBUG: [getHostIP] Failed to find entry IP for appUser refresh")
                return nil
            }
            let entryClient = clientPool.getClientByIP(for: entryIP)

            hproseDebug("DEBUG: [getHostIP] Using entry IP to refresh appUser: \(entryIP)")

            // Refresh appUser's IP via entry
            if let newAppUserIP = try await _getProviderIP(appUser.mid, v4Only: v4Only, hproseClient: entryClient, forceFresh: forceHealthCheck),
               let newAppUserURL = URL(string: ensureHttpPrefix(newAppUserIP)) {
                await applyBaseUrlIfNeeded(appUser, url: newAppUserURL, reason: "getHostIP appUser refresh")

                // Retry with refreshed appUser
                hproseWarning("DEBUG: [getHostIP] Attempt 2: Retrying with refreshed appUser...")
                if let ip = await _getHostIP(nodeId, v4Only: v4Only, hproseClient: appUser.hproseClient, excludedIP: excludedIP, forceFresh: forceHealthCheck) {
                    if usePool {
                        NodePool.shared.updateNodeIP(nodeMid: nodeId, newIP: ip)
                        hproseInfo("DEBUG: [getHostIP] ✅ Updated pool: node \(nodeId) now has working IP (after retry)")
                    }
                    return ip
                }
                hproseError("DEBUG: [getHostIP] Attempt 2 also failed via refreshed appUser")
            } else {
                hproseError("DEBUG: [getHostIP] Failed to refresh appUser IP")
            }

            // Attempt 3: ask the entry node itself which addresses serve this node.
            // Unlike the two attempts above it does not depend on appUser owning a
            // usable route, so it still answers when appUser cannot be repaired.
            if let ip = await hostIPFromEntryNode(
                nodeId,
                v4Only: v4Only,
                excludedIP: excludedIP,
                usePool: usePool,
                entryClient: entryClient,
                forceFresh: forceHealthCheck
            ) {
                return ip
            }

            hproseError("DEBUG: [getHostIP] Node \(nodeId) IPs not resolvable via appUser or entry node")
            return nil

        } catch {
            hproseError("DEBUG: [getHostIP] Error during appUser refresh: \(error)")
            return nil
        }
    }
    
    /// Resolves `nodeId` through the entry node.
    ///
    /// The entry node keeps its own address registry, so this answers whether or not
    /// appUser owns a usable route — which makes it the right fallback both when appUser
    /// is unhealthy and when it responds without a usable address list.
    ///
    /// - Parameter entryClient: an already-resolved entry client, when the caller has one.
    ///   `findEntryIP()` fetches and parses the app URL's HTML, so it is not cheap enough
    ///   to repeat within a single resolution.
    private func hostIPFromEntryNode(
        _ nodeId: String,
        v4Only: Bool,
        excludedIP: String?,
        usePool: Bool,
        entryClient: HproseClient?,
        forceFresh: Bool = false
    ) async -> String? {
        let client: HproseClient
        if let entryClient {
            client = entryClient
        } else {
            do {
                guard let entryIP = try await findEntryIP() else {
                    hproseError("DEBUG: [getHostIP] Failed to find entry IP to resolve node \(nodeId)")
                    return nil
                }
                client = clientPool.getClientByIP(for: entryIP)
                hproseDebug("DEBUG: [getHostIP] Resolving node \(nodeId) directly through entry node \(entryIP)")
            } catch {
                hproseError("DEBUG: [getHostIP] Error finding entry IP for node \(nodeId): \(error)")
                return nil
            }
        }

        guard let ip = await _getHostIP(nodeId, v4Only: v4Only, hproseClient: client, excludedIP: excludedIP, forceFresh: forceFresh) else {
            hproseError("DEBUG: [getHostIP] Entry node could not resolve node \(nodeId)")
            return nil
        }
        if usePool {
            NodePool.shared.updateNodeIP(nodeMid: nodeId, newIP: ip)
            hproseInfo("DEBUG: [getHostIP] ✅ Updated pool: node \(nodeId) resolved via entry node")
        }
        return ip
    }

    /// Internal helper that performs the actual IP resolution and health checking
    /// - Parameters:
    ///   - nodeId: The node ID to resolve IPs for
    ///   - v4Only: Whether to request IPv4 addresses only
    ///   - hproseClient: The Hprose client to use for the API call
    ///   - excludedIP: An advertised address to drop from the candidate list before
    ///     health-racing them, so an alternate-route lookup never returns the address
    ///     the caller just failed on.
    ///   - forceFresh: Re-probe candidates rather than trusting a cached verdict. An
    ///     alternate-route lookup runs seconds after the read failed, well inside the
    ///     30s health cache, so without this it can hand back an address last judged
    ///     healthy before anything went wrong.
    /// - Returns: A healthy IP address for the node, or nil if none found
    private func _getHostIP(_ nodeId: String, v4Only: Bool = false, hproseClient: HproseClient?, excludedIP: String? = nil, forceFresh: Bool = false) async -> String? {
        let entry = "get_node_ips"
        let params = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "nodeid": nodeId,
            "v4only": v4Only ? "true" : "false"
        ]
        
        guard let hproseClient = hproseClient else {
            hproseDebug("DEBUG: [_getHostIP] No hprose client available")
            return nil
        }
        
        let rawResponse = await invokeRunMApp(using: hproseClient, entry: entry, params: params)
        guard let response = rawResponse else {
            hproseDebug("DEBUG: [_getHostIP] No response from server.")
            return nil
        }
        
        // Unwrap v2 response
        let unwrappedResponse: Any?
        do {
            unwrappedResponse = try Self.unwrapV2Response(response)
        } catch {
            let nsError = error as NSError
            hproseError("DEBUG: [_getHostIP] Error unwrapping v2 response: domain: \(nsError.domain), code: \(nsError.code)")
            return nil
        }
        
        if let ipList = unwrappedResponse as? [String] {
            // Filter and trim IP addresses. Nodes advertise every address they are
            // bound to, including Tailscale CGNAT (100.64.0.0/10) and LAN addresses
            // that are unreachable — or, worse, reachable but wrong — from another
            // network. Only public literals are route candidates, matching
            // _getProviderIP.
            let excludedKey = excludedIP.map { normalizeHostPort($0) }
            let publicIPs = ipList
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { Gadget.isValidPublicIpAddress($0) }
            let ipAddresses = publicIPs
                .filter { excludedKey == nil || normalizeHostPort($0) != excludedKey }

            if publicIPs.count != ipList.count {
                hproseDebug("DEBUG: [_getHostIP] Dropped \(ipList.count - publicIPs.count) non-public address(es) advertised by node \(nodeId)")
            }
            if let excludedKey, ipAddresses.count != publicIPs.count {
                hproseDebug("DEBUG: [_getHostIP] Excluded \(excludedKey) from node \(nodeId) candidates")
            }
            hproseDebug("DEBUG: [_getHostIP] Retrieved \(ipAddresses.count) IP address(es) from get_node_ips API")

            // Test IPs in batches of 4 for faster discovery during high load
            let batchSize = 4
            for batchStart in stride(from: 0, to: ipAddresses.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ipAddresses.count)
                let batch = Array(ipAddresses[batchStart..<batchEnd])
                
                
                // Test this batch in parallel - return as soon as first IP responds successfully
                let healthyIP: String? = await withTaskGroup(of: (String, Bool)?.self) { group in
                    for ip in batch {
                        group.addTask {
                            // Check for cancellation before starting
                            if Task.isCancelled {
                                return nil
                            }
                            
                            
                            let isHealthy = await self.isRouteAlive(ip, forceFresh: forceFresh, logFailures: false)

                            if Task.isCancelled { return nil }

                            return (ip, isHealthy)
                        }
                    }
                    
                    // Return IMMEDIATELY when first healthy IP is found
                    for await result in group {
                        if let (ip, isHealthy) = result, isHealthy {
                            hproseDebug("DEBUG: [_getHostIP] Found healthy node IP: \(ip) - returning immediately")
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
                hproseError("DEBUG: [_getHostIP] All health checks failed for \(ipAddresses.count) IP(s), returning nil")
                return nil
            }
            
            hproseDebug("DEBUG: [_getHostIP] No IPs available in response")
            return nil
        }
        // Log the shape we actually got. "Invalid format" on its own says nothing about
        // whether the node sent a dict, an error string, or a JSON-encoded list, which is
        // the first thing you need in order to tell a server problem from a parse gap.
        hproseWarning("DEBUG: [_getHostIP] Invalid IpList response format for node \(nodeId): \(responseShapeDescription(unwrappedResponse))")
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
        // Phase A (demotion prep): appUser.mid doesn't change across retries.
        let appUserMid = await MainActor.run { self.appUser.mid }

        for attempt in 0...maxRetries {
            // On retry, force refresh appUser's baseUrl by passing empty string
            let forceRefresh = attempt > 0
            if forceRefresh {
                hproseWarning("[sendMessage] 🔄 Retry attempt \(attempt): Refreshing sender's baseUrl")
            }

            // Refresh appUser's route if needed. fetchUser commits whatever route it
            // confirms through UserRoutes, so there is nothing to copy back.
            if forceRefresh {
                _ = try await fetchUser(appUserMid, baseUrl: "")
            }

            // Snapshot the (possibly just-refreshed) sender baseUrl for this attempt.
            let appUserBaseUrl = await MainActor.run { self.appUser.baseUrl }

            let entry = "message_outgoing"
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "userid": appUserMid,
                "receiptid": receiptId,
                "msg": message.toJSONString()
            ]

            guard let baseUrl = appUserBaseUrl else {
                let errorMsg = "Failed to create client for sender node"
                hproseError("[sendMessage] ❌ \(errorMsg) - baseUrl: nil")
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
            
            let senderClient = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

            let rawResponse = await invokeRunMApp(using: senderClient, entry: entry, params: params)
            let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
            let response = unwrappedResponse ?? Self.normalizeHproseContainers(rawResponse)
            
            // Handle new response format: {success: false, error: e.message}
            if let responseDict = Self.asStringKeyedDictionary(response) {
                if let success = responseDict["success"] as? Bool, !success {
                    let errorMessage = responseDict["error"] as? String ?? "Unknown error"
                    lastError = errorMessage
                    hproseError("[sendMessage] ❌ Failed to send to sender node (attempt \(attempt + 1)/\(maxRetries + 1)): \(errorMessage)")
                    
                    if attempt < maxRetries {
                        let delay = UInt64(attempt + 1) * 2_000_000_000 // 2, 4 seconds
                        hproseWarning("[sendMessage] ⏳ Waiting \(delay / 1_000_000_000) seconds before retry...")
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
                    return MessageSendResult(success: true, errorMessage: nil)
                }
            } else {
                // Handle legacy boolean response
                let isSuccess = response as? Bool ?? false
                if isSuccess {
                    return MessageSendResult(success: true, errorMessage: nil)
                } else {
                    let errorMessage = "Failed to send to sender node (legacy format)"
                    lastError = errorMessage
                    hproseError("[sendMessage] ❌ \(errorMessage) (attempt \(attempt + 1)/\(maxRetries + 1))")
                    
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                        continue
                    }
                }
            }
        }
        
        // All retries exhausted
        let finalError = lastError ?? "Failed to send message to sender node after \(maxRetries + 1) attempts"
        hproseError("[sendMessage] ❌ All retry attempts exhausted for sender node: \(finalError)")
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
        // Phase A (demotion prep): appUser.mid doesn't change across retries.
        let appUserMid = await MainActor.run { self.appUser.mid }

        for attempt in 0...maxRetries {
            // On retry, force refresh recipient's baseUrl by passing empty string
            let forceRefresh = attempt > 0
            if forceRefresh {
                hproseWarning("[sendMessage] 🔄 Retry attempt \(attempt): Refreshing recipient's baseUrl for userId: \(receiptId)")
            }
            
            // Fetch recipient user (with forced refresh on retry)
            receiptUser = try await fetchUser(receiptId, baseUrl: forceRefresh ? "" : "")
            
            guard let recipient = receiptUser else {
                let errorMsg = "Recipient user not found"
                hproseError("[sendMessage] ❌ \(errorMsg) for userId: \(receiptId)")
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
            
            // Snapshot recipient's (freshly-fetched) baseUrl for this attempt.
            let recipientBaseUrl = await MainActor.run { recipient.baseUrl }

            let receiptEntry = "message_incoming"
            let receiptParams: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "version": "v2",
                "senderid": appUserMid,
                "receiptid": receiptId,
                "msg": message.toJSONString()
            ]

            // Get fresh client (will be recreated if baseUrl changed)
            guard let rBaseUrl = recipientBaseUrl else {
                let errorMsg = "Failed to create client for recipient node"
                hproseError("[sendMessage] ❌ \(errorMsg) - baseUrl: nil")
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
            
            let recipientClient = clientPool.getClientByUrl(for: rBaseUrl.absoluteString, timeout: 15)

            let rawReceiptResponse = await invokeRunMApp(using: recipientClient, entry: receiptEntry, params: receiptParams)
            let receiptResponseUnwrapped = try? Self.unwrapV2Response(rawReceiptResponse)
            let receiptResponse = receiptResponseUnwrapped ?? Self.normalizeHproseContainers(rawReceiptResponse)
            
            // Handle new response format for message_incoming
            if let receiptResponseDict = Self.asStringKeyedDictionary(receiptResponse) {
                if let success = receiptResponseDict["success"] as? Bool, !success {
                    let errorMessage = receiptResponseDict["error"] as? String ?? "Failed to send to recipient node"
                    lastError = errorMessage
                    hproseError("[sendMessage] ❌ Failed to send to recipient node (attempt \(attempt + 1)/\(maxRetries + 1)): \(errorMessage)")
                    
                    if attempt < maxRetries {
                        // Wait before retry with exponential backoff
                        let delay = UInt64(attempt + 1) * 2_000_000_000 // 2, 4 seconds
                        hproseWarning("[sendMessage] ⏳ Waiting \(delay / 1_000_000_000) seconds before retry...")
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
                    return MessageSendResult(success: true, errorMessage: nil)
                }
            } else {
                // Legacy boolean response
                let receiptSuccess = receiptResponse as? Bool ?? false
                if receiptSuccess {
                    return MessageSendResult(success: true, errorMessage: nil)
                } else {
                    let errorMessage = "Failed to send to recipient node (legacy format)"
                    lastError = errorMessage
                    hproseError("[sendMessage] ❌ \(errorMessage) (attempt \(attempt + 1)/\(maxRetries + 1))")
                    
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
        hproseError("[sendMessage] ❌ All retry attempts exhausted: \(finalError)")
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
        let isBlocked = await MainActor.run { recipient.isUserBlacklisted(self.appUser.mid) }
        if isBlocked {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("You cannot send a message to this user because you are blocked", comment: "Message blocked error")])
        }
        
        // Step 1: Send to sender's own node (message_outgoing) with retry
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
        
        
        // Step 2: Send to recipient's node (message_incoming) with retry
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
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserBaseUrl) = await MainActor.run { (self.appUser.mid, self.appUser.baseUrl) }
        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let entry = "message_fetch"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUserMid,
            "senderid": senderId
        ]
        
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
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
                if message.authorId != appUserMid {
                    // Return message with server's timestamp preserved
                    return message
                } else {
                    return nil
                }
            } catch {
                hproseError("[fetchMessages] Error decoding message: \(error)")
                return nil
            }
        }
    }
    
    /// Check for new incoming messages (only check, do not fetch them)
    func checkNewMessages() async throws -> [ChatMessage] {
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserBaseUrl, appUserIsGuest) = await MainActor.run { (self.appUser.mid, self.appUser.baseUrl, self.appUser.isGuest) }
        guard !appUserIsGuest else { return [] }

        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let entry = "message_check"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUserMid
        ]
        
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        
        let response = unwrappedResponse as? [[String: Any]] ?? []
        
        return response.compactMap { messageData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: messageData)
                let message = try JSONDecoder().decode(ChatMessage.self, from: jsonData)
                
                // Only return messages that are incoming (sent by others to current user)
                // Filter out messages sent by the current user
                if message.authorId != appUserMid {
                    // Return message with server's timestamp preserved
                    return message
                } else {
                    return nil
                }
            } catch {
                hproseError("[checkNewMessages] Error decoding message: \(error)")
                return nil
            }
        }
    }
    
    /// Check for app upgrades and update domain in preferences
    func checkAndUpdateDomain() async {
        
        let entry = "check_upgrade"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "entry": entry
        ]
        
        let appUserBaseUrl = await MainActor.run { self.appUser.baseUrl }
        guard let baseUrl = appUserBaseUrl else {
            hproseDebug("[checkAndUpdateDomain] Client not initialized")
            return
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params, priority: .background)
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        
        guard let response = unwrappedResponse as? [String: Any] else {
            hproseWarning("[checkAndUpdateDomain] Invalid response format")
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
            hproseDebug("[checkAndUpdateDomain] No upgrade domain received")
            return
        }
        
        // Keep the log deduplication and published domain update together so startup
        // and foreground checks can safely overlap.
        await MainActor.run {
            if lastLoggedUpgradeDomain != domain {
                hproseDebug("[checkAndUpdateDomain] Received domain: \(domain)")
                lastLoggedUpgradeDomain = domain
            }
            _domainToShare = "http://" + domain
        }
    }
    
    // MARK: - Content Moderation Methods
    
    /// Blocks a user
    func blockUser(userId: String) async throws {
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserBaseUrl) = await MainActor.run { (self.appUser.mid, self.appUser.baseUrl) }
        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let entry = "block_user"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUserMid,
            "blocked": userId
        ]
        
        _ = await invokeRunMApp(using: client, entry: entry, params: params)
    }
    
    /// Deletes the current user's account
    func deleteAccount() async throws -> [String: Any] {
        // Phase A (demotion prep): snapshot @MainActor appUser reads.
        let (appUserMid, appUserBaseUrl) = await MainActor.run { (self.appUser.mid, self.appUser.baseUrl) }
        guard let baseUrl = appUserBaseUrl else {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Client not initialized", comment: "Client initialization error")])
        }
        let client = clientPool.getClientByUrl(for: baseUrl.absoluteString, timeout: 15)

        let entry = "delete_account"
        let params: [String: Any] = [
            "aid": appId,
            "ver": "last",
            "version": "v2",
            "userid": appUserMid
        ]
        let rawResponse = await invokeRunMApp(using: client, entry: entry, params: params)
        let unwrappedResponse = try? Self.unwrapV2Response(rawResponse)
        return unwrappedResponse as? [String: Any] ?? [:]
    }
    
    /// Reports a tweet for inappropriate content and deletes it from backend
    func reportTweet(tweetId: String, tweetAuthorId: String, category: String, comments: String) async throws {
        // First, delete the tweet from backend
        _ = try await deleteTweet(tweetId, tweetAuthorId: tweetAuthorId)
        
        // Send notification to system admin about the reported and deleted content
        // Note: Admin notification failure won't affect tweet deletion success
        await notifySystemAdmin(tweetId: tweetId, category: category, comments: comments)
    }
    
    /// Send notification to system admin about reported and deleted content
    private func notifySystemAdmin(tweetId: String, category: String, comments: String) async {
        let adminUserId = Gadget.getAlphaIds().first ?? "" // System admin user ID
        // Phase A (demotion prep): snapshot @MainActor appUser.mid.
        let appUserMid = await MainActor.run { self.appUser.mid }

        // Create notification message
        let notificationContent = """
        🚨 CONTENT REPORT & DELETION ALERT 🚨

        Tweet ID: \(tweetId) - DELETED
        Category: \(category)
        Reporter: \(appUserMid)
        Comments: \(comments.isEmpty ? "None" : comments)
        Time: \(Date().formatted())

        Tweet has been automatically deleted from the platform due to reported content.
        Please review this action within 24 hours as per App Store compliance requirements.
        """

        // Create chat message
        let sessionId = ChatMessage.generateSessionId(userId: appUserMid, receiptId: adminUserId)
        let notificationMessage = ChatMessage(
            authorId: appUserMid,
            receiptId: adminUserId,
            chatSessionId: sessionId,
            content: notificationContent
        )
        
        do {
            let result = try await sendMessage(receiptId: adminUserId, message: notificationMessage)
            if result.success == true {
            } else {
                hproseError("[notifySystemAdmin] Failed to send notification to admin: \(result.errorMsg ?? "Unknown error")")
                // Log the failure but don't throw error - admin notification is not critical for tweet deletion
            }
        } catch {
            hproseError("[notifySystemAdmin] Error sending notification to admin: \(error)")
            // Log the error but don't throw - admin notification is not critical for tweet deletion
            // The tweet has already been deleted successfully, so we don't want to fail the entire operation
        }
    }
}

// NOTE: Array.chunked extension is now in TweetUploadManager.swift
