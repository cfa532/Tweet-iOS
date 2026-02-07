# getProviderIP Flow - Complete Logic

## Overview
`getProviderIP(userId)` is responsible for finding a healthy IP address for any user with intelligent fallback logic.

> **📚 Related Documentation**: 
> - [NODEPOOL_STRATEGY.md](NODEPOOL_STRATEGY.md) - Human-friendly guide on NodePool usage
> - [FETCHUSER_RETRY_IMPLEMENTATION.md](FETCHUSER_RETRY_IMPLEMENTATION.md) - fetchUser architecture and retry logic

## Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ getProviderIP(userId)                                           │
└─────────────────────────────────────────────────────────────────┘
                           ↓
        ┌──────────────────────────────────────┐
        │ Safety Check: userId == GUEST_ID?    │
        └──────────────────────────────────────┘
                 ↓ No                  ↓ Yes
                                  [Throw Error]
                 ↓
        ┌──────────────────────────────────────┐
        │ Step 1: Try _getProviderIP(userId)   │
        │ Uses: appUser.hproseClient (default) │
        └──────────────────────────────────────┘
                 ↓
        ┌──────────────────────────────────────┐
        │ _getProviderIP Logic:                 │
        │ 1. Query server for user's IP list    │
        │ 2. Test each IP with health check     │
        │ 3. Return first healthy IP            │
        │ 4. If all fail → return nil           │
        └──────────────────────────────────────┘
                 ↓
        ┌──────────────────────────────────────┐
        │ Got healthy IP?                       │
        └──────────────────────────────────────┘
         ↓ Yes                          ↓ No
    [Return IP] ✓                       ↓
                              ┌──────────────────────┐
                              │ Step 2: Branch by    │
                              │ userId == appUser.mid│
                              └──────────────────────┘
                               ↓                    ↓
                    ┌──────────────────┐  ┌──────────────────────┐
                    │ Case A:          │  │ Case B:              │
                    │ userId IS appUser│  │ userId NOT appUser   │
                    └──────────────────┘  └──────────────────────┘
                               ↓                    ↓
                    ┌──────────────────┐  ┌──────────────────────┐
                    │ Use Entry IP     │  │ Check appUser health │
                    │ Fallback         │  └──────────────────────┘
                    └──────────────────┘            ↓
                               ↓          ┌──────────────────────┐
                    ┌──────────────────┐  │ appUserClient exists?│
                    │ findEntryIP()    │  └──────────────────────┘
                    └──────────────────┘   ↓ Yes          ↓ No
                               ↓       [Return nil]        
                    ┌──────────────────┐            
                    │ _getProviderIP(  │  ┌──────────────────────┐
                    │   appUser.mid,   │  │ isServerHealthy(     │
                    │   entryIPClient) │  │   appUserClient)?    │
                    └──────────────────┘  └──────────────────────┘
                               ↓           ↓ Healthy    ↓ Unhealthy
                         [Return IP                     ↓
                          or nil]        [Return nil]   ┌──────────────────────┐
                                         (User's IPs    │ Case B1: AppUser     │
                                          are down)     │ is UNHEALTHY         │
                                                        └──────────────────────┘
                                                                  ↓
                                                        ┌──────────────────────┐
                                                        │ 1. findEntryIP()     │
                                                        │ 2. Get appUser's IP  │
                                                        │    via entry client  │
                                                        │ 3. Update            │
                                                        │    appUser.baseUrl   │
                                                        └──────────────────────┘
                                                                  ↓
                                                        ┌──────────────────────┐
                                                        │ Retry:               │
                                                        │ _getProviderIP(      │
                                                        │   userId)            │
                                                        │ (with refreshed      │
                                                        │  appUser)            │
                                                        └──────────────────────┘
                                                                  ↓
                                                          [Return IP or nil]
