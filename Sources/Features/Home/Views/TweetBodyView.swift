import SwiftUI

struct TweetBodyView: View {
    let tweet: Tweet
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let content = tweet.content, !content.isEmpty {
                Text(content)
                    .font(.body)
            }
            
            if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                let appUser = HproseInstance.shared.appUser
                MediaGridView(attachments: attachments, baseUrl: appUser.baseUrl ?? "")
            }
        }
        TweetActionButtonsView(tweet: tweet)
    }
}

struct MediaGridView: View {
    let attachments: [MimeiFileType]
    let baseUrl: String
    
    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible())
        ]
        
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments, id: \.self) { attachment in // Use the correct ForEach initializer
                AsyncImage(url: attachment.getUrl(baseUrl)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(height: 200)
                .clipped()
            }
        }
    }
}

