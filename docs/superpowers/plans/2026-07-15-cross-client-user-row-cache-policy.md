# Cross-Client User Row Cache Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make follower/following rows on iOS and Android honor the existing 30-minute user-cache policy while retaining forced user refresh when a profile opens.

**Architecture:** iOS will remove the row-specific forced fetch and use the existing `HproseInstance.fetchUser` stale-while-revalidate behavior. Android already has the matching behavior in its current worktree: list prefetch calls ordinary `fetchUser(id)`, while the in-progress profile-opening path validates the route and performs a forced refresh. Preserve those Android edits and verify them rather than adding duplicate state or another cache policy.

**Tech Stack:** Swift 6, SwiftUI, Kotlin, Jetpack Compose, coroutines, Gradle

## Global Constraints

- Keep the existing 30-minute user-cache lifespan unchanged on both clients.
- Fresh cached rows must not issue `get_user` requests.
- Expired cached rows must remain renderable while a deduplicated background refresh runs.
- Uncached rows must retain their existing loading and failure behavior.
- Opening an actual user profile must continue to force-refresh the user after route validation.
- Do not overwrite or stage unrelated existing iOS project/scheme changes or Android route-validation/profile-loading changes.
- Keep routine reads distinct from explicit synchronization and recovery APIs.

---

### Task 1: Make iOS Cached Rows Use the Shared Cache Policy

**Files:**
- Modify: `Sources/Features/Profile/UserRowView.swift:376-390`
- Verify: `Sources/Features/Profile/ProfileView.swift:735-750`

**Interfaces:**
- Consumes: `HproseInstance.fetchUser(_:baseUrl:maxRetries:forceRefresh:skipRetryAndBlacklist:v4Only:refreshExpiredCacheInBackground:) async throws -> User?`
- Produces: Cached-row loading through the default `fetchUser(userId)` policy; no new public interface.

- [ ] **Step 1: Run the policy assertion and verify the current row violates it**

Run:

```bash
python3 -c 'from pathlib import Path; s=Path("Sources/Features/Profile/UserRowView.swift").read_text(); block=s[s.index("DEBUG: [UserRowView] Refreshing cached user"):s.index("} catch is CancellationError", s.index("DEBUG: [UserRowView] Refreshing cached user"))]; assert "forceRefresh: true" not in block'
```

Expected: FAIL with `AssertionError`, proving the cached-row branch still forces refresh.

- [ ] **Step 2: Replace the forced cached-row call with the ordinary cache-aware call**

Change only the cached-row refresh operation to:

```swift
print("DEBUG: [UserRowView] Refreshing expired cached user if needed: \(userId)")
return try await hproseInstance.fetchUser(userId)
```

Keep route preparation, cancellation checks, `UserRowLoadGate`, cached rendering, and failure fallback unchanged.

- [ ] **Step 3: Run the focused policy assertions**

Run:

```bash
python3 -c 'from pathlib import Path; row=Path("Sources/Features/Profile/UserRowView.swift").read_text(); block=row[row.index("DEBUG: [UserRowView] Refreshing expired cached user if needed"):row.index("} catch is CancellationError", row.index("DEBUG: [UserRowView] Refreshing expired cached user if needed"))]; assert "fetchUser(userId)" in block; assert "forceRefresh: true" not in block; profile=Path("Sources/Features/Profile/ProfileView.swift").read_text(); assert "forceRefresh: true" in profile'
```

Expected: exit 0 with no output.

- [ ] **Step 4: Review the iOS diff for coherent scope**

Run:

```bash
git diff --check -- Sources/Features/Profile/UserRowView.swift
git diff -- Sources/Features/Profile/UserRowView.swift
```

Expected: no whitespace errors and a diff limited to the cached-row fetch/log statement.

### Task 2: Verify Android Matches the Same Boundary

