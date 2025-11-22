//
//  UserRowView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/10.
//
import SwiftUI
import Combine

@available(iOS 16.0, *)
struct UserRowView: View {
    let userId: String
    let cancellationToken: UUID
    let onFollowToggle: ((User) async -> Void)?
    let onTap: ((User) -> Void)?
    let onLoadFailed: ((String) -> Void)?
    @ObservedObject private var user: User
    @State private var isFollowing: Bool = false
    @State private var showFullProfile: Bool = false
    @State private var isLoading: Bool = true
    @State private var loadFailed: Bool = false
    @State private var loadingTask: Task<Void, Never>?
    @State private var currentCancellationToken: UUID
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""
    @State private var toastType: ToastView.ToastType = .error
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // MARK: - Initialization
    init(
        userId: String,
        cancellationToken: UUID,
        onFollowToggle: ((User) async -> Void)? = nil,
        onTap: ((User) -> Void)? = nil,
        onLoadFailed: ((String) -> Void)? = nil
    ) {
        self.userId = userId
        self.cancellationToken = cancellationToken
        self.onFollowToggle = onFollowToggle
        self.onTap = onTap
        self.onLoadFailed = onLoadFailed
        self._currentCancellationToken = State(initialValue: cancellationToken)
        // Initialize ObservedObject with singleton instance
        self._user = ObservedObject(wrappedValue: User.getInstance(mid: userId))
    }
    
