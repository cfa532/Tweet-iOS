import Foundation

@MainActor
final class UserStore {
    static let shared = UserStore()

    private init() {}

    func user(mid: MimeiId) -> User {
        User.getInstance(mid: mid)
    }

    @discardableResult
    func merge(
        _ decoded: DecodedUserRecord,
        shouldUpdateBaseUrl: Bool = false
    ) -> User {
        merge(
            decoded.record,
            shouldUpdateBaseUrl: shouldUpdateBaseUrl,
            nilFieldsToClear: decoded.explicitNullFields
        )
    }

    @discardableResult
    func merge(
        _ record: UserRecord,
        shouldUpdateBaseUrl: Bool = false,
        nilFieldsToClear: Set<String> = []
    ) -> User {
        let instance = User.getInstance(mid: record.mid)
        merge(record, into: instance, shouldUpdateBaseUrl: shouldUpdateBaseUrl, nilFieldsToClear: nilFieldsToClear)
        return instance
    }

    private func merge(
        _ record: UserRecord,
        into instance: User,
        shouldUpdateBaseUrl: Bool,
        nilFieldsToClear: Set<String>
    ) {
        instance.name = record.name ?? instance.name
        if record.hasValidUsername {
            instance.username = record.username
        }
        instance.password = record.password ?? instance.password
        if let avatar = User.sanitizedAvatarId(record.avatar) {
            instance.avatar = avatar
        }
        instance.email = record.email ?? instance.email
        instance.profile = record.profile ?? instance.profile
        instance.timestamp = record.timestamp
        instance.lastLogin = record.lastLogin ?? instance.lastLogin
        instance.cloudDrivePort = record.cloudDrivePort
        instance.domainToShare = record.domainToShare ?? instance.domainToShare
        instance.hostIds = record.hostIds ?? instance.hostIds
        instance.hasAcceptedTerms = record.hasAcceptedTerms
        instance.publicKey = record.publicKey ?? instance.publicKey
        instance.agentPublicKey = record.agentPublicKey ?? instance.agentPublicKey

        if shouldUpdateBaseUrl, let baseUrl = record.baseUrl {
            instance.baseUrl = baseUrl
        }
        if let writableUrl = record.writableUrl {
            instance.writableUrl = writableUrl
        }

        instance.tweetCount = record.tweetCount ?? instance.tweetCount
        instance.followingCount = record.followingCount ?? instance.followingCount
        instance.followersCount = record.followersCount ?? instance.followersCount
        instance.bookmarksCount = record.bookmarksCount ?? instance.bookmarksCount
        instance.favoritesCount = record.favoritesCount ?? instance.favoritesCount
        instance.commentsCount = record.commentsCount ?? instance.commentsCount

        instance.fansList = record.fansList ?? instance.fansList
        instance.followingList = record.followingList ?? instance.followingList
        instance.bookmarkedTweets = record.bookmarkedTweets ?? instance.bookmarkedTweets
        instance.favoriteTweets = record.favoriteTweets ?? instance.favoriteTweets
        instance.repliedTweets = record.repliedTweets ?? instance.repliedTweets
        instance.commentsList = record.commentsList ?? instance.commentsList
        instance.topTweets = record.topTweets ?? instance.topTweets
        instance.userBlackList = record.userBlackList ?? instance.userBlackList

        clearExplicitNullFields(nilFieldsToClear, from: instance)
    }

    private func clearExplicitNullFields(_ fields: Set<String>, from instance: User) {
        for field in fields {
            switch field {
            case User.CodingKeys.name.rawValue:
                instance.name = nil
            case User.CodingKeys.password.rawValue:
                instance.password = nil
            case User.CodingKeys.avatar.rawValue:
                instance.avatar = nil
            case User.CodingKeys.email.rawValue:
                instance.email = nil
            case User.CodingKeys.profile.rawValue:
                instance.profile = nil
            case User.CodingKeys.domainToShare.rawValue:
                instance.domainToShare = nil
            case User.CodingKeys.hostIds.rawValue:
                instance.hostIds = nil
            case User.CodingKeys.publicKey.rawValue:
                instance.publicKey = nil
            case User.CodingKeys.agentPublicKey.rawValue:
                instance.agentPublicKey = nil
            default:
                break
            }
        }
    }
}

@MainActor
final class TweetStore {
    static let shared = TweetStore()

    private init() {}

    func tweet(mid: MimeiId) -> Tweet? {
        Tweet.getInstance(for: mid)
    }

    @discardableResult
    func merge(
        _ record: TweetRecord,
        author: User? = nil,
        prewarmHeight: Bool = true
    ) -> Tweet {
        let attachments = record.attachments?.map { $0.makeMedia(author: author) }
        let instance = Tweet.getInstance(
            mid: record.mid,
            authorId: record.authorId,
            content: record.content,
            timestamp: record.timestamp,
            title: record.title,
            originalTweetId: record.originalTweetId,
            originalAuthorId: record.originalAuthorId,
            author: author,
            favorites: record.favorites,
            favoriteCount: record.favoriteCount ?? 0,
            bookmarkCount: record.bookmarkCount ?? 0,
            retweetCount: record.retweetCount ?? 0,
            commentCount: record.commentCount ?? 0,
            attachments: attachments,
            isPrivate: record.isPrivate,
            downloadable: record.downloadable
        )
        if prewarmHeight {
            TweetHeightPrewarmer.shared.prewarm(instance)
        }
        return instance
    }

    @discardableResult
    func update(_ tweet: Tweet, with record: TweetRecord) -> Tweet {
        tweet.performBatchUpdate {
            if let content = record.content { tweet.content = content }
            if let title = record.title { tweet.title = title }
            if let favorites = record.favorites { tweet.favorites = favorites }
            tweet.favoriteCount = record.favoriteCount
            tweet.bookmarkCount = record.bookmarkCount
            tweet.retweetCount = record.retweetCount
            tweet.commentCount = record.commentCount
            if let attachments = record.attachments {
                tweet.attachments = attachments.map { $0.makeMedia(author: tweet.author) }
            }
            if let isPrivate = record.isPrivate { tweet.isPrivate = isPrivate }
            if let downloadable = record.downloadable { tweet.downloadable = downloadable }
            tweet.timestamp = record.timestamp
        }
        return tweet
    }
}
