import SwiftUI

struct ChatListScreen: View {
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messageCheckTimer: Timer?
    @State private var showStartChat = false
    @State private var sessionToDelete: ChatSession?
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        VStack {
                let currentUserSessions = chatSessionManager.chatSessions.filter { $0.userId == HproseInstance.shared.appUser.mid }
                if currentUserSessions.isEmpty {
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
                        ForEach(chatSessionManager.chatSessions
                            .filter { $0.userId == HproseInstance.shared.appUser.mid }
                            .sorted(by: { $0.timestamp > $1.timestamp })) { session in
                            ChatSessionRow(session: session)
                        }
                        .onDelete(perform: deleteChatSession)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Chats"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { receiptId in
                ChatScreen(receiptId: receiptId)
            }
            .task {
            await loadChatSessions()
        }
        .onAppear {
            // Force reload sessions from Core Data when view appears
            chatSessionManager.reloadChatSessionsFromCoreData()
            
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
        .alert("Delete Chat", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                confirmDeleteChatSession()
            }
        } message: {
            if let session = sessionToDelete {
                Text("Are you sure you want to delete the chat with \(session.receiptId)? This will permanently delete all messages in this conversation.")
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
        for index in offsets {
            let session = chatSessionManager.chatSessions[index]
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
}

struct ChatSessionRow: View {
    let session: ChatSession
    @State private var user: User?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    
    var body: some View {
        NavigationLink(value: session.receiptId) {
            HStack(alignment: .top, spacing: 12) {
                // User Avatar
                if let user = user {
                    Avatar(user: user, size: 44)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "person")
                                .foregroundColor(.gray)
                        )
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        // Name and Handle on one line
                        if let user = user {
                            HStack(spacing: 0) {
                                Text(user.name ?? "")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("@\(user.username ?? "")")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                            .lineLimit(1)
                            .truncationMode(.tail)
                        } else {
                            Text("Loading...")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        // Date
                        Text(formatDate(session.timestamp))
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    
                    // Message preview
                    Text(getMessagePreview())
                        .font(.system(size: 15, weight: .regular))
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
        .task {
            user = try? await hproseInstance.fetchUser(session.receiptId)
        }
    }
    
    private func getMessagePreview() -> String {
        let message = session.lastMessage
        let isFromCurrentUser = message.authorId == hproseInstance.appUser.mid
        
        // If there's text content, show it
        if let content = message.content, !content.isEmpty {
            return content
        }
        
        // If there are attachments, show appropriate message based on direction
        if let attachments = message.attachments, !attachments.isEmpty {
            return isFromCurrentUser ? "📎 Attachment sent" : "📎 Attachment received"
        }
        
        // Fallback
        return isFromCurrentUser ? "Message sent" : "Message received"
    }
    
    private func formatDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDate(date, equalTo: calendar.date(byAdding: .day, value: -1, to: now) ?? now, toGranularity: .day) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }
}

 
