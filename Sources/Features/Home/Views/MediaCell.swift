//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI

struct MediaCell: View {
    let attachment: MimeiFileType
    let baseUrl: String

    var body: some View {
        AsyncImage(url: attachment.getUrl(baseUrl)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.gray
        }
        .clipped()
    }
}
