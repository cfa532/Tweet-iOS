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
                    if let onFollowToggle = onFollowToggle {
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
    }
    
    private func loadUser() {
        Task {
            do {
                if let fetchedUser = try await hproseInstance.fetchUser(userId) {
                    await MainActor.run {
                        self.user = fetchedUser
                        self.isFollowing = hproseInstance.appUser.followingList?.contains(userId) ?? false
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.user = nil
                        self.isLoading = false
                    }
                }
            } catch {
                print("Error loading user \(userId): \(error)")
                await MainActor.run {
                    self.user = nil
                    self.isLoading = false
                }
            }
        }
    }
}
