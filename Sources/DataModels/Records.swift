import Foundation

struct MediaRecord: Codable, Hashable, Sendable {
    var mid: MimeiId
    var type: MediaType
    var size: Int64?
    var fileName: String?
    var timestamp: Date
    var aspectRatio: Float?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case mid
        case type
        case size
        case fileName
        case timestamp
        case aspectRatio
        case url
    }

    init(
        mid: MimeiId,
        type: MediaType,
        size: Int64? = nil,
        fileName: String? = nil,
        timestamp: Date = Date(),
        aspectRatio: Float? = nil,
        url: String? = nil
    ) {
        self.mid = mid
        self.type = type
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self.url = url
    }

    init(media: MimeiFileType) {
        self.init(
            mid: media.mid,
            type: media.type,
            size: media.size,
            fileName: media.fileName,
            timestamp: media.timestamp,
            aspectRatio: media.aspectRatio,
            url: media.url
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decode(String.self, forKey: .mid)

        if let mediaType = try? container.decode(MediaType.self, forKey: .type) {
            type = mediaType
        } else if let typeString = try? container.decode(String.self, forKey: .type) {
            type = MediaType.fromString(typeString)
        } else {
            type = .unknown
        }

        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        aspectRatio = try container.decodeIfPresent(Float.self, forKey: .aspectRatio)
        url = try container.decodeIfPresent(String.self, forKey: .url)

        if let doubleValue = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else if let stringValue = try? container.decode(String.self, forKey: .timestamp),
                  let doubleValue = Double(stringValue) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else {
            timestamp = Date()
        }
    }

    @MainActor
    func makeMedia(author: User? = nil) -> MimeiFileType {
        let media = MimeiFileType(
            mid: mid,
            mediaType: type,
            size: size,
            fileName: fileName,
            timestamp: timestamp,
            aspectRatio: aspectRatio,
            url: url
        )
        if let author {
            media.setAuthor(author)
        }
        return media
    }
}

struct UserRecord: Codable, Sendable {
    var mid: MimeiId
    var baseUrl: URL?
    var writableUrl: URL?
    var name: String?
    var username: String?
    var password: String?
    var avatar: MimeiId?
    var email: String?
    var profile: String?
    var timestamp: Date
    var lastLogin: Date?
    var cloudDrivePort: Int
    var domainToShare: String?
    var tweetCount: Int?
    var followingCount: Int?
    var followersCount: Int?
    var bookmarksCount: Int?
    var favoritesCount: Int?
    var commentsCount: Int?
    var hostIds: [MimeiId]?
    var hasAcceptedTerms: Bool
    var publicKey: String?
    var agentPublicKey: String?
    var fansList: [MimeiId]?
    var followingList: [MimeiId]?
    var bookmarkedTweets: [MimeiId]?
    var favoriteTweets: [MimeiId]?
    var repliedTweets: [MimeiId]?
    var commentsList: [MimeiId]?
    var topTweets: [MimeiId]?
    var userBlackList: [MimeiId]?

    var hasValidUsername: Bool {
        guard let username else { return false }
        return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case mid, baseUrl, writableUrl, name, username, password, avatar, email, profile, timestamp, lastLogin, cloudDrivePort, domainToShare
        case tweetCount, followingCount, followersCount, bookmarksCount, favoritesCount, commentsCount
        case hostIds, hasAcceptedTerms, publicKey, agentPublicKey, fansList, followingList, bookmarkedTweets, favoriteTweets, repliedTweets, commentsList, topTweets, userBlackList
    }

    init(from decoder: Decoder) throws {
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
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
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
        hasAcceptedTerms = try container.decodeIfPresent(Bool.self, forKey: .hasAcceptedTerms) ?? false
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
    }

