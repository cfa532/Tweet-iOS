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
                            Button(action: {
                                searchText = ""
                                Task {
                                    await searchViewModel.clearResults()
                                }
                            }) {
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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
    }
}

struct UserSearchResultRow: View {
    let user: User
    
    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.mid)) {
            HStack {
                UserAvatarView(user: user, size: 40)
                
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
        
        // TODO: Implement search functionality through HproseInstance
        // This would typically call the backend service to search for users
        
        // For now, we'll simulate a search
        await MainActor.run {
            isLoading = false
            // TODO: Update searchResults with actual results from backend
        }
    }
    
    func clearResults() async {
        await MainActor.run {
            searchResults = []
        }
    }
}

// Placeholder for UserProfileView - this should be implemented based on your existing profile view
struct UserProfileView: View {
    let userId: String
    
    var body: some View {
        Text("User Profile for \(userId)")
            .navigationTitle("Profile")
    }
} 