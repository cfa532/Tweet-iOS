import SwiftUI

struct ChatListScreen: View {
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messageCheckTimer: Timer?
    @State private var showStartChat = false
    
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
                    Text(session.lastMessage.content?.isEmpty != false ? "📎 Attachment" : (session.lastMessage.content ?? "📎 Attachment"))
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

 
