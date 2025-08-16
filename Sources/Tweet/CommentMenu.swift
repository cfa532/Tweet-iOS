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
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isDeleting = false

    var body: some View {
        Menu {
            if comment.authorId == appUser.mid || parentTweet.authorId == appUser.mid {
                Button(role: .destructive) {
                    isDeleting = true
                    // Start deletion in background
                    Task {
                        do {
                            try await deleteComment(comment)
                        } catch {
                            print("Comment deletion failed. \(comment)")
                            await MainActor.run {
                                alertMessage = "Failed to delete comment. \(error)"
                                showAlert = true
                            }
                        }
                        isDeleting = false
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isDeleting)
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
                .padding(12)
                .contentShape(Rectangle())
        }
        .alert(NSLocalizedString("Delete Comment", comment: "Delete comment alert title"), isPresented: $showAlert) {
            Button(NSLocalizedString("OK", comment: "OK button"), role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func deleteComment(_ comment: Tweet) async throws {
        // Post notification for optimistic UI update
        NotificationCenter.default.post(
            name: .commentDeleted,
            object: nil,
            userInfo: ["comment": comment]
        )
        await MainActor.run {
            parentTweet.commentCount = max(0, (parentTweet.commentCount ?? 1) - 1)
        }
        // Attempt actual deletion
        if let response = try? await hproseInstance.deleteComment(parentTweet: parentTweet, commentId: comment.mid),
           let commentId = response["commentId"] as? String,
           let count = response["count"] as? Int {
            print("Successfully deleted comment: \(commentId) \(count)")
            
            // Update parent tweet's comment count
            await MainActor.run {
                parentTweet.commentCount = count
            }
        } else {
            // If deletion fails, post restoration notification
            NotificationCenter.default.post(
                name: .commentRestored,
                object: nil,
                userInfo: ["comment": comment]
            )
            throw NSError(domain: "CommentService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete comment"])
        }
    }
}

