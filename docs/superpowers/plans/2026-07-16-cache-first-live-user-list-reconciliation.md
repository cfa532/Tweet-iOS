# Cache-First Live User List Reconciliation Implementation Plan

> **For Codex:** Execute this plan in place on the existing `AppLink` branch. Preserve the user's unrelated Xcode project, scheme, and workspace-state changes.

**Goal:** Keep cached follower/following rows visible immediately, then reconcile the currently open screen with the authoritative remote ID list so slow remote users appear on the first visit.

**Architecture:** Split list loading into two explicit operations. `UserListView` first asks for cached IDs and publishes them immediately, then awaits a separate authoritative refresh and replaces the open screen's ID snapshot in server order. Each ID continues to use the existing `UserRowView` cache-first lifecycle: cached user content renders first, a placeholder represents an unresolved user, successful asynchronous loading updates the row, and terminal row failure removes only that UI row.

**Tech Stack:** Swift 6, SwiftUI, XCTest-free source regression checks, Xcode build verification.

---

## Task 1: Add a failing source regression check

**Files:**
- Inspect: `Sources/Features/Profile/UserListView.swift`
- Inspect: `Sources/Features/Home/HomeViewModel.swift`

**Step 1: Run a source-level assertion for the intended API**

Run a read-only script that asserts `UserListView` accepts an `authoritativeUserFetcher` and that `UserListDestinationView` supplies it. The assertion must fail before production changes because the two-phase API does not yet exist.

**Step 2: Confirm the failure is for the expected reason**

Verify the output identifies the missing `authoritativeUserFetcher` symbol, rather than a path or interpreter error.

## Task 2: Make `UserListView` reconcile cached and authoritative IDs

**Files:**
- Modify: `Sources/Features/Profile/UserListView.swift`

**Step 1: Add the authoritative loader dependency**

Keep `userFetcher` as the cached/paged source used by pagination. Add:

```swift
let authoritativeUserFetcher: @MainActor @Sendable () async throws -> [String]
```

Require it in the initializer. This makes the live update observable by the view instead of hiding it in an unstructured background task.

**Step 2: Extract first-page publication into a small main-actor helper**

Add a helper that:

- replaces `allUserIds` with the filtered IDs,
- preserves at least the currently visible row count during refresh, capped by the new list size,
- reveals at least `visibleBatchSize`,
- resets `nextDisplayIndex` and `nextPageNumber`,
- derives `hasMoreServerPages` from the unfiltered authoritative/cached count,
- recomputes `hasMoreUsers`, and
- prefetches the accepted IDs.

This helper must accept an explicit `minimumVisibleCount` so initial cached publication uses the normal visible batch while authoritative reconciliation does not unnecessarily collapse already revealed rows.

**Step 3: Implement the two-phase refresh**

Update `refreshUsers()` to:

1. retain current rows and show the central spinner only when no rows are visible,
2. request cached page zero with `userFetcher(0, pageSize)`, filter it, and publish it immediately when present,
3. await `authoritativeUserFetcher()`, filter the result, and publish it to the same view even when it is empty,
4. clear the error and loading states after success,
5. retain cached/current rows without an error if the authoritative request fails, and
6. show the retry error only when neither cached nor current rows exist.

Do not add `print`; no new diagnostic logging is required.

**Step 4: Preserve row failure semantics**

Keep `onLoadFailed` limited to removing the failed ID from the view's local arrays. Do not mutate `targetUser.fansList` or `targetUser.followingList`, because a user-object transport failure is not evidence that the social relationship disappeared.

## Task 3: Split the destination's cache and network loaders

**Files:**
- Modify: `Sources/Features/Home/HomeViewModel.swift`

**Step 1: Make `userFetcher` cache-only**

Retain the cold-start Core Data hydration of the profile owner. Return the requested slice from `fansList` or `followingList`. Remove the hidden `Task` and all direct network loading from this closure.

**Step 2: Add `authoritativeUserFetcher`**

The new closure must:

1. call `getListByType` and await its full result,
2. update the correct owner list on the main actor,
3. persist the updated owner through `TweetCacheManager`, and
4. return the complete authoritative ID list to `UserListView`.

A successful empty response must be returned and persisted as authoritative. A thrown error must leave the cached owner list unchanged.

## Task 4: Verify behavior and build safety

**Files:**
- Verify: `Sources/Features/Profile/UserListView.swift`
- Verify: `Sources/Features/Home/HomeViewModel.swift`

**Step 1: Re-run the source regression assertion**

Confirm both the declaration and call site now contain `authoritativeUserFetcher`, and confirm the old comment/logic that refreshed only “for the next access” is gone.

**Step 2: Review the final diff**

Check specifically that:

- cached IDs publish before the awaited remote result,
- remote IDs update the same open `UserListView`,
- blacklisted/invalid/duplicate filtering remains unchanged,
- the empty authoritative list clears the display,
- a remote failure retains cached rows,
- row failures do not alter the owner's authoritative relationship arrays,
- no new `print` was introduced, and
- unrelated dirty files were not modified.

**Step 3: Build the iOS app**

Run the repository's existing Xcode build command for the `Tweet` scheme against an available simulator or generic iOS Simulator destination. If sandboxed simulator services prevent the build, rerun the same build with the already authorized Xcode build capability.

**Step 4: Commit only the implementation files**

Stage and commit `UserListView.swift` and `HomeViewModel.swift` only. Leave the user's unrelated project, scheme, and workspace-state changes untouched.
