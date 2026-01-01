# fetchUser and Retry Logic Implementation Guide

## Overview

This document describes the architecture and implementation pattern for `fetchUser` with intelligent retry logic, IP resolution, and server health checking. This pattern ensures resilient user data fetching across distributed backend nodes with automatic failover.

## Key Design Principles

### 1. **Single Source of Truth for Health Checking**
- All server health checking and IP resolution logic is centralized in `getProviderIP()`
- Avoid duplicating health checks across different code paths
- Let `getProviderIP()` handle appUser health management automatically

### 2. **Separation of Concerns**
```
fetchUser()                    → Entry point, cache checking, deduplication
  └─> performUserUpdate()      → Retry loop, error handling
       └─> resolveAndUpdateBaseUrl() → IP resolution per attempt
            └─> getProviderIP() → Health checking, fallback logic
```

### 3. **Progressive Fallback Strategy**
1. Use cached data if available and fresh
2. Use existing user.baseUrl on first attempt
3. On retry, resolve fresh IP via `getProviderIP()`
4. `getProviderIP()` internally handles appUser health checks

## Architecture

### Component Responsibilities

#### `fetchUser()` - Entry Point
**Responsibilities:**
- Validate input (reject GUEST_ID)
- Check blacklist (users with repeated failures)
- Return cached data if valid
- Handle background refresh for expired cache
- Deduplicate concurrent requests for same user
- Delegate actual fetch to `performUserUpdate()`

**Key Features:**
```swift
func fetchUser(
    _ userId: String,
    baseUrl: String = "",          // Empty = force IP resolution
    maxRetries: Int = 2,
    forceRefresh: Bool = false,    // Skip cache check
    skipRetryAndBlacklist: Bool = false  // For internal retries
) async throws -> User?
```

#### `performUserUpdate()` - Retry Orchestration
**Responsibilities:**
- Execute retry loop (typically 2 attempts)
- Call `resolveAndUpdateBaseUrl()` before each attempt
- Make server call via hproseClient
- Process response and handle errors
- Manage blacklist on final failure

**Retry Logic:**
```swift
for attempt in 1...maxRetries {
    // 1. Resolve/update baseUrl for this attempt
    try await resolveAndUpdateBaseUrl(...)
    
    // 2. Make server call
    let rawResponse = hproseClient.invoke("runMApp", ...)
    
    // 3. Process response
    let success = try await processUserDataResponse(...)
    if success { return user }
    
    // 4. On failure, clear baseUrl and retry
    user.baseUrl = nil
}
```

#### `resolveAndUpdateBaseUrl()` - IP Resolution Strategy
**Responsibilities:**
- Determine if IP resolution is needed for this attempt
- Apply different strategies for first vs retry attempts
- Delegate to `getProviderIP()` for actual resolution

**Logic Flow:**
```swift
// First attempt: use existing baseUrl if available
if attempt == 1 && userHasBaseUrl && !forceFreshIP {
    return  // Use existing baseUrl
}

// Retry attempts: always get fresh IP
if attempt > 1 {
    let providerIP = try await getProviderIP(user.mid)
    user.baseUrl = URL(string: providerIP)
}

// First attempt when forcing fresh IP
else {
    let providerIP = try await getProviderIP(user.mid)
    user.baseUrl = URL(string: providerIP)
}
```

#### `getProviderIP()` - Health Checking & Fallback
**Responsibilities:**
- Attempt to get provider IP using `appUser.hproseClient`
- Check appUser server health if initial lookup fails
- Automatically refresh appUser IP if unhealthy
- Fall back to entry IP discovery as last resort

