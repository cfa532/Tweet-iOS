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
                        mediaCell(attachments[0])
                            .frame(width: gridWidth, height: gridHeight)
                    case 2:
                        HStack(spacing: 2) {
                            mediaCell(attachments[0])
                            mediaCell(attachments[1])
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 3:
                        HStack(spacing: 2) {
                            mediaCell(attachments[0])
                                .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            VStack(spacing: 2) {
                                mediaCell(attachments[1])
                                mediaCell(attachments[2])
                            }
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 4:
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                mediaCell(attachments[0])
                                mediaCell(attachments[1])
                            }
                            HStack(spacing: 2) {
                                mediaCell(attachments[2])
                                mediaCell(attachments[3])
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

    @ViewBuilder
    private func mediaCell(_ attachment: MimeiFileType) -> some View {
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
