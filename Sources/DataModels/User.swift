import Foundation
import hprose

enum UserCacheStatus: String {
    case unknown
    case fresh
    case stale
    case refreshing
    case refreshFailed
}

class User: ObservableObject, Codable, Identifiable, Hashable {
    // MARK: - Singleton Dictionary
    private static var userInstances: [MimeiId: User] = [:]
    static let userInstancesQueue = DispatchQueue(label: "user.instances.queue")
    
    // MARK: - Properties
    @Published var mid: MimeiId
    @Published var baseUrl: URL? {
        didSet {
            let userId = mid
            Task { @MainActor in
                if baseUrl != oldValue {
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var writableUrl: URL?
    /// When writableUrl was last resolved. Used for the 5-minute TTL cache.
    var writableUrlResolvedAt: Date?
    @Published var name: String?
    @Published var username: String?
    @Published var password: String?
    @Published var avatar: MimeiId? {
        didSet {
            let userId = mid
            Task { @MainActor in
                if avatar != oldValue {
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var email: String?
    @Published var profile: String?
    @Published var timestamp: Date
    @Published var lastLogin: Date?
    @Published var cloudDrivePort: Int = 0
    @Published var domainToShare: String?
    
    @Published var tweetCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = tweetCount, count < 0 {
                tweetCount = 0
                return
            }
            
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when tweetCount changes
                if let newValue = tweetCount, newValue != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.tweetCount = newValue
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var followingCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = followingCount, count < 0 {
                followingCount = 0
                return
            }
            
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when followingCount changes
                if let newValue = followingCount, newValue != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.followingCount = newValue
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var followersCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = followersCount, count < 0 {
                followersCount = 0
                return
            }
            
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when followersCount changes
                if let newValue = followersCount, newValue != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.followersCount = newValue
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var bookmarksCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = bookmarksCount, count < 0 {
                bookmarksCount = 0
                return
            }
            
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when bookmarksCount changes
                if let newValue = bookmarksCount, newValue != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.bookmarksCount = newValue
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var favoritesCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = favoritesCount, count < 0 {
                favoritesCount = 0
                return
            }
            
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when favoritesCount changes
                if let newValue = favoritesCount, newValue != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.favoritesCount = newValue
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var commentsCount: Int? {
        didSet {
            // Ensure count never goes below zero
            if let count = commentsCount, count < 0 {
                commentsCount = 0
                return
            }
        }
    }
    
    @Published var hostIds: [MimeiId]? // hostIds[0]=writable host, hostIds[1]=best access node
    /// For read RPCs: prefer hostIds[1] (best access node from provider resolution), fall back to hostIds[0].
    var accessHostId: MimeiId? { hostIds.flatMap { $0.count > 1 ? $0[1] : $0.first } }
    @Published var hasAcceptedTerms: Bool = false // Terms of Service acceptance
    @Published var publicKey: String?
    @Published var agentPublicKey: String? // Public key for AI agent authentication
    
    public var hproseClient: HproseClient? {
        get {
            guard let baseUrl = baseUrl else { 
                return nil 
            }
            
            let client = HproseInstance.shared.clientPool.getClientByUrl(for: baseUrl.absoluteString)
            
            // Configure timeout for regular operations (15 seconds - fast fail for bad servers)
            client.timeout = 15  // 15 seconds (detect slow/dead servers quickly)
            
            return client
        }
    }
    
    /// Hprose client targeting the user's writable node. Use for any RPC that
    /// mutates server-side data (uploads, toggles, edits, deletes) so the
    /// request lands directly on the writable host instead of being delegated.
    /// Returns nil when the writable URL hasn't been resolved yet — callers
    /// should treat that as an error.
    public var writableClient: HproseClient? {
        get {
            guard let writableUrl = writableUrl else {
                return nil
            }

            let client = HproseInstance.shared.clientPool.getClientByUrl(for: writableUrl.absoluteString)

            // Default timeout: 10s. Fast-fail on bad servers. Long-running mutations
            // (e.g. file uploads use URLSession with its own 10-minute timeout;
            // toggle operations override this per-call to ~30s).
            client.timeout = 10

            return client
        }
    }
    
    @MainActor
    func resetClients() {
        // With clientPool, we don't need to manually close clients
        // The pool manages lifecycle. We can clear the pool for specific URLs if needed
        if let baseUrl = baseUrl {
            let urlString = "\(baseUrl)/webapi/"
            HproseInstance.shared.clientPool.clear(for: urlString)
        }
        
        if let writableUrl = writableUrl {
            let urlString = "\(writableUrl)/webapi/"
            HproseInstance.shared.clientPool.clear(for: urlString)
        }
    }
    
    @Published var fansList: [MimeiId]? // List of MimeiId
    @Published var followingList: [MimeiId]? // List of MimeiId
    @Published var bookmarkedTweets: [MimeiId]? {
        didSet {
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when bookmarkedTweets changes
                if bookmarkedTweets != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.bookmarkedTweets = bookmarkedTweets
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var favoriteTweets: [MimeiId]? {
        didSet {
            let userId = mid  // Capture mid before Task to avoid race conditions
            Task { @MainActor in
                // Update cached version when favoriteTweets changes
                if favoriteTweets != oldValue {
                    // Update the singleton instance in the cache (thread-safe)
                    User.userInstancesQueue.sync {
                        User.userInstances[userId]?.favoriteTweets = favoriteTweets
                    }
                    // Also update Core Data cache if this is the app user
                    if userId == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var repliedTweets: [MimeiId]? // List of MimeiId
    @Published var commentsList: [MimeiId]? // List of MimeiId
    @Published var topTweets: [MimeiId]? // List of MimeiId
    @Published var userBlackList: [MimeiId]? // List of MimeiId
    @Published var cacheStatus: UserCacheStatus = .unknown
    
    var id: String { mid }  // Computed property that returns mid
    
    // MARK: - Initialization
    init(
        mid: MimeiId = Constants.GUEST_ID,
        baseUrl: URL? = nil,
        name: String? = nil,
        username: String? = nil,
        password: String? = nil,
        avatar: MimeiId? = nil,
        email: String? = nil,
        profile: String? = nil,
        cloudDrivePort: Int = 0,
        domainToShare: String? = nil,
        hostIds: [MimeiId]? = nil,
        publicKey: String? = nil,
        hasAcceptedTerms: Bool = false
    ) {
        self.mid = mid
        self.baseUrl = baseUrl
        self.name = name
        self.username = username
        self.password = password
        self.avatar = User.sanitizedAvatarId(avatar)
        self.email = email
        self.profile = profile
        self.timestamp = Date.now
        self.lastLogin = Date.now
        self.cloudDrivePort = cloudDrivePort
        self.domainToShare = domainToShare
        self.tweetCount = nil
        self.followingCount = nil
        self.followersCount = nil
        self.bookmarksCount = nil
        self.favoritesCount = nil
        self.commentsCount = nil
        self.hostIds = hostIds
        self.publicKey = publicKey
        self.hasAcceptedTerms = hasAcceptedTerms
        self.cacheStatus = .unknown
    }
    
    // MARK: - Factory Methods
    static func getInstance(mid: MimeiId) -> User {
        return userInstancesQueue.sync {
            if let existingUser = User.userInstances[mid] {
                return existingUser
            }
            let newUser = User(mid: mid)
            User.userInstances[mid] = newUser
            return newUser
        }
    }
    
    /// Get all user instances (for search functionality)
    static func getAllInstances() -> [String: User] {
        return userInstancesQueue.sync {
            return userInstances
        }
    }
    
    /// Update user instance with backend data. Keep current baseUrl
    static func from(dict: [String: Any]) throws -> User {
        do {
            // Convert NSArray objects to proper JSON arrays and handle type conversions
            var sanitizedDict = dict
            var explicitNullFields: Set<String> = []
            for (key, value) in dict {
                if key == CodingKeys.avatar.rawValue {
                    if let avatar = value as? String,
                       let sanitizedAvatar = sanitizedAvatarId(avatar) {
                        sanitizedDict[key] = sanitizedAvatar
                    } else {
                        sanitizedDict.removeValue(forKey: key)
                    }
                } else if let nsArray = value as? NSArray {
                    // Convert NSArray to Swift Array
                    let swiftArray = nsArray.compactMap { $0 as? String }
                    sanitizedDict[key] = swiftArray
                } else if key == "cloudDrivePort" {
                    // Handle cloudDrivePort: convert to Int from String, NSNumber, or Int
                    if let number = value as? NSNumber {
                        sanitizedDict[key] = number.intValue
                    } else if let string = value as? String, let intValue = Int(string) {
                        sanitizedDict[key] = intValue
                    } else if value is Int {
                        // Already Int, keep as is
                        sanitizedDict[key] = value
                    } else {
                        // Invalid type, use 0 as default
                        sanitizedDict[key] = 0
                    }
                } else if !JSONSerialization.isValidJSONObject([key: value]) {
                } else if value is NSNull {
                    explicitNullFields.insert(key)
                }
            }
            
            let jsonData = try JSONSerialization.data(withJSONObject: sanitizedDict, options: [])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decodedUser = try decoder.decode(User.self, from: jsonData)
            
            // CRITICAL: Always preserve the existing baseUrl from the singleton instance
            // The backend may send a baseUrl from hostId[0], but we need the user's provider IP
            // which is resolved via getProviderIP(user.mid), not from hostId
            let instance = getInstance(mid: decodedUser.mid)
            decodedUser.baseUrl = instance.baseUrl  // Preserve provider IP, ignore backend baseUrl
            decodedUser.writableUrl = instance.writableUrl
            
            updateUserInstance(with: decodedUser, nilFieldsToClear: explicitNullFields)
            return userInstancesQueue.sync {
                User.userInstances[decodedUser.mid]!
            }
        } catch {
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("ERROR: [User.from] Missing key '\(key)' at path: \(context.codingPath)")
                case .typeMismatch(let type, let context):
                    print("ERROR: [User.from] Type mismatch for type '\(type)' at path: \(context.codingPath)")
                case .valueNotFound(let type, let context):
                    print("ERROR: [User.from] Value not found for type '\(type)' at path: \(context.codingPath)")
                case .dataCorrupted(let context):
                    print("ERROR: [User.from] Data corrupted at path: \(context.codingPath)")
                @unknown default:
                    print("ERROR: [User.from] Unknown decoding error")
                }
            }
            throw NSError(domain: "User", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode dict to user: \(error.localizedDescription)"])
        }
    }

    static func sanitizedAvatarId(_ value: String?) -> MimeiId? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let nullSentinels: Set<String> = ["null", "nil", "none", "undefined", "<null>", "(null)"]
        guard !nullSentinels.contains(lowercased) else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        guard !trimmed.contains("://"),
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            return nil
        }

        return trimmed
    }
    
    static func from(cdUser: CDUser) -> User {
        // Try to decode the full user object from cache.
        if let userData = cdUser.userData,
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
            // baseUrl is persisted in cache and should be loaded
            // Pass true to apply cached baseUrl so avatar can load immediately on app start
            updateUserInstance(with: decodedUser, true)
        }
        return getInstance(mid: cdUser.mid ?? Constants.GUEST_ID)
    }
    
    static func updateUserInstance(
        with user: User,
        _ shouldUpdateBaseUrl: Bool = false,
        nilFieldsToClear: Set<String> = []
    ) {
        let instance = getInstance(mid: user.mid)
        
        // Update synchronously if already on MainActor, otherwise dispatch to MainActor
        if Thread.isMainThread {
            mergeUserData(
                into: instance,
                from: user,
                shouldUpdateBaseUrl: shouldUpdateBaseUrl,
                nilFieldsToClear: nilFieldsToClear
            )
        } else {
            DispatchQueue.main.async {
                mergeUserData(
                    into: instance,
                    from: user,
                    shouldUpdateBaseUrl: shouldUpdateBaseUrl,
                    nilFieldsToClear: nilFieldsToClear
                )
            }
        }
    }

    private static func mergeUserData(
        into instance: User,
        from user: User,
        shouldUpdateBaseUrl: Bool,
        nilFieldsToClear: Set<String>
    ) {
        instance.name = user.name ?? instance.name
        instance.username = user.username ?? instance.username
        instance.password = user.password ?? instance.password
        if let avatar = sanitizedAvatarId(user.avatar) {
            instance.avatar = avatar
        }
        instance.email = user.email ?? instance.email
        instance.profile = user.profile ?? instance.profile
        instance.timestamp = user.timestamp
        instance.lastLogin = user.lastLogin ?? instance.lastLogin
        instance.cloudDrivePort = user.cloudDrivePort
        instance.domainToShare = user.domainToShare ?? instance.domainToShare
        instance.hostIds = user.hostIds ?? instance.hostIds
        instance.publicKey = user.publicKey ?? instance.publicKey
        instance.agentPublicKey = user.agentPublicKey ?? instance.agentPublicKey

        // Base URLs are only committed from validated routes or cache load.
        if shouldUpdateBaseUrl, let newBaseUrl = user.baseUrl {
            instance.baseUrl = newBaseUrl
        }
        if let newWritableUrl = user.writableUrl {
            instance.writableUrl = newWritableUrl
        }

        if let v = user.tweetCount {
            if instance.tweetCount != v {
                print("DEBUG: [User.updateUserInstance] Updating tweetCount from \(instance.tweetCount ?? 0) to \(v) for user \(instance.mid)")
            }
            instance.tweetCount = v
        }
        if let v = user.followingCount { instance.followingCount = v }
        if let v = user.followersCount { instance.followersCount = v }
        if let v = user.bookmarksCount { instance.bookmarksCount = v }
        if let v = user.favoritesCount { instance.favoritesCount = v }
        if let v = user.commentsCount { instance.commentsCount = v }

        // Update collection properties only when the source provided them.
        // Empty arrays are still authoritative; nil means "not included".
        if let v = user.fansList { instance.fansList = v }
        if let v = user.followingList { instance.followingList = v }
        if let v = user.bookmarkedTweets { instance.bookmarkedTweets = v }
        if let v = user.favoriteTweets { instance.favoriteTweets = v }
        if let v = user.repliedTweets { instance.repliedTweets = v }
        if let v = user.commentsList { instance.commentsList = v }
        if let v = user.topTweets { instance.topTweets = v }
        if let v = user.userBlackList { instance.userBlackList = v }

        for field in nilFieldsToClear {
            switch field {
            case CodingKeys.name.rawValue:
                instance.name = nil
            case CodingKeys.password.rawValue:
                instance.password = nil
            case CodingKeys.avatar.rawValue:
                break
            case CodingKeys.email.rawValue:
                instance.email = nil
            case CodingKeys.profile.rawValue:
                instance.profile = nil
            case CodingKeys.domainToShare.rawValue:
                instance.domainToShare = nil
            case CodingKeys.publicKey.rawValue:
                instance.publicKey = nil
            case CodingKeys.agentPublicKey.rawValue:
                instance.agentPublicKey = nil
            default:
                break
            }
        }
    }
    
    // CodingKeys to handle @Published properties
    enum CodingKeys: String, CodingKey {
        case mid, baseUrl, writableUrl, name, username, password, avatar, email, profile, timestamp, lastLogin, cloudDrivePort, domainToShare
        case tweetCount, followingCount, followersCount, bookmarksCount, favoritesCount, commentsCount
        case hostIds, publicKey, agentPublicKey, fansList, followingList, bookmarkedTweets, favoriteTweets, repliedTweets, commentsList, topTweets, userBlackList
    }
    
    // Required initializer for Codable
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        mid = try container.decode(String.self, forKey: .mid)
        baseUrl = try container.decodeIfPresent(URL.self, forKey: .baseUrl)
        writableUrl = try container.decodeIfPresent(URL.self, forKey: .writableUrl)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        avatar = User.sanitizedAvatarId(try container.decodeIfPresent(String.self, forKey: .avatar))
        email = try container.decodeIfPresent(String.self, forKey: .email)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.now
        lastLogin = try container.decodeIfPresent(Date.self, forKey: .lastLogin)
        cloudDrivePort = try container.decodeIfPresent(Int.self, forKey: .cloudDrivePort) ?? 0
        domainToShare = try container.decodeIfPresent(String.self, forKey: .domainToShare)
        
        tweetCount = try container.decodeIfPresent(Int.self, forKey: .tweetCount)
        followingCount = try container.decodeIfPresent(Int.self, forKey: .followingCount)
        followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount)
        bookmarksCount = try container.decodeIfPresent(Int.self, forKey: .bookmarksCount)
        favoritesCount = try container.decodeIfPresent(Int.self, forKey: .favoritesCount)
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount)
        
        hostIds = try container.decodeIfPresent([String].self, forKey: .hostIds)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        agentPublicKey = try container.decodeIfPresent(String.self, forKey: .agentPublicKey)
        
        fansList = try container.decodeIfPresent([String].self, forKey: .fansList)
        followingList = try container.decodeIfPresent([String].self, forKey: .followingList)
        bookmarkedTweets = try container.decodeIfPresent([String].self, forKey: .bookmarkedTweets)
        favoriteTweets = try container.decodeIfPresent([String].self, forKey: .favoriteTweets)
        repliedTweets = try container.decodeIfPresent([String].self, forKey: .repliedTweets)
        commentsList = try container.decodeIfPresent([String].self, forKey: .commentsList)
        topTweets = try container.decodeIfPresent([String].self, forKey: .topTweets)
        userBlackList = try container.decodeIfPresent([String].self, forKey: .userBlackList)
        cacheStatus = .unknown
    }
    
    // Encode method for Codable
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(mid, forKey: .mid)
        // NOW caching baseUrl for faster app restarts
        // Safe because retry mechanism automatically re-resolves if IP changed
        try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
        // Don't cache writableUrl - resolved fresh from hostIds each time
        // try container.encodeIfPresent(writableUrl, forKey: .writableUrl)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(User.sanitizedAvatarId(avatar), forKey: .avatar)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(lastLogin, forKey: .lastLogin)
        try container.encode(cloudDrivePort, forKey: .cloudDrivePort)
        try container.encodeIfPresent(domainToShare, forKey: .domainToShare)
        
        try container.encodeIfPresent(tweetCount, forKey: .tweetCount)
        try container.encodeIfPresent(followingCount, forKey: .followingCount)
        try container.encodeIfPresent(followersCount, forKey: .followersCount)
        try container.encodeIfPresent(bookmarksCount, forKey: .bookmarksCount)
        try container.encodeIfPresent(favoritesCount, forKey: .favoritesCount)
        try container.encodeIfPresent(commentsCount, forKey: .commentsCount)
        
        try container.encodeIfPresent(hostIds, forKey: .hostIds)
        try container.encodeIfPresent(publicKey, forKey: .publicKey)
        try container.encodeIfPresent(agentPublicKey, forKey: .agentPublicKey)
        
        try container.encodeIfPresent(fansList, forKey: .fansList)
        try container.encodeIfPresent(followingList, forKey: .followingList)
        try container.encodeIfPresent(bookmarkedTweets, forKey: .bookmarkedTweets)
        try container.encodeIfPresent(favoriteTweets, forKey: .favoriteTweets)
        try container.encodeIfPresent(repliedTweets, forKey: .repliedTweets)
        try container.encodeIfPresent(commentsList, forKey: .commentsList)
        try container.encodeIfPresent(topTweets, forKey: .topTweets)
        try container.encodeIfPresent(userBlackList, forKey: .userBlackList)
    }
    
    var isGuest: Bool {
        return mid == Constants.GUEST_ID
    }
    
    /**
     * Check if the app user is in this user's blacklist
     * @param appUserId The app user's ID to check
     * @return true if app user is blacklisted, false otherwise
     */
    func isUserBlacklisted(_ appUserId: MimeiId) -> Bool {
        return userBlackList?.contains(appUserId) ?? false
    }
    
    var avatarUrl: String? {
        if let avatar = avatar {
            // Use user's baseUrl if available, otherwise fallback to HproseInstance.baseUrl
            // This ensures avatars load even when cached user doesn't have baseUrl yet (e.g., at app startup)
            let effectiveBaseUrl = baseUrl ?? HproseInstance.baseUrl
            return avatar.count > Constants.MIMEI_ID_LENGTH ? "\(effectiveBaseUrl)/ipfs/\(avatar)" :  "\(effectiveBaseUrl)/mm/\(avatar)"
        }
        return nil
    }
    
    /// Checks if the user's cached data has expired (30 minutes)
    /// Returns true if the user is not cached or if the cache has expired
    func hasExpired() async -> Bool {
        // Check if user exists in cache and if cache has expired
        return await TweetCacheManager.shared.hasExpired(mid: mid)
    }

    // MARK: - Hashable
    static func == (lhs: User, rhs: User) -> Bool {
        return lhs.mid == rhs.mid
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(mid)
    }
    
    // MARK: - Writable URL Resolution

    /// Tracks an in-flight `resolveWritableUrl()` call so concurrent first-time
    /// callers all await the same Task instead of each performing a redundant
    /// network resolution.
    private var resolveWritableUrlTask: Task<URL, Error>?

    /// Returns the writable URL for the user, resolving via hostIds if needed.
    /// Follows NodePool pattern: check pool -> resolve fresh -> update pool on success.
    /// Throws if no host ID is configured or the writable host can't be reached;
    /// otherwise always returns a valid URL.
    @MainActor
    func resolveWritableUrl() async throws -> URL {
        // Return cached URL if it was resolved within the last 5 minutes.
        let ttl: TimeInterval = 5 * 60
        if let url = writableUrl, let resolvedAt = writableUrlResolvedAt,
           Date().timeIntervalSince(resolvedAt) < ttl {
            print("DEBUG: [resolveWritableUrl] Using cached writableUrl (age \(Int(Date().timeIntervalSince(resolvedAt)))s): \(url.absoluteString)")
            return url
        }

        // Coalesce concurrent callers onto a single in-flight Task.
        if let inFlight = resolveWritableUrlTask {
            print("DEBUG: [resolveWritableUrl] Awaiting in-flight resolve Task")
            return try await inFlight.value
        }

        let task = Task<URL, Error> { @MainActor in
            defer { self.resolveWritableUrlTask = nil }
            return try await self.performWritableUrlResolution()
        }
        resolveWritableUrlTask = task
        return try await task.value
    }

    @MainActor
    private func performWritableUrlResolution() async throws -> URL {
        guard let hostId = self.hostIds?.first, !hostId.isEmpty else {
            print("ERROR: [resolveWritableUrl] hostIds[0] is nil or empty")
            throw NSError(domain: "HproseService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Upload server not configured. Please set Host ID in profile settings.", comment: "Upload error")
            ])
        }

        print("DEBUG: [resolveWritableUrl] Resolving fresh IP for writable host \(hostId)")

        // Always go through getHostIP — it validates any NodePool-cached entry with a
        // health check before returning it, so stale IPs are rejected automatically.
        if let hostIP = await HproseInstance.shared.getHostIP(hostId, v4Only: true),
           let url = URL(string: "http://\(hostIP)") {
            print("DEBUG: [resolveWritableUrl] ✅ Health-checked IP: \(hostIP)")
            NodePool.shared.updateNodeIP(nodeMid: hostId, newIP: "http://\(hostIP)")
            self.writableUrl = url
            self.writableUrlResolvedAt = Date()
            return url
        }

        print("ERROR: [resolveWritableUrl] getHostIP returned nil for hostId: \(hostId)")
        throw NSError(domain: "HproseService", code: -1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString("Upload server not responding. Please try again later.", comment: "Upload error"),
            NSLocalizedFailureReasonErrorKey: "Writable host \(hostId) failed health check"
        ])
    }
}
