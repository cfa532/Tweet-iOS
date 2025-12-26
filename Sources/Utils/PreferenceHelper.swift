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
        var urls: Set<String>
        if !urlsString.isEmpty {
            urls = Set(urlsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        } else {
            urls = Set<String>()
        }
        // Always include AppConfig.baseUrl if not already present
        urls.insert(AppConfig.baseUrl)
        return urls
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
    
    func resetSpeakerMuteToDefault() {
        userDefaults.removeObject(forKey: "speakerMuted")
    }
    
    // MARK: - Dark Mode
    func setDarkMode(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: "darkModeEnabled")
    }
    
    func getDarkMode() -> Bool {
        return userDefaults.bool(forKey: "darkModeEnabled")
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
    
    // MARK: - Local HTTP Server Port
    func getLocalHTTPServerPort() -> UInt16 {
        let savedPort = userDefaults.integer(forKey: "localHTTPServerPort")
        if savedPort > 0 && savedPort <= 65535 {
            return UInt16(savedPort)
        }
        return 8080 // Default port
    }
    
    func setLocalHTTPServerPort(_ port: UInt16) {
        userDefaults.set(Int(port), forKey: "localHTTPServerPort")
        NSLog("DEBUG: [PreferenceHelper] Saved LocalHTTPServer port: \(port)")
    }
} 
