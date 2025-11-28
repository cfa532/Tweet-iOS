 import Foundation
import Combine
import hprose

class User: ObservableObject, Codable, Identifiable, Hashable {
    // MARK: - Singleton Dictionary
    private static var userInstances: [MimeiId: User] = [:]
    static let userInstancesQueue = DispatchQueue(label: "user.instances.queue")
    
    // MARK: - Properties
    @Published var mid: MimeiId
    @Published var baseUrl: URL?
    @Published var writableUrl: URL?
    @Published var name: String?
    @Published var username: String?
    @Published var password: String?
    @Published var avatar: MimeiId? // MimeiId
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
    
    @Published var hostIds: [MimeiId]? // List of MimeiId
    @Published var hasAcceptedTerms: Bool = false // Terms of Service acceptance
    @Published var publicKey: String?
    private var _hproseClient: HproseClient?
    public var hproseClient: HproseClient? {
        get {
            guard let baseUrl = baseUrl else { 
                return nil 
            }

            if let cached = _hproseClient {
                return cached
            } else {
                if baseUrl == HproseInstance.shared.appUser.baseUrl {
                    // Create a new client since the shared one is private
                    let client = HproseHttpClient()
                    client.timeout = 300000  // 5 minutes in milliseconds (matches Kotlin regular client)
                    client.uri = "\(baseUrl)/webapi/"
                    _hproseClient = client
                    return client
                } else {
                    let client = HproseHttpClient()
                    client.timeout = 300000  // 5 minutes in milliseconds (matches Kotlin regular client)
                    client.uri = "\(baseUrl)/webapi/"
                    _hproseClient = client
                    return client
                }
            }
        }
    }
    private var _uploadClient: HproseClient?
    public var uploadClient: HproseClient? {
        get {
            guard let writableUrl = writableUrl else { 
                return nil 
            }

            if let cached = _uploadClient {
                return cached
            } else {
                if writableUrl == HproseInstance.shared.appUser.baseUrl {
                    // Use the main hprose client if available, otherwise create a new one
                    // Create a new client for upload
                    let client = HproseHttpClient()
                    client.timeout = 3000000  // 50 minutes (same as Kotlin) for large uploads
                    client.uri = "\(writableUrl)/webapi/"
                    _uploadClient = client
                    return client
                } else {
                    let client = HproseHttpClient()
                    client.timeout = 3000000  // 50 minutes (same as Kotlin) for large uploads
                    client.uri = "\(writableUrl)/webapi/"
                    _uploadClient = client
                    return client
                }
            }
        }
    }
    
