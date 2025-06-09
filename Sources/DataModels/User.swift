import Foundation
import Combine

enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
    static let MAX_TWEET_SIZE = 28000
    static let MIMEI_ID_LENGTH = 27
}

enum UserContentType: String {
    case FAVORITES = "favorite_list"     // get favorite tweet list of an user
    case BOOKMARKS = "bookmark_list"     // get bookmarks
    case COMMENTS = "comment_list"       // comments made by an user
    case FOLLOWER = "get_followers_sorted"      // follower list of an user
    case FOLLOWING = "get_followings_sorted"    // following list
}

actor AppUserStore: ObservableObject {
    static let shared = AppUserStore()
    @Published private(set) var appUser: User = User(mid: Constants.GUEST_ID)
    
    func initialize(preferenceHelper: PreferenceHelper) async {
        let userId = preferenceHelper.getUserId() ?? Constants.GUEST_ID
        let baseUrl = preferenceHelper.getAppUrls().first ?? ""
        
        // Get the singleton instance for the user
        let instance = await User.getInstance(mid: userId)
        instance.baseUrl = baseUrl
        instance.followingList = Gadget.getAlphaIds()
        
        // Update the reference to point to the singleton instance
        self.appUser = instance
        
        // Try to initialize app entry
        do {
            try await initAppEntry(preferenceHelper: preferenceHelper)
        } catch {
            print("Error initializing app entry: \(error)")
            // Don't throw here, allow the app to continue with default settings
        }
    }
    
    private func initAppEntry(preferenceHelper: PreferenceHelper) async throws {
        for url in preferenceHelper.getAppUrls() {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = Gadget.shared.extractParamMap(from: html)
                let appId = paramData["mid"] as? String ?? ""
                HproseInstance.appId = appId
                
                guard let addrs = paramData["addrs"] as? String else { continue }
                print("Initializing with addresses: \(addrs)")
                
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    #if DEBUG
                        let firstIp = "218.72.53.166:8002"  // for testing
                    #endif
                    
                    let baseUrl = "http://\(firstIp)"
                    HproseInstance.baseUrl = baseUrl
                    
                    if !appUser.isGuest,
                       let user = try await HproseInstance.shared.getUser(appUser.mid, baseUrl: baseUrl) {
                        // Valid login user is found, use its provider IP as base.
                        HproseInstance.baseUrl = baseUrl
                        let followings = (try? await HproseInstance.shared.getFollows(user: user, entry: .FOLLOWING)) ?? Gadget.getAlphaIds()
                        appUser.baseUrl = HproseInstance.baseUrl
                        appUser.followingList = followings
                        return
                    } else {
                        let user = await User.getInstance(mid: Constants.GUEST_ID)
                        user.baseUrl = HproseInstance.baseUrl
                        user.followingList = Gadget.getAlphaIds()
                        self.appUser = user
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
    
    func updateAppUser(_ newUser: User) async {
        // Get the singleton instance for the new user
        let instance = await User.getInstance(mid: newUser.mid)
        // Update the singleton instance with new values
        instance.baseUrl = newUser.baseUrl
        instance.writableUrl = newUser.writableUrl
        instance.name = newUser.name
        instance.username = newUser.username
        instance.avatar = newUser.avatar
        instance.email = newUser.email
        instance.profile = newUser.profile
        instance.cloudDrivePort = newUser.cloudDrivePort
        
        instance.tweetCount = newUser.tweetCount
        instance.followingCount = newUser.followingCount
        instance.followersCount = newUser.followersCount
        instance.bookmarksCount = newUser.bookmarksCount
        instance.favoritesCount = newUser.favoritesCount
        instance.commentsCount = newUser.commentsCount
        
        instance.hostIds = newUser.hostIds
        
        // Update the reference to point to the singleton instance
        self.appUser = instance
    }
    
    func getAppUser() async -> User {
        return appUser
    }
}

actor UserStore {
    static let shared = UserStore()
    private var instances: [String: User] = [:]
    
    func getInstance(mid: String) -> User {
        if let existingInstance = instances[mid] {
            return existingInstance
        }
        let newUser = User(mid: mid)
        instances[mid] = newUser
        return newUser
    }
    
    func updateInstance(with user: User) {
        let instance = getInstance(mid: user.mid)
        instance.name = user.name
        instance.username = user.username
        instance.password = user.password
        instance.avatar = user.avatar
        instance.email = user.email
        instance.profile = user.profile
        instance.lastLogin = user.lastLogin
        instance.cloudDrivePort = user.cloudDrivePort
        instance.hostIds = user.hostIds
        
        instance.tweetCount = user.tweetCount
        instance.followingCount = user.followingCount
        instance.followersCount = user.followersCount
        instance.bookmarksCount = user.bookmarksCount
        instance.favoritesCount = user.favoritesCount
        instance.commentsCount = user.commentsCount
    }
    
    func clearInstance(mid: String) {
        instances.removeValue(forKey: mid)
    }
    
    func clearAllInstances() {
        instances.removeAll()
    }
}

class User: ObservableObject, Codable, Identifiable, Hashable, @unchecked Sendable {
    // MARK: - Static Methods
    static func getInstance(mid: String) async -> User {
        return await UserStore.shared.getInstance(mid: mid)
    }
    
    static func from(dict: [String: Any]) async -> User {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decodedUser = try decoder.decode(User.self, from: jsonData)
            await UserStore.shared.updateInstance(with: decodedUser)
            return await UserStore.shared.getInstance(mid: decodedUser.mid)
        } catch {
            print("Error converting dictionary to User: \(error)")
            return await getInstance(mid: Constants.GUEST_ID)
        }
    }
    
    static func from(cdUser: CDUser) async -> User {
        // Try to decode the full user data
        if let userData = cdUser.userData,
           let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
            decodedUser.baseUrl = HproseInstance.baseUrl
            await UserStore.shared.updateInstance(with: decodedUser)
        }
        return await getInstance(mid: cdUser.mid ?? Constants.GUEST_ID)
    }
    
    // MARK: - Properties
    @Published var mid: String
    @Published var baseUrl: String?
    @Published var writableUrl: String?
    @Published var name: String?
    @Published var username: String?
    @Published var password: String?
    @Published var avatar: String? // MimeiId
    @Published var email: String?
    @Published var profile: String?
    @Published var timestamp: Date
    @Published var lastLogin: Date?
    @Published var cloudDrivePort: Int?
    
    @Published var tweetCount: Int?
    @Published var followingCount: Int?
    @Published var followersCount: Int?
    @Published var bookmarksCount: Int?
    @Published var favoritesCount: Int?
    @Published var commentsCount: Int?
    
    @Published var hostIds: [String]? // List of MimeiId
    @Published var publicKey: String?
    
    @Published var fansList: [String]? // List of MimeiId
    @Published var followingList: [String]? // List of MimeiId
    @Published var bookmarkedTweets: [String]? // List of MimeiId
    @Published var favoriteTweets: [String]? // List of MimeiId
    @Published var repliedTweets: [String]? // List of MimeiId
    @Published var commentsList: [String]? // List of MimeiId
    @Published var topTweets: [String]? // List of MimeiId
    
    var id: String { mid }  // Computed property that returns mid
    
    // MARK: - Initialization
    init(
        mid: String = Constants.GUEST_ID,
        baseUrl: String? = nil,
        name: String? = nil,
        username: String? = nil,
        password: String? = nil,
        avatar: String? = nil,
        email: String? = nil,
        profile: String? = nil,
        cloudDrivePort: Int? = nil,
        hostIds: [String]? = nil,
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
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
        writableUrl = try container.decodeIfPresent(String.self, forKey: .writableUrl)
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

    // MARK: - Hashable
    static func == (lhs: User, rhs: User) -> Bool {
        return lhs.mid == rhs.mid
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(mid)
    }
    
    // MARK: - Writable URL Resolution
    /// Returns the writable URL for the user, resolving via hostIds if needed
    func resolvedWritableUrl() async throws -> String? {
        if let writableUrl = self.writableUrl, !writableUrl.isEmpty {
            return writableUrl
        }
        if let hostId = self.hostIds?.first, !hostId.isEmpty {
            if let hostIP = await HproseInstance.shared.getHostIP(hostId) {
                self.writableUrl = "http://\(hostIP)"
                return self.writableUrl
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No writable url available"])
    }
}
