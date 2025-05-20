import Foundation
import hprose
import PhotosUI
import AVFoundation
import BackgroundTasks

@objc protocol HproseService {
    func runMApp(_ entry: String, _ request: [String: Any], _ args: [NSData]?) -> Any?
}

// MARK: - Array Extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - HproseService
final class HproseInstance: ObservableObject {
    // MARK: - Properties
    static let shared = HproseInstance()
    @Published var appUser: User = User(mid: Constants.GUEST_ID)
    
    private var appId: String = Bundle.main.bundleIdentifier ?? ""
    private let cachedUsersLock = NSLock()
    private var _cachedUsers: Set<User> = []
    private var cachedUsers: Set<User> {
        get {
            cachedUsersLock.withLock { _cachedUsers }
        }
        set {
            cachedUsersLock.withLock { _cachedUsers = newValue }
        }
    }
    private var preferenceHelper: PreferenceHelper?
    private var chatDatabase: ChatDatabase?
    private var tweetDao: CachedTweetDao?
    
    private lazy var client: HproseClient = {
        let client = HproseHttpClient()
        client.timeout = 60
        return client
    }()
    private var hproseClient: AnyObject?
    
    // MARK: - Initialization
    private init() {}
    
    // MARK: - Public Methods
    func initialize() async throws {
        self.preferenceHelper = PreferenceHelper()
        self.chatDatabase = ChatDatabase.shared
        self.tweetDao = TweetCacheDatabase.shared.tweetDao()
        
        appUser = User(
            mid: Constants.GUEST_ID,
            baseUrl: preferenceHelper?.getAppUrls().first ?? "",
        )
        appUser.followingList = Gadget.getAlphaIds()
        
        try await initAppEntry()
    }
    
    private func initAppEntry() async throws {
        // Clear cached users during retry init
        cachedUsers.removeAll()
        
        for url in preferenceHelper?.getAppUrls() ?? [] {
            do {
                let html = try await fetchHTML(from: url)
                let paramData = Gadget.shared.extractParamMap(from: html)
                appId = paramData["mid"] as? String ?? ""
                guard let addrs = paramData["addrs"] as? String else {return}
                print(addrs)
                if let firstIp = Gadget.shared.filterIpAddresses(addrs) {
                    #if DEBUG
                        let firstIp = "125.118.43.78:8002"  // for testing
                    #endif
                    appUser = appUser.copy(baseUrl: "http://\(firstIp)")
                    client.uri = appUser.baseUrl!+"/webapi/"
                    hproseClient = client.useService(HproseService.self) as AnyObject
                    
                    if let userId = preferenceHelper?.getUserId(), userId != Constants.GUEST_ID,
                       // get best IP for the given userId
                       let providerIp = try await getProvider(userId) {
                        // get user object from this IP
                        if let user = try await getUser(userId, baseUrl: "http://\(providerIp)") {
                            appUser = user
                            appUser.baseUrl = "http://\(providerIp)"
                            cachedUsers.insert(appUser)
                            return
                        }
                    }
                    appUser.followingList = Gadget.getAlphaIds()
                    cachedUsers.insert(appUser)
                    return
                }
            } catch {
                print("Error initializing app entry: \(error)")
            }
        }
    }
    
    // MARK: - Tweet Operations
    func fetchTweets(
        user: User,
        startRank: UInt,
        endRank: UInt,
        entry: String = "get_tweet_feed"
    ) async throws -> [Tweet] {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.isGuest ? "iFG4GC9r0fF22jYBCkuPThybzwO" : appUser.mid,
                "start": startRank,
                "end": endRank,
                "gid": appUser.mid,
                "hostid": user.hostIds?.first as Any
            ]
            
            guard let response = service.runMApp(entry, params, nil) as? [[String: Any]] else {
                print("Invalid response format from server")
                return []
            }
            
            // First create tweets without author data
            let tweets = response.compactMap { dict -> Tweet? in
                return Tweet.from(dict: dict)
            }
            