**Internal Logic:**
```swift
func getProviderIP(_ mid: String) async throws -> String? {
    // 1. Try lookup using appUser's client
    if let ip = await _getProviderIP(mid, hproseClient: appUser.hproseClient) {
        return ip
    }
    
    // 2. If user IS appUser, use entry IP
    if mid == appUser.mid {
        let entryIP = try await findEntryIP()
        return await _getProviderIP(mid, hproseClient: entryIPClient)
    }
    
    // 3. If user is NOT appUser, check appUser health
    if !await isServerHealthy(appUser.hproseClient) {
        // Refresh appUser's IP via entry
        let entryIP = try await findEntryIP()
        let newIP = await _getProviderIP(appUser.mid, hproseClient: entryIPClient)
        appUser.baseUrl = URL(string: newIP)
    }
    
    // 4. Try again with refreshed appUser
    return await _getProviderIP(mid)
    
    // 5. Still failing? Try entry IP as last resort
    let entryIP = try await findEntryIP()
    return await _getProviderIP(mid, hproseClient: entryIPClient)
}
```

## Why This Pattern Works

### 1. **Eliminates Redundant Node Comparison**

**❌ Old Pattern (Redundant):**
```swift
if attempt > 1 {
    if user.hostIds[1] == appUser.hostIds[1] {
        // Same node: check appUser health manually
        if await isServerHealthy(appUser.hproseClient) {
            // Use appUser's baseUrl
        } else {
            // Refresh appUser manually
            try await refreshAppUser()
            // Then call getProviderIP
        }
    } else {
        // Different node: call getProviderIP
    }
}
```

**✅ New Pattern (Simplified):**
```swift
if attempt > 1 {
    // getProviderIP handles ALL cases internally:
    // - appUser health checking
    // - Same/different node logic
    // - Automatic refresh if needed
    let providerIP = try await getProviderIP(user.mid)
}
```

**Why it's redundant:**
- Both paths end up calling `getProviderIP(user.mid)`
- `getProviderIP` uses `appUser.hproseClient` by default
- Health checking happens inside `getProviderIP` anyway
- Node location doesn't matter since we're using appUser's client

### 2. **Centralized Health Management**

All health-related decisions happen in one place (`getProviderIP`):
- Server reachability testing
- Automatic fallback to entry IP
- AppUser IP refresh when needed
- Retry with different entry points

### 3. **Clean Separation of Concerns**

```
Cache Layer     → fetchUser() handles caching, deduplication
Retry Layer     → performUserUpdate() handles retry loop
Resolution      → resolveAndUpdateBaseUrl() decides when to resolve
Health Layer    → getProviderIP() handles all health checks
```

## Implementation Guidelines

### When to Force Fresh IP Resolution

Pass empty `baseUrl` parameter to force IP resolution:
```swift
// During login - ensure we get a healthy IP
let user = try await fetchUser(userId, baseUrl: "")

// Normal fetch - use cached baseUrl
let user = try await fetchUser(userId)
```

### Error Handling Strategy

1. **Transient Errors:** Retry with fresh IP
2. **Null Response:** Clear baseUrl, retry triggers new IP resolution
3. **Repeated Failures:** Add to blacklist after maxRetries
4. **Network Errors:** Log, retry with delay

### Cache Strategy

```swift
// Return stale cache while refreshing in background
if cachedUser.hasExpired && !baseUrl.isEmpty {
    Task {
        await startBackgroundRefresh(userId)
    }
    return cachedUser  // Return stale data immediately
}

// During login (baseUrl empty), don't return stale data
if baseUrl.isEmpty && hasExpired {
    // Fall through to fetch fresh data
}
```

### Deduplication Pattern

Prevent concurrent fetches for the same user:
```swift
private var ongoingUserUpdates: Set<String> = []
private let userUpdateQueue = DispatchQueue(label: "user.update.queue")

// Check and mark as in-progress atomically
let shouldProceed = userUpdateQueue.sync {
    guard !ongoingUserUpdates.contains(userId) else { return false }
    ongoingUserUpdates.insert(userId)
    return true
}

// Clean up in defer block
defer {
    userUpdateQueue.sync {
        ongoingUserUpdates.remove(userId)
    }
}
```

