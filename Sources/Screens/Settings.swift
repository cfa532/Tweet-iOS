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
    
    // Agent Token states
    @State private var showAgentTokenSheet = false
    @State private var agentToken: String = ""
    @State private var isGeneratingToken = false
    @State private var showTokenCopiedAlert = false
    @State private var showRevokeConfirmation = false
    
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
                
                // Agent Token Section - only show for logged-in users
                if !hproseInstance.appUser.isGuest {
                    Section(header: Text(LocalizedStringKey("AI Agent Access"))) {
                        Button {
                            showAgentTokenSheet = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey("Agent Token"))
                                        .foregroundColor(.primary)
                                    Text(hproseInstance.appUser.agentPublicKey != nil 
                                         ? LocalizedStringKey("Token configured") 
                                         : LocalizedStringKey("Not configured"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
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
            .sheet(isPresented: $showAgentTokenSheet) {
                AgentTokenView(
                    agentToken: $agentToken,
                    isGenerating: $isGeneratingToken,
                    showCopiedAlert: $showTokenCopiedAlert,
                    showRevokeConfirmation: $showRevokeConfirmation,
                    hproseInstance: hproseInstance
                )
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
            CachingPlayerItem.clearAllCache()

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

// MARK: - Agent Token View

struct AgentTokenView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var agentToken: String
    @Binding var isGenerating: Bool
    @Binding var showCopiedAlert: Bool
    @Binding var showRevokeConfirmation: Bool
    @ObservedObject var hproseInstance: HproseInstance
    
    @State private var errorMessage: String?
    @State private var showError = false
    
    private var hasExistingToken: Bool {
        hproseInstance.appUser.agentPublicKey != nil
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Info Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label(LocalizedStringKey("What is an Agent Token?"), systemImage: "info.circle")
                            .font(.headline)
                        
                        Text(LocalizedStringKey("An agent token allows AI agents to post on your behalf without knowing your password. The token contains a cryptographic key that proves the agent is authorized by you."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Security Warning
                    VStack(alignment: .leading, spacing: 12) {
                        Label(LocalizedStringKey("Security Notice"), systemImage: "exclamationmark.shield")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        Text(LocalizedStringKey("Keep your token secret! Anyone with this token can post as you. If compromised, generate a new token to revoke access."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Token Display/Generation
                    if !agentToken.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizedStringKey("Your Agent Token"))
                                .font(.headline)
                            
                            Text(agentToken)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                            
                            Button {
                                UIPasteboard.general.string = agentToken
                                showCopiedAlert = true
                            } label: {
                                Label(LocalizedStringKey("Copy Token"), systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    
                    // Action Buttons
                    VStack(spacing: 12) {
                        if hasExistingToken {
                            Button {
                                showRevokeConfirmation = true
                            } label: {
                                HStack {
                                    if isGenerating {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }
                                    Text(LocalizedStringKey("Regenerate Token (Revokes Old)"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(isGenerating)
                        } else {
                            Button {
                                generateToken()
                            } label: {
                                HStack {
                                    if isGenerating {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }
                                    Text(LocalizedStringKey("Generate Token"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isGenerating)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle(LocalizedStringKey("Agent Token"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(LocalizedStringKey("Done")) {
                        dismiss()
                    }
                }
            }
            .alert(LocalizedStringKey("Token Copied"), isPresented: $showCopiedAlert) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(LocalizedStringKey("The agent token has been copied to your clipboard."))
            }
            .alert(LocalizedStringKey("Regenerate Token?"), isPresented: $showRevokeConfirmation) {
                Button(LocalizedStringKey("Cancel"), role: .cancel) { }
                Button(LocalizedStringKey("Regenerate"), role: .destructive) {
                    generateToken()
                }
            } message: {
                Text(LocalizedStringKey("This will revoke the existing token. Any AI agents using the old token will no longer be able to post as you."))
            }
            .alert(LocalizedStringKey("Error"), isPresented: $showError) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }
    
    private func generateToken() {
        isGenerating = true
        
        Task {
            do {
                let result = try await hproseInstance.generateAgentToken()
                await MainActor.run {
                    agentToken = result
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isGenerating = false
                }
            }
        }
    }
}
