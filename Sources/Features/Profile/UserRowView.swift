//
//  UserRowView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/10.
//
import SwiftUI

@available(iOS 16.0, *)
struct UserRowView: View {
    let user: User
    let onFollowToggle: ((User) async -> Void)?
    let onTap: ((User) -> Void)?
    @State private var isFollowing: Bool = false
    @State private var showFullProfile: Bool = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        Button {
            onTap?(user)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                NavigationLink(destination: ProfileView(user: user, onLogout: nil)) {
                    Avatar(user: user, size: 40)
                }
                .buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(user.name ?? "User Name")
                            .font(.system(size: 14, weight: .semibold))
                        Text("@\(user.username ?? "username")")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    if let profile = user.profile, !profile.isEmpty {
                        Group {
                            if showFullProfile {
                                Text(profile)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                                Button("Show less") {
                                    showFullProfile = false
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                                .buttonStyle(.plain)
                            } else {
                                Text(profile)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if profile.count > 80 {
                                    Button("...") {
                                        showFullProfile = true
                                    }
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Spacer()
                if let onFollowToggle = onFollowToggle {
                    Button {
                        Task {
                            await onFollowToggle(user)
                            isFollowing.toggle()
                        }
                    } label: {
                        Text(isFollowing ? "Unfollow" : "Follow")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isFollowing ? Color.red : Color.blue, lineWidth: 1)
                            )
                            .foregroundColor(isFollowing ? .red : .blue)
                    }
                }
            }
            .padding(.horizontal)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            isFollowing = hproseInstance.appUser.followingList?.contains(user.mid) ?? false
        }
        // Remove .padding(.vertical, 2) for minimal row height
    }
}