## Testing Scenarios

### Scenario 1: Normal Fetch (Cache Hit)
```
1. Check cache → found, not expired
2. Return cached user
Result: No network call
```

### Scenario 2: First Fetch (No Cache)
```
1. Check cache → not found
2. Attempt 1: resolveAndUpdateBaseUrl()
   - Call getProviderIP(userId)
   - Set user.baseUrl
3. Make server call → success
4. Save to cache
Result: 1 network call
```

### Scenario 3: Retry After Failure
```
1. Attempt 1: Server call fails
2. Attempt 2: resolveAndUpdateBaseUrl()
   - Call getProviderIP(userId) for fresh IP
   - getProviderIP checks appUser health
   - If unhealthy, refreshes appUser first
   - Returns new IP for user
3. Make server call with new IP → success
Result: 2 network calls (initial + retry)
```

### Scenario 4: appUser Server Unhealthy
```
1. Attempt 2: Call getProviderIP(userId)
2. Initial lookup fails
3. Check appUser health → unhealthy
4. getProviderIP internally:
   - Discovers entry IP
   - Resolves appUser's new IP
   - Updates appUser.baseUrl
   - Retries lookup for userId
5. Returns fresh IP
Result: Automatic recovery without explicit node checking
```

## Key Takeaways

1. **Don't duplicate health checks** - `getProviderIP` is the single source of truth
2. **Node location doesn't matter** - Both same/different node use appUser's client
3. **Let getProviderIP handle complexity** - It has all the fallback logic built-in
4. **Keep retry logic simple** - Just call getProviderIP on retry attempts
5. **Separate concerns** - Cache, retry, resolution, and health are independent layers

## Anti-Patterns to Avoid

❌ **Checking node location in retry logic**
- `getProviderIP` already uses `appUser.hproseClient` by default
- Node comparison adds no value

❌ **Manually refreshing appUser before getProviderIP**
- `getProviderIP` does this internally when needed
- Creates duplicate health checks

❌ **Different code paths for same/different nodes**
- Both end up using appUser's client
- Increases complexity without benefit

❌ **Skipping getProviderIP's internal logic**
- It has sophisticated fallback strategies
- Replicating them creates maintenance burden

## Health Check Fallback Strategy

### Critical Fix: Unhealthy IP Handling

**Previous behavior (problematic):**
```swift
// _getProviderIP would return unhealthy IP as fallback
if !ipAddresses.isEmpty {
    return ipAddresses[0]  // Even if all health checks failed
}
```

**Problem:**
- When all IPs failed health checks, `_getProviderIP` returned the first IP anyway
- `getProviderIP` saw non-nil result and returned immediately
- Entry IP fallback logic never triggered
- Caller used unhealthy IP → failed again → user blacklisted

**Current behavior (fixed):**
```swift
// _getProviderIP returns nil when all health checks fail
if !ipAddresses.isEmpty {
    return nil  // Triggers entry IP fallback in getProviderIP
}
```

**Benefits:**
1. Triggers `getProviderIP`'s entry IP fallback (lines 1495-1510)
2. Entry IP can discover healthy alternative routes
3. Only fails if both provider IPs AND entry IP fail
4. Prevents repeated use of known-bad IPs

### Fallback Chain

When fetching a user's provider IP:

```
1. Try user's IPs with health checks (_getProviderIP with appUser client)
   ├─ If any IP healthy → return it ✓
   └─ If all unhealthy → return nil

2. getProviderIP receives nil, checks if user is appUser
   ├─ If user IS appUser → use entry IP to lookup appUser's IPs
   └─ If user is NOT appUser → check appUser health

3. For non-appUser: Check appUser health
   ├─ If appUser UNHEALTHY:
   │  ├─ Refresh appUser via entry IP
   │  ├─ Update appUser.baseUrl with new IP
   │  └─ Retry _getProviderIP(userId) with refreshed appUser
   │
   └─ If appUser HEALTHY:
      └─ Return nil (no entry IP fallback needed)

4. Result handling
   └─ nil means all user's IPs are genuinely unhealthy
      └─ Caller handles error appropriately
```

