//
//  Settings.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI


struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isCleaningCache = false
    @State private var showCacheCleanedAlert = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text(LocalizedStringKey("Account"))) {
                    if !hproseInstance.appUser.isGuest {
                        Button("Logout") {
                            hproseInstance.logout()
                            NotificationCenter.default.post(name: .userDidLogout, object: nil)
                            dismiss()
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section(header: Text(LocalizedStringKey("App Settings"))) {
                    Toggle("Dark Mode", isOn: $themeManager.isDarkMode)
                    
                    Button(action: {
                        cleanupCache()
                    }) {
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
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .alert(LocalizedStringKey("Cache Cleared"), isPresented: $showCacheCleanedAlert) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(LocalizedStringKey("All image and tweet caches have been cleared successfully."))
            }
        }
    }
    
    private func cleanupCache() {
        isCleaningCache = true
        Task.detached(priority: .background) {
            // Clear image cache completely
            ImageCacheManager.shared.clearAllCache()
            
            // Clear tweet cache completely
            TweetCacheManager.shared.clearAllCache()
            
            await MainActor.run {
                isCleaningCache = false
                showCacheCleanedAlert = true
            }
        }
    }
}

