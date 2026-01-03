import SwiftUI

struct ChatListScreen: View {
    @Binding var navigationPath: NavigationPath
    let onProfileNavigate: (() -> Void)?
    let onChatNavigate: (() -> Void)?
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messageCheckTimer: Timer?
    @State private var sessionToDelete: ChatSession?
    @State private var showDeleteConfirmation = false
    @State private var followingUsers: [User] = []
    @State private var isLoadingFollowings = false
    @State private var showStartNewChat = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    init(navigationPath: Binding<NavigationPath>, onProfileNavigate: (() -> Void)? = nil, onChatNavigate: (() -> Void)? = nil) {
        self._navigationPath = navigationPath
        self.onProfileNavigate = onProfileNavigate
        self.onChatNavigate = onChatNavigate
    }
    
    // Computed property for filtered and sorted sessions
    private var currentUserSessions: [ChatSession] {
        chatSessionManager.chatSessions
            .filter { $0.userId == HproseInstance.shared.appUser.mid }
            .filter { 
                // Filter out sessions with nil or empty message content
                guard let content = $0.lastMessage.content else { return false }
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted(by: { $0.timestamp > $1.timestamp })
    }
    
    var body: some View {
        VStack {
                if currentUserSessions.isEmpty {
                    // Show followings list when no chats exist or all messages are empty
                    FollowingsListForChat(followingUsers: followingUsers, isLoadingFollowings: isLoadingFollowings)
                } else {
                    List {
                        ForEach(currentUserSessions) { session in
                            ChatSessionRow(session: session)
                        }
                        .onDelete(perform: deleteChatSession)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Chats"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showStartNewChat = true
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
            .navigationDestination(for: String.self) { receiptId in
                ChatScreen(
                    receiptId: receiptId,
                    navigationPath: $navigationPath,
                    onProfileNavigate: {
                        onProfileNavigate?()
                    }
                )
                .onAppear {
                    // When ChatScreen appears, reset profile flag
                    onChatNavigate?()
                }
            }
            .navigationDestination(for: User.self) { user in
                ProfileView(user: user, onLogout: nil, navigationPath: $navigationPath)
            }
            .sheet(isPresented: $showStartNewChat) {
                NavigationStack {
                    FollowingsListForChat(followingUsers: followingUsers, isLoadingFollowings: isLoadingFollowings)
                        .navigationTitle(LocalizedStringKey("Start Chat"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button(LocalizedStringKey("Done")) {
                                    showStartNewChat = false
                                }
                            }
                        }
                }
                .onAppear {
                    // Refresh followings when opening the sheet
                    if followingUsers.isEmpty {
                        Task {
                            await loadFollowings()
                        }
                    }
                }
            }
            .task {
                // Only load chat sessions if they're empty
                if chatSessionManager.chatSessions.isEmpty {
                    await loadChatSessions()
                    // Also load followings when no chats exist
                    await loadFollowings()
                }
            }
            .onChange(of: currentUserSessions.isEmpty) { oldValue, newValue in
                // When sessions become empty, load followings to show the empty state
                if newValue && followingUsers.isEmpty {
                    Task {
                        await loadFollowings()
                    }
                }
            }
            .onAppear {
                // Always check for new messages when view appears, but don't reload existing sessions
                Task {
                    await chatSessionManager.checkBackendForNewMessages()
                }
                
                // Start periodic checking for new messages
                startPeriodicMessageCheck()
                
                // Clear badge count when chat list is opened
                DispatchQueue.main.async {
                    UNUserNotificationCenter.current().setBadgeCount(0) { error in
                        if let error = error {
                            print("[ChatListScreen] Error clearing badge count: \(error)")
                        }
                    }
                }
            }
            .onDisappear {
                // Stop periodic checking when view disappears
                stopPeriodicMessageCheck()
            }
            .alert(NSLocalizedString("Delete Chat", comment: "Delete chat alert title"), isPresented: $showDeleteConfirmation) {
                Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {
                    sessionToDelete = nil
                }
                Button(NSLocalizedString("Delete", comment: "Delete button"), role: .destructive) {
                    confirmDeleteChatSession()
                }
            } message: {
                if let session = sessionToDelete {
                    Text(String(format: NSLocalizedString("Are you sure you want to delete the chat with %@? This will permanently delete all messages in this conversation.", comment: "Delete chat confirmation"), session.receiptId))
                }
            }
    }
    
    private func loadChatSessions() async {
        await chatRepository.loadChatSessions()
    }
    
    // MARK: - Periodic Message Checking
    
    private func startPeriodicMessageCheck() {
        // Check for new messages every 60 seconds
        messageCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            Task {
                await chatSessionManager.checkBackendForNewMessages()
            }
        }
        
        // Also check immediately when starting
        Task {
            await chatSessionManager.checkBackendForNewMessages()
        }
    }
    
    private func stopPeriodicMessageCheck() {
        messageCheckTimer?.invalidate()
        messageCheckTimer = nil
    }
    
    // MARK: - Chat Session Management
    
    private func deleteChatSession(offsets: IndexSet) {
        // Get the filtered sessions array
        let sessions = currentUserSessions
        
        for index in offsets {
            // Use the index from the filtered array, not the full array
            let session = sessions[index]
            sessionToDelete = session
            showDeleteConfirmation = true
        }
    }
    
    private func confirmDeleteChatSession() {
        guard let session = sessionToDelete else { return }
        
        // Delete from Core Data (this will cascade delete all messages)
        chatSessionManager.removeChatSession(receiptId: session.receiptId)
        
        sessionToDelete = nil
        showDeleteConfirmation = false
    }
    
    // MARK: - Followings Loading
    
    private func loadFollowings() async {
        // Don't reload if we already have followings cached
        guard followingUsers.isEmpty else {
            print("[ChatListScreen] Followings already loaded, skipping reload")
            return
        }
        
        isLoadingFollowings = true
        
        // Try to get following IDs from cached appUser first (instant, no network call)
        var followingIds = hproseInstance.appUser.followingList ?? []
        
        // If cache is empty, fetch from server
        if followingIds.isEmpty {
            do {
                followingIds = try await hproseInstance.getListByType(
                    user: hproseInstance.appUser,
                    entry: .FOLLOWING
                )
                print("[ChatListScreen] Fetched \(followingIds.count) following IDs from server")
            } catch {
                print("[ChatListScreen] Error fetching followings from server: \(error)")
                await MainActor.run {
                    isLoadingFollowings = false
                }
                return
            }
        } else {
            print("[ChatListScreen] Using \(followingIds.count) cached following IDs")
        }
        
        guard !followingIds.isEmpty else {
            await MainActor.run {
                isLoadingFollowings = false
            }
            return
        }
        
        // Use singleton pattern - get users instantly from cache
        // Include ALL users, even without username (they'll be fetched)
        var users: [User] = []
        for userId in followingIds {
            let user = User.getInstance(mid: userId)
            users.append(user)
        }
        
        await MainActor.run {
            self.followingUsers = users
            self.isLoadingFollowings = false
        }
        
        // Refresh user data in background for all users to ensure data is fresh
        let instance = hproseInstance
        Task.detached(priority: .background) {
            for userId in followingIds {
                _ = try? await instance.fetchUser(userId)
            }
        }
    }
}

// MARK: - Followings List for Chat

struct FollowingsListForChat: View {
    let followingUsers: [User]
    let isLoadingFollowings: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            if isLoadingFollowings {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if followingUsers.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "person.2")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text(NSLocalizedString("No followings found", comment: "Empty followings list message"))
                        .font(.headline)
                        .foregroundColor(.gray)
                    Text(NSLocalizedString("Follow some users to start chatting", comment: "Empty followings instruction"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(followingUsers) { user in
                    FollowingRowForChat(user: user)
                }
            }
        }
        .navigationDestination(for: String.self) { receiptId in
            ChatScreen(receiptId: receiptId)
                .onAppear {
                    // Dismiss the sheet when navigating to chat
                    dismiss()
                }
        }
    }
}

// Separate row view for better performance
struct FollowingRowForChat: View {
    let user: User
    
    var body: some View {
        // Only show the row if user data is already loaded (has username)
        if let username = user.username {
            NavigationLink(value: user.mid) {
                HStack {
                    Avatar(user: user, size: 40)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(user.name ?? "")@\(username)")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        
                        if let profile = user.profile, !profile.isEmpty {
                            Text(profile)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    
                    Image(systemName: "message")
                        .foregroundColor(.blue)
                        .font(.system(size: 16, weight: .medium))
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct ChatSessionRow: View {
    let session: ChatSession
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    
    // Initialize with cached singleton immediately (synchronous, instant)
    @State private var user: User
    @State private var isLoading = false
    
    init(session: ChatSession) {
        self.session = session
        // Get cached user singleton synchronously - this is instant and doesn't block
        _user = State(initialValue: User.getInstance(mid: session.receiptId))
    }
    
    var body: some View {
        NavigationLink(value: session.receiptId) {
            HStack(alignment: .top, spacing: 12) {
                // User Avatar - always show immediately from cached singleton
                Avatar(user: user, size: 44)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        // Name and Handle on one line
                        if let username = user.username {
                            HStack(spacing: 0) {
                                Text(user.name ?? "")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("@\(username)")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                            .lineLimit(1)
                            .truncationMode(.tail)
                        } else {
                            HStack(spacing: 4) {
                                Text(NSLocalizedString("Loading...", comment: "Loading message"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        // Date
                        Text(formatDate(session.timestamp))
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    
                    // Message preview
                    Text(getMessagePreview())
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                
                if session.hasNews {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            // If user data is missing, fetch it in background and update the view
            if user.username == nil || user.baseUrl == nil {
                isLoading = true
                Task(priority: .userInitiated) {
                    // Fetch user data
                    if let freshUser = try? await hproseInstance.fetchUser(session.receiptId) {
                        await MainActor.run {
                            self.user = freshUser
                            self.isLoading = false
                        }
                    } else {
                        await MainActor.run {
                            self.isLoading = false
                        }
                    }
                }
            }
        }
    }
    
    private func getMessagePreview() -> String {
        let message = session.lastMessage
        if let preview = message.previewText(for: hproseInstance.appUser.mid) {
            return preview
        }
        let isFromCurrentUser = message.authorId == hproseInstance.appUser.mid
        return isFromCurrentUser ? NSLocalizedString("Message sent", comment: "Sent fallback") : NSLocalizedString("Message received", comment: "Received fallback")
    }
    
    private func formatDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDate(date, equalTo: calendar.date(byAdding: .day, value: -1, to: now) ?? now, toGranularity: .day) {
            return NSLocalizedString("Yesterday", comment: "Yesterday label")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

 
