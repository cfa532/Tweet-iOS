//
//  Avatar.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI

struct Avatar: View {
    let user: User
    let size: Int = 40
    
    var body: some View {
        if let avatarUrl = user.avatarUrl {
            AsyncImage(url: URL(string: avatarUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray
            }
            .frame(width: CGFloat(size), height: CGFloat(size))
            .clipShape(Circle())
        } else {
            Image("ic_splash")
                .frame(width: CGFloat(size), height: CGFloat(size))
                .clipShape(Circle())
        }
    }
}
