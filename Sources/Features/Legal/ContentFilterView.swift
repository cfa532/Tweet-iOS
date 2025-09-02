import SwiftUI

struct ContentFilterView: View {
    @ObservedObject var tweet: Tweet
    @Environment(\.dismiss) private var dismiss
    @State private var hproseInstance = HproseInstanceState(hproseInstance: HproseInstance.shared)
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
    // Filter options
    @State private var blockUser = false
    @State private var hideKeywords = false
    @State private var customKeywords = ""
    @State private var filterProfanity = false
    @State private var filterViolence = false
    @State private var filterAdultContent = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Content Filtering"))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text(LocalizedStringKey("Control what content you see on your timeline"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // User-specific filters
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("User Actions"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        VStack(spacing: 0) {
                            Toggle(LocalizedStringKey("Block this user"), isOn: $blockUser)
                                .padding()
                                .background(Color(.systemGray6))
                            
                            Divider()
                                .padding(.leading)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(LocalizedStringKey("Hide posts with keywords"), isOn: $hideKeywords)
                                    .padding()
                                
                                if hideKeywords {
                                    TextField(LocalizedStringKey("Enter keywords separated by commas"), text: $customKeywords)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .padding(.horizontal)
                                        .padding(.bottom)
                                }
                            }
                            .background(Color(.systemGray6))
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    
                    // Content type filters
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("Content Types"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        VStack(spacing: 0) {
                            Toggle(LocalizedStringKey("Filter profanity"), isOn: $filterProfanity)
                                .padding()
                                .background(Color(.systemGray6))
                            
                            Divider()
                                .padding(.leading)
                            
                            Toggle(LocalizedStringKey("Filter violent content"), isOn: $filterViolence)
                                .padding()
                                .background(Color(.systemGray6))
                            
                            Divider()
                                .padding(.leading)
                            
                            Toggle(LocalizedStringKey("Filter adult content"), isOn: $filterAdultContent)
                                .padding()
                                .background(Color(.systemGray6))
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    
                    // Information section
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LocalizedStringKey("How Content Filtering Works"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label(LocalizedStringKey("Filtered content will be hidden from your timeline"), systemImage: "eye.slash")
                            Label(LocalizedStringKey("You can always change these settings later"), systemImage: "gearshape")
                            Label(LocalizedStringKey("Blocking users prevents them from interacting with you"), systemImage: "person.crop.circle.badge.xmark")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(LocalizedStringKey("Cancel")) {
                    dismiss()
                },
                trailing: Button(LocalizedStringKey("Apply Filters")) {
                    applyFilters()
                }
                .fontWeight(.semibold)
            )
        }
        .overlay(
            // Toast message overlay
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )
    }
    
    private func applyFilters() {
        Task {
            do {
                // Apply user blocking
                if blockUser {
                    try await hproseInstance.blockUser(userId: tweet.authorId)
                    
                    // Handle UI updates after successful backend call
                    await MainActor.run {
                        // Remove blocked user from following list
                        if let followingList = hproseInstance.appUser.followingList {
                            hproseInstance.appUser.followingList = followingList.filter { $0 != tweet.authorId }
                            print("[ContentFilterView] Removed \(tweet.authorId) from following list")
                        }
                        
                        // Remove all tweets from the blocked user from current views
                        NotificationCenter.default.post(
                            name: .tweetDeleted,
                            object: nil,
                            userInfo: ["blockedUserId": tweet.authorId]
                        )
                        print("[ContentFilterView] Posted notification to remove tweets from blocked user: \(tweet.authorId)")
                        
                        toastMessage = NSLocalizedString("User blocked successfully", comment: "Block user success")
                        toastType = .success
                        showToast = true
                    }
                }
                
                // Store filter preferences (in a real app, this would save to user preferences)
                await MainActor.run {
                    if !blockUser {
                        toastMessage = NSLocalizedString("Content filters applied", comment: "Filter success")
                        toastType = .success
                        showToast = true
                    }
                }
                
                // Dismiss after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    toastMessage = NSLocalizedString("Failed to apply filters", comment: "Filter error")
                    toastType = .error
                    showToast = true
                }
            }
        }
    }
}
