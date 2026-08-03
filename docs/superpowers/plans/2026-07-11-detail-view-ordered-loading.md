# Tweet Detail Ordered Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show cached detail data first, await the detail tweet synchronization, and then fetch comments exactly once even when the tweet request fails.

**Architecture:** Keep `TweetDetailView` as the single owner of page-zero loading and sequence its existing operations without new coordination state. `CommentListUIKitView` renders bound comments and retains pagination, but does not initiate page zero.

**Tech Stack:** Swift 6, SwiftUI, UIKit, structured concurrency, Xcode

## Global Constraints

- Preserve cached tweet and comments when network requests fail.
- Do not call `refreshTweet` during detail-view opening.
- Attempt comments after `getTweet(fromDetailView: true)` finishes, including on failure.
- Preserve comment pagination and the five-minute refresh timer.

---

### Task 1: Make the parent the single ordered initial loader

**Files:**
- Modify: `Sources/Tweet/TweetDetailView.swift:1021-1023,1517-1641`
- Modify: `Sources/Tweet/UIKit/CommentListUIKitView.swift:61-71`
- Test: temporary source regression check run from the repository root

**Interfaces:**
- Consumes: `doReadTweet(isInitialLoad:) async`, `refreshComments() async`, and `configureCommentCacheContextIfNeeded()`
- Produces: `loadInitialServerData() async`, which awaits the tweet read and then attempts the comment read

- [ ] **Step 1: Run a failing regression check**

```bash
python3 -c "from pathlib import Path; d=Path('Sources/Tweet/TweetDetailView.swift').read_text(); u=Path('Sources/Tweet/UIKit/CommentListUIKitView.swift').read_text(); assert 'await loadInitialServerData()' in d; assert 'async let tweetRead' not in d; block=u[u.index('.task(id: parentTweet.mid)'):u.index('.onReceive', u.index('.task(id: parentTweet.mid)'))]; assert 'await refreshComments()' not in block"
```

Expected: FAIL because `loadInitialServerData()` does not exist.

- [ ] **Step 2: Implement ordered loading**

Replace the initial fire-and-forget network tasks with `Task { await loadInitialServerData() }`. Add:

```swift
private func loadInitialServerData() async {
    await doReadTweet(isInitialLoad: true)
    await refreshComments()
}
```

Make pull-to-refresh sequential:

```swift
private func refreshTweetAndComments() async {
    await doReadTweet(isInitialLoad: false)
    await refreshComments()
}
```

Remove the opening-time `doResyncTweet()` task because the server now synchronizes through `getTweet(fromDetailView: true)`. Retain timer-driven refresh. Remove the child view's initial `refreshComments()` call and initialize its UI state from the bound comments:

```swift
.task(id: parentTweet.mid) {
    guard loadedParentTweetId != parentTweet.mid else { return }
    loadedParentTweetId = parentTweet.mid
    initialLoadComplete = true
    if !comments.isEmpty {
        currentPage = UInt((comments.count - 1) / Int(pageSize))
        hasMoreComments = comments.count >= pageSize
    }
}
```

- [ ] **Step 3: Re-run the regression check**

Run the command from Step 1.

Expected: PASS with exit status 0.

- [ ] **Step 4: Review callers**

```bash
rg -n "setupInitialData|loadInitialServerData|refreshTweetAndComments|doResyncTweet|await refreshComments" Sources/Tweet/TweetDetailView.swift Sources/Tweet/UIKit/CommentListUIKitView.swift
```

Expected: one parent initial sequence, one ordered pull-to-refresh sequence, no child page-zero fetch, and no opening-time `doResyncTweet`.

### Task 2: Verify the application build

**Files:**
- Verify: `Sources/Tweet/TweetDetailView.swift`
- Verify: `Sources/Tweet/UIKit/CommentListUIKitView.swift`

**Interfaces:**
- Consumes: ordered loading from Task 1
- Produces: build evidence for the Swift changes

- [ ] **Step 1: Check the diff**

```bash
git diff --check
git diff -- Sources/Tweet/TweetDetailView.swift Sources/Tweet/UIKit/CommentListUIKitView.swift
```

Expected: no whitespace errors and only loading ownership/order changes.

- [ ] **Step 2: Build without code signing**

```bash
xcodebuild -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm requirements**

Inspect the final source and verify cache setup precedes the initial task; the detail tweet request precedes comments; tweet failure does not stop comments; one page-zero owner remains; and pull-to-refresh is sequential.
