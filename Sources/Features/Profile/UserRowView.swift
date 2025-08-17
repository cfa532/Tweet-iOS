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
    
    private func formatRegistrationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Since \(formatter.string(from: date))"
    }

    var body: some View {
        Button {
            onTap?(user)
        } label: {
            HStack(alignment: .top, spacing: 4) {
                NavigationLink(destination: ProfileView(user: user, onLogout: nil)) {
                    Avatar(user: user, size: 48)
                }
                .buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(user.name ?? "User Name")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("@\(user.username ?? NSLocalizedString("Noone", comment: "Default username"))")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("- " + formatRegistrationDate(user.timestamp))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
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
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            isFollowing = hproseInstance.appUser.followingList?.contains(user.mid) ?? false
        }
        Divider()
            .padding(.horizontal, 8)
    }
}
