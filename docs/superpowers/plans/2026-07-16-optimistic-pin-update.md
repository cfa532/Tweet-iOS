# Optimistic Pin Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update pinned tweets immediately on pin/unpin, roll back failed mutations, and restore favorite/bookmark RPC timeouts to 30 seconds.

**Architecture:** Existing `.tweetPinStatusChanged` notifications remain the single UI synchronization path. Pin actions publish the intended state before the RPC, publish a correction on failure or server disagreement, and `ProfileView` applies notifications directly instead of re-reading potentially stale replicated data.

**Tech Stack:** Swift 6, SwiftUI, UIKit, NotificationCenter, Hprose.

## Global Constraints

- Do not run tests unless explicitly requested.
- Preserve writable-node routing and existing failure toasts.
- Avoid new global state and unrelated refactors.

---

### Task 1: Optimistic pin actions

**Files:**
- Modify: `Sources/Tweet/TweetItemHeaderView.swift`
- Modify: `Sources/Tweet/UIKit/TweetCellContentView.swift`

**Interfaces:**
- Consumes: `.tweetPinStatusChanged` with `tweetId` and `isPinned`.
- Produces: immediate intended-state notification plus rollback/reconciliation notification.

- [x] Publish `!currentPinState` before invoking `togglePinnedTweet`.
- [x] Keep the optimistic state when the server confirms it.
- [x] Publish the server result if it differs.
- [x] Publish the old state and the existing warning toast on nil/error.

### Task 2: Apply pin notifications locally

**Files:**
- Modify: `Sources/Features/Profile/ProfileView.swift`
- Modify: `Sources/Features/Profile/ProfileTweetsSection.swift`

**Interfaces:**
- Consumes: optimistic and rollback `.tweetPinStatusChanged` notifications.
- Produces: immediately updated `pinnedTweets`, `pinnedTweetIds`, and regular profile tweets.

- [x] Replace the delayed server refresh with direct state mutation for the matching profile.
- [x] Insert newly pinned tweets at the front and remove unpinned tweets.
- [x] Restore newly unpinned tweets to the regular list from the tweet singleton.

### Task 3: Restore timeouts and verify

**Files:**
- Modify: `Sources/Core/HproseInstance.swift`

**Interfaces:**
- Produces: favorite/bookmark writable clients with 30-second timeouts.

- [x] Change the two 60-second timeout requests back to 30 seconds.
- [x] Run Swift parser checks on modified Swift files.
- [x] Run `git diff --check` on modified files.
- [x] Review the focused diff for rollback and caller impact.