    @MainActor
    func resetClients() {
        if let httpClient = _hproseClient as? HproseHttpClient {
            httpClient.close()
        }
        if let uploadClient = _uploadClient as? HproseHttpClient {
            uploadClient.close()
        }
        _hproseClient = nil
        _uploadClient = nil
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
    
    var id: String { mid }  // Computed property that returns mid
    
    private var baseUrlCancellable: AnyCancellable?
    private var writableUrlCancellable: AnyCancellable?
    
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
        self.avatar = avatar
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
        // Observe baseUrl changes to clear cached clients
        baseUrlCancellable = $baseUrl
            .sink { [weak self] _ in
                self?._hproseClient = nil
                self?._uploadClient = nil
            }
        
        // Observe writableUrl changes to clear upload client cache
        writableUrlCancellable = $writableUrl
            .sink { [weak self] _ in
                self?._uploadClient = nil
            }
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
            for (key, value) in dict {
                if let nsArray = value as? NSArray {
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
            
            updateUserInstance(with: decodedUser)
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
    
    static func from(cdUser: CDUser) -> User {
        // Try to decode the full user object from cache.
        if let userData = cdUser.userData,
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
            // baseUrl is now persisted (since retry mechanism handles stale IPs)
            // writableUrl is NOT persisted (resolved fresh from hostIds each time)
            updateUserInstance(with: decodedUser)
        }
        return getInstance(mid: cdUser.mid ?? Constants.GUEST_ID)
    }
    
    static func updateUserInstance(with user: User) {
        let instance = getInstance(mid: user.mid)
        
        // Update synchronously if already on MainActor, otherwise dispatch to MainActor
        if Thread.isMainThread {
            instance.name = user.name
            instance.username = user.username
            instance.password = user.password
            instance.avatar = user.avatar
            instance.email = user.email
            instance.profile = user.profile
            instance.timestamp = user.timestamp
            instance.lastLogin = user.lastLogin
            instance.cloudDrivePort = user.cloudDrivePort
            instance.domainToShare = user.domainToShare
            instance.hostIds = user.hostIds
            
            // CRITICAL: Never overwrite baseUrl from user parameter - it might be from hostId[0]
            // baseUrl should only be set via getProviderIP(user.mid) in HproseInstance
            // Preserve the existing baseUrl that was correctly resolved from provider IP
            // writableUrl: Not persisted, resolved fresh from hostIds
            // Note: baseUrl is preserved above in User.from(dict:), so we don't overwrite it here
            if let newWritableUrl = user.writableUrl {
                instance.writableUrl = newWritableUrl
            }
            
            if instance.tweetCount != user.tweetCount {
                print("DEBUG: [User.updateUserInstance] Updating tweetCount from \(instance.tweetCount ?? 0) to \(user.tweetCount ?? 0) for user \(instance.mid)")
            }
            instance.tweetCount = user.tweetCount
            instance.followingCount = user.followingCount
            instance.followersCount = user.followersCount
            instance.bookmarksCount = user.bookmarksCount
            instance.favoritesCount = user.favoritesCount
            instance.commentsCount = user.commentsCount
            
            // Update array properties
            instance.fansList = user.fansList
            instance.followingList = user.followingList
            instance.bookmarkedTweets = user.bookmarkedTweets
            instance.favoriteTweets = user.favoriteTweets
            instance.repliedTweets = user.repliedTweets
            instance.commentsList = user.commentsList
            instance.topTweets = user.topTweets
            instance.userBlackList = user.userBlackList
        } else {
            DispatchQueue.main.async {
                instance.name = user.name
                instance.username = user.username
                instance.password = user.password
                instance.avatar = user.avatar
                instance.email = user.email
                instance.profile = user.profile
                instance.timestamp = user.timestamp
                instance.lastLogin = user.lastLogin
                instance.cloudDrivePort = user.cloudDrivePort
                instance.domainToShare = user.domainToShare
                instance.hostIds = user.hostIds
                
                // CRITICAL: Never overwrite baseUrl from user parameter - it might be from hostId[0]
                // baseUrl should only be set via getProviderIP(user.mid) in HproseInstance
                // Preserve the existing baseUrl that was correctly resolved from provider IP
                // writableUrl: Not persisted, resolved fresh from hostIds
                // Note: baseUrl is preserved above in User.from(dict:), so we don't overwrite it here
                if let newWritableUrl = user.writableUrl {
                    instance.writableUrl = newWritableUrl
                }
                
                if instance.tweetCount != user.tweetCount {
                    print("DEBUG: [User.updateUserInstance] Updating tweetCount from \(instance.tweetCount ?? 0) to \(user.tweetCount ?? 0) for user \(instance.mid)")
                }
                instance.tweetCount = user.tweetCount
                instance.followingCount = user.followingCount
                instance.followersCount = user.followersCount
                instance.bookmarksCount = user.bookmarksCount
                instance.favoritesCount = user.favoritesCount
                instance.commentsCount = user.commentsCount
                
                // Update array properties
                instance.fansList = user.fansList
                instance.followingList = user.followingList
                instance.bookmarkedTweets = user.bookmarkedTweets
                instance.favoriteTweets = user.favoriteTweets
                instance.repliedTweets = user.repliedTweets
                instance.commentsList = user.commentsList
                instance.topTweets = user.topTweets
                instance.userBlackList = user.userBlackList
            }
        }
    }
    
    // CodingKeys to handle @Published properties
    enum CodingKeys: String, CodingKey {
        case mid, baseUrl, writableUrl, name, username, password, avatar, email, profile, timestamp, lastLogin, cloudDrivePort, domainToShare
        case tweetCount, followingCount, followersCount, bookmarksCount, favoritesCount, commentsCount
        case hostIds, publicKey, fansList, followingList, bookmarkedTweets, favoriteTweets, repliedTweets, commentsList, topTweets, userBlackList
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
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
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
        
        fansList = try container.decodeIfPresent([String].self, forKey: .fansList)
        followingList = try container.decodeIfPresent([String].self, forKey: .followingList)
        bookmarkedTweets = try container.decodeIfPresent([String].self, forKey: .bookmarkedTweets)
        favoriteTweets = try container.decodeIfPresent([String].self, forKey: .favoriteTweets)
        repliedTweets = try container.decodeIfPresent([String].self, forKey: .repliedTweets)
        commentsList = try container.decodeIfPresent([String].self, forKey: .commentsList)
        topTweets = try container.decodeIfPresent([String].self, forKey: .topTweets)
        userBlackList = try container.decodeIfPresent([String].self, forKey: .userBlackList)
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
        try container.encodeIfPresent(avatar, forKey: .avatar)
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
            // baseUrl now usually available (cached from disk), fallback for edge cases
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
    /// Returns the writable URL for the user, resolving via hostIds if needed
    @MainActor
    func resolveWritableUrl() async throws -> URL? {
        if let writableUrl = self.writableUrl {
            return writableUrl
        }
        if let hostId = self.hostIds?.first, !hostId.isEmpty {
            if let hostIP = await HproseInstance.shared.getHostIP(hostId, v4Only: "true") {
                let url = URL(string: "http://\(hostIP)")
                self.writableUrl = url
                return url
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No writable url available"])
    }
}
