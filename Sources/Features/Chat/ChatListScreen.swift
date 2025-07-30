import SwiftUI

struct ChatListScreen: View {
    @StateObject private var chatRepository = ChatRepository()
    @State private var chatSessions: [ChatSession] = []
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                if chatSessions.isEmpty {
                    VStack {
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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(chatSessions) { session in
                        ChatSessionRow(session: session)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Chats"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await loadChatSessions()
        }
    }
    
    private func loadChatSessions() async {
        await chatRepository.loadChatSessions()
        // TODO: Update chatSessions from repository
    }
}

struct ChatSessionRow: View {
    let session: ChatSession
    @State private var user: User?
    
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
            await loadUser()
        }
    }
    
    private func loadUser() async {
        // TODO: Load user information for the receiptId
        // This would typically call HproseInstance to get user details
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