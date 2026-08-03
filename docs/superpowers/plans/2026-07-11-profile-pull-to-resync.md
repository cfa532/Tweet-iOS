# Profile Pull-to-Resync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop automatic profile-open resync and await conditional user resync only during an explicit profile pull-to-refresh.

**Architecture:** Keep refresh orchestration in `ProfileView`, with an explicit Boolean determining whether the existing conditional resync phase runs. Route the profile list's existing pull-to-refresh extra callback to that orchestration, so timeline refresh completes first and the UIKit refresh control remains active through user, pinned-tweet, and resync work.

**Tech Stack:** Swift 6, SwiftUI, UIKit `UIRefreshControl`, async/await, existing Hprose backend client.

## Global Constraints

- Do not change the `resync_user` backend contract or `HproseInstance.resyncUser`.
- Continue to skip resync when the refreshed user's read host equals its root host.
- Keep resync failures non-fatal and preserve successfully refreshed data.
- Await pull-triggered resync before ending the refresh indicator.
- Preserve the repository's Swift 6 actor-boundary rules.

---

### Task 1: Route resync through explicit pull-to-refresh

**Files:**
- Modify: `Sources/Features/Profile/ProfileView.swift:102-107, 230-250, 719-786`
- Modify: `Sources/Features/Profile/ProfileTweetsSection.swift:125-250`

**Interfaces:**
- Consumes: `HproseInstance.resyncUser(userId:) async throws -> ResyncUserResult` and `TweetListView.onRefreshExtra: (() async -> Void)?`.
- Produces: `ProfileView.refreshProfileData(resyncIfNeeded: Bool) async` and `ProfileTweetsSection.onProfileRefresh: () async -> Void`.

- [ ] **Step 1: Establish the pre-change verification baseline**

Run:

```bash
rg -n "refreshProfileData|onPinnedTweetsRefresh|resyncUser" Sources/Features/Profile/ProfileView.swift Sources/Features/Profile/ProfileTweetsSection.swift
```

Expected: the initial `.task` calls `refreshProfileData()` and the same method reaches `resyncUser`; pull-to-refresh routes only to `onPinnedTweetsRefresh`.

- [ ] **Step 2: Make the resync phase explicitly opt-in**

Change the initial task call and method signature in `ProfileView.swift` to:

```swift
await refreshProfileData(resyncIfNeeded: false)

private func refreshProfileData(resyncIfNeeded: Bool) async {
```

After the successful user fetch, await pinned tweets directly and gate the existing resync block:

```swift
await refreshPinnedTweets()

guard resyncIfNeeded else {
    return
}

guard shouldResyncProfileUser(refreshedProfileUser) else {
    print("DEBUG: [ProfileView] Skipping resync for \(profileUserId): current read node is already root host")
    return
}
```

Keep the existing detached `resyncUser`, cache update, returned-tweet state update, cancellation check, and error handling unchanged.

- [ ] **Step 3: Route profile pull-to-refresh to the opt-in refresh**

Rename `ProfileTweetsSection.onPinnedTweetsRefresh` to `onProfileRefresh` in its property, initializer parameter, assignment, and `TweetListView` call:

```swift
let onProfileRefresh: () async -> Void

onProfileRefresh: @escaping () async -> Void,

self.onProfileRefresh = onProfileRefresh

onRefreshExtra: onProfileRefresh,
```

At the `ProfileTweetsSection` construction site in `ProfileView.swift`, pass:

```swift
onProfileRefresh: {
    await refreshProfileData(resyncIfNeeded: true)
},
```

Because `TweetListView` already awaits `refreshTweetsFromUserPull()` and then `onRefreshExtra`, and `TweetTableViewController` ends its refresh control only after awaiting `onRefresh`, no lower-layer changes are needed.

- [ ] **Step 4: Verify source-level behavior**

Run:

```bash
rg -n "refreshProfileData\(resyncIfNeeded:|onProfileRefresh|onPinnedTweetsRefresh|resyncUser" Sources/Features/Profile/ProfileView.swift Sources/Features/Profile/ProfileTweetsSection.swift
```

Expected: the initial task uses `false`, the pull callback uses `true`, `onPinnedTweetsRefresh` has no matches in these files, and the existing `resyncUser` call remains inside the gated method.

- [ ] **Step 5: Build the app target**

Run:

```bash
xcodebuild -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`, with no new Swift concurrency or closure-signature errors. The repository currently has no XCTest source target, so this focused wiring change is verified by source assertions and a full compiler build.

- [ ] **Step 6: Review the final diff**

Run:

```bash
git diff --check
git diff -- Sources/Features/Profile/ProfileView.swift Sources/Features/Profile/ProfileTweetsSection.swift
```

Expected: no whitespace errors; the diff only changes the trigger and awaiting behavior described above.
