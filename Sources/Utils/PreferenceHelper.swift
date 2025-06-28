import Foundation

class PreferenceHelper {
    private let userDefaults = UserDefaults.standard
    
    // MARK: - App URLs
    func setAppUrls(_ urls: Set<String>) {
        let urlsString = urls.filter { !$0.isEmpty }.joined(separator: ",")
        userDefaults.set(urlsString, forKey: "custom_urls")
    }
    
    func getAppUrls() -> Set<String> {
        let urlsString = userDefaults.string(forKey: "custom_urls") ?? ""
        if !urlsString.isEmpty {
            return Set(urlsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        } else {
            // Replace with your default base URL if needed
            return [AppConfig.baseUrl]
        }
    }
    
    // MARK: - Speaker Mute
    func setSpeakerMute(_ isMuted: Bool) {
        userDefaults.set(isMuted, forKey: "speakerMuted")
    }
    
    func getSpeakerMute() -> Bool {
        if userDefaults.object(forKey: "speakerMuted") == nil {
            return true // Default to muted if not set
        }
        return userDefaults.bool(forKey: "speakerMuted")
    }
    
    // MARK: - User ID
    func getUserId() -> String? {
        return userDefaults.string(forKey: "userId")
    }
    
    func setUserId(_ id: String?) {
        userDefaults.set(id, forKey: "userId")
    }
    
    // MARK: - Tweet Feed Tab Index
    func getTweetFeedTabIndex() -> Int {
        return userDefaults.integer(forKey: "tweetFeedIndex")
    }
    
    func setTweetFeedTabIndex(_ index: Int) {
        userDefaults.set(index, forKey: "tweetFeedIndex")
    }
    
    // MARK: - Cloud Port
    func getCloudPort() -> String? {
        return userDefaults.string(forKey: "cloudPort")
    }
    
    func setCloudPort(_ port: String?) {
        userDefaults.set(port, forKey: "cloudPort")
    }
} 
