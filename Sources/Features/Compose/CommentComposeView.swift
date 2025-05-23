import SwiftUI

struct CommentComposeView: View {
    @Binding var tweet: Tweet
    @Environment(\.dismiss) private var dismiss
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var error: Error?
    @State private var isQuoting = false
    
    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Quote toggle
                Toggle(isOn: $isQuoting) {
                    Text("Quote Tweet")
                        .font(.subheadline)
                }
                .padding()
                .background(Color(.systemBackground))
                
                // Original tweet preview when quoting
                if isQuoting {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(tweet.author?.name ?? "Unknown")
                                .font(.headline)
                            Text("@\(tweet.author?.username ?? "")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        if let content = tweet.content {
                            Text(content)
                                .font(.body)
                        }
                        
                        if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                            MediaGridView(attachments: attachments, baseUrl: baseUrl)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
                
                TextEditor(text: $commentText)
                    .frame(maxHeight: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                
                // Character count
                HStack {
                    Spacer()
                    Text("\(max(0, Constants.MAX_TWEET_SIZE - commentText.count))")
                        .foregroundColor(commentText.count > Constants.MAX_TWEET_SIZE ? .red : .gray)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(.systemGray4)),
                    alignment: .top
                )
            }
            .navigationTitle(isQuoting ? "Quote Tweet" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isQuoting ? "Quote" : "Reply") {
                        Task {
                            await submitComment()
                        }
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
    }
    
    private func submitComment() async {
        isSubmitting = true
        do {
            let comment = Tweet(
                mid: "",
                authorId: hproseInstance.appUser.mid,
                content: commentText.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: Date(),
                originalTweetId: isQuoting ? tweet.mid : nil,
                originalAuthorId: isQuoting ? tweet.authorId : nil,
                author: hproseInstance.appUser
            )
            
            if let updatedTweet = try await hproseInstance.submitComment(comment, to: tweet) {
                tweet = updatedTweet
                dismiss()
            }
        } catch {
            self.error = error
        }
        isSubmitting = false
    }
} 
