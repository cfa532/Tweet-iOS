# Detail Pull-to-Refresh Tweet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict `refresh_tweet` to explicit pull-to-refresh in Tweet Detail and Comment Detail while keeping initial and timer refreshes on ordinary server reads.

**Architecture:** Reuse Tweet Detail's existing read and resync helpers, changing only which helper owns pull and timer events. Give Comment Detail the equivalent pull sequence—refresh its tweet model, fetch page-zero replies, then notify the embedded comment list to reset pagination metadata.

**Tech Stack:** Swift 6, SwiftUI `.refreshable`, async/await, existing Hprose `get_tweet`, `refresh_tweet`, and `get_comments` APIs.

## Global Constraints

- Do not alter `HproseInstance` or backend request models.
- Preserve existing uncommitted ordered-loading changes in Tweet Detail and `CommentListUIKitView`.
- Initial detail loading must not call `refresh_tweet`.
- The five-minute timer must use `get_tweet` only and must not refresh comments.
- Pull-to-refresh must await its tweet and comment work before its spinner ends.
- Failures remain best-effort and must not clear existing displayed data.

---

### Task 1: Route Tweet Detail pull and timer events

**Files:**
- Modify: `Sources/Tweet/TweetDetailView.swift:1525-1610`

**Interfaces:**
- Consumes: `doReadTweet(isInitialLoad:) async`, `doResyncTweet() async`, and `refreshComments() async`.
- Produces: pull behavior that awaits `refresh_tweet` then `get_comments`, and timer behavior that invokes only `get_tweet`.

- [ ] **Step 1: Capture the pre-change call-path evidence**

Run:

```bash
sed -n '1525,1615p' Sources/Tweet/TweetDetailView.swift
```

Expected: the five-minute timer calls `doResyncTweet()`, while `refreshTweetAndComments()` calls `doReadTweet(isInitialLoad: false)`.

- [ ] **Step 2: Swap the timer and pull helper ownership**

Change the timer body to:

```swift
refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    Task { @MainActor in
        await doReadTweet(isInitialLoad: false)
    }
}
```

Change pull-to-refresh orchestration to:

```swift
// Pull-to-refresh: sync the latest tweet state, then reload comments.
private func refreshTweetAndComments() async {
    await doResyncTweet()
    await refreshComments()
}
```

- [ ] **Step 3: Verify Tweet Detail call paths**

Run:

```bash
sed -n '1525,1615p' Sources/Tweet/TweetDetailView.swift
```

Expected: initial loading still calls `doReadTweet(isInitialLoad: true)`; the timer calls `doReadTweet(isInitialLoad: false)`; pull calls `doResyncTweet()` followed by `refreshComments()`.

### Task 2: Add equivalent Comment Detail pull behavior

**Files:**
- Modify: `Sources/Tweet/CommentDetailView.swift:90-355`
- Modify: `Sources/Tweet/CommentListView.swift:20-175`

**Interfaces:**
- Consumes: `HproseInstance.refreshTweet(tweetId:authorId:)`, `HproseInstance.fetchComments(_:pageNumber:pageSize:)`, and the bound `[Tweet]` reply list.
- Produces: `CommentDetailView.refreshCommentAndReplies() async` and `CommentListView.externalRefreshToken: Int`.

- [ ] **Step 1: Add external pagination reset support to CommentListView**

Add an optional token property and initializer parameter:

```swift
let externalRefreshToken: Int

externalRefreshToken: Int = 0,

self.externalRefreshToken = externalRefreshToken
```

Observe it after the existing task:

```swift
.onChange(of: externalRefreshToken) { _, _ in
    currentPage = 0
    hasMoreComments = comments.count >= Int(pageSize)
    initialLoadComplete = true
}
```

- [ ] **Step 2: Add Comment Detail pull orchestration**

Add state:

```swift
@State private var repliesRefreshToken = 0
```

Attach pull-to-refresh to the outer `ScrollView`:

```swift
.refreshable {
    await refreshCommentAndReplies()
}
```

Pass the token to the embedded list:

```swift
externalRefreshToken: repliesRefreshToken,
```

Implement the ordered refresh:

```swift
private func refreshCommentAndReplies() async {
    if let refreshed = try? await hproseInstance.refreshTweet(
        tweetId: comment.mid,
        authorId: comment.authorId
    ) {
        try? comment.update(from: refreshed)
    }

    if let refreshedReplies = try? await hproseInstance.fetchComments(
        comment,
        pageNumber: 0,
        pageSize: 10
    ) {
        replies = refreshedReplies.compactMap { $0 }
        repliesRefreshToken += 1
    }
}
```

Keep `syncComment()` and its open-time `getTweet(... fromDetailView: true)` unchanged.

- [ ] **Step 3: Verify source call paths and formatting**

Run:

```bash
rg -n "refreshable|refreshCommentAndReplies|refreshTweet\(|fetchComments\(|externalRefreshToken|doResyncTweet|doReadTweet" Sources/Tweet/TweetDetailView.swift Sources/Tweet/CommentDetailView.swift Sources/Tweet/CommentListView.swift
git diff --check
```

Expected: `refresh_tweet` is reachable from both pull gestures, the Tweet Detail timer uses `get_tweet`, Comment Detail pull fetches replies, and there are no whitespace errors.

- [ ] **Step 4: Build the iOS target**

Run:

```bash
xcodebuild -project Tweet.xcodeproj -scheme Tweet -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/TweetDerivedData build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`. The repository has no XCTest source target, so the behavior is verified through exact call-path assertions and a full Swift compiler build.

- [ ] **Step 5: Review only the intended diff**

Run:

```bash
git diff -- Sources/Tweet/TweetDetailView.swift Sources/Tweet/CommentDetailView.swift Sources/Tweet/CommentListView.swift
```

Expected: the diff preserves the pre-existing ordered-loading changes and adds only the approved pull, timer, reply-fetch, and pagination-reset behavior.