```

## Step-by-Step Breakdown

### Step 1: Initial Attempt
```swift
let providerIP = await _getProviderIP(userId, v4Only: v4Only)
if providerIP != nil {
    return providerIP  // SUCCESS: Found healthy IP
}
// If nil, proceed to fallback logic
```

**What `_getProviderIP` does:**
1. Calls server API: `get_provider_ips` for userId
2. Receives IP list: `["122.231.91.212:8002", "IPv6:8002", ...]`
3. Tests each IP in parallel with health checks
4. Returns first healthy IP
5. **If all health checks fail → returns nil** (changed behavior!)

### Step 2A: User IS appUser (Bootstrap Case)
```swift
if userId == appUser.mid {
    // AppUser needs entry IP to bootstrap itself
    let entryIP = try await findEntryIP()
    return await _getProviderIP(appUser.mid, hproseClient: entryIPClient)
}
```

**Why:** AppUser can't use itself to look itself up, needs external entry point.

### Step 2B: User is NOT appUser
```swift
else {
    guard let appUserClient = appUser.hproseClient else {
        return nil  // Can't proceed without appUser client
    }
    
    if await isServerHealthy(appUserClient) != true {
        // Case B1: AppUser UNHEALTHY - refresh and retry
    } else {
        // Case B2: AppUser HEALTHY - return nil
    }
}
```

#### Case B1: AppUser is UNHEALTHY
```swift
// 1. Discover entry IP
let entryIP = try await findEntryIP()

// 2. Get fresh IP for appUser via entry
let ip = await _getProviderIP(appUser.mid, hproseClient: entryIPClient)
if let ip = ip {
    appUser.baseUrl = URL(string: "http://\(ip)")
}

// 3. Retry original user lookup with refreshed appUser
return await _getProviderIP(userId)
```

**Why:** AppUser's server is down/unreachable, need to refresh it before we can look up other users.

#### Case B2: AppUser is HEALTHY
```swift
// AppUser responded but all user's IPs failed health checks
// Entry IP would return same unhealthy IPs - no point trying
return nil
```

**Why:** AppUser gave us authoritative answer (IP list), those IPs are genuinely down. Entry IP won't help.

## Key Behaviors

### ✅ Returns Healthy IP When:
- Any IP from the list passes health check
- Entry IP fallback finds a healthy alternative (appUser case or unhealthy appUser case)

### ❌ Returns nil When:
- All user's IPs failed health checks AND appUser is healthy
- appUser.hproseClient is nil
- Entry IP discovery fails (throws error)

### 🔄 Uses Entry IP Fallback When:
1. **User IS appUser** - bootstrap case
2. **AppUser is UNHEALTHY** - need to refresh appUser first

### ⏭️ Skips Entry IP Fallback When:
- **AppUser is HEALTHY** - we already have authoritative answer

## Changes Made

### Change 1: `_getProviderIP` Returns nil on Health Check Failure
**Before:**
```swift
if !ipAddresses.isEmpty {
    return ipAddresses[0]  // Return unhealthy IP anyway
}
```

**After:**
```swift
if !ipAddresses.isEmpty {
    return nil  // Trigger fallback logic
}
```

**Impact:** Enables proper fallback to entry IP when needed.

### Change 2: Skip Entry IP When AppUser is Healthy
**Before:**
```swift
if await isServerHealthy(appUserClient) {
    // Still try entry IP fallback
    let entryIP = try await findEntryIP()
    return await _getProviderIP(userId, hproseClient: entryIPClient)
}
```

**After:**
```swift
if await isServerHealthy(appUserClient) {
    // AppUser healthy = we have authoritative answer
    return nil
}
```

**Impact:** Eliminates unnecessary entry IP lookups, fails fast when user's IPs are genuinely down.

## Example Scenarios

### Scenario 1: Normal Success
```
Input: userId = "abc123"
Step 1: _getProviderIP("abc123") via appUser client
        → Returns: "125.229.161.122:8080" ✓
Result: Return healthy IP immediately
```

### Scenario 2: All User IPs Down, AppUser Healthy
```
Input: userId = "6ESd5eGrbz2zzlrUdYPXBJV16bP"
Step 1: _getProviderIP("6ESd...") via appUser client
        → Gets: ["122.231.91.212:8002", "IPv6:8002"]
        → Health checks: All fail ❌
        → Returns: nil
Step 2: Check appUser health
        → appUser client: HEALTHY ✓
        → AppUser gave authoritative answer (IPs are down)
        → Skip entry IP (would return same IPs)
Result: Return nil (caller uses cache, blacklists temporarily)
```

### Scenario 3: AppUser Unhealthy, Refresh and Retry
```
Input: userId = "xyz789"
Step 1: _getProviderIP("xyz789") via appUser client
        → No response (appUser down)
        → Returns: nil
Step 2: Check appUser health
        → appUser client: UNHEALTHY ❌
