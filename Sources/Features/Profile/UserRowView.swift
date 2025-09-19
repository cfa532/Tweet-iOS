//
//  UserRowView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/10.
//
import SwiftUI

@available(iOS 16.0, *)
struct UserRowView: View {
    let userId: String
    let cancellationToken: UUID
    let onFollowToggle: ((User) async -> Void)?
    let onTap: ((User) -> Void)?
    let onLoadFailed: ((String) -> Void)?
    @State private var user: User?
    @State private var isFollowing: Bool = false
    @State private var showFullProfile: Bool = false
    @State private var isLoading: Bool = true
    @State private var loadFailed: Bool = false
    @State private var loadingTask: Task<Void, Never>?
    @State private var currentCancellationToken: UUID
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Sequential loading control
    @State private var shouldStartLoading: Bool = false
    
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
            } else if let user = user {
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
                            Task {
                                await onFollowToggle(user)
                                isFollowing.toggle()
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
        .onAppear {
            loadUser()
        }
        .onDisappear {
            // Cancel any ongoing loading task when view disappears
            loadingTask?.cancel()
        }
        .onChange(of: cancellationToken) { newToken in
            // Cancel loading task when cancellation token changes
            if newToken != currentCancellationToken {
                loadingTask?.cancel()
                currentCancellationToken = newToken
            }
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
                if let fetchedUser = try await hproseInstance.fetchUser(userId) {
                    // Check if task should be cancelled before processing
                    guard taskCancellationToken == currentCancellationToken else {
                        print("DEBUG: [UserRowView] Task cancelled during processing for user \(userId)")
                        return
                    }
                    
                    // Validate user has required fields
                    if fetchedUser.mid.isEmpty || (fetchedUser.username?.isEmpty ?? true) {
                        print("DEBUG: [UserRowView] Invalid user data for ID: \(userId) - missing mid or username")
                        await MainActor.run {
                            // Check if task was cancelled before updating UI
                            guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                            self.loadFailed = true
                            self.isLoading = false
                            // Notify parent that this user failed to load
                            self.onLoadFailed?(userId)
                        }
                    } else {
                        print("DEBUG: [UserRowView] Successfully fetched user: \(fetchedUser.mid)")
                        await MainActor.run {
                            // Check if task was cancelled before updating UI
                            guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                            self.user = fetchedUser
                            self.isFollowing = (hproseInstance.appUser.followingList)?.contains(userId) ?? false
                            self.isLoading = false
                        }
                    }
                } else {
                    print("DEBUG: [UserRowView] No user found for ID: \(userId)")
                    await MainActor.run {
                        // Check if task was cancelled before updating UI
                        guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                        self.loadFailed = true
                        self.isLoading = false
                        // Notify parent that this user failed to load
                        self.onLoadFailed?(userId)
                    }
                }
            } catch is CancellationError {
                print("DEBUG: [UserRowView] Loading cancelled for user \(userId)")
            } catch {
                print("DEBUG: [UserRowView] Error loading user \(userId): \(error)")
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled && taskCancellationToken == currentCancellationToken else { return }
                    self.loadFailed = true
                    self.isLoading = false
                    // Notify parent that this user failed to load
                    self.onLoadFailed?(userId)
                }
            }
        }
    }
}