**Files:**
- Verify existing worktree: `/Users/cfa532/Documents/GitHub/Tweet/app/src/main/java/us/fireshare/tweet/viewmodel/UserViewModel.kt:160-285`
- Verify existing worktree: `/Users/cfa532/Documents/GitHub/Tweet/app/src/main/java/us/fireshare/tweet/viewmodel/UserViewModel.kt:1015-1045`
- Verify cache: `/Users/cfa532/Documents/GitHub/Tweet/app/src/main/java/us/fireshare/tweet/HproseInstance.kt:4314-4370`

**Interfaces:**
- Consumes: `HproseInstance.fetchUser(userId, ..., forceRefresh = false): User?`
- Produces: Verified cross-client behavior; no Android production edit unless the asserted current worktree behavior is absent.

- [ ] **Step 1: Assert follower/following prefetch uses ordinary fetch**

Run from `/Users/cfa532/Documents/GitHub/Tweet`:

```bash
python3 -c 'from pathlib import Path; s=Path("app/src/main/java/us/fireshare/tweet/viewmodel/UserViewModel.kt").read_text(); block=s[s.index("private fun prefetchUsers"):s.index("fun getBookmarks", s.index("private fun prefetchUsers"))]; assert "fetchUser(id)" in block; assert "forceRefresh = true" not in block'
```

Expected: exit 0 with no output.

- [ ] **Step 2: Assert profile opening retains the forced refresh**

Run from `/Users/cfa532/Documents/GitHub/Tweet`:

```bash
python3 -c 'from pathlib import Path; s=Path("app/src/main/java/us/fireshare/tweet/viewmodel/UserViewModel.kt").read_text(); init=s[s.index("suspend fun initLoad"):s.index("fun refreshUserData", s.index("suspend fun initLoad"))]; refresh=s[s.index("private suspend fun refreshUserDataFromServer"):s.index("fun refreshPinnedTweets", s.index("private suspend fun refreshUserDataFromServer"))]; assert "validateAndRepairProfileRoute" in init; assert "refreshUserDataFromServer()" in init; assert "forceRefresh = true" in refresh'
```

Expected: exit 0 with no output.

- [ ] **Step 3: Confirm Android retains 30-minute stale-while-revalidate**

Run from `/Users/cfa532/Documents/GitHub/Tweet`:

```bash
python3 -c 'from pathlib import Path; cache=Path("app/src/main/java/us/fireshare/tweet/datamodel/TweetCacheManager.kt").read_text(); fetch=Path("app/src/main/java/us/fireshare/tweet/HproseInstance.kt").read_text(); assert "USER_CACHE_EXPIRATION_TIME = 30 * 60 * 1000L" in cache; assert "startBackgroundRefresh(" in fetch'
```

Expected: exit 0 with no output.

- [ ] **Step 4: Review Android without modifying or staging existing work**

Run:

```bash
git -C /Users/cfa532/Documents/GitHub/Tweet diff --check
git -C /Users/cfa532/Documents/GitHub/Tweet status --short
```

Expected: no whitespace errors. Existing modifications remain unstaged and intact.

### Task 3: Cross-Client Build and Final Review

**Files:**
- Verify: `Sources/Features/Profile/UserRowView.swift`
- Verify existing Android worktree: `/Users/cfa532/Documents/GitHub/Tweet`

**Interfaces:**
- Consumes: Completed iOS row-policy edit and existing Android cache/profile boundaries.
- Produces: Build evidence and final scoped diff review.

- [ ] **Step 1: Build the iOS app**

Run:

```bash
xcodebuild -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/Tweet-iOS-derived CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Compile Android Kotlin sources**

Run from `/Users/cfa532/Documents/GitHub/Tweet`:

```bash
./gradlew :app:compileFullDebugKotlin
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Run final policy assertions and diff checks**

Repeat the focused assertions from Tasks 1 and 2, then run:

```bash
git diff --check
git status --short
git -C /Users/cfa532/Documents/GitHub/Tweet diff --check
git -C /Users/cfa532/Documents/GitHub/Tweet status --short
```

Expected: all assertions and diff checks pass; the iOS production diff is limited to `UserRowView.swift`; existing unrelated modifications in both repositories remain preserved.