Step 3: Refresh appUser via entry IP
        → findEntryIP() → "203.0.113.1:8080"
        → _getProviderIP(appUser.mid, entryIPClient)
        → Returns: "198.51.100.5:8080"
        → Update appUser.baseUrl
Step 4: Retry with refreshed appUser
        → _getProviderIP("xyz789") with new appUser
        → Returns: "192.0.2.10:8002" ✓
Result: Return healthy IP via refreshed route
```

### Scenario 4: AppUser is the Target
```
Input: userId = appUser.mid
Step 1: _getProviderIP(appUser.mid) via appUser client
        → Can't lookup self
        → Returns: nil
Step 2: User IS appUser (bootstrap)
        → findEntryIP() → "203.0.113.1:8080"
        → _getProviderIP(appUser.mid, entryIPClient)
        → Returns: "198.51.100.5:8080" ✓
Result: Return healthy IP via entry
```

## Integration with fetchUser

```swift
// In retry logic (attempt > 1)
guard let providerIP = try await getProviderIP(user.mid) else {
    throw HproseError.noResponse(userId: user.mid)
}
user.baseUrl = URL(string: "http://\(providerIP)")
```

**Flow:**
1. First attempt fails
2. Retry calls `getProviderIP(user.mid)`
3. `getProviderIP` returns healthy IP or nil
4. If nil → retry fails → user blacklisted
5. If IP → use it for retry attempt

## Summary

The `getProviderIP` flow now:
1. ✅ **Always tries health checks first** (no blind IP return)
2. ✅ **Uses entry IP only when necessary** (appUser unhealthy or appUser lookup)
3. ✅ **Fails fast when appropriate** (appUser healthy = authoritative answer)
4. ✅ **Refreshes appUser when needed** (ensures routing info is current)
5. ✅ **Avoids redundant lookups** (no entry IP when appUser is healthy)

This provides robust failover while being efficient and avoiding unnecessary network calls.

---

## Real-World Log Examples

### Example 1: Success - Found Healthy Alternative IP

User `ikJwDEsob7HVwn6Tj-ZSEzwwd2o` fetch succeeds on retry:

```
ERROR: [fetchUser] USER UPDATE FAILED: userId: ikJwDEsob7HVwn6Tj-ZSEzwwd2o, attempt: 1/2
DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT 2/2 - Resolving provider IP for userId: ikJwDEsob7HVwn6Tj-ZSEzwwd2o (retry)

