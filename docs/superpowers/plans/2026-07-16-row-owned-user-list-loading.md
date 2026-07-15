# Row-Owned User List Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each iOS follower/following row exclusively own its cached display, placeholder, asynchronous user load, success replacement, and terminal-failure dismissal.

**Architecture:** Remove `UserListView`'s competing user-object prefetch task while retaining its relationship-ID reconciliation and visible batching. Keep all object loading inside `UserRowView`, and migrate that lifecycle's remaining console prints to the existing OSLog logger so attempts and outcomes are observable.

**Tech Stack:** Swift 6, SwiftUI, OSLog, Xcode workspace build.

## Global Constraints

- Do not change authoritative follower/following ID synchronization.
- Do not change user-cache lifetime or profile force-refresh behavior.
- Do not change blacklist persistence, blacklist filtering, or cache clearing.
- Do not change backend APIs, recovery routing, or Android code.
- A failed user-object load removes only the local row, not the owner's relationship list.
- Do not introduce `print` in iOS code touched by this plan.
- Preserve unrelated changes in the Xcode project, scheme, and workspace state.

---

### Task 1: Prove the competing loading paths still exist

**Files:**
- Inspect: `Sources/Features/Profile/UserListView.swift`
- Inspect: `Sources/Features/Profile/UserRowView.swift`

**Interfaces:**
- Consumes: Existing `UserListView.prefetchUsers(_:)` and `UserRowView.loadUser()`.
- Produces: A source-level red check that fails until one row owns the lifecycle.

- [ ] **Step 1: Run the failing source regression check**

```bash
python3 -c "from pathlib import Path; list_source=Path('Sources/Features/Profile/UserListView.swift').read_text(); row_source=Path('Sources/Features/Profile/UserRowView.swift').read_text(); problems=[]; problems += ['list owns prefetchTask'] if 'prefetchTask' in list_source else []; problems += ['list calls prefetchUsers'] if 'prefetchUsers(' in list_source else []; problems += ['row uses print'] if 'print(' in row_source else []; assert not problems, '; '.join(problems)"
```

Expected: FAIL with all three current conflicts: `list owns prefetchTask; list calls prefetchUsers; row uses print`.

- [ ] **Step 2: Confirm authoritative reconciliation remains present before editing**

```bash
rg -n "authoritativeUserFetcher|publishUserIds" Sources/Features/Profile/UserListView.swift Sources/Features/Home/HomeViewModel.swift
```

Expected: matches in both the list view and its destination; this behavior must survive the change.

### Task 2: Remove list-owned user-object prefetching

**Files:**
- Modify: `Sources/Features/Profile/UserListView.swift:20-310`

**Interfaces:**
- Consumes: `allUserIds`, `displayedUserIds`, `publishUserIds`, and `loadMoreUsers`.
- Produces: A list view that owns only ID state and constructs `UserRowView` for admitted IDs.

- [ ] **Step 1: Remove prefetch task state and cancellation**

Delete:

```swift
@State private var prefetchTask: Task<Void, Never>?
```

and delete each:

```swift
prefetchTask?.cancel()
```

- [ ] **Step 2: Remove prefetch calls from ID publication**

Delete the calls below without changing adjacent ID/pagination state:

```swift
prefetchUsers(userIds)
prefetchUsers(filteredUserIds)
```

- [ ] **Step 3: Remove the prefetch implementation**

Delete `prefetchUsers(_:)` completely, including its task group. Do not replace it with delayed prefetch or another background loader. `UserRowView.loadUser()` becomes the only user-object fetch owner.

- [ ] **Step 4: Run the source check and observe the remaining red condition**

Run the Task 1 source regression check again.

Expected: FAIL only with `row uses print`.

### Task 3: Make the row lifecycle observable through OSLog

**Files:**
- Modify: `Sources/Features/Profile/UserRowView.swift:355-455`

**Interfaces:**
- Consumes: Existing file-level `userRowLogger`, `loadUser()`, and `hideAndBlacklistUser(taskCancellationToken:reason:)`.
- Produces: Structured lifecycle logs with no `print` in `UserRowView`.

