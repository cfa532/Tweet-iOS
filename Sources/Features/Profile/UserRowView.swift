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
    let onFollowToggle: ((User) async -> Void)?
    let onTap: ((User) -> Void)?
    @State private var user: User?
    @State private var isFollowing: Bool = false
    @State private var showFullProfile: Bool = false
    @State private var isLoading: Bool = true
    @State private var loadingTask: Task<Void, Never>?
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    private func formatRegistrationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Since \(formatter.string(from: date))"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
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
            } else {
                // Error state or user not found
                HStack {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.secondary)
                    Text(NSLocalizedString("User not found", comment: "User not found message"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
    }
    
    private func loadUser() {
        // Cancel any existing loading task
        loadingTask?.cancel()
        
        // Create a new loading task
        loadingTask = Task {
            do {
                print("DEBUG: [UserRowView] Loading user with ID: \(userId)")
                if let fetchedUser = try await hproseInstance.fetchUser(userId) {
                    print("DEBUG: [UserRowView] Successfully fetched user: \(fetchedUser.mid)")
                    await MainActor.run {
                        // Check if task was cancelled before updating UI
                        guard !Task.isCancelled else { return }
                        self.user = fetchedUser
                        self.isFollowing = (hproseInstance.appUser.followingList)?.contains(userId) ?? false
                        self.isLoading = false
                    }
                } else {
                    print("DEBUG: [UserRowView] No user found for ID: \(userId)")
                    await MainActor.run {
                        // Check if task was cancelled before updating UI
                        guard !Task.isCancelled else { return }
                        self.user = nil
                        self.isLoading = false
                    }
                }
            } catch is CancellationError {
                print("DEBUG: [UserRowView] Loading cancelled for user \(userId)")
            } catch {
                print("DEBUG: [UserRowView] Error loading user \(userId): \(error)")
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    self.user = nil
                    self.isLoading = false
                }
            }
        }
    }
}