            // Then fetch author data for each tweet
            var tweetsWithAuthors: [Tweet] = []
            for var tweet in tweets {
                if let author = try await getUser(tweet.authorId) {
                    tweet.author = author
                    tweetsWithAuthors.append(tweet)
                }
            }
            
            return tweetsWithAuthors
        }
    }
    
    func getUserId(_ username: String) async throws -> String? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let entry = "get_userid"
            let params = [
                "aid": appId,
                "ver": "last",
                "username": username,
            ]
            guard let response = service.runMApp(entry, params, nil) else {
                print("Invalid response format from server")
                return nil
            }
            return response as? String
        }
    }
    
    func getUser(_ userId: String, baseUrl: String = shared.appUser.baseUrl ?? "") async throws -> User? {
        // Check cache first
        if let cachedUser = cachedUsersLock.withLock({ _cachedUsers.first(where: { $0.mid == userId }) }) {
            return cachedUser
        }
        
        return try await withRetry {
            guard var service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            if baseUrl != appUser.baseUrl {
                // try to get User object from a different node other than the current one.
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "http://\(baseUrl)/webapi/"
                service = newClient.useService(HproseService.self) as AnyObject
            }

            let entry = "get_user"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": userId,
            ]
            guard let response = service.runMApp(entry, params, nil) else {
                print("Invalid response format from server")
                return nil
            }
            
            // First try to decode it as User
            if let userData = try? JSONSerialization.data(withJSONObject: response),
               var user = try? JSONDecoder().decode(User.self, from: userData) {
                // Cache the user
                user.baseUrl = baseUrl
                _ = cachedUsersLock.withLock { _cachedUsers.insert(user) }
                return user
            }
            
            // If decoding as User failed, the response might be an IP address
            if let ipAddress = response as? String {
                // Create new client for this IP
                let newClient = HproseHttpClient()
                newClient.timeout = 60
                newClient.uri = "http://\(ipAddress)/webapi/"
                let newService = newClient.useService(HproseService.self) as AnyObject
                
                // Make new request to get user from this IP
                if let userResponse = newService.runMApp(entry, params, nil) as? [String: Any],
                   let userData = try? JSONSerialization.data(withJSONObject: userResponse),
                   var user = try? JSONDecoder().decode(User.self, from: userData) {
                    // Cache the user
                    user.baseUrl = "http://\(ipAddress)"
                    _ = cachedUsersLock.withLock { _cachedUsers.insert(user) }
                    return user
                }
            }
            
            return nil
        }
    }
    
    func login(_ loginUser: User) async throws -> [String: Any] {
        return try await withRetry {
            let entry = "login"
            let params = [
                "aid": appId,
                "ver": "last",
                "username": loginUser.username!,
                "password": loginUser.password!
            ]
            let newClient = HproseHttpClient()
            newClient.timeout = 60
            newClient.uri = "\(loginUser.baseUrl!)/webapi/"
            let newService = newClient.useService(HproseService.self) as AnyObject
            
            guard let response = newService.runMApp(entry, params, nil) as? [String: Any] else {
                return ["reason": "Invalid response format from server", "status": "failure"]
            }
            
            if let status = response["status"] as? String {
                if status == "failure" {
                    if let reason = response["reason"] as? String {
                        return ["reason": reason, "status": "failure"]
                    }
                    return ["reason": "Unknown error occurred", "status": "failure"]
                } else if status == "success" {
                    if let userJsonString = response["user"] as? String {
                        guard let userData = userJsonString.data(using: .utf8) else {
                            return ["reason": "Failed to convert user data to UTF-8", "status": "failure"]
                        }
                        
                        do {
                            var userObject = try JSONDecoder().decode(User.self, from: userData)
                            hproseClient = newService   // update serving node for current session.
                            userObject.baseUrl = loginUser.baseUrl
                            
                            // Capture the value before the MainActor block
                            let finalUser = userObject
                            
                            // Update appUser on the main thread
                            await MainActor.run {
                                self.appUser = finalUser
                                preferenceHelper?.setUserId(finalUser.mid)
                            }
                            
                            return ["user": userObject, "status": "success"]
                        } catch {
                            return ["reason": "Failed to decode user data: \(error.localizedDescription)", "status": "failure"]
                        }
                    }
                    return ["reason": "User data not found", "status": "failure"]
                }
            }
            return ["reason": "Invalid response status", "status": "failure"]
        }
    }
    
    func likeTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "like_tweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.id,
                "tweetid": tweetId
            ]
        }
    }
    
    func bookmarkTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "bookmark_tweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.id,
                "tweetid": tweetId
            ]
        }
    }

    func retweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "retweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.id,
                "tweetid": tweetId
            ]
        }
    }
    
    func deleteTweet(_ tweetId: String) async throws {
        try await withRetry {
            let entry = "delete_tweet"
            let params = [
                "aid": appId,
                "ver": "last",
                "userid": appUser.id,
                "tweetid": tweetId
            ]
        }
    }
    
    // MARK: - File Upload
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil
    ) async throws -> MimeiFileType? {
        try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            // Create temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            var offset: Int64 = 0
            let chunkSize = 1024 * 1024 // 1MB chunks
            var request: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "offset": offset
            ]
            
            do {
                let fileHandle = try FileHandle(forReadingFrom: tempURL)
                defer { try? fileHandle.close() }
                
                while true {
                    let data = fileHandle.readData(ofLength: chunkSize)
                    if data.isEmpty { break }
                    
                    let nsData = data as NSData
                    if let fsid = service.runMApp("upload_ipfs", request, [nsData]) as? String {
                        offset += Int64(data.count)
                        request["offset"] = offset
                        request["fsid"] = fsid
                    }
                }
                
                // Mark upload as finished
                request["finished"] = "true"
                if let referenceId = referenceId {
                    request["referenceid"] = referenceId
                }
                
                guard let cid = service.runMApp("upload_ipfs", request, nil) as? String else {
                    return nil
                }
                
                // Determine media type
                let mediaType: MediaType
                if typeIdentifier.hasPrefix("public.image") {
                    // Check for specific image types
                    if typeIdentifier.contains("jpeg") || typeIdentifier.contains("jpg") {
                        mediaType = .image
                    } else if typeIdentifier.contains("png") {
                        mediaType = .image
                    } else if typeIdentifier.contains("gif") {
                        mediaType = .image
                    } else if typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
                        mediaType = .image
                    } else {
                        mediaType = .image // Default to image for any public.image type
                    }
                } else if typeIdentifier.hasPrefix("public.movie") {
                    mediaType = .video
                } else if typeIdentifier.hasPrefix("public.audio") {
                    mediaType = .audio
                } else if typeIdentifier == "public.composite-content" {
                    mediaType = .pdf
                } else if typeIdentifier == "public.zip-archive" {
                    mediaType = .zip
                } else if typeIdentifier == "public.composite-content" {
                    mediaType = .word
                } else {
                    // Try to determine type from file extension
                    let fileExtension = typeIdentifier.components(separatedBy: ".").last?.lowercased()
                    switch fileExtension {
                    case "jpg", "jpeg", "png", "gif", "heic", "heif":
                        mediaType = .image
                    case "mp4", "mov", "m4v", "mkv":
                        mediaType = .video
                    case "mp3", "m4a", "wav":
                        mediaType = .audio
                    case "pdf":
                        mediaType = .pdf
                    case "zip":
                        mediaType = .zip
                    case "doc", "docx":
                        mediaType = .word
                    default:
                        mediaType = .unknown
                    }
                }
                
                // Get file attributes
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let fileSize = fileAttributes[.size] as? UInt64 ?? 0
                let fileTimestamp = fileAttributes[.modificationDate] as? Date ?? Date()
                
                // Get aspect ratio for videos
                var aspectRatio: Float?
                if mediaType == .video {
                    aspectRatio = try await getVideoAspectRatio(url: tempURL)
                }
                
                // Create MimeiFileType with the CID
                return MimeiFileType(
                    mid: cid,
                    type: mediaType.rawValue,
                    size: Int64(fileSize),
                    fileName: fileName,
                    timestamp: fileTimestamp,
                    aspectRatio: aspectRatio,
                    url: nil
                )
            } catch {
                print("Error uploading file: \(error)")
                throw error
            }
        }
    }
    
    private func getVideoAspectRatio(url: URL) async throws -> Float? {
        let asset = AVAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            return nil
        }
        
        let size = try await videoTrack.load(.naturalSize)
        return Float(size.width / size.height)
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
    
    private func getProvider(_ mid: String) async throws -> String? {
        return try await withRetry {
            let params = [
                "aid": appId,
                "ver": "last",
                "mid": mid
            ]
            if let response = hproseClient?.runMApp("get_provider", params, []) {
                return response as? String
            }
            return nil
        }
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
                return try await block()
            } catch {
                retryCount += 1
                try await initAppEntry()
            }
        }
        throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network error: All retries failed."])
    }
    