    init(
        mid: MimeiId = Constants.GUEST_ID,
        baseUrl: URL? = nil,
        writableUrl: URL? = nil,
        name: String? = nil,
        username: String? = nil,
        password: String? = nil,
        avatar: MimeiId? = nil,
        email: String? = nil,
        profile: String? = nil,
        timestamp: Date = Date(),
        lastLogin: Date? = nil,
        cloudDrivePort: Int = 0,
        domainToShare: String? = nil,
        tweetCount: Int? = nil,
        followingCount: Int? = nil,
        followersCount: Int? = nil,
        bookmarksCount: Int? = nil,
        favoritesCount: Int? = nil,
        commentsCount: Int? = nil,
        hostIds: [MimeiId]? = nil,
        hasAcceptedTerms: Bool = false,
        publicKey: String? = nil,
        agentPublicKey: String? = nil,
        fansList: [MimeiId]? = nil,
        followingList: [MimeiId]? = nil,
        bookmarkedTweets: [MimeiId]? = nil,
        favoriteTweets: [MimeiId]? = nil,
        repliedTweets: [MimeiId]? = nil,
        commentsList: [MimeiId]? = nil,
        topTweets: [MimeiId]? = nil,
        userBlackList: [MimeiId]? = nil
    ) {
        self.mid = mid
        self.baseUrl = baseUrl
        self.writableUrl = writableUrl
        self.name = name
        self.username = username
        self.password = password
        self.avatar = User.sanitizedAvatarId(avatar)
        self.email = email
        self.profile = profile
        self.timestamp = timestamp
        self.lastLogin = lastLogin
        self.cloudDrivePort = cloudDrivePort
        self.domainToShare = domainToShare
        self.tweetCount = tweetCount
        self.followingCount = followingCount
        self.followersCount = followersCount
        self.bookmarksCount = bookmarksCount
        self.favoritesCount = favoritesCount
        self.commentsCount = commentsCount
        self.hostIds = hostIds
        self.hasAcceptedTerms = hasAcceptedTerms
        self.publicKey = publicKey
        self.agentPublicKey = agentPublicKey
        self.fansList = fansList
        self.followingList = followingList
        self.bookmarkedTweets = bookmarkedTweets
        self.favoriteTweets = favoriteTweets
        self.repliedTweets = repliedTweets
        self.commentsList = commentsList
        self.topTweets = topTweets
        self.userBlackList = userBlackList
    }

    @MainActor
    init(user: User) {
        self.init(
            mid: user.mid,
            baseUrl: user.baseUrl,
            writableUrl: user.writableUrl,
            name: user.name,
            username: user.username,
            password: user.password,
            avatar: user.avatar,
            email: user.email,
            profile: user.profile,
            timestamp: user.timestamp,
            lastLogin: user.lastLogin,
            cloudDrivePort: user.cloudDrivePort,
            domainToShare: user.domainToShare,
            tweetCount: user.tweetCount,
            followingCount: user.followingCount,
            followersCount: user.followersCount,
            bookmarksCount: user.bookmarksCount,
            favoritesCount: user.favoritesCount,
            commentsCount: user.commentsCount,
            hostIds: user.hostIds,
            hasAcceptedTerms: user.hasAcceptedTerms,
            publicKey: user.publicKey,
            agentPublicKey: user.agentPublicKey,
            fansList: user.fansList,
            followingList: user.followingList,
            bookmarkedTweets: user.bookmarkedTweets,
            favoriteTweets: user.favoriteTweets,
            repliedTweets: user.repliedTweets,
            commentsList: user.commentsList,
            topTweets: user.topTweets,
            userBlackList: user.userBlackList
        )
    }
}

struct DecodedUserRecord: Sendable {
    var record: UserRecord
    var explicitNullFields: Set<String>
}

extension UserRecord {
    static func fromCacheData(_ data: Data) throws -> UserRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try decoder.decode(UserRecord.self, from: data)
        guard record.hasValidUsername else {
            throw NSError(domain: "UserRecord", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid user data: username is empty"])
        }
        return record
    }

