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
    private var currentPage: UInt = 0
    private let pageSize: UInt = 20
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
                parentTweet,
                pageNumber: 0,
                pageSize: pageSize
            )
            await MainActor.run {
                comments = newComments.compactMap{ $0 }
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
                parentTweet,
                pageNumber: nextPage,
                pageSize: pageSize
            )
            await MainActor.run {
                let existingIds = Set(comments.map { $0.mid })
                let uniqueNew = moreComments.compactMap { $0 }.filter { !existingIds.contains($0.mid) }
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

    func addComment(_ comment: Tweet?) {
        if let comment = comment {
            comments.insert(comment, at: 0)
        }
    }

    func removeComment(_ comment: Tweet) {
        comments.removeAll { $0.mid == comment.mid }
    }
}