    private func formatRegistrationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Since \(formatter.string(from: date))"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if loadFailed {
                // Don't display anything when load fails
                EmptyView()
            } else if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(NSLocalizedString("Loading user...", comment: "Loading user message"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Avatar(user: user, size: 48)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(user.name ?? "User Name")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("@\(user.username ?? NSLocalizedString("Noone", comment: "Default username"))")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        Text(formatRegistrationDate(user.timestamp))
                            .font(.caption)
                            .foregroundColor(.gray)
                        if let profile = user.profile, !profile.isEmpty {
                            Group {
                                if showFullProfile {
                                    Text(profile)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(nil)
                                    Button(NSLocalizedString("Show less", comment: "Show less button")) {
                                        showFullProfile = false
                                    }
                                    .font(.caption)
                                    .foregroundColor(.themeAccent)
                                    .buttonStyle(.plain)
                                } else {
                                    Text(profile)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(3)
                                        .truncationMode(.tail)
                                    if profile.count > 200 {
                                        Button(NSLocalizedString("...", comment: "More options button")) {
                                            showFullProfile = true
                                        }
                                        .font(.caption)
                                        .foregroundColor(.themeAccent)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                    // Only show follow/unfollow button if app user is not a guest and onFollowToggle is provided
                    if let onFollowToggle = onFollowToggle, !hproseInstance.appUser.isGuest {
                        DebounceButton(
                            cooldownDuration: 0.5,
                            enableVibration: false
                        ) {
                            // Toggle optimistically first
                            isFollowing.toggle()
                            Task {
                                await handleToggleFollowing(for: user, onFollowToggle: onFollowToggle)
                            }
                        } label: {
                            Text(isFollowing ? NSLocalizedString("Unfollow", comment: "Unfollow button") : NSLocalizedString("Follow", comment: "Follow button"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(isFollowing ? Color.red : Color.blue, lineWidth: 1)
                                )
                                .foregroundColor(isFollowing ? .red : .blue)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap?(user)
                }
            }
            
            Divider()
                .padding(.horizontal, 8)
        }
        .overlay(
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 20)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showToast)
        )
        .onAppear {
            loadUser()
        }
        .onDisappear {
            // Cancel any ongoing loading task when view disappears
            loadingTask?.cancel()
        }
        .onChange(of: cancellationToken) { _, newToken in
            // Cancel loading task when cancellation token changes
            if newToken != currentCancellationToken {
                loadingTask?.cancel()
                currentCancellationToken = newToken
            }
        }
    }
    
    private func handleToggleFollowing(for user: User, onFollowToggle: ((User) async -> Void)?) async {
        if let ret = try? await hproseInstance.toggleFollowing(followingId: user.mid) {
            // Update the isFollowing state based on the result
            await MainActor.run {
                isFollowing = ret
            }
            
            // Update app user's followingList based on the result
            if ret {
                // User is now following - add to followingList
                if hproseInstance.appUser.followingList == nil {
                    hproseInstance.appUser.followingList = []
                }
                if !hproseInstance.appUser.followingList!.contains(user.mid) {
                    hproseInstance.appUser.followingList!.append(user.mid)
                }
            } else {
                // User is no longer following - remove from followingList
                hproseInstance.appUser.followingList?.removeAll { $0 == user.mid }
            }
            
            // Update the followed user's fansList and counts on main thread
            await MainActor.run {
                if ret {
                    // User is now following - add app user to followed user's fansList
                    if user.fansList == nil {
                        user.fansList = []
                    }
                    if !user.fansList!.contains(hproseInstance.appUser.mid) {
                        user.fansList!.append(hproseInstance.appUser.mid)
                    }
                    // Increment the followed user's followers count
                    user.followersCount = (user.followersCount ?? 0) + 1
                    
                    // Fetch and add recent tweets from newly followed user to main feed
                    Task {
                        await FollowingsTweetViewModel.shared.addTweetsFromNewlyFollowedUser(user)
                    }
                } else {
                    // User is no longer following - remove app user from followed user's fansList
                    user.fansList?.removeAll { $0 == hproseInstance.appUser.mid }
                    // Decrement the followed user's followers count
                    user.followersCount = max(0, (user.followersCount ?? 0) - 1)
                    
                    // Remove unfollowed user's tweets from main feed
                    FollowingsTweetViewModel.shared.removeTweetsFromUser(user.mid)
                }
                
                // Update app user's following count
                if ret {
                    // User is now following - increment app user's following count
                    hproseInstance.appUser.followingCount = (hproseInstance.appUser.followingCount ?? 0) + 1
                } else {
                    // User is no longer following - decrement app user's following count
                    hproseInstance.appUser.followingCount = max(0, (hproseInstance.appUser.followingCount ?? 0) - 1)
                }
            }
        } else {
            // Revert the isFollowing state on failure
            await MainActor.run {
                isFollowing.toggle()
            }
            showToastMessage(NSLocalizedString("Failed to toggle following status", comment: "Profile action error"))
        }
    }
    
    private func showToastMessage(_ message: String) {
        toastMessage = message
        toastType = .error
        showToast = true
        
        // Auto-hide toast after 3 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showToast = false
        }
    }
    
    private func loadUser() {
        // Cancel any existing loading task
        loadingTask?.cancel()
        
        // Store the current cancellation token for this task
        let taskCancellationToken = currentCancellationToken
        
        // Create a new loading task
        loadingTask = Task {
            do {
                // Check if this task should be cancelled before starting
                guard taskCancellationToken == currentCancellationToken else {
                    print("DEBUG: [UserRowView] Task cancelled before starting for user \(userId)")
                    return
                }
                
                print("DEBUG: [UserRowView] Loading user with ID: \(userId)")
                // Keep spinner showing while fetchUser is in progress (includes retries)
                // fetchUser will retry up to 3 times before returning skeleton on failure
                let fetchedUser = try await hproseInstance.fetchUser(userId)
                
                // Check if task should be cancelled before processing
                guard taskCancellationToken == currentCancellationToken else {
                    print("DEBUG: [UserRowView] Task cancelled during processing for user \(userId)")
                    return
                }
                
                // The user singleton will be automatically updated by fetchUser's background task
                // @ObservedObject will cause view to refresh when singleton's @Published properties change
                let sanitizedUsername = fetchedUser?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                // Only remove user row if fetchUser failed after retries (returns skeleton with no username)
                // Otherwise keep showing spinner until valid user is loaded
                if let fetchedUser = fetchedUser, !sanitizedUsername.isEmpty {
                    // Valid user loaded - hide spinner and show user
                    print("DEBUG: [UserRowView] Fetched user: \(fetchedUser.mid), username: \(sanitizedUsername)")
                    await MainActor.run {
                        // Check if task was cancelled before updating UI
                        guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                        self.isFollowing = (hproseInstance.appUser.followingList)?.contains(userId) ?? false
                        self.isLoading = false
                    }
                } else {
                    // fetchUser returned skeleton (no username) after all retries failed
                    // Remove the user row to indicate failure
                    print("⚠️ [UserRowView] fetchUser failed after retries for ID: \(userId) - removing row")
                    await MainActor.run {
                        guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                        self.loadFailed = true
                        self.isLoading = false
                        self.onLoadFailed?(userId)
                    }
                }
            } catch is CancellationError {
                print("DEBUG: [UserRowView] Loading cancelled for user \(userId)")
            } catch {
                // fetchUser threw error after all retries failed
                // Remove the user row to indicate failure
                print("DEBUG: [UserRowView] Error loading user \(userId) after retries: \(error)")
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                    self.loadFailed = true
                    self.isLoading = false
                    // Notify parent that this user failed to load after retries
                    self.onLoadFailed?(userId)
                }
            }
        }
    }
}
