import Foundation
import Combine

class User: ObservableObject, Codable, Identifiable, Hashable {
    // MARK: - Singleton Dictionary
    private static var userInstances: [MimeiId: User] = [:]
    
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
    @Published var cloudDrivePort: Int? = 8010
    
    @Published var tweetCount: Int?
    @Published var followingCount: Int?
    @Published var followersCount: Int?
    @Published var bookmarksCount: Int?
    @Published var favoritesCount: Int?
    @Published var commentsCount: Int?
    
    @Published var hostIds: [MimeiId]? // List of MimeiId
    @Published var publicKey: String?
    private var _hproseService: AnyObject?
    public var hproseService: AnyObject? {
        get {
            guard let baseUrl = baseUrl else { return nil }

            if let cached = _hproseService {
                return cached
            } else {
                if baseUrl == HproseInstance.shared.appUser.baseUrl {
                    return HproseInstance.shared._hproseService
                } else {
                    let client = HproseHttpClient()
                    client.timeout = 30000
                    client.uri = "\(baseUrl)/webapi/"
                    let service = client.useService(HproseService.self) as? AnyObject
                    _hproseService = service
                    return service
                }
            }
        }
    }
    private var _uploadService: AnyObject?
    public var uploadService: AnyObject? {
        get {
            guard let baseUrl = writableUrl else { 
                print("DEBUG: uploadService - writableUrl is nil")
                return nil 
            }

            if let cached = _uploadService {
                print("DEBUG: uploadService - returning cached service")
                return cached
            } else {
                print("DEBUG: uploadService - creating new service for baseUrl: \(baseUrl)")
                if baseUrl == HproseInstance.shared.appUser.baseUrl {
                    // Use the main hprose service if available, otherwise create a new one
                    if let mainService = HproseInstance.shared.appUser._hproseService {
                        print("DEBUG: uploadService - using main hprose service")
                        _uploadService = mainService
                        return mainService
                    } else {
                        // Fallback to creating a new service
                        print("DEBUG: uploadService - main service not available, creating new one")
                        let client = HproseHttpClient()
                        client.timeout = 30000
                        client.uri = "\(baseUrl)/webapi/"
                        let service = client.useService(HproseService.self) as? AnyObject
                        _uploadService = service
                        print("DEBUG: uploadService - new service created: \(service != nil)")
                        return service
                    }
                } else {
                    print("DEBUG: uploadService - creating service for different baseUrl")
                    let client = HproseHttpClient()
                    client.timeout = 30000
                    client.uri = "\(baseUrl)/webapi/"
                    let service = client.useService(HproseService.self) as? AnyObject
                    _uploadService = service
                    print("DEBUG: uploadService - new service created: \(service != nil)")
                    return service
                }
            }
        }
    }
    
    @Published var fansList: [String]? // List of MimeiId
    @Published var followingList: [String]? // List of MimeiId
    @Published var bookmarkedTweets: [String]? // List of MimeiId
    @Published var favoriteTweets: [String]? // List of MimeiId
    @Published var repliedTweets: [String]? // List of MimeiId
    @Published var commentsList: [String]? // List of MimeiId
    @Published var topTweets: [String]? // List of MimeiId
    
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
        cloudDrivePort: Int? = nil,
        hostIds: [MimeiId]? = nil,
        publicKey: String? = nil
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
        // Observe baseUrl changes to clear cached clients
        baseUrlCancellable = $baseUrl
            .sink { [weak self] _ in
                self?._hproseService = nil
                self?._uploadService = nil
            }
        
