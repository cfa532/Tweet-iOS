//
//  MediaGridView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI

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


