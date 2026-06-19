//
//  VideoLoadingManager.swift
//  Tweet
//
//  Tracks app-start video gating and aggregate video load activity.
//  Directional feed preloading is owned by VideoPlaybackCoordinator.
//

import Combine
import Foundation

@MainActor
class VideoLoadingManager: ObservableObject {
    static let shared = VideoLoadingManager()

    @Published private(set) var isInStartupPhase: Bool = true

    private var activeLoadingCount: Int = 0
    private var loadCountInLastMinute: Int = 0
    private var monitoringTimer: Timer?

    private init() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadCountInLastMinute = 0
            }
        }
    }

    /// End the startup phase - allows deferred video operations to proceed.
    func endStartupPhase() async {
        await MainActor.run {
            isInStartupPhase = false
            NotificationCenter.default.post(name: .startupPhaseEnded, object: nil)
        }
    }

    /// Notify that a video load has started.
    func videoLoadStarted() {
        activeLoadingCount += 1
        loadCountInLastMinute += 1
    }

    /// Notify that a video load has completed.
    func videoLoadCompleted() {
        activeLoadingCount = max(0, activeLoadingCount - 1)
    }

    deinit {
        monitoringTimer?.invalidate()
    }
}
