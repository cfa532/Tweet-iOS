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
    
    // Account action states
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showDeleteAccountError = false

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
                
                if !hproseInstance.appUser.isGuest {
                    Section(header: Text(LocalizedStringKey("Account"))) {
                        Button {
                            showLogoutConfirmation = true
                        } label: {
                            Text(LocalizedStringKey("Logout"))
//                                .foregroundColor(.red)
                        }

                        Button {
                            showDeleteAccountConfirmation = true
                        } label: {
                            HStack {
                                Text(LocalizedStringKey("Delete Account"))
//                                    .foregroundColor(.red)
                                Spacer()
                                if isDeletingAccount {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isDeletingAccount)
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
            .navigationTitle(NSLocalizedString("Settings", comment: "Settings screen title"))
            .navigationBarItems(trailing: Button(NSLocalizedString("Done", comment: "Done button")) {
                dismiss()
            })
            .alert(LocalizedStringKey("Cache Cleared"), isPresented: $showCacheCleanedAlert) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(LocalizedStringKey("All caches, users, and tweets have been cleared successfully."))
            }
            .alert(NSLocalizedString("Are you sure you want to logout?", comment: "Logout confirmation alert title"), isPresented: $showLogoutConfirmation) {
                Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
                Button(NSLocalizedString("Logout", comment: "Logout button"), role: .destructive) {
                    Task { await handleLogout() }
                }
            } message: {
                Text(NSLocalizedString("This action cannot be undone.", comment: "Logout confirmation message"))
            }
            .alert(NSLocalizedString("Are you sure you want to delete your account?", comment: "Delete account confirmation alert title"), isPresented: $showDeleteAccountConfirmation) {
                Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
                Button(NSLocalizedString("Delete Account", comment: "Delete account button"), role: .destructive) {
                    Task { await handleDeleteAccount() }
                }
            } message: {
                Text(NSLocalizedString("This action cannot be undone.", comment: "Delete account confirmation message"))
            }
            .alert(LocalizedStringKey("Error"), isPresented: $showDeleteAccountError) {
                Button(LocalizedStringKey("OK")) { }
            } message: {
                Text(deleteAccountError ?? NSLocalizedString("Unknown error", comment: "Fallback error message"))
            }
        }
    }
    
    private func handleLogout() async {
        await hproseInstance.logout()
        await MainActor.run {
            NotificationCenter.default.post(name: .userDidLogout, object: nil)
            dismiss()
        }
    }

    private func handleDeleteAccount() async {
        isDeletingAccount = true
        do {
            let result = try await hproseInstance.deleteAccount()
            if let success = result["success"] as? Bool, success {
                TweetCacheManager.shared.clearAllCache()
                ImageCacheManager.shared.clearAllCache()
                await hproseInstance.logout()
                await MainActor.run {
                    NotificationCenter.default.post(name: .userDidLogout, object: nil)
                    isDeletingAccount = false
                    dismiss()
                }
            } else {
                let message = result["message"] as? String ?? "Unknown error occurred"
                await MainActor.run {
                    deleteAccountError = message
                    showDeleteAccountError = true
                    isDeletingAccount = false
                }
            }
        } catch {
            await MainActor.run {
                deleteAccountError = ErrorMessageHelper.userFriendlyMessage(from: error)
                showDeleteAccountError = true
                isDeletingAccount = false
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
                Text(errorMessage ?? NSLocalizedString("Unknown error", comment: "Fallback error message"))
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