//    func sendMessage(receiptId: String, message: ChatMessage) async throws {
//        try await withRetry {
//            let entry = "message_outgoing"
//            let encodedMsg = try JSONEncoder().encode(message).base64EncodedString()
//            
//            let params: [Any] = [
//                appId,
//                "last",
//                entry,
//                appUser.id,
//                receiptId,
//                encodedMsg,
//                appUser.hostIds?.first ?? ""
//            ]
//            
//            
//            // Write message to receipt's Mimei db
//            if let receipt = try await getUser(receiptId) {
//                client.uri = receipt.baseUrl
//                let receiptEntry = "message_incoming"
//                let receiptParams: [Any] = [
//                    appId,
//                    "last",
//                    receiptEntry,
//                    appUser.id,
//                    receiptId,
//                    encodedMsg
//                ]
//
//            }
//        }
//    }
    
//    func fetchMessages(senderId: String, messageCount: Int = 50) async throws -> [ChatMessage]? {
//        try await withRetry {
//            client.uri = appUser.baseUrl
//            let entry = "message_fetch"
//            let params: [Any] = [
//                appId,
//                "last",
//                entry,
//                appUser.id,
//                senderId
//            ]
//            
//            let response = try await client.invoke("fetchMessages", params) as? [[String: Any]]
//            return try response?.compactMap { dict in
//                let data = try JSONSerialization.data(withJSONObject: dict)
//                return try JSONDecoder().decode(ChatMessage.self, from: data)
//            }
//        }
//    }
    
    // MARK: - Background Upload
    struct PendingUpload: Codable {
        let tweet: Tweet
        let selectedItemData: [ItemData]
        
        struct ItemData: Codable {
            let identifier: String
            let typeIdentifier: String
            let data: Data
            let fileName: String
        }
    }
    
    // MARK: - Background Task Registration
    static func handleBackgroundTask(task: BGProcessingTask) {
        // Schedule the next background task
        scheduleNextBackgroundTask()
        
        // Create a task to handle the upload
        let uploadTask = Task {
            // Look for the temporary file
            let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            
            do {
                let data = try Data(contentsOf: tempFileURL)
                guard let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data) else {
                    print("DEBUG: Failed to decode pending upload data")
                    task.setTaskCompleted(success: false)
                    return
                }
                
                print("DEBUG: Found pending upload with \(pendingUpload.selectedItemData.count) items")
                
                // Clean up the temporary file immediately after reading
                try? FileManager.default.removeItem(at: tempFileURL)
                
                var tweet = pendingUpload.tweet
                var uploadedAttachments: [MimeiFileType] = []
                
                // Process items in pairs
                let itemPairs = pendingUpload.selectedItemData.chunked(into: 2)
                print("DEBUG: Processing \(itemPairs.count) item pairs")
                
                for (index, pair) in itemPairs.enumerated() {
                    print("DEBUG: Processing pair \(index + 1)")
                    do {
                        let pairAttachments = try await shared.uploadItemPair(pair)
                        print("DEBUG: Successfully uploaded pair \(index + 1)")
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("DEBUG: Error uploading pair \(index + 1): \(error)")
                        task.setTaskCompleted(success: false)
                        return
                    }
                }
                
                if pendingUpload.selectedItemData.count != uploadedAttachments.count {
                    print("DEBUG: Attachment count mismatch. Expected: \(pendingUpload.selectedItemData.count), Got: \(uploadedAttachments.count)")
                    task.setTaskCompleted(success: false)
                    return
                }
                
                // Update tweet with uploaded attachments
                tweet.attachments = uploadedAttachments
                
                // Upload the tweet
                print("DEBUG: Uploading final tweet")
                if let uploadedTweet = try await shared.uploadTweet(tweet) {
                    print("DEBUG: Successfully uploaded tweet: \(uploadedTweet)")
                    task.setTaskCompleted(success: true)
                } else {
                    print("DEBUG: Failed to upload tweet")
                    task.setTaskCompleted(success: false)
                }
            } catch {
                print("DEBUG: Error in background task: \(error)")
                task.setTaskCompleted(success: false)
            }
        }
        
        // Set up the task expiration handler
        task.expirationHandler = {
            uploadTask.cancel()
        }
    }
    
    private static func scheduleNextBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: "com.tweet.upload")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // Schedule next task in 1 hour
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Successfully scheduled next background task")
        } catch {
            print("Could not schedule next background task: \(error)")
        }
    }
    
    func uploadTweet(_ tweet: Tweet) async throws -> Tweet? {
        return try await withRetry {
            guard let service = hproseClient else {
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
            }
            
            let params: [String: Any] = [
                "aid": appId,
                "ver": "last",
                "hostid": "ReyCUFHHZmk0N5w_wxUeEuoY5Xr",
                "tweet": String(data: try JSONEncoder().encode(tweet), encoding: .utf8) ?? ""
            ]
            
            let rawResponse = service.runMApp("add_tweet", params, nil)
            guard let newTweetId = rawResponse as? String else {
                return Tweet?.none
            }
            
            var uploadedTweet = tweet
            uploadedTweet.mid = newTweetId
            return uploadedTweet
        }
    }
    
    private func uploadItemPair(_ pair: [PendingUpload.ItemData]) async throws -> [MimeiFileType] {
        let uploadTasks = pair.map { itemData in
            Task {
                return try await uploadToIPFS(
                    data: itemData.data,
                    typeIdentifier: itemData.typeIdentifier,
                    fileName: itemData.fileName
                )
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
                throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Attachment upload failure in pair"])
            }
            
            return uploadResults.compactMap { $0 }
        }
    }
    
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingUpload.ItemData]) {
        Task.detached(priority: .background) {
            do {
                var tweet = tweet
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                
                for (index, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(index + 1): \(error)")
                        return
                    }
                }
                
                if itemData.count != uploadedAttachments.count {
                    print("Attachment count mismatch. Expected: \(itemData.count), Got: \(uploadedAttachments.count)")
                    return
                }
                
                tweet.attachments = uploadedAttachments
                
                if let uploadedTweet = try await self.uploadTweet(tweet) {
                    await MainActor.run {
                        print("Tweet published successfully \(uploadedTweet)")
                    }
                } else {
                    await MainActor.run {
                        print("Failed to publish tweet")
                    }
                }
            } catch {
                print("Error in background upload: \(error)")
                await MainActor.run {
                    print("Error during upload: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Hprose Service Wrapper
    private func callService<T>(_ service: AnyObject?, entry: String, params: [String: Any], transform: @escaping ((Any?) throws -> T)) async throws -> T {
        guard let service = service else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let response = service.runMApp(entry, params, [])
                    let result = try transform(response)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func callService(_ service: AnyObject?, entry: String, params: [String: Any]) async throws {
        guard let service = service else {
            throw NSError(domain: "HproseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service not initialized"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    _ = service.runMApp(entry, params, [])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ChatMessage: Codable {
    // TODO: Implement ChatMessage properties
}

// MARK: - Database Types
class ChatDatabase {
    static let shared = ChatDatabase()
    private init() {}
}

class TweetCacheDatabase {
    static let shared = TweetCacheDatabase()
    private init() {}
    
    func tweetDao() -> CachedTweetDao {
        return CachedTweetDao()
    }
}

class CachedTweetDao {
    func getLastTweetRank() -> Int {
        // TODO: Implement last tweet rank retrieval
        return 0
    }
}
