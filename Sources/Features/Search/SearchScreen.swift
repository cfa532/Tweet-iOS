import SwiftUI

struct SearchScreen: View {
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        
                        TextField(LocalizedStringKey("Search by username or name..."), text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .onSubmit {
                                Task {
                                    await searchViewModel.search(query: searchText)
                                }
                            }
                        
                        if !searchText.isEmpty {
                            DebounceButton(
                                cooldownDuration: 0.3,
                                enableAnimation: true,
                                enableVibration: false
                            ) {
                                searchText = ""
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
                        cooldownDuration: 0.5,
                        enableAnimation: true,
                        enableVibration: false
                    ) {
                        Task {
                            await searchViewModel.search(query: searchText)
                        }
                    } label: {
                        Text(LocalizedStringKey("Search"))
                            .foregroundColor(.blue)
                    }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                
                // Search Results
                if searchViewModel.isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Spacer()
                } else if searchViewModel.searchResults.isEmpty && !searchText.isEmpty {
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
                } else if searchText.isEmpty && searchViewModel.searchResults.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Search for users"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Search by username or display name"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(searchViewModel.searchResults) { user in
                        UserSearchResultRow(user: user)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Search"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: User.self) { user in
                ProfileView(user: user, onLogout: {
                    navigationPath.removeLast(navigationPath.count)
                }, navigationPath: $navigationPath)
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
                    // Display name and username, handling nil values gracefully
                    HStack(spacing: 4) {
                        if let name = user.name, !name.isEmpty {
                            Text(name)
                                .font(.headline)
                                .foregroundColor(.primary)
                        }
                        if let username = user.username, !username.isEmpty {
                            Text("@\(username)")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        } else if user.name == nil || user.name?.isEmpty == true {
                            // Show placeholder if both name and username are empty
                            Text("Unknown User")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
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
        }
    }
}

class SearchViewModel: ObservableObject {
    @Published var searchResults: [User] = []
    @Published var isLoading = false
    
    private let hproseInstance = HproseInstance.shared
    private let cacheManager = TweetCacheManager.shared
    
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await clearResults()
            return
        }
        
        await MainActor.run {
            isLoading = true
        }
        
        // Remove @ prefix if present for consistent searching
        let cleanQuery = query.hasPrefix("@") ? String(query.dropFirst()) : query
        
        do {
            // Step 1: Search cached users for partial matches (fast, works offline)
            let cachedResults = await cacheManager.searchUsers(query: cleanQuery)
            
            // Step 2: Try exact username match from API (if no cached results or query looks like a username)
            // Only do API call if query doesn't contain spaces (usernames can't have spaces)
            var finalResults = cachedResults
            if !cleanQuery.contains(" ") {
                if let userId = try? await hproseInstance.getUserId(cleanQuery),
                   let user = try? await hproseInstance.fetchUser(userId) {
                    // Add to results if not already there
                    if !finalResults.contains(where: { $0.mid == user.mid }) {
                        finalResults.insert(user, at: 0) // Put exact match first
                    } else {
                        // Move exact match to the front
                        if let index = finalResults.firstIndex(where: { $0.mid == user.mid }) {
                            let exactMatch = finalResults.remove(at: index)
                            finalResults.insert(exactMatch, at: 0)
                        }
                    }
                }
            }
            
            // Step 3: Sort results: exact username matches first, then by name
            let queryLower = cleanQuery.lowercased()
            let sortedResults = finalResults.sorted { user1, user2 in
                let username1 = user1.username?.lowercased() ?? ""
                let username2 = user2.username?.lowercased() ?? ""
                
                // Exact username match comes first
                if username1 == queryLower && username2 != queryLower {
                    return true
                }
                if username2 == queryLower && username1 != queryLower {
                    return false
                }
                
                // Username starts with query comes next
                if username1.hasPrefix(queryLower) && !username2.hasPrefix(queryLower) {
                    return true
                }
                if username2.hasPrefix(queryLower) && !username1.hasPrefix(queryLower) {
                    return false
                }
                
                // Otherwise sort alphabetically by username
                return username1 < username2
            }
            
            // Step 4: Update results on MainActor
            await MainActor.run {
                searchResults = sortedResults
            }
        } catch {
            print("Search error: \(error)")
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    func clearResults() async {
        await MainActor.run {
            searchResults = []
        }
    }
}
