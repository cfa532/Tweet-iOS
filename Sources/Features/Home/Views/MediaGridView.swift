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

    @State private var isVisible: Bool = false

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let gridWidth = geometry.size.width
                let gridHeight = gridWidth * 0.75 // 4:3 aspect ratio
                let firstVideoIndex = attachments.firstIndex { $0.type.lowercased() == "video" }

                ZStack {
                    switch attachments.count {
                    case 1:
                        MediaCell(
                            attachment: attachments[0],
                            baseUrl: baseUrl,
                            play: isVisible && firstVideoIndex == 0
                        )
                        .frame(width: gridWidth, height: gridHeight)
                    case 2:
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            MediaCell(
                                attachment: attachments[1],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 1
                            )
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 3:
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            VStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[1],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 1
                                )
                                MediaCell(
                                    attachment: attachments[2],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 2
                                )
                            }
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 4:
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[0],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 0
                                )
                                MediaCell(
                                    attachment: attachments[1],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 1
                                )
                            }
                            HStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[2],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 2
                                )
                                MediaCell(
                                    attachment: attachments[3],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 3
                                )
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
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false }
            }
            .aspectRatio(4/3, contentMode: .fit)
        }
    }
}
