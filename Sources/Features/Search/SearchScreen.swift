import SwiftUI

struct SearchScreen: View {
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    @StateObject private var searchViewModel = SearchViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath = NavigationPath()
    @FocusState private var isSearchFieldFocused: Bool

    init(onShowLogin: (() -> Void)? = nil, onShowToast: ((String, Bool) -> Void)? = nil) {
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
    }
    
    private var isShowingResultsList: Bool {
        !(searchViewModel.userResults.isEmpty && searchViewModel.tweetResults.isEmpty)
    }

    private func hideKeyboard() {
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(XTheme.secondaryTextColor)
                        
                        TextField("", text: $searchViewModel.searchText)
                            .accessibilityLabel(Text(LocalizedStringKey("Search")))
                            .textFieldStyle(PlainTextFieldStyle())
                            .focused($isSearchFieldFocused)
                            .onSubmit {
                                Task {
                                    await searchViewModel.search()
                                }
                                isSearchFieldFocused = false
                            }
                        
                        if !searchViewModel.searchText.isEmpty {
                            DebounceButton(
                                cooldownDuration: 0.3,
                                enableAnimation: true,
                                enableHaptic: false
                            ) {
                                searchViewModel.searchText = ""
                                // Don't clear results when clearing search text - keep them for better UX
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(XTheme.secondaryTextColor)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(XTheme.secondaryBackgroundColor)
                    .cornerRadius(20)
                    
                    DebounceButton(
                        
                        enableAnimation: true,
                        enableHaptic: false
                    ) {
                        hideKeyboard()
                        Task {
                            await searchViewModel.search()
                        }
                    } label: {
                        Text(LocalizedStringKey("Search"))
                            .foregroundColor(XTheme.accentColor)
                    }
                    .disabled(searchViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                
                // Search Results. Any tap in this area (outside the search bar) closes the
                // keyboard; simultaneous so row navigation and "Load more" still fire.
                VStack(spacing: 0) {
                    if searchViewModel.isLoading && !isShowingResultsList {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(2.0)
                            Text(String(format: NSLocalizedString("%ds", comment: "Search countdown in seconds"), searchViewModel.countdownSeconds))
                                .font(.subheadline)
                                .foregroundColor(XTheme.secondaryTextColor)
                                .monospacedDigit()
                        }
                        Spacer()
                    } else if searchViewModel.userResults.isEmpty && searchViewModel.tweetResults.isEmpty && !searchViewModel.searchText.isEmpty {
                        VStack {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(XTheme.secondaryTextColor)
                            Text(LocalizedStringKey("No results found"))
                                .font(.headline)
                                .foregroundColor(XTheme.secondaryTextColor)
                            Text(LocalizedStringKey("Try a different search term"))
                                .font(.caption)
                                .foregroundColor(XTheme.secondaryTextColor)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchViewModel.searchText.isEmpty && searchViewModel.userResults.isEmpty && searchViewModel.tweetResults.isEmpty {
                        VStack {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(XTheme.secondaryTextColor)
                            Text(LocalizedStringKey("Search"))
                                .font(.headline)
                                .foregroundColor(XTheme.secondaryTextColor)
                            Text(LocalizedStringKey("Search by @username or tweet content"))
                                .font(.caption)
                                .foregroundColor(XTheme.secondaryTextColor)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            // User results section
                            if !searchViewModel.userResults.isEmpty {
                                Section(header: Text(LocalizedStringKey("Accounts"))) {
                                    ForEach(searchViewModel.visibleUserResults) { user in
                                        UserSearchResultRow(user: user)
                                    }

                                    if searchViewModel.hasMoreUserResults {
                                        Button {
                                            searchViewModel.loadNextUserPage()
                                        } label: {
                                            Text(LocalizedStringKey("Load more"))
                                                .frame(maxWidth: .infinity)
                                                .foregroundColor(XTheme.accentColor)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            
                            // Tweet results section
                            if !searchViewModel.tweetResults.isEmpty {
                                Section(header: Text(LocalizedStringKey("Tweets"))) {
                                    ForEach(searchViewModel.visibleTweetResults) { tweet in
                                        TweetSearchResultRow(tweet: tweet)
                                    }

                                    if searchViewModel.hasMoreTweetResults {
                                        Button {
                                            searchViewModel.loadNextTweetPage()
                                        } label: {
                                            Text(LocalizedStringKey("Load more"))
                                                .frame(maxWidth: .infinity)
                                                .foregroundColor(XTheme.accentColor)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }

                            if searchViewModel.isLoading {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text(String(format: NSLocalizedString("%ds", comment: "Search countdown in seconds"), searchViewModel.countdownSeconds))
                                        .font(.subheadline)
                                        .foregroundColor(XTheme.secondaryTextColor)
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .scrollDismissesKeyboard(.immediately)
                        .scrollContentBackground(.hidden)
                        .background(XTheme.backgroundColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // A tap recognizer above a List swallows row taps (NavigationLink rows stop
                // responding), so only enable it for the non-list states. The list closes the
                // keyboard on drag, and on row navigation via the path change below.
                .simultaneousGesture(
                    TapGesture().onEnded { hideKeyboard() },
                    including: isShowingResultsList ? .subviews : .all
                )
            }
            .onChange(of: navigationPath.count) { _, _ in
                hideKeyboard()
            }
            .background(XTheme.backgroundColor)
            .navigationTitle(LocalizedStringKey("Search"))
            .navigationBarTitleDisplayMode(.inline)
            .appNavigationDestinations(
                path: $navigationPath,
                onShowLogin: onShowLogin,
                onShowToast: onShowToast,
                onProfileLogout: {
                    navigationPath.removeLast(navigationPath.count)
                },
                onUserProfileAppear: {
                    hideKeyboard()
                }
            )
        }
    }
}

struct UserSearchResultRow: View {
    let user: User
    
    var body: some View {
        NavigationLink(value: user) {
            HStack {
                Avatar(user: user, size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Display name and username
                    // Username is guaranteed to exist (filtered in search)
                    HStack(spacing: 4) {
                        if let name = user.name, !name.isEmpty {
                            Text(name)
                                .font(.headline)
                                .foregroundColor(XTheme.textColor)
                        }
                        // Username is always present (validation ensures this)
                        Text("@\(user.username ?? "")")
                            .font(.headline)
                            .foregroundColor(XTheme.secondaryTextColor)
                    }
                    
                    if let profile = user.profile, !profile.isEmpty {
                        Text(profile)
                            .font(.caption)
                            .foregroundColor(XTheme.secondaryTextColor)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct TweetSearchResultRow: View {
    let tweet: Tweet
    
    var body: some View {
        NavigationLink(value: tweet) {
            VStack(alignment: .leading, spacing: 8) {
                // Author info
                HStack {
                    Avatar(user: tweet.author ?? User.getInstance(mid: tweet.authorId), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = tweet.author?.name, !name.isEmpty {
                            Text(name)
                                .font(.headline)
                                .foregroundColor(XTheme.textColor)
                        }
                        if let username = tweet.author?.username, !username.isEmpty {
                            Text("@\(username)")
                                .font(.subheadline)
                                .foregroundColor(XTheme.secondaryTextColor)
                        }
                    }
                    Spacer()
                }
                
                // Tweet content preview
                if let content = tweet.content, !content.isEmpty {
                    Text(content)
                        .font(.body)
                        .foregroundColor(XTheme.textColor)
                        .lineLimit(3)
                } else if let title = tweet.title, !title.isEmpty {
                    Text(title)
                        .font(.body)
                        .foregroundColor(XTheme.textColor)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()

    @Published var userResults: [User] = []
    @Published var tweetResults: [Tweet] = []
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var countdownSeconds: Int = 30
    @Published private(set) var userPage = 1
    @Published private(set) var tweetPage = 1

    private let hproseInstance = HproseInstance.shared
    private let cacheManager = TweetCacheManager.shared
    private var countdownTask: Task<Void, Never>?
    private var activeSearchTask: Task<Void, Never>?

    private static let searchTimeoutSeconds = 30
    private static let userPageSize = 25
    private static let tweetPageSize = 20

    private init() {}

    var visibleUserResults: [User] {
        Array(userResults.prefix(userPage * Self.userPageSize))
    }

    var visibleTweetResults: [Tweet] {
        Array(tweetResults.prefix(tweetPage * Self.tweetPageSize))
    }

    var hasMoreUserResults: Bool {
        visibleUserResults.count < userResults.count
    }

    var hasMoreTweetResults: Bool {
        visibleTweetResults.count < tweetResults.count
    }

    func loadNextUserPage() {
        guard hasMoreUserResults else { return }
        userPage += 1
    }

    func loadNextTweetPage() {
        guard hasMoreTweetResults else { return }
        tweetPage += 1
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await clearResults()
            return
        }

        isLoading = true
        countdownSeconds = Self.searchTimeoutSeconds
        userResults = []
        tweetResults = []
        userPage = 1
        tweetPage = 1

        let isUsernameOnly = query.hasPrefix("@")
        let userQuery = isUsernameOnly ? String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : query

        // Cancel any previous in-flight search
        activeSearchTask?.cancel()

        // Launch search as an unstructured Task so its lifetime is NOT tied to the
        // calling Task's cancellation — only the countdown (or a new search) can stop it.
        let searchTask = Task {
            await self.runSearchQueries(query: query, isUsernameOnly: isUsernameOnly, userQuery: userQuery)
        }
        activeSearchTask = searchTask

        // Countdown: tick every second; cancel the search task when it reaches zero
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for remaining in stride(from: Self.searchTimeoutSeconds - 1, through: 0, by: -1) {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                countdownSeconds = remaining
            }
            searchTask.cancel()  // 30 s elapsed — give up
        }

        // Wait for the search to finish (naturally or via the 30 s cancel above)
        await searchTask.value

        // A replaced search must not stop the new search's countdown or loading state.
        guard activeSearchTask == searchTask else { return }
        countdownTask?.cancel()
        activeSearchTask = nil
        isLoading = false
    }

    private func runSearchQueries(query: String, isUsernameOnly: Bool, userQuery: String) async {
        await withTaskGroup(of: Void.self) { group in
            if !userQuery.isEmpty {
                group.addTask {
                    await self.searchUsers(query: userQuery, isUsernameOnly: isUsernameOnly)
                }
            }

            // Account discovery must not delay cached tweet and comment results.
            if !isUsernameOnly {
                group.addTask {
                    await self.searchTweets(query: query)
                }
            }
        }
    }

    private func searchUsers(query: String, isUsernameOnly: Bool) async {
        // Publish local matches before starting the slower exact-name lookup.
        await cacheManager.searchUsersIncremental(query: query) { [weak self] users in
            guard !Task.isCancelled, let self else { return }
            self.userResults = users
        }

        // Preserve @-only lookup and exact-match priority without blocking cached results.
        guard !Task.isCancelled,
              isUsernameOnly || !query.contains(" "),
              let userId = try? await hproseInstance.getUserId(query),
              !Task.isCancelled,
              let user = try? await hproseInstance.fetchUser(userId),
              !Task.isCancelled,
              let username = user.username, !username.isEmpty else { return }
        userResults.removeAll { $0.mid == user.mid }
        userResults.insert(user, at: 0)
    }

    private func searchTweets(query: String) async {
        await cacheManager.searchTweetsIncremental(query: query) { [weak self] tweets in
            guard !Task.isCancelled, let self else { return }
            self.tweetResults = tweets
        }
    }
    
    func clearResults() async {
        await MainActor.run {
            userResults = []
            tweetResults = []
            userPage = 1
            tweetPage = 1
        }
    }
    
    // Computed property for backward compatibility
    var searchResults: [User] {
        userResults
    }
}
