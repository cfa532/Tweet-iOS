import SwiftUI

struct SearchScreen: View {
    @StateObject private var searchViewModel = SearchViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath = NavigationPath()
    @FocusState private var isSearchFieldFocused: Bool
    
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
                            .foregroundColor(.gray)
                        
                        TextField(LocalizedStringKey("Search by username or name..."), text: $searchViewModel.searchText)
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
                                enableVibration: false
                            ) {
                                searchViewModel.searchText = ""
                                // Don't clear results when clearing search text - keep them for better UX
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(20)
                    
                    DebounceButton(
                        
                        enableAnimation: true,
                        enableVibration: false
                    ) {
                        hideKeyboard()
                        Task {
                            await searchViewModel.search()
                        }
                    } label: {
                        Text(LocalizedStringKey("Search"))
                            .foregroundColor(.blue)
                    }
                    .disabled(searchViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                
                // Search Results
                if searchViewModel.isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Spacer()
                } else if searchViewModel.userResults.isEmpty && searchViewModel.tweetResults.isEmpty && !searchViewModel.searchText.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("No results found"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Try a different search term"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Close keyboard when tapping on empty state
                        hideKeyboard()
                    }
                } else if searchViewModel.searchText.isEmpty && searchViewModel.userResults.isEmpty && searchViewModel.tweetResults.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Search"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Search by username or tweet content"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Close keyboard when tapping on empty state
                        hideKeyboard()
                    }
                } else {
                    List {
                        // User results section
                        if !searchViewModel.userResults.isEmpty {
                            Section(header: Text(LocalizedStringKey("Accounts"))) {
                                ForEach(searchViewModel.userResults) { user in
                                    UserSearchResultRow(user: user)
                                }
                            }
                        }
                        
                        // Tweet results section
                        if !searchViewModel.tweetResults.isEmpty {
                            Section(header: Text(LocalizedStringKey("Tweets"))) {
                                ForEach(searchViewModel.tweetResults) { tweet in
                                    TweetSearchResultRow(tweet: tweet)
                                }
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle(LocalizedStringKey("Search"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: User.self) { user in
                ProfileView(user: user, onLogout: {
                    navigationPath.removeLast(navigationPath.count)
                }, navigationPath: $navigationPath)
                    .onAppear {
                        // Dismiss keyboard when navigating to profile
                        hideKeyboard()
                    }
            }
            .navigationDestination(for: Tweet.self) { tweet in
                TweetDetailView(tweet: tweet)
            }
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
                                .foregroundColor(.primary)
                        }
                        // Username is always present (validation ensures this)
                        Text("@\(user.username ?? "")")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let profile = user.profile, !profile.isEmpty {
                        Text(profile)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                                .foregroundColor(.primary)
                        }
                        if let username = tweet.author?.username, !username.isEmpty {
                            Text("@\(username)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                
                // Tweet content preview
                if let content = tweet.content, !content.isEmpty {
                    Text(content)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                } else if let title = tweet.title, !title.isEmpty {
                    Text(title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()
    
    @Published var userResults: [User] = []
    @Published var tweetResults: [Tweet] = []
    @Published var searchText: String = ""
    @Published var isLoading = false
    
    private let hproseInstance = HproseInstance.shared
    private let cacheManager = TweetCacheManager.shared
    
    private init() {}
    
    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await clearResults()
            return
        }
        
        await MainActor.run {
            isLoading = true
            userResults = []
            tweetResults = []
        }
        
        // Check if query starts with @ (username-only search)
        let isUsernameOnly = query.hasPrefix("@")
        let userQuery = isUsernameOnly ? String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : query
        
        // Search users
        if !userQuery.isEmpty {
            // When @ is present, do both exact match and partial search
            var exactUser: User? = nil
            
            // Always try exact match when @ is present (get userId from username and fetch from backend)
            if isUsernameOnly {
                if let userId = try? await hproseInstance.getUserId(userQuery),
                   let user = try? await hproseInstance.fetchUser(userId) {
                    // CRITICAL: Validate user has a username before adding to results
                    if let username = user.username, !username.isEmpty {
                        exactUser = user
                    }
                }
            } else {
                // For non-@ queries, only try exact match if no spaces
                if !userQuery.contains(" ") {
                    if let userId = try? await hproseInstance.getUserId(userQuery),
                       let user = try? await hproseInstance.fetchUser(userId) {
                        if let username = user.username, !username.isEmpty {
                            exactUser = user
                        }
                    }
                }
            }
            
            // Always do partial search of known usernames/names
            // Capture exactUser as immutable to avoid Swift 6 concurrency error
            let capturedExactUser = exactUser
            await cacheManager.searchUsersIncremental(query: userQuery, limit: 25) { [weak self] users in
                // Update UI immediately with each batch of results
                guard let self = self else { return }
                await MainActor.run {
                    var finalResults = users
                    
                    // Merge exact match if found
                    if let exactUser = capturedExactUser {
                        // Add to results if not already there
                        if !finalResults.contains(where: { $0.mid == exactUser.mid }) {
                            finalResults.insert(exactUser, at: 0) // Put exact API match first
                        } else {
                            // Move exact match to the front if it exists
                            if let index = finalResults.firstIndex(where: { $0.mid == exactUser.mid }) {
                                let exactMatch = finalResults.remove(at: index)
                                finalResults.insert(exactMatch, at: 0)
                            }
                        }
                    }
                    
                    self.userResults = finalResults
                }
            }
        }
        
        // Only search tweets if query doesn't start with @ (matches Android logic)
        if !isUsernameOnly {
            let tweets = await cacheManager.searchTweets(query: query, limit: 40)
            await MainActor.run {
                self.tweetResults = tweets
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    func clearResults() async {
        await MainActor.run {
            userResults = []
            tweetResults = []
        }
    }
    
    // Computed property for backward compatibility
    var searchResults: [User] {
        userResults
    }
}
