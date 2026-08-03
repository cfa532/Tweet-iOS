# Pin Toggle Warning Toast Implementation Plan

> **For agentic workers:** Implement inline in the current session. Do not dispatch subagents for this scoped change.

**Goal:** Show a warning toast whenever a pin or unpin request fails or returns no status.

**Architecture:** Reuse the existing `.errorOccurred` notification and `ContentView` toast state. Pin call sites publish an `NSError` in the `PinToggle` domain; the global observer recognizes that domain and presents it as a warning while preserving tweet-deletion errors as errors.

**Tech Stack:** Swift 6, SwiftUI, UIKit, NotificationCenter

## Global Constraints

- Do not run tests unless the user explicitly asks.
- Preserve unrelated working-tree changes.
- Keep the change limited to pin/unpin error presentation.

---

### Task 1: Publish and display pin-toggle failures

**Files:**
- Modify: `Sources/Tweet/TweetItemHeaderView.swift`
- Modify: `Sources/Tweet/UIKit/TweetCellContentView.swift`
- Modify: `Sources/App/ContentView.swift`

**Interfaces:**
- Consumes: `Notification.Name.errorOccurred`, `ErrorMessageHelper.userFriendlyMessage(from:)`, `ToastView.ToastType.warning`
- Produces: `NSError(domain: "PinToggle", code: -1, ...)` notifications from every active pin/unpin failure path

- [x] **Step 1: Replace silent SwiftUI pin failures**

Change `TweetMenu.togglePin()` from `try?` to `do/catch`, and post a `PinToggle` error notification when the RPC throws or returns nil.

- [x] **Step 2: Replace silent UIKit pin failures**

In `TweetCellContentView.createTweetMenu`, post the same `PinToggle` error notification from both the thrown-error and nil-response paths.

- [x] **Step 3: Present pin failures as warnings**

Extend the existing `.errorOccurred` observer in `ContentView` to accept `PinToggle` alongside `TweetDeletion`. Use `.warning` for `PinToggle` and retain `.error` for `TweetDeletion`.

- [x] **Step 4: Perform static verification**

Run `git diff --check` for the three modified source files, inspect their complete diff, and confirm every active `togglePinnedTweet` caller either posts success or reports failure. Do not run tests.
