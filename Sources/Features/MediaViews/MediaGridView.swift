//
//  MediaGridView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaGridView: View {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let maxImages: Int = 4
    @State private var selectedIndex: Int = 0
    @State private var showBrowser = false
    
    private func isPortrait(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar < 1.0
    }

    private func isLandscape(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar > 1.0
    }

    private func gridAspect() -> CGFloat {
        let count = attachments.count
        let allPortrait = attachments.allSatisfy { isPortrait($0) }
        let allLandscape = attachments.allSatisfy { isLandscape($0) }
        
        switch count {
        case 1:
            return CGFloat(attachments[0].aspectRatio ?? 1.0)
        case 2:
            if allPortrait { return 4.0/3.0 }
            if allLandscape { return 3.0/4.0 }
            return 1.0
        case 3:
            if allPortrait { return 4.0/3.0 }
            if allLandscape { return 3.0/4.0 }
            return 1.0
        default:
            return 1.0
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gridWidth: CGFloat = 320
            let gridHeight = gridWidth / gridAspect()

            ZStack {
                switch attachments.count {
                case 1:
                    MediaCell(
                        parentTweet: parentTweet,
                        attachmentIndex: 0,
                        aspectRatio: 1.0
                    )
                    .environmentObject(MuteState.shared)
                    .frame(width: gridWidth, height: gridHeight)
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedIndex = 0
                        showBrowser = true
                    }
                    
                case 2:
                    if isPortrait(attachments[0]) {
                        HStack(spacing: 2) {
                            ForEach(Array(attachments.enumerated()), id: \ .offset) { idx, att in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth / 2 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            ForEach(Array(attachments.enumerated()), id: \ .offset) { idx, att in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    }
                    
                case 3:
                    if isPortrait(attachments[0]) {
                        HStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            
                            VStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth, height: gridHeight / 2 - 1)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            
                            HStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                }
                            }
                        }
                    }
                    
                default:
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                if idx < attachments.count {
                                    ZStack {
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                        .aspectRatio(contentMode: .fill)
                                        .clipped()
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedIndex = idx
                                            showBrowser = true
                                        }
                                        
                                        if idx == 3 && attachments.count > 4 {
                                            Color.black.opacity(0.4)
                                            Text("+\(attachments.count - 4)")
                                                .foregroundColor(.white)
                                                .font(.title)
                                                .bold()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .clipped()
            .onAppear { }
            .onDisappear { }
            .fullScreenCover(isPresented: $showBrowser) {
                MediaBrowserView(attachments: attachments, initialIndex: selectedIndex)
            }
        }
    }
}

// MARK: - Zoomable View
struct ZoomableView<Content: View>: View {
    let content: Content
    @Binding var scale: CGFloat
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(scale: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._scale = scale
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            content
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                scale = min(max(scale * delta, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                            },
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    let newOffset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                    // Limit the offset based on scale
                                    let maxOffset = (scale - 1) * geometry.size.width / 2
                                    offset = CGSize(
                                        width: min(max(newOffset.width, -maxOffset), maxOffset),
                                        height: min(max(newOffset.height, -maxOffset), maxOffset)
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2
                        }
                    }
                }
                .allowsHitTesting(scale > 1) // Only allow zoom gestures when zoomed in
        }
    }
}