- [ ] **Step 1: Replace cancellation prints with debug logs**

Use hash-masked IDs for routine cancellation diagnostics:

```swift
userRowLogger.debug("User load cancelled before start: \(userId, privacy: .private(mask: .hash))")
userRowLogger.debug("Cached user refresh cancelled: \(userId, privacy: .private(mask: .hash))")
userRowLogger.debug("User load cancelled during processing: \(userId, privacy: .private(mask: .hash))")
userRowLogger.debug("User load cancelled: \(userId, privacy: .private(mask: .hash))")
```

- [ ] **Step 2: Log uncached load attempts and successful replacements**

Immediately before `fetchUser` for an uncached row:

```swift
userRowLogger.info("Loading uncached user: \(userId, privacy: .public)")
```

After a renderable user is returned:

```swift
userRowLogger.info("Loaded user row: \(fetchedUser.mid, privacy: .public)")
```

These information-level events make the invalid-ID attempt visible in collected logs.

- [ ] **Step 3: Log retained cached rows and terminal failures**

For a cached refresh error that does not remove the row:

```swift
userRowLogger.warning("Cached user refresh failed; retaining row for \(userId, privacy: .public): \(error.localizedDescription, privacy: .public)")
```

For a thrown uncached load:

```swift
userRowLogger.error("User load failed after retries for \(userId, privacy: .public): \(error.localizedDescription, privacy: .public)")
```

At the start of `hideAndBlacklistUser`:

```swift
userRowLogger.error("Dismissing user row \(userId, privacy: .public): \(reason, privacy: .public)")
```

Keep the existing `BlackList.shared.recordFailure(userId)` and `onLoadFailed?(userId)` behavior unchanged.

- [ ] **Step 4: Run the source regression check**

Run the Task 1 source regression check again.

Expected: PASS with exit code 0.

### Task 4: Verify and commit the implementation

**Files:**
- Verify: `Sources/Features/Profile/UserListView.swift`
- Verify: `Sources/Features/Profile/UserRowView.swift`

**Interfaces:**
- Consumes: Completed row-owned lifecycle implementation.
- Produces: A compiling implementation commit containing only the two intended Swift files.

- [ ] **Step 1: Verify authoritative reconciliation and row failure boundaries**

```bash
python3 -c "from pathlib import Path; list_source=Path('Sources/Features/Profile/UserListView.swift').read_text(); row_source=Path('Sources/Features/Profile/UserRowView.swift').read_text(); assert 'authoritativeUserFetcher' in list_source; assert 'publishUserIds' in list_source; assert 'onLoadFailed?(userId)' in row_source; assert 'fansList' not in row_source; assert 'followingList?.removeAll' not in row_source; print('PASS: reconciliation preserved and row failure stays local')"
```

Expected: `PASS: reconciliation preserved and row failure stays local`.

- [ ] **Step 2: Check formatting and scope**

```bash
git diff --check
git diff --name-only
```

Expected: no whitespace errors. The implementation diff contains the two Swift files plus the user's pre-existing Xcode project, scheme, and workspace-state changes; only the Swift files will be staged.

- [ ] **Step 3: Build the dependency-aware workspace**

```bash
xcodebuild -quiet -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TweetCodexRowOwnedUserLoadingDerived CODE_SIGNING_ALLOWED=NO build
```

Expected: exit code 0. Existing third-party or run-script warnings are acceptable; Swift compilation errors are not.

- [ ] **Step 4: Stage only the implementation files**

```bash
git add Sources/Features/Profile/UserListView.swift Sources/Features/Profile/UserRowView.swift
git diff --cached --check
git diff --cached --name-only
```

Expected staged files:

```text
Sources/Features/Profile/UserListView.swift
Sources/Features/Profile/UserRowView.swift
```

- [ ] **Step 5: Commit**

```bash
git commit -m "fix: make profile user rows own loading"
```
