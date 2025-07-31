import SwiftUI

struct ChatListScreen: View {
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messageCheckTimer: Timer?
    @State private var showStartChat = false
    @State private var selectedSession: ChatSession? = nil
    @State private var showChatScreen = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack {
                if chatSessionManager.chatSessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "message")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("No chats yet"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Start a conversation to see your chats here"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button(action: {
                            showStartChat = true
                        }) {
                            HStack {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .medium))
                                Text(LocalizedStringKey("Start Chat"))
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(chatSessionManager.chatSessions) { session in
                            ChatSessionRow(session: session)
                        }
                        .onDelete(perform: deleteChatSession)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Chats"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await loadChatSessions()
        }
        .onAppear {
            // Start periodic checking for new messages
            startPeriodicMessageCheck()
        }
        .onDisappear {
            // Stop periodic checking when view disappears
            stopPeriodicMessageCheck()
        }
        .sheet(isPresented: $showStartChat) {
            StartChatView()
        }
    }
    
    private func loadChatSessions() async {
        await chatRepository.loadChatSessions()
    }
    
    // MARK: - Periodic Message Checking
    
    private func startPeriodicMessageCheck() {
        // Check for new messages every 30 seconds
        messageCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
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
        for index in offsets {
            let session = chatSessionManager.chatSessions[index]
            chatSessionManager.removeChatSession(receiptId: session.receiptId)
        }
    }
}

struct ChatSessionRow: View {
    let session: ChatSession
    @State private var user: User?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    
    var body: some View {
        NavigationLink(destination: ChatScreen(receiptId: session.receiptId)) {
            HStack {
                // User Avatar
                if let user = user {
                    UserAvatarView(user: user, size: 40)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "person")
                                .foregroundColor(.gray)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let user = user {
                            Text("\(user.name ?? "")@\(user.username ?? "")")
                                .font(.headline)
                                .foregroundColor(.primary)
                        } else {
                            Text("Loading...")
                                .font(.headline)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        Text(formatDate(session.timestamp))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    Text(session.lastMessage.content)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                if session.hasNews {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.vertical, 4)
        }
        .task {
            user = try? await hproseInstance.fetchUser(session.receiptId)
        }
    }
    
    private func formatDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct UserAvatarView: View {
    let user: User
    let size: CGFloat
    
    var body: some View {
        if let avatarUrl = user.avatarUrl, !avatarUrl.isEmpty {
            AsyncImage(url: URL(string: avatarUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Text(String((user.name ?? "").prefix(1)))
                            .font(.headline)
                            .foregroundColor(.gray)
                    )
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Text(String((user.name ?? "").prefix(1)))
                        .font(.headline)
                        .foregroundColor(.gray)
                )
        }
    }
} 
