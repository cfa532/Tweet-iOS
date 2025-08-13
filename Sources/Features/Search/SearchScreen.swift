import SwiftUI

struct SearchScreen: View {
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        
                        TextField(LocalizedStringKey("Search users..."), text: $searchText)
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
                                Task {
                                    await searchViewModel.clearResults()
                                }
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
                    
                    Button(action: {
                        Task {
                            await searchViewModel.search(query: searchText)
                        }
                    }) {
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
                        Text(LocalizedStringKey("Try searching for a different username"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchText.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Search for users"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Enter a username to find users"))
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
        }
    }
}

struct UserSearchResultRow: View {
    let user: User
    
    var body: some View {
        NavigationLink(destination: ProfileView(user: user, onLogout: nil)) {
            HStack {
                Avatar(user: user, size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(user.name ?? "")@\(user.username ?? "")")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
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
    
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await clearResults()
            return
        }
        
        await MainActor.run {
            isLoading = true
        }
        
        do {
            // If query starts with @, search for a user by username
            if query.hasPrefix("@") {
                let username = String(query.dropFirst())
                if let userId = try await hproseInstance.getUserId(username),
                   let user = try await hproseInstance.fetchUser(userId) {
                    await MainActor.run {
                        searchResults = [user]
                    }
                } else {
                    await MainActor.run {
                        searchResults = []
                    }
                }
            } else {
                // TODO: Implement tweet content search
                // For now, clear results for non-@ searches
                await MainActor.run {
                    searchResults = []
                }
            }
        } catch {
            print("Search error: \(error)")
            await MainActor.run {
                searchResults = []
            }
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
