//
//  CommentsViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/5/30.
//

@MainActor
@available(iOS 16.0, *)
class CommentsViewModel: ObservableObject {
    @Published var comments: [Tweet] = []
    @Published var isLoading: Bool = false
    @Published var hasMore: Bool = true
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    private var currentPage: Int = 0
    private let pageSize: Int = 20
    private let hproseInstance: HproseInstance
    var parentTweet: Tweet

    init(hproseInstance: HproseInstance, parentTweet: Tweet) {
        self.hproseInstance = hproseInstance
        self.parentTweet = parentTweet
    }

    func loadInitial() async {
        await MainActor.run { isLoading = true; currentPage = 0 }
        do {
            let newComments = try await hproseInstance.fetchComments(
                tweet: parentTweet,
                pageNumber: 0,
                pageSize: pageSize
            )
            await MainActor.run {
                comments = newComments
                hasMore = newComments.count == pageSize
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                showToast = true
                toastMessage = "Failed to load comments."
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await MainActor.run { isLoading = true }
        let nextPage = currentPage + 1
        do {
            let moreComments = try await hproseInstance.fetchComments(
                tweet: parentTweet,
                pageNumber: nextPage,
                pageSize: pageSize
            )
            await MainActor.run {
                let existingIds = Set(comments.map { $0.mid })
                let uniqueNew = moreComments.filter { !existingIds.contains($0.mid) }
                comments.append(contentsOf: uniqueNew)
                hasMore = moreComments.count == pageSize
                currentPage = nextPage
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                showToast = true
                toastMessage = "Failed to load more comments."
            }
        }
    }

    func addComment(_ comment: Tweet) {
        comments.insert(comment, at: 0)
    }

    func removeComment(_ comment: Tweet) {
        comments.removeAll { $0.mid == comment.mid }
    }

    func postComment(_ comment: Tweet, tweet: Tweet) async {
        addComment(comment)
        do {
            guard let (updatedParent, newComment) = try await hproseInstance.addComment(comment, to: tweet) else {
                throw NSError(domain: "AddComment", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result from addComment"])
            }
            if let idx = comments.firstIndex(where: { $0 === comment }) {
                comments[idx].mid = newComment.mid
            }
            print("Backend returned updated commentCount:", updatedParent.commentCount as Any)
            if let count = updatedParent.commentCount, count > 0 {
                tweet.commentCount = count
            } else {
                tweet.commentCount = (tweet.commentCount ?? 0) + 1
            }
        } catch {
            removeComment(comment)
            await MainActor.run {
                showToast = true
                toastMessage = "Failed to post comment."
            }
        }
    }

    func deleteComment(_ comment: Tweet) async {
        let idx = comments.firstIndex(where: { $0.mid == comment.mid })
        removeComment(comment)
        parentTweet.commentCount = max(0, (parentTweet.commentCount ?? 1) - 1)
        do {
            let result = try await hproseInstance.deleteComment(parentTweet: parentTweet, commentId: comment.mid)
            if let dict = result, let deletedId = dict["commentId"] as? String, let count = dict["count"] as? Int, deletedId == comment.mid {
                parentTweet.commentCount = count
            }
        } catch {
            if let idx = idx {
                comments.insert(comment, at: idx)
            }
            parentTweet.commentCount = (parentTweet.commentCount ?? 0) + 1
            await MainActor.run {
                showToast = true
                toastMessage = "Failed to delete comment."
            }
        }
    }
}
