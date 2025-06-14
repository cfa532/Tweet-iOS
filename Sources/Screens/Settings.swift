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
    @State private var isCleaningCache = false
    @State private var showCacheCleanedAlert = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    if !hproseInstance.appUser.isGuest {
                        Button("Logout") {
                            hproseInstance.logout()
                            NotificationCenter.default.post(name: .userDidLogout, object: nil)
                            dismiss()
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("App Settings")) {
                    Toggle("Dark Mode", isOn: .constant(false))
                    Toggle("Notifications", isOn: .constant(true))
                    
                    Button(action: {
                        cleanupCache()
                    }) {
                        HStack {
                            Text("Clear Media Cache")
                            Spacer()
                            if isCleaningCache {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(isCleaningCache)
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .alert("Cache Cleared", isPresented: $showCacheCleanedAlert) {
                Button("OK") { }
            } message: {
                Text("Media cache has been cleared successfully.")
            }
        }
    }
    
    private func cleanupCache() {
        isCleaningCache = true
        Task.detached(priority: .background) {
            // Clean up image cache
            ImageCacheManager.shared.cleanupOldCache()
            // Clean up video cache
            VideoCacheManager.shared.cleanupOldCache()
            // Clear tweet cache
            TweetCacheManager.shared.deleteExpiredTweets()
            await MainActor.run {
                isCleaningCache = false
                showCacheCleanedAlert = true
            }
        }
    }
}