    static func fromDictionary(_ dict: [String: Any]) throws -> DecodedUserRecord {
        var sanitizedDict = dict
        var explicitNullFields: Set<String> = []

        for (key, value) in dict {
            if key == CodingKeys.avatar.rawValue {
                if let avatar = value as? String,
                   let sanitizedAvatar = User.sanitizedAvatarId(avatar) {
                    sanitizedDict[key] = sanitizedAvatar
                } else {
                    sanitizedDict.removeValue(forKey: key)
                }
            } else if let nsArray = value as? NSArray {
                sanitizedDict[key] = nsArray.compactMap { $0 as? String }
            } else if key == CodingKeys.cloudDrivePort.rawValue {
                if let number = value as? NSNumber {
                    sanitizedDict[key] = number.intValue
                } else if let string = value as? String, let intValue = Int(string) {
                    sanitizedDict[key] = intValue
                } else if value is Int {
                    sanitizedDict[key] = value
                } else {
                    sanitizedDict[key] = 0
                }
            } else if value is NSNull {
                explicitNullFields.insert(key)
            } else if !JSONSerialization.isValidJSONObject([key: value]) {
                sanitizedDict.removeValue(forKey: key)
            }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: sanitizedDict, options: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try decoder.decode(UserRecord.self, from: jsonData)
        guard record.hasValidUsername else {
            throw NSError(domain: "UserRecord", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid user data: username is empty"])
        }
        return DecodedUserRecord(record: record, explicitNullFields: explicitNullFields)
    }
}

struct TweetRecord: Codable, Sendable {
    var mid: MimeiId
    var authorId: MimeiId
    var content: String?
    var timestamp: Date
    var title: String?
    var originalTweetId: MimeiId?
    var originalAuthorId: MimeiId?
    var favorites: [Bool]?
    var favoriteCount: Int?
    var bookmarkCount: Int?
    var retweetCount: Int?
    var commentCount: Int?
    var attachments: [MediaRecord]?
    var isPrivate: Bool?
    var downloadable: Bool?

    enum CodingKeys: String, CodingKey {
        case mid
        case authorId
        case content
        case timestamp
        case title
        case originalTweetId
        case originalAuthorId
        case favorites
        case favoriteCount
        case bookmarkCount
        case retweetCount
        case commentCount
        case attachments
        case isPrivate
        case downloadable
    }

    init(
        mid: MimeiId,
        authorId: MimeiId,
        content: String? = nil,
        timestamp: Date = Date(),
        title: String? = nil,
        originalTweetId: MimeiId? = nil,
        originalAuthorId: MimeiId? = nil,
        favorites: [Bool]? = [false, false, false],
        favoriteCount: Int? = 0,
        bookmarkCount: Int? = 0,
        retweetCount: Int? = 0,
        commentCount: Int? = 0,
        attachments: [MediaRecord]? = nil,
        isPrivate: Bool? = nil,
        downloadable: Bool? = nil
    ) {
        self.mid = mid
        self.authorId = authorId
        self.content = content
        self.timestamp = timestamp
        self.title = title
        self.originalTweetId = originalTweetId
        self.originalAuthorId = originalAuthorId
        self.favorites = favorites
        self.favoriteCount = favoriteCount
        self.bookmarkCount = bookmarkCount
        self.retweetCount = retweetCount
        self.commentCount = commentCount
        self.attachments = attachments
        self.isPrivate = isPrivate
        self.downloadable = downloadable
    }

    @MainActor
    init(tweet: Tweet) {
        self.init(
            mid: tweet.mid,
            authorId: tweet.authorId,
            content: tweet.content,
            timestamp: tweet.timestamp,
            title: tweet.title,
            originalTweetId: tweet.originalTweetId,
            originalAuthorId: tweet.originalAuthorId,
            favorites: tweet.favorites,
            favoriteCount: tweet.favoriteCount,
            bookmarkCount: tweet.bookmarkCount,
            retweetCount: tweet.retweetCount,
            commentCount: tweet.commentCount,
            attachments: tweet.attachments?.map(MediaRecord.init(media:)),
            isPrivate: tweet.isPrivate,
            downloadable: tweet.downloadable
        )
    }
}

extension TweetRecord {
    static func fromCacheData(_ data: Data) throws -> TweetRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TweetRecord.self, from: data)
    }

    static func fromDictionary(_ dict: [String: Any]) throws -> TweetRecord {
        var validatedDict = dict
        validatedDict["timestamp"] = normalizedTimestampMilliseconds(from: dict["timestamp"])

        let jsonData = try JSONSerialization.data(withJSONObject: validatedDict, options: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TweetRecord.self, from: jsonData)
    }

    private static func normalizedTimestampMilliseconds(from value: Any?) -> Double {
        if let string = value as? String, let milliseconds = Double(string) {
            return milliseconds
        }
        if let double = value as? Double, double > 0 {
            return double
        }
        if let int = value as? Int, int > 0 {
            return Double(int)
        }
        return Date().timeIntervalSince1970 * 1000
    }

    @MainActor
    func makeTweet(author: User? = nil) -> Tweet {
        Tweet(
            mid: mid,
            authorId: authorId,
            content: content,
            timestamp: timestamp,
            title: title,
            originalTweetId: originalTweetId,
            originalAuthorId: originalAuthorId,
            author: author,
            favorites: favorites,
            favoriteCount: favoriteCount ?? 0,
            bookmarkCount: bookmarkCount ?? 0,
            retweetCount: retweetCount ?? 0,
            commentCount: commentCount ?? 0,
            attachments: attachments?.map { $0.makeMedia(author: author) },
            isPrivate: isPrivate,
            downloadable: downloadable
        )
    }
}