DEBUG: [_getProviderIP] Retrieved 2 IP address(es) from get_provider_ips API
DEBUG: [_getProviderIP] Testing batch: IPs 1-2 of 2
DEBUG: [_getProviderIP] Testing IP 1/2: 43.165.128.251:8081
DEBUG: [_getProviderIP] Testing IP 2/2: [240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081

DEBUG: [isServerHealthy] ✅ HEAD request succeeded: http://[240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081/ (status: 200)
DEBUG: [IPCache] Cached IP: 240e:391:ec0:e980:1093:96a4:5f2f:5689:8081
DEBUG: [_getProviderIP] ✅ IP test PASSED: [240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081
DEBUG: [_getProviderIP] Found healthy provider IP: [240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081 - returning immediately

DEBUG: [updateUserFromServer] Updated baseUrl (retry attempt 2) to http://[240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081
DEBUG: [fetchUser] get_user rawResponse received for ikJwDEsob7HVwn6Tj-ZSEzwwd2o
[BlackList] Removed ikJwDEsob7HVwn6Tj-ZSEzwwd2o from candidates after successful access
```

**Result:** ✅ Found healthy IPv6 address, fetch succeeded

---

### Example 2: Clean Failure - All User IPs Down, AppUser Healthy

User `GNBqYVYBAbn0N2YBO5CNq1sE-Rv` fails cleanly:

```
ERROR: [fetchUser] USER UPDATE FAILED: userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv, attempt: 1/2
DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT 2/2 - Resolving provider IP for userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv (retry)

DEBUG: [_getProviderIP] Retrieved 2 IP address(es) from get_provider_ips API
DEBUG: [_getProviderIP] Testing batch: IPs 1-2 of 2
DEBUG: [_getProviderIP] Testing IP 1/2: 122.231.91.212:8081
DEBUG: [_getProviderIP] Testing IP 2/2: [240e:391:eb4:ae00:c2b:1d34:9b4b:9bf8]:8081

DEBUG: [isServerHealthy] ❌ HEAD request error for http://122.231.91.212:8081/: domain=NSURLErrorDomain, code=-1005
DEBUG: [_getProviderIP] ❌ IP test FAILED: 122.231.91.212:8081

DEBUG: [isServerHealthy] ❌ HEAD request error for http://[240e:391:eb4:ae00:c2b:1d34:9b4b:9bf8]:8081/: domain=NSURLErrorDomain, code=-1001
DEBUG: [_getProviderIP] ❌ IP test FAILED: [240e:391:eb4:ae00:c2b:1d34:9b4b:9bf8]:8081

DEBUG: [_getProviderIP] All health checks failed for 2 IP(s), returning nil to trigger fallback

DEBUG: [IPCache] Cache HIT for IP: 125.229.161.122:8080 (age: 25s)
DEBUG: [getProviderIP] Initial lookup failed for GNBqYVYBAbn0N2YBO5CNq1sE-Rv and appUser server is healthy - all user IPs are unhealthy

ERROR: [fetchUser] USER UPDATE FAILED: userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv, attempt: 2/2
ERROR: [fetchUser] ALL RETRIES FAILED: userId: GNBqYVYBAbn0N2YBO5CNq1sE-Rv, maxRetries: 2
[BlackList] Resource GNBqYVYBAbn0N2YBO5CNq1sE-Rv failed 185 times
```

**Result:** ❌ Clean failure - no entry IP fallback because appUser is healthy

**Key observations:**
1. ✅ `_getProviderIP` returned `nil` after all health checks failed
2. ✅ `getProviderIP` checked appUser health (cache hit - healthy)
3. ✅ Skipped entry IP fallback (appUser gave authoritative answer)
4. ✅ Failed cleanly with proper error handling

---

### Example 3: Background Refresh Success

User `iq1w-iqAbwGsZX653vV0lL1PL_D` background refresh succeeds:

```
DEBUG: [fetchUser] Returning stale cached user while refreshing in background
DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT 1/2 - Using user's existing baseUrl

ERROR: [backgroundRefresh] Network error during get_user: userId: iq1w-iqAbwGsZX653vV0lL1PL_D, domain: NSURLErrorDomain, code: -1001
ERROR: [backgroundRefresh] USER UPDATE FAILED: userId: iq1w-iqAbwGsZX653vV0lL1PL_D, attempt: 1/2

DEBUG: [resolveAndUpdateBaseUrl] ATTEMPT 2/2 - Resolving provider IP for userId: iq1w-iqAbwGsZX653vV0lL1PL_D (retry)
DEBUG: [_getProviderIP] Retrieved 2 IP address(es) from get_provider_ips API
DEBUG: [_getProviderIP] Testing IP 1/2: 60.163.239.46:8002

DEBUG: [IPCache] Cache HIT for IP: 60.163.239.46:8002 (age: 9s)
DEBUG: [_getProviderIP] ✅ IP test PASSED: 60.163.239.46:8002
DEBUG: [_getProviderIP] Found healthy provider IP: 60.163.239.46:8002 - returning immediately

DEBUG: [updateUserFromServer] Updated baseUrl (retry attempt 2) to http://60.163.239.46:8002
DEBUG: [backgroundRefresh] get_user rawResponse received for iq1w-iqAbwGsZX653vV0lL1PL_D
```

**Result:** ✅ Retry found healthy IP via IP cache, background refresh succeeded

---

## Performance Optimizations Visible in Logs

### IP Caching
```
DEBUG: [IPCache] Cache HIT for IP: 60.163.239.46:8002 (age: 9s)
DEBUG: [_getProviderIP] ✅ IP test PASSED: 60.163.239.46:8002
```
- Recently validated IPs skip health check
- Reduces latency on retry attempts

### Parallel Health Checks
```
DEBUG: [_getProviderIP] Testing batch: IPs 1-2 of 2
DEBUG: [_getProviderIP] Testing IP 1/2: 43.165.128.251:8081
DEBUG: [_getProviderIP] Testing IP 2/2: [240e:391:ec0:e980:1093:96a4:5f2f:5689]:8081
```
- Multiple IPs tested in parallel
- First healthy IP wins, others cancelled

### Early Cancellation
```
DEBUG: [_getProviderIP] Found healthy provider IP: 60.163.239.46:8002 - returning immediately
DEBUG: [isServerHealthy] ⏭️  HEAD request cancelled for http://[...] (faster IP found)
```
- As soon as one IP passes, others are cancelled
- Minimizes wait time