**Key Insight:** When appUser is healthy, we **do NOT try entry IP fallback**. This is because:
- AppUser successfully responded with the user's IP list
- All those IPs failed health checks (they are genuinely unhealthy)
- Entry IP would return the **same list** of unhealthy IPs
- No point in redundant lookup - the user's servers are simply down
- Let the caller handle the failure appropriately (cache, retry later, etc.)

### Example Scenario: Healthy appUser, User's Servers Down

```
Scenario: Fetching user "6ESd5eGrbz2zzlrUdYPXBJV16bP" 
AppUser server is healthy, but target user's servers are all down

Step 1: _getProviderIP via appUser client
  - Query appUser's server for user's IPs
  - Server responds: [122.231.91.212:8002, IPv6-address:8002]
  - Health checks: Both fail ❌ (user's servers are down)
  - Returns: nil (triggers fallback logic)

Step 2: getProviderIP checks appUser health
  - appUser server: HEALTHY ✓
  - appUser server successfully responded with IP list
  - The problem is with the target user's IPs, not our lookup ability

Step 3: No entry IP fallback
  - Since appUser is healthy and responded, we have the authoritative answer
  - Entry IP would return the same unhealthy IPs
  - Return nil to indicate all user's IPs are unreachable

Step 4: Caller handles gracefully
  - Return cached user data if available
  - Add user to blacklist temporarily
  - Let user retry later when servers recover

Result: Clean failure handling without redundant entry IP lookup
```

**When Entry IP Fallback IS Used:**
- User IS appUser (need entry IP to bootstrap)
- AppUser is UNHEALTHY (need entry IP to refresh appUser first)

**When Entry IP Fallback is NOT Used:**
- AppUser is HEALTHY (we already have authoritative routing info)
- The target user's IPs are simply unreachable (no alternative route exists)

This ensures maximum resilience against:
- Temporary network issues
- Server downtime
- Stale IP caches
- Node failures

## Conclusion

The simplified retry pattern leverages `getProviderIP()`'s built-in intelligence to handle all scenarios uniformly. By eliminating redundant node comparison and manual appUser health management, and by ensuring unhealthy IPs trigger proper fallback logic, we achieve:

- **Simpler code** - 50+ lines removed from retry logic
- **Single source of truth** - All health logic in getProviderIP
- **Better maintainability** - Fewer code paths to test
- **Robust fallback** - Unhealthy IPs trigger entry IP fallback instead of retry with same bad IP
- **Same reliability** - All edge cases still handled correctly

This pattern should be used as a reference for any similar distributed system operations that require intelligent failover and health checking.

## Issue 1 Fix: CancellationError Handling

### Problem
When user lists load many users simultaneously (e.g., followers screen with 30+ users), if the user navigates away quickly, ongoing fetch tasks get cancelled. Previously, `CancellationError` was logged as a failure and counted toward retry attempts:

```
ERROR: [fetchUser] USER UPDATE FAILED: userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv, attempt: 1/2
DEBUG: [fetchUser] Exception in fetchUser: userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv, error: CancellationError()
⚠️ [UserRowView] fetchUser failed after retries - removing row
```

### Solution
Detect and handle `CancellationError` early in the catch block:
- Don't log as ERROR (use DEBUG instead)
- Don't retry (propagate immediately)
- Don't add to blacklist
- Don't increment failure counters

```swift
} catch {
    // Handle cancellation specially - don't log as failure, don't retry
    if error is CancellationError {
        print("DEBUG: [\(logPrefix)] Fetch cancelled for userId: \(user.mid), attempt: \(attempt)/\(maxRetries)")
        throw error // Propagate cancellation immediately
    }
    
    // ... rest of error handling for real failures
}
```

