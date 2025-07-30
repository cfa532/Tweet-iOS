import SwiftUI

struct ChatScreen: View {
    let receiptId: String
    @StateObject private var chatRepository = ChatRepository()
    @State private var messages: [ChatMessage] = []
    @State private var messageText = ""
    @State private var user: User?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.blue)
                }
                
                if let user = user {
                    UserAvatarView(user: user, size: 32)
                    VStack(alignment: .leading) {
                        Text("\(user.name)@\(user.username)")
                            .font(.headline)
                        if let profile = user.profile {
                            Text(profile)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                } else {
                    Text("Loading...")
                        .font(.headline)
                }
                
                Spacer()
            }
            .padding()
            .background(Color(.systemBackground))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color(.separator)),
                alignment: .bottom
            )
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            ChatMessageView(message: message, isFromCurrentUser: message.authorId == HproseInstance.shared.appUser.mid)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Message Input
            HStack {
                TextField(LocalizedStringKey("Type a message..."), text: $messageText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(1...5)
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(.systemBackground))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color(.separator)),
                alignment: .top
            )
        }
        .task {
            await loadUser()
            await loadMessages()
        }
    }
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            content: messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        Task {
            await chatRepository.sendMessage(message)
            messageText = ""
            await loadMessages()
        }
    }
    
    private func loadUser() async {
        // TODO: Load user information for the receiptId
        // This would typically call HproseInstance to get user details
    }
    
    private func loadMessages() async {
        await chatRepository.loadMessages(for: receiptId)
        // TODO: Update messages from repository
    }
}

struct ChatMessageView: View {
    let message: ChatMessage
    let isFromCurrentUser: Bool
    
    var body: some View {
        HStack {
            if !isFromCurrentUser {
                // Avatar for received messages
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person")
                            .foregroundColor(.gray)
                    )
            }
            
            Spacer()
                .frame(width: isFromCurrentUser ? 0 : 8)
            
            VStack(alignment: isFromCurrentUser ? .trailing : .leading) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isFromCurrentUser ? Color.blue : Color(.systemGray5)
                    )
                    .foregroundColor(
                        isFromCurrentUser ? .white : .primary
                    )
                    .clipShape(ChatBubbleShape(isFromCurrentUser: isFromCurrentUser))
                
                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)
            }
            
            Spacer()
                .frame(width: isFromCurrentUser ? 8 : 0)
            
            if isFromCurrentUser {
                // Avatar for sent messages
                UserAvatarView(user: HproseInstance.shared.appUser, size: 32)
            }
        }
    }
    
    private func formatTime(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
} 