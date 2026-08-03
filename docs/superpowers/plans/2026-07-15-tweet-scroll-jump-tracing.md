# Tweet Scroll-Jump Tracing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Debug-only causal logs that identify which tweet height relayout moves the visible feed anchor.

**Architecture:** Instrument the existing height-change callback and `performPendingHeightRelayout` boundary in `TweetTableViewController`. Use one searchable prefix and capture geometry before relayout, immediately after UIKit relayout, and after optional anchor restoration without changing the existing mutation sequence.

**Tech Stack:** Swift 6, UIKit, `UITableView`

## Global Constraints

- Emit logs only in Debug builds.
- Use the prefix `🧭 [SCROLL JUMP TRACE]` for every new diagnostic message.
- Do not change row heights, scrolling, anchoring, cache behavior, or update timing.
- Do not log every `scrollViewDidScroll` callback.

---

### Task 1: Instrument height relayout causality

**Files:**
- Modify: `Sources/Tweet/UIKit/TweetTableViewController.swift:2438-2478`
- Modify: `Sources/Tweet/UIKit/TweetTableViewController.swift:3308-3352`
- Test: structural Debug-log checks and iOS Simulator build

**Interfaces:**
- Consumes: existing `onHeightChanged`, `cachedHeight(for:width:)`, `pendingHeightRelayoutTweetIds`, `tweetForRow`, and `performPendingHeightRelayout` behavior
- Produces: Debug console entries prefixed with `🧭 [SCROLL JUMP TRACE]`

- [x] **Step 1: Run the structural check and verify it fails**

Run:

```bash
test "$(rg -c '🧭 \[SCROLL JUMP TRACE\]' Sources/Tweet/UIKit/TweetTableViewController.swift)" -ge 4
```

Expected: exit status 1 because no trace entries exist yet.

- [x] **Step 2: Log a visible cell's height request before caching it**

Inside `cell.onHeightChanged`, before `setCachedHeight`, add a `#if DEBUG` message containing `feedIdentifier`, `tweet.mid`, `indexPath.row`, the old cached height, `desiredHeight`, `tableView.contentOffset.y`, `tableView.contentSize.height`, `isUserDragging`, and `isDecelerating`.

- [x] **Step 3: Log geometry around the pending table relayout**

In `performPendingHeightRelayout`, capture and log before the existing `beginUpdates/endUpdates` call:

```swift
#if DEBUG
let tracePendingTweetIds = pendingHeightRelayoutTweetIds.sorted()
let traceAnchorTweetId = anchorIndexPath.flatMap { tweetForRow($0.row)?.mid } ?? "none"
let traceOffsetBefore = tableView.contentOffset.y
let traceContentHeightBefore = tableView.contentSize.height
#endif
```

After the relayout, log the raw offset/content-height changes. In the existing anchor-restoration branch, log either the applied correction and delta or an explicit `anchor-no-correction` event.

- [x] **Step 4: Verify trace coverage and formatting**

Run:

```bash
test "$(rg -c '🧭 \[SCROLL JUMP TRACE\]' Sources/Tweet/UIKit/TweetTableViewController.swift)" -ge 4
git diff --check
```

Expected: both commands exit successfully and every new message has the shared prefix.

- [x] **Step 5: Build the app**

Run:

```bash
xcodebuild -quiet -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TweetCodexDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: exit status 0, with no new Swift compile errors.

- [x] **Step 6: Review the final diff**

Confirm `TweetTableViewController.swift` contains logging-only changes and that the existing order remains: capture anchor, clear pending IDs, relayout, calculate anchor correction, optionally set content offset.
