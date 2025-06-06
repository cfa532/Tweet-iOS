//
//  CommentMenu.swift
//  Tweet
//
//  Created by 超方 on 2025/6/6.
//

import SwiftUI

@available(iOS 16.0, *)
struct CommentMenu: View {
    @ObservedObject var comment: Tweet
    @ObservedObject var parentTweet: Tweet
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info

    var body: some View {
        ZStack {
            Menu {
                if comment.authorId == appUser.mid {
                    Button(role: .destructive) {
                        // Start deletion in background
                        Task {
                            do {
                                try await deleteComment(comment)
                            } catch {
                                print("Comment deletion failed. \(comment)")
                                await MainActor.run {
                                    toastMessage = "Failed to delete comment."
                                    toastType = .error
                                    showToast = true
                                }
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            if showToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showToast)
            }
        }
    }
    
    private func deleteComment(_ comment: Tweet) async throws {
        // Post notification for optimistic UI update
        NotificationCenter.default.post(
            name: .commentDeleted,
            object: nil,
            userInfo: ["commentId": comment.mid]
        )
        
        // Attempt actual deletion
        if let response = try? await hproseInstance.deleteComment(parentTweet: parentTweet, commentId: comment.mid),
           let commentId = response["commentId"] as? String,
           let count = response["count"] as? Int {
            print("Successfully deleted comment: \(commentId)")
            
            // Update parent tweet's comment count
            await MainActor.run {
                parentTweet.commentCount = count
            }
        } else {
            // If deletion fails, post restoration notification
            NotificationCenter.default.post(
                name: .commentRestored,
                object: nil,
                userInfo: ["commentId": comment.mid]
            )
            await MainActor.run {
                toastMessage = "Failed to delete comment."
                toastType = .error
                showToast = true
            }
        }
    }
}