        // Observe writableUrl changes to clear upload service cache
        writableUrlCancellable = $writableUrl
            .sink { [weak self] _ in
                self?._uploadService = nil
            }
    }
    
    // MARK: - Factory Methods
    static func getInstance(mid: MimeiId) -> User {
        if let existingUser = userInstances[mid] {
            return existingUser
        }
        let newUser = User(mid: mid)
        userInstances[mid] = newUser
        return newUser
    }
    
    /// Update user instance with backend data. Keep current baseUrl
    static func from(dict: [String: Any]) throws -> User {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decodedUser = try decoder.decode(User.self, from: jsonData)
            
            // keep original baseUrl when updated by user dictionary from backend.
            let instance = getInstance(mid: decodedUser.mid)
            decodedUser.baseUrl = instance.baseUrl
            decodedUser.writableUrl = instance.writableUrl
            
            updateUserInstance(with: decodedUser)
            return userInstances[decodedUser.mid]!
        } catch {
            throw NSError(domain: "User", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode dict to user"])
        }
    }
    
    static func from(cdUser: CDUser) -> User {
        // Try to decode the full user object from cache.
        if let userData = cdUser.userData,
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
            updateUserInstance(with: decodedUser)
        }
        return getInstance(mid: cdUser.mid ?? Constants.GUEST_ID)
    }
    
    static func updateUserInstance(with user: User) {
        let instance = getInstance(mid: user.mid)
        Task { @MainActor in
            instance.name = user.name
            instance.username = user.username
            instance.password = user.password
            instance.avatar = user.avatar
            instance.email = user.email
            instance.profile = user.profile
            instance.lastLogin = user.lastLogin
            instance.cloudDrivePort = user.cloudDrivePort
            instance.hostIds = user.hostIds
            instance.baseUrl = user.baseUrl
            instance.writableUrl = user.writableUrl
            
            instance.tweetCount = user.tweetCount
            instance.followingCount = user.followingCount
            instance.followersCount = user.followersCount
            instance.bookmarksCount = user.bookmarksCount
            instance.favoritesCount = user.favoritesCount
            instance.commentsCount = user.commentsCount
        }
    }
    
    // CodingKeys to handle @Published properties
    enum CodingKeys: String, CodingKey {
        case mid, baseUrl, writableUrl, name, username, password, avatar, email, profile, timestamp, lastLogin, cloudDrivePort
        case tweetCount, followingCount, followersCount, bookmarksCount, favoritesCount, commentsCount
        case hostIds, publicKey, fansList, followingList, bookmarkedTweets, favoriteTweets, repliedTweets, commentsList, topTweets
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
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        lastLogin = try container.decodeIfPresent(Date.self, forKey: .lastLogin)
        cloudDrivePort = try container.decodeIfPresent(Int.self, forKey: .cloudDrivePort)
        
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
    }
    
    // Encode method for Codable
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(mid, forKey: .mid)
        try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
        try container.encodeIfPresent(writableUrl, forKey: .writableUrl)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(lastLogin, forKey: .lastLogin)
        try container.encodeIfPresent(cloudDrivePort, forKey: .cloudDrivePort)
        
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
    }
    
    var isGuest: Bool {
        return mid == Constants.GUEST_ID
    }
    
    var avatarUrl: String? {
        if let avatar = avatar, let baseUrl = baseUrl {
            return avatar.count > Constants.MIMEI_ID_LENGTH ? "\(baseUrl)/ipfs/\(avatar)" :  "\(baseUrl)/mm/\(avatar)"
        }
        return nil
    }
    
    /// Computed property that determines if the user's cached data has expired
    /// Returns true if the user is not cached or if the cache has expired (30 minutes)
    var hasExpired: Bool {
        // Check if user exists in cache and if cache has expired
        return TweetCacheManager.shared.hasExpired(mid: mid)
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
            if let hostIP = await HproseInstance.shared.getHostIP(hostId) {
                let url = URL(string: "http://\(hostIP)")
                self.writableUrl = url
                return url
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No writable url available"])
    }
    
    /**
     * Resolves the most responsive writable URL from the user's first hostId.
     * It checks only the first hostId, constructs a potential URL, and checks for its reachability.
     * If a responsive URL is found, it is set as the user's `writableUrl` and returned.
     * If the first host is not responsive, it defaults to the user's `baseUrl`.
     * This method runs asynchronously and updates the `writableUrl` property directly.
     * Only accepts public IP addresses with ports between 8000 and 9000.
     * Returns the resolved URL or nil if resolution fails.
     */
    
    /// Force refresh the upload service cache
    func refreshUploadService() {
        _uploadService = nil
    }
}
