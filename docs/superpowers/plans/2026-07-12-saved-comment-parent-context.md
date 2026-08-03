# Saved Comment Parent Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve each comment's immediate parent ID and show that parent as embedded context when the comment appears in bookmark or favorite lists.

**Architecture:** Add `parentTweetId` to the existing Codable/sendable tweet pipeline, assign it at both comment creation sites, and introduce a small presentation-only embedded-reference resolver. Bookmark/favorite UIKit feeds use that resolver for rendering, loading, media coordination, and height calculation; every other feed retains existing retweet/quote behavior.

**Tech Stack:** Swift 6, SwiftUI, UIKit, Codable, Core Data payload caching, XCTest/xcodebuild.

## Global Constraints

- `parentTweetId` always identifies the immediate parent object.
- `originalTweetId` and `originalAuthorId` remain reserved for retweets and deliberately authored quote tweets.
- Do not mutate shared `Tweet` singletons for presentation-only behavior.
- Do not change comment node routing, ownership, references, synchronization depth, or recovery APIs.
- Older payloads without `parentTweetId` must continue to decode and render.
- Preserve the user's existing changes to `Tweet.xcscheme` and `UserInterfaceState.xcuserstate`.

---

### Task 1: Persist the Immediate Parent Relationship

**Files:**
- Modify: `Sources/DataModels/Tweet.swift`
- Modify: `Sources/DataModels/Records.swift`
- Modify: `Sources/DataModels/ModelStores.swift`
- Modify: `Sources/Core/TweetCacheManager.swift`
- Modify: `Sources/Core/HproseInstance.swift`
- Test: `TweetTests/SavedCommentParentContextTests.swift`

**Interfaces:**
- Produces: `Tweet.parentTweetId: MimeiId?`
- Produces: `TweetRecord.parentTweetId: MimeiId?`
- Produces: upload JSON key `parentTweetId`

- [ ] **Step 1: Add failing Codable and record propagation tests**

Create tests that construct a tweet with `parentTweetId: "parent-comment"`, round-trip it through `JSONEncoder`/`JSONDecoder` and `TweetRecord`, and assert the value survives. Decode a legacy JSON fixture without the key and assert the property is `nil`.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `xcodebuild test -workspace Tweet.xcworkspace -scheme Tweet -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TweetTests/SavedCommentParentContextTests`

Expected: FAIL because `Tweet` and `TweetRecord` do not expose `parentTweetId`.

- [ ] **Step 3: Add the minimal field plumbing**

Add the optional property and parameter beside the existing relationship fields. Carry it through `CodingKeys`, decoding, encoding, `getInstance`, initializers, `update`, dictionary merging, copies, `TweetRecord.init(tweet:)`, `makeTweet`, `TweetStore.merge/update`, and cache reconstruction. Add this optional key to `HproseInstance.uploadTweet`'s explicit payload.

- [ ] **Step 4: Run focused tests and verify passing**

Run the focused test command from Step 2.

Expected: PASS with no Codable or actor-isolation failures.

### Task 2: Assign Parent IDs During Comment and Reply Creation

**Files:**
- Modify: `Sources/Features/Compose/CommentComposeView.swift`
- Modify: `Sources/Features/Compose/ReplyEditorView.swift`
- Test: `TweetTests/SavedCommentParentContextTests.swift`

**Interfaces:**
- Consumes: `Tweet.getInstance(..., parentTweetId: MimeiId?)`
- Produces: every locally created comment/reply has `parentTweetId == immediateParent.mid`

- [ ] **Step 1: Add failing immediate-parent tests**

Extract or expose a focused comment factory if needed, then test a top-level comment gets the top-level tweet ID and a reply gets its parent comment ID—not the root tweet ID.

- [ ] **Step 2: Run tests and verify failure**

Run the focused test command.

Expected: FAIL because composition does not assign `parentTweetId`.

- [ ] **Step 3: Set the field at both creation sites**

Pass `parentTweetId: tweet.mid` in `CommentComposeView` and `parentTweetId: parentTweet.mid` in `ReplyEditorView`. Keep the existing quote fields independent.

