//
//  Settings.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

import SwiftUI
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var muteState = MuteState.shared
    @State private var isCleaningCache = false
    @State private var showCacheCleanedAlert = false
    
    private var currentServerIP: String {
        // Extract IP from appUser's baseUrl
        if let baseUrl = hproseInstance.appUser.baseUrl?.absoluteString {
            // Remove protocol and path to get just the IP:port
            let urlString = baseUrl
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
            // Remove any trailing path
            if let firstSlash = urlString.firstIndex(of: "/") {
                return String(urlString[..<firstSlash])
            }
            return urlString
        }
        return NSLocalizedString("Not connected", comment: "Server IP not available")
    }
    
    var body: some View {
        NavigationView {
            List {

                
                Section(header: Text(LocalizedStringKey("App Settings"))) {
                    Toggle(NSLocalizedString("Dark Mode", comment: "Dark mode toggle"), isOn: $themeManager.isDarkMode)
                    
                    Toggle(LocalizedStringKey("Mute Videos"), isOn: $muteState.isMuted)
                        .onChange(of: muteState.isMuted) { _, newValue in
                            // The MuteState will automatically save to preferences
                            print("DEBUG: [SETTINGS] Mute setting changed to: \(newValue)")
                        }
                    
                    DebounceButton(
                        cooldownDuration: 0.5,
                        enableAnimation: true,
                        enableHaptic: false
                    ) {
                        cleanupCache()
                    } label: {
                        HStack {
                            Text(LocalizedStringKey("Clear Media Cache"))
                            Spacer()
                            if isCleaningCache {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }
                    .disabled(isCleaningCache)
                }
                
                Section(header: Text(LocalizedStringKey("About"))) {
                    HStack {
                        Text(LocalizedStringKey("Version"))
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.gray)
                    }
                    
                    if hproseInstance.appUser.isGuest {
                        HStack {
                            Text(LocalizedStringKey("Server IP"))
                            Spacer()
                            Text(currentServerIP)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Settings", comment: "Settings screen title"))
            .navigationBarItems(trailing: Button(NSLocalizedString("Done", comment: "Done button")) {
                dismiss()
            })
            .alert(LocalizedStringKey("Cache Cleared"), isPresented: $showCacheCleanedAlert) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(LocalizedStringKey("All caches, users, and tweets have been cleared successfully."))
            }
        }
    }
    
    private func cleanupCache() {
        print("DEBUG: [Settings] Starting cache cleanup with spinner")
        isCleaningCache = true

        Task {
            // Use tweet-centered cleanup - clears ALL tweets (including private) and their media
            print("DEBUG: [Settings] Clearing TweetCacheManager")
            TweetCacheManager.shared.manualClearAllCache()

            // Clear chat cache
            print("DEBUG: [Settings] Clearing ChatCacheManager")
            ChatCacheManager.shared.clearAllCache()

            // Clear all memory caches
            print("DEBUG: [Settings] Clearing memory caches")
            VideoStateCache.shared.clearAllCache()
            DetailVideoManager.shared.clearCurrentVideo()
            Tweet.clearAllInstances()
            GlobalImageLoadManager.shared.clearAll()

            // Clear all video cache files from disk
            print("DEBUG: [Settings] Clearing CachingPlayerItem")
            await CachingPlayerItem.clearAllCache()

            // Reinitialize app entry to refresh user and tweet data
            print("DEBUG: [Settings] Reinitializing app entry")
            do {
                try await hproseInstance.initAppEntry()
                print("DEBUG: [Settings] App entry reinitialized after cache clear")
            } catch {
                print("Failed to reinitialize app entry: \(error)")
            }

            // Force UI refresh by posting notification
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("CacheCleared"), object: nil)
                print("DEBUG: [Settings] Posted CacheCleared notification")
                isCleaningCache = false
                showCacheCleanedAlert = true
                print("DEBUG: [Settings] Cache cleanup complete")
            }
        }
    }
}
