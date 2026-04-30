import SwiftUI

/// Central registration for `NavigationStack` destinations that `ProfileView` and nested flows push
/// (`User`, `UserListDestination`, `TweetListDestination`, `CommentNavigation`, `Tweet`).
/// Attach this once per stack (Home, Search, Chat, …) so new tabs cannot forget a destination type.
struct AppNavigationDestinationsModifier: ViewModifier {
    @Binding var navigationPath: NavigationPath
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)?
    /// Called as `ProfileView.onLogout` when non-nil (e.g. home clears path and returns to root).
    var onProfileLogout: (() -> Void)?
    /// Invoked from `ProfileView`’s root `onAppear` (e.g. Search dismisses keyboard).
    var onUserProfileAppear: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: User.self) { user in
                ProfileView(
                    user: user,
                    onLogout: onProfileLogout,
                    navigationPath: $navigationPath,
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast
                )
                .onAppear {
                    onUserProfileAppear?()
                }
            }
            .navigationDestination(for: UserListDestination.self) { destination in
                UserListDestinationView(destination: destination, navigationPath: $navigationPath)
            }
            .navigationDestination(for: TweetListDestination.self) { destination in
                TweetListDestinationView(
                    destination: destination,
                    navigationPath: $navigationPath,
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast
                )
            }
            .navigationDestination(for: CommentNavigation.self) { commentNav in
                CommentDetailView(comment: commentNav.comment, parentTweet: commentNav.parentTweet)
            }
            .navigationDestination(for: Tweet.self) { tweet in
                if tweet.originalTweetId != nil,
                   (tweet.content?.isEmpty ?? true),
                   (tweet.attachments?.isEmpty ?? true) {
                    CommentDetailViewWithParent(comment: tweet)
                } else {
                    TweetDetailView(tweet: tweet)
                }
            }
    }
}

extension View {
    func appNavigationDestinations(
        path navigationPath: Binding<NavigationPath>,
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil,
        onProfileLogout: (() -> Void)? = nil,
        onUserProfileAppear: (() -> Void)? = nil
    ) -> some View {
        modifier(AppNavigationDestinationsModifier(
            navigationPath: navigationPath,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast,
            onProfileLogout: onProfileLogout,
            onUserProfileAppear: onUserProfileAppear
        ))
    }
}