### Benefits
- Cleaner logs (no false ERROR messages)
- Faster cancellation (no retry delays)
- Better UX (cancelled fetches don't pollute blacklist)
- Accurate failure metrics (only real failures counted)

## NodePool Architecture: Persistent Authoritative Source

### Overview
The `User` object has a `hostIds` array:
- **Item 0**: Writable host (for WRITE operations - posting tweets, updating profile)
- **Item 1**: Access node (for READ operations - viewing user data, loading profiles)
- Backend keeps user objects in sync across nodes

**Key Principle**: 
- The NodePool **only tracks hostIds[1]** (access node) for read operations
- hostIds[0] (writable host) is not the pool's concern - only used for write operations
- Nodes persist indefinitely and maintain arrays of valid IPs (IPv4 and IPv6)

### Architecture

```swift
/// Persistent pool of nodes with multiple IP addresses
class NodePool {
    private var nodes: [String: NodeInfo] = [:]  // [nodeMID: NodeInfo]
    
    struct NodeInfo {
        let mid: String       // Node MID
        var ips: [String]     // Array of valid IPs (IPv4 and IPv6)
        var lastUpdate: Date  // When IPs were last updated
        
        func hasIP(_ ip: String) -> Bool
        func getPreferredIP() -> String?  // Prefers IPv4 over IPv6
    }
}
```

### Access Flow

**Before accessing any user resource:**

1. **Validate user's IP against pool**
   ```swift
   if NodePool.shared.isUserIPValid(for: user) {
       // User's baseUrl is in pool, proceed with access
       return
   }
   ```

2. **Get IP from user's access node in pool**
   ```swift
   if let poolIP = NodePool.shared.getIPFromNode(for: user) {
       // Use IP from pool (uses access node - hostIds[1])
       user.baseUrl = URL(string: poolIP)
   }
   ```

3. **On failure: Re-resolve and update pool**
   ```swift
   // Fetch failed, resolve fresh IP
   let newIP = try await getProviderIP(user.mid)
   
   // Success: Replace access node's IP list with new IP
   if let accessNodeMid = user.hostIds?[1] {
       NodePool.shared.updateNodeIP(nodeMid: accessNodeMid, newIP: newIP)
   }
   ```

### Implementation Status: ✅ COMPLETE

#### What Was Implemented

1. **NodePool Class** (`Sources/Core/NodePool.swift`)
   - Persistent storage (no pruning)
   - Multiple IPs per node (IPv4 and IPv6)
   - Thread-safe operations with concurrent dispatch queue
   - IP validation: `isUserIPValid(for:)`
   - IP retrieval: `getIPFromNode(for:)`
   - IP updates: `updateNodeIP(nodeMid:newIP:)` replaces IP list
   - IP additions: `addIPToNode(nodeMid:ip:)` adds to existing list

2. **Integration with fetchUser Flow**
   - `resolveAndUpdateBaseUrl` validates user IP against pool first
   - If not in pool, gets IP from pool before calling `getProviderIP`
   - On successful fetch, calls `updateFromUser` to add IPs to pool
   - On failure and re-resolution, replaces node's IP list

3. **Smart Routing**
   - Only uses access node (hostIds[1]) for read operations
   - hostIds[0] (writable host) not tracked in pool - only for writes
   - IPv4 preferred over IPv6 for better compatibility

#### Key Features

```swift
// 1. Validate before access
if NodePool.shared.isUserIPValid(for: user) {
    // Proceed - user's IP is in pool
} else {
    // Get fresh IP from pool or re-resolve
}

// 2. Get IP from user's node
if let ip = NodePool.shared.getIPFromNode(for: user) {
    user.baseUrl = URL(string: "http://\(ip)")
}

// 3. Update pool on re-resolution (replaces IP list)
NodePool.shared.updateNodeIP(nodeMid: nodeMid, newIP: newIP)

// 4. Add discovered IPs (doesn't replace)
NodePool.shared.updateFromUser(user)
```

#### Benefits Realized

- 🏆 **Authoritative source**: Pool is more reliable than user's cached IP
- ⚡ **Reduced latency**: Validation is instant (no network call)
- 🌐 **Multi-IP support**: Each node can have IPv4 and IPv6 addresses
- 🔄 **Self-correcting**: Failed IPs trigger re-resolution and pool update
- 💾 **Persistent**: Nodes never pruned, knowledge accumulates over time
- 🎯 **Smart routing**: Respects backend's hostIds architecture

### Example Flow

**First fetch for a user:**
```
1. User has baseUrl: http://[240e:...]:8081
2. Check pool → not found
3. Get IP from pool → not found (pool empty)
4. Call getProviderIP → returns 125.229.161.122:8080
5. Fetch succeeds
6. updateNodeIP → pool now has node with [125.229.161.122:8080]
```

**Subsequent fetch:**
```
1. User has baseUrl: http://125.229.161.122:8080
2. Check pool → found! ✅
3. Proceed immediately (no getProviderIP call)
```

**Failed access:**
```
1. User has baseUrl: http://old-ip:8080
2. Check pool → not found (IP changed)
3. Get IP from pool → returns 125.229.161.122:8080
4. Fetch succeeds
5. addIPToNode → pool now has [old-ip:8080, 125.229.161.122:8080]
```

**Failed access + re-resolution:**
```
1. Fetch fails with IP from pool
2. Call getProviderIP → returns new-ip:8080
3. Fetch succeeds
4. updateNodeIP → pool IP list REPLACED: [new-ip:8080]
```

## Resource Management: Foreground Recovery

### Problem
When the app goes to background for an extended period (especially with overlays like share sheets or detail views active), iOS can reclaim memory by releasing resources:
- **Images**: `UIImage` objects released from memory
- **Videos**: `AVPlayerItem` objects released by the system

When the app returns to foreground, these resources remain nil and don't automatically reload because:
- `.onAppear` doesn't fire again (views are still "visible")
- Share sheet or detail view is still active
- Users see blank images or stuck video spinners

### Solution: Foreground Notification Observers

Each image-displaying view now sets up a notification observer to detect foreground return and reload released resources.

#### Implementation Pattern

**1. Add State Variable**
```swift
@State private var foregroundObserver: NSObjectProtocol? = nil
```

**2. Setup in `.onAppear`**
```swift
.onAppear {
    // ... existing load logic ...
    setupForegroundObserver()
}
```

**3. Cleanup in `.onDisappear`**
```swift
.onDisappear {
    // Clean up observer
    if let observer = foregroundObserver {
        NotificationCenter.default.removeObserver(observer)
        foregroundObserver = nil
    }
}
```

**4. Observer Implementation**
```swift
private func setupForegroundObserver() {
    guard attachment.type == .image else { return }
    guard foregroundObserver == nil else { return } // Avoid duplicates
    
    foregroundObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
    ) { _ in
        // Only reload if image was released
        guard self.image == nil else { return }
        
        print("DEBUG: [View] App returned to foreground, image released - reloading")
        self.loadImage()
    }
}
```

**Important**: Do NOT use `[weak self]` capture list - SwiftUI Views are structs (value types), not classes, and cannot be captured weakly. The observer is properly cleaned up in `.onDisappear`, preventing memory leaks.

#### Views Implementing Resource Reloading

1. **MediaCell** (`Sources/Features/MediaViews/MediaCell.swift`)
   - Tweet list images
   - Only reloads if cell is visible: `guard self.isVisible, self.image == nil`

2. **DetailMediaCell** (`Sources/Tweet/TweetDetailView.swift`)
   - Full-size detail view images
   - Reloads for visible detail images

3. **ChatImageThumbnail** (`Sources/Features/Chat/ChatMessageView.swift`)
   - Chat message images
   - Reloads released thumbnails

4. **TweetActionButtonsView** (`Sources/Tweet/TweetActionButtonsView.swift`)
   - Share sheet preview images
   - Only regenerates if share sheet is active: `guard self.shareSheetItems != nil`
   - Regenerates preview and updates share sheet with new items

#### Video Recovery

Videos already have comprehensive foreground recovery through:
- `SimpleVideoPlayer.recoverFromBackground()` - Detects broken players, reloads if needed
- `FullScreenVideoManager` / `DetailVideoManager` - Singleton managers handle app lifecycle
- Delayed health checks - Catches players that appear healthy but are actually broken

Videos don't need the observer pattern because:
- They have active playback state that needs continuous monitoring
- Recovery is more complex (state restoration, seek positions, playback status)
- Singleton managers already listen to app lifecycle notifications

### Example Scenario: Share Sheet Recovery

**Sequence:**
```
1. User taps share button
   - Preview image generated
   - Share sheet opens

2. User switches to another app (long background)
   - iOS reclaims memory
   - Preview image released (image = nil)
   - Share sheet still active

3. User returns to app
   - willEnterForegroundNotification fires
   - Observer detects shareSheetItems != nil
   - Observer checks attachmentPreviewImage == nil
   - Regenerates preview
   - Updates share sheet with new items

4. User completes share
   - Share sheet dismissed
   - Observer cleaned up in onDisappear
```

### Benefits

- ✅ **Seamless UX**: Images reload automatically, no user action needed
- ✅ **Efficient**: Only reloads if resource was actually released (`image == nil`)
- ✅ **Context-aware**: Share sheet only reloads if still active
- ✅ **No memory leaks**: Observers properly cleaned up in view lifecycle
- ✅ **Works with overlays**: Share sheets, detail views, login sheets all handled

### Testing

To test resource recovery:
1. Open app with image-heavy content
2. Open share sheet (for preview testing)
3. Switch to another app
4. Wait 5+ minutes (or use Xcode memory pressure)
5. Return to app
6. Verify images reload automatically
7. Verify share sheet preview regenerates

This ensures users never see blank images or broken share sheets after returning from background.

## Profile Backend Call Optimization

### Overview
ProfileView has been optimized to eliminate redundant `get_user` backend calls that were occurring when users opened profile screens.

### Changes Implemented

#### 1. Fixed Double Trigger Issue
The view lifecycle was causing `.task` to trigger twice:
- Once when view appeared
- Again when `profileRefreshCounter` was incremented in `.onAppear`

**Solution:**
- Changed `.task(id:)` from `profileRefreshCounter` to `user.mid`
- Added guard to only fetch if `!didLoad`
- Simplified state management

#### 2. Session-Based Resync Optimization
`resyncUser()` is a long-running operation that updates server-side state. It now only runs once per app session per user.

**Implementation:**
```swift
private static var resyncedUsersThisSession: Set<String> = []
private static let resyncLock = NSLock()
```

**Benefits:**
- First profile view per session: Calls `get_user` + `resync_user`
- Subsequent views: Only calls `get_user` (fast refresh)
- ~50% reduction in backend calls for frequently viewed profiles

### Results
- **Before**: 2+ backend calls per profile view
- **After**: 1-2 backend calls (2 only on first view per session)

### Documentation
For complete details on the profile optimization, see:
- `docs/fixes/PROFILE_BACKEND_CALL_OPTIMIZATION.md` - Comprehensive iOS and Android optimization guide

### Integration with fetchUser
The ProfileView optimization works seamlessly with the `fetchUser` retry logic:
- ProfileView controls WHEN to fetch (lifecycle management)
- `fetchUser` controls HOW to fetch (retry logic, health checks, failover)
- Clear separation of concerns ensures maintainable code

