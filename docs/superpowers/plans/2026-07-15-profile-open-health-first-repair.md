# Profile-Open Health-First Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render cached profile content immediately, probe the current read route once in the background, and then reload current server data through either the healthy cached route or a repaired route.

**Architecture:** Add one `HproseInstance` operation that freshly probes the current `User.baseUrl`, retains it when healthy, and otherwise removes the stale pooled route, resolves a replacement, and applies that replacement to the shared `User`. `ProfileView` invokes its existing user and pinned-tweet refresh after either outcome, and explicitly reloads profile tweets when repair changes the route.

**Tech Stack:** Swift 6, SwiftUI, URLSession HEAD health checks, NodePool

## Global Constraints

- Cached profile data must render before networking.
- A healthy current `baseUrl` is retained and used to refresh current server data.
- A health-check failure or timeout is authoritative evidence that the current IP is stale.
- A backend RPC timeout is not evidence that an IP is stale.
- TweetWeb and Android are out of scope.

---

### Task 1: Add profile-route health validation and repair

**Files:**
- Modify: `Sources/Core/HproseInstance.swift`
- Test: structural source checks plus iOS Simulator build

**Interfaces:**
- Consumes: `User.baseUrl`, `User.hostIds`, `isServerHealthyWithTimeout(_:timeout:useCache:)`, `getHostIP(_:v4Only:forceHealthCheck:)`, `getProviderIP(_:v4Only:)`, `applyBaseUrlIfNeeded(_:url:reason:)`
- Produces: `validateAndRepairProfileRoute(for:) async -> Bool`, where `true` means a healthy route is ready for profile-data refresh

- [ ] **Step 1: Verify the new operation is absent**

Run: `test "$(rg -c 'func validateAndRepairProfileRoute' Sources/Core/HproseInstance.swift)" -eq 1`

Expected: exit status 1.

- [ ] **Step 2: Implement the health-first operation**

Snapshot `mid`, `baseUrl`, and the read-node ID in one `MainActor.run`. Probe the normalized current route with `useCache: false`. Return `true` immediately when healthy. When unhealthy, remove the matching route from NodePool, resolve a replacement through the read node with forced health checking (falling back to provider discovery), apply the replacement to the shared user, and return `true`; return `false` only when no usable route is available or the task was cancelled.

- [ ] **Step 3: Verify the operation exists**

Run: `test "$(rg -c 'func validateAndRepairProfileRoute' Sources/Core/HproseInstance.swift)" -eq 1`

Expected: exit status 0.

### Task 2: Gate profile reload behind route repair

**Files:**
- Modify: `Sources/Features/Profile/ProfileView.swift`
- Test: structural source checks plus iOS Simulator build

**Interfaces:**
- Consumes: `validateAndRepairProfileRoute(for:) async -> Bool`
- Produces: `validateProfileRouteOnOpen() async`

- [ ] **Step 1: Verify profile opening still refreshes unconditionally**

Run: `rg -n 'await refreshProfileData\(resyncIfNeeded: false\)' Sources/Features/Profile/ProfileView.swift`

Expected: one match in the profile-open `.task`.

- [ ] **Step 2: Implement the cache-first profile-open gate**

Replace the `.task` call with `validateProfileRouteOnOpen()`. The helper calls `validateAndRepairProfileRoute`, refreshes server data whenever a healthy route is ready, and increments `profileTweetsRefreshToken` only when route repair changed the user's `baseUrl`.

- [ ] **Step 3: Verify the unconditional call is gone from `.task`**

Run: `rg -n 'validateProfileRouteOnOpen|validateAndRepairProfileRoute' Sources/Features/Profile/ProfileView.swift`

Expected: the `.task`, helper declaration, and repair call are present.

### Task 3: Verify behavior and compilation

**Files:**
- Review: `Sources/Core/HproseInstance.swift`
- Review: `Sources/Features/Profile/ProfileView.swift`

**Interfaces:**
- Consumes: completed Tasks 1 and 2
- Produces: verified iOS implementation

- [ ] **Step 1: Run source and whitespace checks**

Run: `git diff --check` and verify the healthy branch returns before `fetchUser` is called.

- [ ] **Step 2: Build Debug**

Run: `xcodebuild -quiet -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TweetCodexDerivedData CODE_SIGNING_ALLOWED=NO build`

Expected: exit status 0.

- [ ] **Step 3: Build Release**

Run: `xcodebuild -quiet -workspace Tweet.xcworkspace -scheme Tweet -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TweetCodexDerivedDataRelease CODE_SIGNING_ALLOWED=NO build`

Expected: exit status 0.
