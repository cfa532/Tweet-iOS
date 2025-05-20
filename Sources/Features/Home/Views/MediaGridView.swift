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
        if attachments.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let gridWidth = geometry.size.width
                let gridHeight = gridWidth * 0.75 // 4:3 aspect ratio

                ZStack {
                    switch attachments.count {
                    case 1:
                        MediaCell(attachment: attachments[0], baseUrl: baseUrl)
                            .frame(width: gridWidth, height: gridHeight)
                    case 2:
                        HStack(spacing: 2) {
                            MediaCell(attachment: attachments[0], baseUrl: baseUrl)
                            MediaCell(attachment: attachments[1], baseUrl: baseUrl)
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 3:
                        HStack(spacing: 2) {
                            MediaCell(attachment: attachments[0], baseUrl: baseUrl)
                                .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            VStack(spacing: 2) {
                                MediaCell(attachment: attachments[1], baseUrl: baseUrl)
                                MediaCell(attachment: attachments[2], baseUrl: baseUrl)
                            }
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 4:
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                MediaCell(attachment: attachments[0], baseUrl: baseUrl)
                                MediaCell(attachment: attachments[1], baseUrl: baseUrl)
                            }
                            HStack(spacing: 2) {
                                MediaCell(attachment: attachments[2], baseUrl: baseUrl)
                                MediaCell(attachment: attachments[3], baseUrl: baseUrl)
                            }
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    default:
                        EmptyView()
                    }
                }
                .frame(width: gridWidth, height: gridHeight)
                .clipped()
                .cornerRadius(8)
            }
            .aspectRatio(4/3, contentMode: .fit)
        }
    }
}
