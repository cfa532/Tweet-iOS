//
//  Settings.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI


struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hproseInstance = HproseInstanceState.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var muteState = MuteState.shared
    @State private var isCleaningCache = false
    @State private var showCacheCleanedAlert = false
    
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
                        enableVibration: false
                    ) {
                        cleanupCache()
                    } label: {
                        HStack {
                            Text(LocalizedStringKey("Clear Media Cache"))
                            Spacer()
                            if isCleaningCache {
                                ProgressView()
                                    .scaleEffect(0.8)
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
        isCleaningCache = true
        Task.detached(priority: .background) {
            // Clear all caches completely
            ImageCacheManager.shared.clearAllCache()
            TweetCacheManager.shared.clearAllCache()
            ChatCacheManager.shared.clearAllCache()
            
            // Clear shared asset cache
            await MainActor.run {
                SharedAssetCache.shared.clearCache()
            }
            
            // Reinitialize app entry to refresh user and tweet data
            do {
                try await hproseInstance.initAppEntry()
            } catch {
                print("Failed to reinitialize app entry: \(error)")
            }
            
            await MainActor.run {
                isCleaningCache = false
                showCacheCleanedAlert = true
            }
        }
    }
}

