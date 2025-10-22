import Foundation
import Combine
import hprose

class User: ObservableObject, Codable, Identifiable, Hashable {
    // MARK: - Singleton Dictionary
    private static var userInstances: [MimeiId: User] = [:]
    private static let userInstancesQueue = DispatchQueue(label: "user.instances.queue")
    
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
    
    @Published var tweetCount: Int? {
        didSet {
            Task { @MainActor in
                // Update cached version when tweetCount changes
                if let newValue = tweetCount, newValue != oldValue {
                    // Update the singleton instance in the cache
                    User.userInstances[mid]?.tweetCount = newValue
                    // Also update Core Data cache if this is the app user
                    if mid == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var followingCount: Int? {
        didSet {
            Task { @MainActor in
                // Update cached version when followingCount changes
                if let newValue = followingCount, newValue != oldValue {
                    // Update the singleton instance in the cache
                    User.userInstances[mid]?.followingCount = newValue
                    // Also update Core Data cache if this is the app user
                    if mid == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var followersCount: Int? {
        didSet {
            Task { @MainActor in
                // Update cached version when followersCount changes
                if let newValue = followersCount, newValue != oldValue {
                    // Update the singleton instance in the cache
                    User.userInstances[mid]?.followersCount = newValue
                    // Also update Core Data cache if this is the app user
                    if mid == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var bookmarksCount: Int? {
        didSet {
            Task { @MainActor in
                // Update cached version when bookmarksCount changes
                if let newValue = bookmarksCount, newValue != oldValue {
                    // Update the singleton instance in the cache
                    User.userInstances[mid]?.bookmarksCount = newValue
                    // Also update Core Data cache if this is the app user
                    if mid == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var favoritesCount: Int? {
        didSet {
            Task { @MainActor in
                // Update cached version when favoritesCount changes
                if let newValue = favoritesCount, newValue != oldValue {
                    // Update the singleton instance in the cache
                    User.userInstances[mid]?.favoritesCount = newValue
                    // Also update Core Data cache if this is the app user
                    if mid == HproseInstance.shared.appUser.mid {
                        TweetCacheManager.shared.saveUser(self)
                    }
                }
            }
        }
    }
    @Published var commentsCount: Int?
    
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
    
    @Published var fansList: [MimeiId]? // List of MimeiId
    @Published var followingList: [MimeiId]? // List of MimeiId
    @Published var bookmarkedTweets: [MimeiId]? // List of MimeiId
    @Published var favoriteTweets: [MimeiId]? // List of MimeiId
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
    
    /// Update all user singletons that have localhost baseUrl to use the real IP
    @MainActor
    static func updateAllUsersWithLocalhostToRealIP(realIP: URL) {
        let localhostPattern = "127.0.0.1"
        var usersToUpdate: [(String, User)] = []
        
        // Collect users to update outside of main thread
        userInstancesQueue.sync {
            print("DEBUG: [User] Checking \(User.userInstances.count) cached users for localhost URLs")
            for (mid, user) in User.userInstances {
                if let currentBaseUrl = user.baseUrl, currentBaseUrl.absoluteString.contains(localhostPattern) {
                    usersToUpdate.append((mid, user))
                }
            }
        }
        
        // Update all users in a single batch on MainActor (already on it)
        for (mid, user) in usersToUpdate {
            print("DEBUG: [User] Updating user \(mid) from \(user.baseUrl?.absoluteString ?? "nil") to \(realIP.absoluteString)")
            user.baseUrl = realIP
        }
        print("✅ [User] Updated \(usersToUpdate.count) users from localhost to real IP: \(realIP.absoluteString)")
    }
    
    /// Update user instance with backend data. Keep current baseUrl
    static func from(dict: [String: Any]) throws -> User {
        do {
            // Convert NSArray objects to proper JSON arrays
            var sanitizedDict = dict
            for (key, value) in dict {
                if let nsArray = value as? NSArray {
                    // Convert NSArray to Swift Array
                    let swiftArray = nsArray.compactMap { $0 as? String }
                    sanitizedDict[key] = swiftArray
                } else if !JSONSerialization.isValidJSONObject([key: value]) {
                }
            }
            
            let jsonData = try JSONSerialization.data(withJSONObject: sanitizedDict, options: [])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decodedUser = try decoder.decode(User.self, from: jsonData)
            
            // keep original baseUrl when updated by user dictionary from backend.
            let instance = getInstance(mid: decodedUser.mid)
            decodedUser.baseUrl = instance.baseUrl
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
            // baseUrl and writableUrl are not persisted to Core Data
            // They will be nil and resolved fresh on first use
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
            instance.lastLogin = user.lastLogin
            instance.cloudDrivePort = user.cloudDrivePort
            instance.hostIds = user.hostIds
            
            // Only update baseUrl/writableUrl if the new value is non-nil
            // This preserves memory-cached IPs when loading from disk (where IPs are not persisted)
            if let newBaseUrl = user.baseUrl {
                instance.baseUrl = newBaseUrl
            }
            if let newWritableUrl = user.writableUrl {
                instance.writableUrl = newWritableUrl
            }
            
            instance.tweetCount = user.tweetCount
            instance.followingCount = user.followingCount
            instance.followersCount = user.followersCount
            instance.bookmarksCount = user.bookmarksCount
            instance.favoritesCount = user.favoritesCount
            instance.commentsCount = user.commentsCount
        } else {
            DispatchQueue.main.async {
                instance.name = user.name
                instance.username = user.username
                instance.password = user.password
                instance.avatar = user.avatar
                instance.email = user.email
                instance.profile = user.profile
                instance.lastLogin = user.lastLogin
                instance.cloudDrivePort = user.cloudDrivePort
                instance.hostIds = user.hostIds
                
                // Only update baseUrl/writableUrl if the new value is non-nil
                // This preserves memory-cached IPs when loading from disk (where IPs are not persisted)
                if let newBaseUrl = user.baseUrl {
                    instance.baseUrl = newBaseUrl
                }
                if let newWritableUrl = user.writableUrl {
                    instance.writableUrl = newWritableUrl
                }
                
                instance.tweetCount = user.tweetCount
                instance.followingCount = user.followingCount
                instance.followersCount = user.followersCount
                instance.bookmarksCount = user.bookmarksCount
                instance.favoritesCount = user.favoritesCount
                instance.commentsCount = user.commentsCount
            }
        }
    }
    
    // CodingKeys to handle @Published properties
    enum CodingKeys: String, CodingKey {
        case mid, baseUrl, writableUrl, name, username, password, avatar, email, profile, timestamp, lastLogin, cloudDrivePort
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
        // Don't encode baseUrl/writableUrl - IP addresses should be resolved fresh each session
        // to handle cases where server IPs have changed
        // try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
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
            // This ensures avatarUrl is available even when user.baseUrl is temporarily nil (e.g., after cache load)
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
