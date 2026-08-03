# Idempotent Favorite and Bookmark Implementation Plan

> **For agentic workers:** Execute inline in the current session. Do not dispatch subagents for this coordinated backend/client change.

**Goal:** Make favorite and bookmark mutations honor an explicit desired state, remain backward compatible with legacy toggle callers, and avoid same-node synchronization delays.

**Architecture:** `TweetBackendApp` accepts optional `isfavorite` and `isbookmarked` parameters on the existing endpoints. When present, the backend sets that state idempotently; when absent, it preserves legacy toggle behavior. iOS passes the desired state explicitly and uses a 60-second writable-client timeout, while same-node backend calls skip redundant content synchronization.

**Tech Stack:** Leither MApp JavaScript, Swift 6, Hprose RPC

## Global Constraints

- Preserve the invariants in `TweetBackendApp/docs/LEITHER_DATA_AND_SYNC_CONTRACT.md`.
- Do not run tests unless the user explicitly asks.
- Preserve unrelated changes in every working tree.
- Keep Android and Web compatible through the legacy no-parameter toggle path.

---

### Task 1: Make backend tweet mutations desired-state aware

**Files:**
- Modify: `/Users/cfa532/Documents/GitHub/TweetBackendApp/toggle_favorite.js`
- Modify: `/Users/cfa532/Documents/GitHub/TweetBackendApp/toggle_bookmark.js`

**Interfaces:**
- Consumes: optional `request.isfavorite` / `request.isbookmarked` boolean or string
- Produces: the existing `{ success: true, user, tweet }` response without changing legacy callers

- [x] **Step 1: Parse the optional desired state**

Use `Object.prototype.hasOwnProperty.call(request, field)` to distinguish a new desired-state request from a legacy toggle request. Parse `true` and `"true"` as enabled.

- [x] **Step 2: Set or toggle the tweet interaction**

When the optional state is present, add or remove the user only when current state differs. When it is absent, invert current state exactly as before. Skip tweet backup, publish, and score updates for a no-op retry.

- [x] **Step 3: Preserve desired state across node delegation**

Build the delegated request as an object and add the optional state only when the original request supplied it.

- [x] **Step 4: Mark same-node user updates**

Pass `skipcontentsync: userHostId === nodeId` to the corresponding `*_by_user` operation so a tweet already present on the user’s node is not synchronized and provided again.

### Task 2: Make backend user-list updates retry-safe

**Files:**
- Modify: `/Users/cfa532/Documents/GitHub/TweetBackendApp/toggle_favorite_by_user.js`
- Modify: `/Users/cfa532/Documents/GitHub/TweetBackendApp/toggle_bookmark_by_user.js`

**Interfaces:**
- Consumes: required desired interaction state plus optional `skipcontentsync`
- Produces: unchanged updated-user response

- [x] **Step 1: Forward `skipcontentsync` during delegation**

Parse boolean and string forms, then include the normalized boolean in remote requests.

- [x] **Step 2: Detect no-op updates**

Compare the requested state with the existing hash entry. Only mutate, back up, publish, update score, and synchronize content when the state actually changes.

- [x] **Step 3: Skip redundant same-node content work**

Run `MiMeiSync` and `MiMeiProvide` only when the interaction changed to enabled and `skipcontentsync` is false.

### Task 3: Send desired state from iOS

**Files:**
- Modify: `Sources/Core/HproseInstance.swift`
- Modify: `Sources/Tweet/TweetActionButtonsView.swift`
- Modify: `Sources/Tweet/UIKit/TweetActionBarView.swift`

**Interfaces:**
- Produces: `toggleFavorite(_:isFavorite:)` and `toggleBookmark(_:isBookmarked:)`

- [x] **Step 1: Add explicit desired-state parameters**

Include `isfavorite` or `isbookmarked` in the RPC parameters and retain writable-node routing. Request the pooled 60-second timeout class without mutating the client.

- [x] **Step 2: Update SwiftUI callers**

Compute the desired state before optimistic mutation and pass it explicitly to the RPC.

- [x] **Step 3: Update UIKit callers**

Pass `!wasFavorite` and `!wasBookmarked` from the existing optimistic handlers.

### Task 4: Static verification

- [x] **Step 1: Validate backend syntax**

Run `node --check` for the four backend JavaScript files.

- [x] **Step 2: Validate Swift syntax**

Run `xcrun swiftc -parse` for the three modified Swift files.

- [x] **Step 3: Review compatibility and diffs**

Run `git diff --check` in both projects and confirm every iOS caller supplies desired state while legacy Android/Web requests remain accepted.