- [ ] **Step 4: Run tests and verify passing**

Run the focused test command.

Expected: PASS and immediate-parent assertions succeed.

### Task 3: Resolve Saved-Comment Embedded Context Without Model Mutation

**Files:**
- Create: `Sources/Tweet/TweetEmbeddedReference.swift`
- Modify: `Sources/Tweet/UIKit/TweetTableView.swift`
- Modify: `Sources/Tweet/UIKit/TweetTableViewController.swift`
- Modify: `Sources/Tweet/UIKit/TweetCellContentView.swift`
- Test: `TweetTests/SavedCommentParentContextTests.swift`

**Interfaces:**
- Produces: `TweetPresentationContext` with ordinary and saved-list cases
- Produces: `Tweet.effectiveEmbeddedTweetId(in:) -> MimeiId?`
- Consumes: bookmark/favorite `feedIdentifier` prefixes already provided by `HomeViewModel`

- [ ] **Step 1: Add failing resolver tests**

Test that an actual quote always resolves `originalTweetId`; a comment resolves `parentTweetId` only in bookmark/favorite context; an ordinary feed returns `nil`; and a legacy comment without the field returns `nil`.

- [ ] **Step 2: Run tests and verify failure**

Run the focused test command.

Expected: FAIL because no presentation resolver exists.

- [ ] **Step 3: Implement the resolver and feed context**

Add a small value-type context and pure resolver. Derive saved-list context from the existing `bookmarks_`/`favorites_` feed identifiers and pass it to cell configuration. Do not change `Tweet.originalTweetId`.

- [ ] **Step 4: Render and load the effective embedded tweet**

Update UIKit cell configuration to treat a saved comment as regular outer content plus an embedded card. Reuse `EmbeddedTweetUIView` and cache-first lookup. Since `parentTweetId` has no author ID, do not issue an author-routed network request unless the parent is already resolved with author metadata; leave the embedded state unavailable otherwise while retaining the saved comment.

- [ ] **Step 5: Align prefetching, video coordination, reuse, and height logic**

Replace presentation-sensitive `originalTweetId` checks in the table/cell path with the effective embedded ID. Keep pure-retweet navigation and banners dependent on real quote fields. Include the effective embedded ID in row identity/reconfiguration and height calculations so saved comment cards are neither clipped nor stale.

- [ ] **Step 6: Run tests and verify passing**

Run the focused test command.

Expected: PASS for context selection and normal-feed isolation.

### Task 4: Cache the Parent Alongside Saved Comments

**Files:**
- Modify: `Sources/Core/TweetCacheManager.swift`
- Test: `TweetTests/SavedCommentParentContextTests.swift`

**Interfaces:**
- Consumes: `TweetRecord.parentTweetId`
- Produces: cached bookmark/favorite payload merges the immediate parent before the comment

- [ ] **Step 1: Add a failing cached-parent test**

Save a parent record and a saved comment record under a bookmark/favorite cache key, reload the list, and assert the parent singleton is available while list order remains unchanged.

- [ ] **Step 2: Run the cache test and verify failure**

Run the focused test command.

Expected: FAIL because cached list loading only joins `originalTweetId`.

- [ ] **Step 3: Generalize the cached embedded payload join**

For bookmark/favorite cache keys only, join `parentTweetId` when no actual `originalTweetId` exists. Reuse the existing embedded/original payload fields or rename them narrowly if that improves clarity, then merge the parent and author before the saved comment.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
xcodebuild test -workspace Tweet.xcworkspace -scheme Tweet -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:TweetTests/SavedCommentParentContextTests
xcodebuild test -workspace Tweet.xcworkspace -scheme Tweet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild build -workspace Tweet.xcworkspace -scheme Tweet -destination 'generic/platform=iOS Simulator'
```

Expected: all commands exit 0 with zero test failures and a successful build.

- [ ] **Step 5: Review the final diff**

Confirm every constructor/copy/merge path preserves the optional field, ordinary comments remain unchanged outside saved lists, quote/retweet behavior is intact, and unrelated user changes remain unstaged.
