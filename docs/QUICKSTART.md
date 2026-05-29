# Tweet-iOS Quick Start

Use this guide when setting up the project for local development.

## 1) Prerequisites

- Xcode 15+
- CocoaPods installed (`pod --version`)
- iOS 17 simulator/device (root app entry is iOS 17 annotated)

## 2) Project Setup

From repository root:

```bash
pod install
open Tweet.xcworkspace
```

In Xcode:

1. Select scheme: `Tweet`
2. Choose a simulator/device
3. Build and run (`Cmd + R`)

## 3) First-Run Verification

After launch, verify these basics:

1. App opens without crash
2. Home timeline renders
3. Chat tab loads
4. Compose sheet opens
5. Search screen opens
6. A tweet with media can start playback

## 4) Recommended Reading Order

1. `ARCHITECTURE.md` (system-level design)
2. `VIDEO_PLAYBACK_PIPELINE.md` (video behavior and IPFS path)
3. `UPLOAD_SYSTEM.md` (media publish flow)
4. `NETWORK_RESILIENCE.md` (network fallback and reliability)

## 5) Useful Commands

```bash
# Install dependencies
pod install

# Open workspace
open Tweet.xcworkspace
```

## 6) Troubleshooting

- If pods are out of sync:
  - run `pod install` again
  - clean build folder in Xcode (`Shift + Cmd + K`)
- If media playback fails on first launch:
  - relaunch once to ensure local proxy startup completes
- If build errors mention missing workspace dependencies:
  - make sure you opened `Tweet.xcworkspace`, not `Tweet.xcodeproj`
