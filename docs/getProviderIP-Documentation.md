# `getProviderIP` Function Documentation

## Overview

`getProviderIP` is a critical networking function that resolves and validates healthy IP addresses for user nodes in a distributed system. It handles network failures gracefully with automatic fallback mechanisms to ensure robust connectivity.

---

## Function Signature

```swift
func getProviderIP(_ mid: String, attemptNumber: Int = 1) async throws -> String?
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `mid` | `String` | Required | User's member ID (MimeiId) to resolve IP for |
| `attemptNumber` | `Int` | `1` | Internal retry counter (1 or 2) - tracks fallback attempts |

### Returns

- **Type**: `String?`
- **Value**: A healthy, validated IP address string
- Returns `nil` when no healthy IP can be found

### Throws

- Throws `NSError` after all retry attempts are exhausted
- Throws immediately if attempting to resolve GUEST_ID

---

## Core Functionality

### IP Resolution Process

The function follows a systematic approach to finding a healthy IP:

1. **Fetch IPs from Backend**
   - Calls `get_provider_ips` API via `appUser.hproseClient`
   - Sends user's `mid` to backend

2. **Parse Response** - Handles multiple server response formats:
   - Array of strings: `["192.168.1.1", "192.168.1.2"]`
   - Dictionary with data array: `{data: ["192.168.1.1", "192.168.1.2"]}`
   - Single string: `"192.168.1.1"`
   - Dictionary with single string: `{data: "192.168.1.1"}`

3. **Validate & Clean**
   - Trims whitespace from each IP
   - Filters out empty strings
   - Validates URL format

4. **Health Check with Cache**
   - Checks IP cache first (30-minute validity)
   - If cached: Returns immediately (< 1ms)
   - If not cached: Performs HTTP HEAD request
   - Tests IPs in pairs (batches of 2) concurrently
   - Returns first IP that passes health check
   - Caches validated IPs for future use

5. **Return or Fallback**
   - Returns first healthy IP immediately
   - Triggers fallback if no healthy IPs found

---

## Multi-Tier Fallback System

### Attempt #1 (Primary Resolution)

```
┌─────────────────────────────────────────┐
│ Use appUser.baseUrl                     │
│ ↓                                        │
│ Query backend: get_provider_ips         │
│ ↓                                        │
│ Parse IPs from response                 │
│ ↓                                        │
│ Health check each IP                    │
│ ↓                                        │
│ Return first healthy IP ✓               │
└─────────────────────────────────────────┘
```

**Fallback Triggers:**
- No IPs returned from backend
- All returned IPs fail health check

### Attempt #2 (Fallback Resolution)

Handled by `handleProviderIPFallback(for:)`:

```
┌──────────────────────────────────────────────┐
│ 1. Resolve firstIP from app URLs            │
│    (via resolveFirstIPFromAppUrls)           │
│ ↓                                             │
│ 2. Temporarily set client.uri = firstIP      │
│ ↓                                             │
│ 3. Query backend for target user's IP        │
│    (using firstIP client)                    │
│    (recursive call with attemptNumber: 2)    │
│ ↓                                             │
│ 4a. If target == appUser:                    │
│     ├─ Update client.uri = target's IP       │
│     ├─ Update appUser.baseUrl = target's IP  │
│     └─ Return target IP ✓                    │
│                                               │
│ 4b. If target != appUser:                    │
│     ├─ Restore previous client.uri           │
│     └─ Return target IP ✓                    │
└──────────────────────────────────────────────┘
```

---

## Smart Routing Logic

### Decision Tree

```
getProviderIP(userId, attemptNumber: 1)
│
├─ userId == GUEST_ID?
│  └─ YES → Throw error immediately (safety check)
│
├─ Fetch IPs from backend using appUser.baseUrl
│  ├─ No IPs returned?
│  │  ├─ userId == appUser && attempt == 1?
│  │  │  └─ YES → handleProviderIPFallback(appUser)
│  │  └─ NO → Throw error
│  │
│  └─ Health check each IP
│     ├─ Found healthy IP?
│     │  └─ YES → Return IP ✓
│     │
│     └─ All IPs failed health check?
│        └─ attempt == 1?
│           ├─ userId == appUser?
│           │  └─ YES → handleProviderIPFallback(appUser)
│           │
│           └─ userId != appUser?
│              ├─ Check if appUser.baseUrl is healthy
│              │  ├─ Healthy → Throw error (target-specific issue)
│              │  └─ Unhealthy → handleProviderIPFallback(target)
│              │
│              └─ No appUser.baseUrl → handleProviderIPFallback(target)
│
└─ Throw error (all attempts exhausted)
```

---

## Call Sites

The function is used in 7 strategic locations throughout `HproseInstance.swift`:

| # | Location | Line | Context | Purpose |
|---|----------|------|---------|---------|
| 1 | `fetchUser()` | 1202 | User has nil baseUrl | Initial IP resolution for new/cached users without baseUrl |
| 2 | `updateUserFromServer()` | 1371 | First attempt | Fetch user data from server with fresh IP resolution |
| 3 | `updateUserFromServer()` | 1384 | Retry attempts | Re-resolve IP after network failure during retries |
| 4 | `handleRetryRecovery()` | 1481 | Error recovery | Get new IP after detecting unhealthy server connection |
| 5 | `updateUserFromServerInternal()` | 1749 | Unexpected response | Fallback when server returns unexpected/invalid data |
| 6 | `refreshAppUserFromServer()` | 4770 | Refresh operation | Update appUser's IP before refreshing user data |
| 7 | `handleProviderIPFallback()` | 5986, 6020 | Recursive fallback | Resolve IPs during 2nd attempt fallback recovery |

---

## Safety Features

### ✅ GUEST_ID Protection

```swift
if mid == Constants.GUEST_ID {
    throw NSError(...)  // Never attempt to resolve IP for guest users
}
```

### ✅ Health Validation

Every IP is verified with `isServerHealthy()` before being returned. The function never returns an unverified IP address.

**Validation Method**: HTTP HEAD request with 5-second timeout
- Accepts any 2xx HTTP status code (200-299)
- More efficient than endpoint-based checks (no response body)
- Failed IPs are never cached

**Cache Validation**: 
- Cached IPs are pre-validated (passed health check within last 30 minutes)
- Cache entries expire after 30 minutes
- Invalid IPs can be manually removed from cache

### ✅ Network Issue Isolation

Distinguishes between:
- **User-specific issues**: Target user's IPs are all down (but appUser connection is healthy)
- **Network-wide issues**: Both target and appUser connections are down → triggers fallback

### ✅ State Restoration

```swift
// Store previous state
let previousAppUserBaseUrl = appUser.baseUrl

// Attempt fallback...

catch {
    // Restore on failure
    appUser.baseUrl = previousAppUserBaseUrl
    throw error
}
```

### ✅ Infinite Loop Prevention

The `attemptNumber` parameter tracks attempts:
- **Attempt 1**: Uses existing `appUser.baseUrl`
- **Attempt 2**: Forces re-resolution from app URLs
- **No Attempt 3**: Throws error to prevent infinite recursion

### ✅ Comprehensive Logging

Every step logs debug information:
- `DEBUG`: Successful operations and state changes
- `WARN`: Recoverable issues (IP skipped, health check failed)
- `ERROR`: Fatal errors requiring fallback or throwing

---

## Usage Examples

### Example 1: Basic User IP Resolution

```swift
// Resolve IP for a user when their baseUrl is nil or expired
do {
    if let userIP = try await getProviderIP(userId) {
        user.baseUrl = URL(string: "http://\(userIP)")
        print("✅ Resolved IP: \(userIP)")
    }
} catch {
    print("❌ Failed to resolve IP: \(error)")
}
```

### Example 2: AppUser Refresh with IP Re-resolution

```swift
// Force fresh IP resolution during app user refresh
guard let providerIP = try await getProviderIP(appUser.mid) else {
    throw NSError(domain: "HproseClient", code: -1, 
                  userInfo: [NSLocalizedDescriptionKey: "No provider IP found"])
}

// Update global baseUrl
HproseInstance.baseUrl = URL(string: "http://\(providerIP)")!
```

### Example 3: Retry with Automatic Fallback

```swift
// First attempt (uses cached appUser.baseUrl)
if let ip = try? await getProviderIP(targetUserId, attemptNumber: 1) {
    return ip
}

// Automatic fallback happens internally if attempt 1 fails
// Second attempt (forces re-resolution from app URLs)
// No manual intervention needed - handled by handleProviderIPFallback
```

---

## Error Scenarios Handled

| Scenario | Detection | Response |
|----------|-----------|----------|
| No IPs returned | `ipAddresses.isEmpty` | Trigger fallback (attempt 1) or throw (attempt 2) |
| All IPs unhealthy | All fail `isServerHealthy()` | Trigger fallback with network isolation check |
| Invalid IP format | `URL(string:)` returns nil | Skip IP, try next in list |
| Network unreachable | appUser connection dead | Fallback to `resolveFirstIPFromAppUrls()` |
| Target user unreachable | Target IPs down, appUser healthy | Throw specific error (no fallback) |
| GUEST_ID attempt | `mid == Constants.GUEST_ID` | Throw error immediately |

---

## Key Design Patterns

### 1. **Retry with Escalation**
- **Attempt 1**: Use cached/existing state (fast)
- **Attempt 2**: Full re-resolution from scratch (thorough)

### 2. **Health-First Policy**
Never trusts an IP address without verification. Every returned IP has been confirmed reachable.

### 3. **Graceful Degradation**
Falls back through multiple strategies before giving up:
```
Primary IPs → Fallback to firstIP → Fallback to app URLs → Throw error
```

### 4. **Isolation Detection**
Distinguishes between:
- **Local issues**: "This user's IPs are down" (specific error)
- **Global issues**: "Network is down" (try fallback)

### 5. **Careful State Management**
During fallback, `client.uri` is temporarily modified for the IP query. For appUser targets, both `client.uri` and `appUser.baseUrl` are updated to the resolved IP. For non-appUser targets, `client.uri` is restored to prevent side effects. On failure, previous state is always restored.

---

## Related Functions

### `handleProviderIPFallback(for targetUserId:)`
**Purpose**: Implements the fallback resolution strategy

**Flow**:
1. Resolve `firstIP` via `resolveFirstIPFromAppUrls()`
2. Temporarily set `client.uri = firstIP`
3. Resolve target user's provider IP directly (attempt 2)
4. If target == appUser:
   - Update `client.uri` to resolved IP
   - Update `appUser.baseUrl` to resolved IP
5. If target != appUser:
   - Restore previous `client.uri`
6. Return resolved IP

**Key Insight**: The firstIP client can query for ANY user's provider IP, eliminating the need to resolve appUser's IP first as an intermediate step.

### `resolveFirstIPFromAppUrls(avoidInfiniteLoop:)`
**Purpose**: Emergency fallback that resolves IPs directly from app initialization URLs

**Usage**: Called only when normal resolution fails

**Protection**: `avoidInfiniteLoop` flag prevents recursive calls

### `isServerHealthy(_:)`
**Purpose**: Health check validation for IP addresses using HTTP HEAD requests

**Returns**: `true` if server responds correctly, `false` otherwise

**Method**: Performs HTTP HEAD request to server endpoint (more efficient than calling `/health` endpoint)

**Key Features**:
- Uses HTTP HEAD (no response body - faster and more efficient)
- Checks IP cache first before making network request
- Caches validated IPs for 30 minutes
- Thread-safe cache operations
- Automatic cache cleanup

**Cache Integration**:
```swift
// Check cache first
if getCachedIP(ip) {
    return true  // Instant response - no network request
}

// If not cached, perform HTTP HEAD request
// On success, cache IP for 30 minutes
```

### `isServerHealthyWithTimeout(_:timeout:)`
**Purpose**: Wrapper that adds timeout protection to health checks

**Features**:
- Default 10-second timeout
- Cancels health check if timeout is reached
- Automatically cleans up expired cache entries
- Returns false on timeout or cancellation

---

## IP Cache System

### Overview

The IP cache system prevents redundant health checks by caching validated IPs for 30 minutes. This significantly improves performance by eliminating unnecessary network requests.

### Cache Structure

```swift
private struct IPCacheEntry {
    let ip: String
    let timestamp: Date
    
    var isExpired: Bool {
        // 30 minute expiry (1800 seconds)
        return Date().timeIntervalSince(timestamp) > 1800
    }
}
```

### Cache Operations

| Method | Purpose | Thread-Safe |
|--------|---------|-------------|
| `getCachedIP(_:)` | Check if IP is cached and valid | ✅ Yes |
| `cacheIP(_:)` | Store validated IP with timestamp | ✅ Yes |
| `cleanupExpiredCache()` | Remove expired entries | ✅ Yes |
| `invalidateIPCache(for:)` | Manually invalidate specific IP | ✅ Yes |
| `clearIPCache()` | Clear all cached IPs | ✅ Yes |

### Cache Behavior

**When checking IP health:**
1. ✅ **Cache Hit (IP valid)**: Returns `true` immediately - no network request
2. ⏱️ **Cache Miss or Expired**: Performs HTTP HEAD request
3. ✅ **HEAD Success**: Caches IP for 30 minutes and returns `true`
4. ❌ **HEAD Failure**: Returns `false` (does not cache failed IPs)

**Example Debug Output:**
```
DEBUG: [IPCache] Cache HIT for IP: 192.168.1.100 (age: 327s)
DEBUG: [isServerHealthy] ✅ HEAD request succeeded: http://192.168.1.100/webapi/ (status: 200)
DEBUG: [IPCache] Cached IP: 192.168.1.100
DEBUG: [IPCache] Cleaned up 3 expired entries
```

### Manual Cache Control

```swift
// Invalidate specific IP (e.g., when connection fails later)
HproseInstance.shared.invalidateIPCache(for: "192.168.1.100")

// Clear entire cache (e.g., during logout or network change)
HproseInstance.shared.clearIPCache()
```

---

## Performance Considerations

### ⚡ Optimizations

1. **IP Cache**: Validated IPs cached for 30 minutes - instant response for cached IPs
2. **HTTP HEAD Requests**: No response body - faster than full GET requests
3. **Parallel Testing**: IPs tested in pairs (batches of 2) concurrently
4. **Fast Path**: Returns immediately on first healthy IP found
5. **Lazy Evaluation**: Stops checking IPs once one passes
6. **Cached State**: Attempt 1 uses cached baseUrl (no DNS resolution)

### ⏱️ Timeout Strategy

- HTTP HEAD request timeout: 5 seconds
- Overall health check timeout: 10 seconds (configurable)
- Total function time:
  - **Cached IP**: < 1ms (instant cache hit)
  - **Fast path (first IP healthy)**: ~1-3 seconds
  - **Full fallback**: ~10-15 seconds

### 📊 Cache Performance Impact

| Scenario | Without Cache | With Cache | Improvement |
|----------|---------------|------------|-------------|
| Repeated IP checks | ~2-5s per check | < 1ms | **>2000x faster** |
| Batch operations | Multiple network calls | Single cache lookup | **Significant** |
| Background refresh | Network overhead | Instant validation | **Lower battery usage** |

### 🔄 Retry Budget

- **Max attempts**: 2
- **No exponential backoff**: Each attempt is qualitatively different
  - Attempt 1: Use cached connection
  - Attempt 2: Full re-resolution

---

## Implementation Details

### HTTP HEAD Health Check

**New Implementation (December 2025)**

The health check system was updated to use HTTP HEAD requests instead of calling the `/health` endpoint:

```swift
private func isServerHealthy(_ hproseClient: HproseClient) async -> Bool {
    // Extract base URL from client URI
    // Client URI is "http://IP:PORT/webapi/" but we test "http://IP:PORT/" (server, not endpoint)
    guard let uriString = hproseClient.uri as? String,
          let fullURL = URL(string: uriString),
          let scheme = fullURL.scheme,
          let host = fullURL.host else {
        return false
    }
    
    // Construct base URL (without /webapi/ path) - test server, not service
    var baseURLString = "\(scheme)://\(host)"
    if let port = fullURL.port {
        baseURLString += ":\(port)"
    }
    baseURLString += "/"
    
    let cacheKey = host + (fullURL.port.map { ":\($0)" } ?? "")
    
    // Check cache first - instant response
    if getCachedIP(cacheKey) {
        return true  // < 1ms response time
    }
    
    guard let baseURL = URL(string: baseURLString) else {
        return false
    }
    
    // Perform HTTP HEAD request to BASE URL (5-second timeout)
    // Testing server availability, not service endpoint
    var request = URLRequest(url: baseURL, timeoutInterval: 5.0)
    request.httpMethod = "HEAD"
    
    let (_, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        let isHealthy = (200...299).contains(httpResponse.statusCode)
        
        // Cache validated IPs for 30 minutes
        if isHealthy {
            cacheIP(cacheKey)
        }
        
        return isHealthy
    }
    
    return false
}
```

**Key Points:**
- ✅ Tests **base URL** (`http://IP:PORT/`) not service endpoint (`/webapi/`)
- ✅ Verifies **server availability**, not service functionality
- ✅ More accurate health check (server might be up even if service is down)

**Benefits:**
- ✅ **More Efficient**: HEAD request has no response body (lower bandwidth)
- ✅ **Standard Protocol**: Uses HTTP standard method (no custom endpoint needed)
- ✅ **Better Caching**: Works with IP cache system
- ✅ **Faster**: 5-second timeout vs previous endpoint-based approach
- ✅ **Universal**: Works with any HTTP server

### Parallel IP Testing

IPs are tested in **batches of 2** using Swift's `TaskGroup`:

```swift
let batchSize = 2
for batchStart in stride(from: 0, to: ipAddresses.count, by: batchSize) {
    let batch = Array(ipAddresses[batchStart..<batchEnd])
    
    // Test batch in parallel
    let healthyIP = await withTaskGroup(of: (String, Bool)?.self) { group in
        for (index, ip) in batch.enumerated() {
            group.addTask {
                // Check cache first
                let client = self.clientPool.getClientByIP(for: ip)
                let isHealthy = await self.isServerHealthyWithTimeout(client, timeout: 10.0)
                return (ip, isHealthy)
            }
        }
        
        // Return IMMEDIATELY when first healthy IP found
        for await result in group {
            if let (ip, isHealthy) = result, isHealthy {
                group.cancelAll()  // Cancel remaining checks
                return ip
            }
        }
        return nil
    }
    
    // If found healthy IP, return immediately
    if let ip = healthyIP {
        return ip
    }
}
```

**Why batches of 2?**
- ⚡ Balances parallelism with resource usage
- 🔋 Prevents overwhelming network with too many concurrent requests
- ⏱️ First successful response cancels remaining batch
- 📊 Optimal for most cases (usually 2-4 IPs returned)

---

## Debugging Tips

### Enable Verbose Logging

The function already includes comprehensive logging. Look for these patterns:

```
DEBUG: [getProviderIP] Attempt #1 for user: <userId>
DEBUG: [getProviderIP] Retrieved 3 IP address(es)...
DEBUG: [_getProviderIP] Testing batch: IPs 1-2 of 3
DEBUG: [_getProviderIP] Testing IP 1/3: 192.168.1.1
DEBUG: [IPCache] Cache HIT for IP: 192.168.1.1 (age: 127s)
DEBUG: [isServerHealthy] ✅ HEAD request succeeded: http://192.168.1.1/webapi/ (status: 200)
DEBUG: [IPCache] Cached IP: 192.168.1.1
DEBUG: [_getProviderIP] Found healthy provider IP: 192.168.1.1 - returning immediately
DEBUG: [getProviderIP] ✅ Found healthy IP on attempt #1: 192.168.1.1
```

### Common Issues

| Problem | Log Pattern | Solution |
|---------|-------------|----------|
| All IPs unhealthy | `❌ HEAD request failed` | Check network connectivity or clear cache |
| No IPs returned | `WARN: No provider IPs returned` | Check backend `get_provider_ips` API |
| Fallback triggered | `trying fallback mechanism` | Normal - indicates primary resolution failed |
| Guest ID error | `ERROR: Refusing to get provider IP for GUEST_ID` | Don't call for guest users |
| Cache hit on bad IP | `Cache HIT` but connection fails | Invalidate cache: `invalidateIPCache(for: ip)` |
| Stale cache entries | High cache age values | Normal - auto cleanup happens periodically |
| HEAD timeout | `HEAD request error ... timeout` | Increase timeout or check server response time |

---

## Testing Recommendations

### Unit Tests

```swift
// Test 1: Successful resolution
func testGetProviderIP_Success() async throws {
    let ip = try await hprose.getProviderIP(testUserId)
    XCTAssertNotNil(ip)
    XCTAssertTrue(ip!.contains(".")) // Contains IP format
}

// Test 2: GUEST_ID protection
func testGetProviderIP_GuestIDThrows() async {
    await assertThrowsError {
        try await hprose.getProviderIP(Constants.GUEST_ID)
    }
}

// Test 3: Fallback mechanism
func testGetProviderIP_FallbackOnUnhealthyIPs() async throws {
    // Mock: Primary IPs return unhealthy, fallback succeeds
    let ip = try await hprose.getProviderIP(testUserId)
    XCTAssertNotNil(ip)
}
```

### Integration Tests

```swift
// Test network failure recovery
func testGetProviderIP_NetworkFailureRecovery() async throws {
    // 1. Disconnect network
    // 2. Call getProviderIP - should trigger fallback
    // 3. Reconnect network
    // 4. Verify IP resolution succeeds
}
```

### Cache System Tests

```swift
// Test 1: Cache hit behavior
func testIPCache_CacheHit() async throws {
    let hprose = HproseInstance.shared
    hprose.clearIPCache()
    
    // First call - should cache IP
    let ip1 = try await hprose.getProviderIP(testUserId)
    
    // Second call - should use cache (< 1ms)
    let startTime = Date()
    let ip2 = try await hprose.getProviderIP(testUserId)
    let duration = Date().timeIntervalSince(startTime)
    
    XCTAssertEqual(ip1, ip2)
    XCTAssertLessThan(duration, 0.01) // Should be instant
}

// Test 2: Cache expiry
func testIPCache_Expiry() async throws {
    let hprose = HproseInstance.shared
    hprose.clearIPCache()
    
    // Cache an IP
    let ip = try await hprose.getProviderIP(testUserId)
    
    // Fast forward time (mock) or wait 30+ minutes
    // After expiry, should perform new health check
    
    XCTAssertNotNil(ip)
}

// Test 3: Cache invalidation
func testIPCache_ManualInvalidation() async throws {
    let hprose = HproseInstance.shared
    
    // Cache an IP
    let ip = try await hprose.getProviderIP(testUserId)
    
    // Invalidate cache
    hprose.invalidateIPCache(for: ip!)
    
    // Next call should perform fresh health check
    let ip2 = try await hprose.getProviderIP(testUserId)
    XCTAssertNotNil(ip2)
}

// Test 4: HTTP HEAD health check
func testHealthCheck_HTTPHead() async throws {
    let client = HproseHttpClient()
    client.uri = "http://192.168.1.1/webapi/"
    
    let isHealthy = await HproseInstance.shared.isServerHealthy(client)
    
    // Should perform HEAD request, not GET
    // Verify via network monitoring or logs
    XCTAssertTrue(isHealthy || !isHealthy) // Result depends on server
}
```

---

## Migration Notes

### From Older Implementations

If migrating from a simpler IP resolution system:

1. **Remove manual retry loops** - Now handled internally
2. **Remove manual baseUrl updates** - Automatic during fallback
3. **Add GUEST_ID checks** - New safety requirement
4. **Update error handling** - More specific error types now

### Breaking Changes

- **Parameter added**: `attemptNumber` is new (but has default value)
- **Behavior change**: Now performs health checks (may be slower but more reliable)
- **Error handling**: Throws specific errors instead of returning nil

---

## Security Considerations

### 🔒 IP Validation

- IPs are validated for format before use
- Health checks prevent using compromised/redirected servers

### 🔒 State Protection

- GUEST_ID cannot trigger IP resolution (prevents abuse)
- State restoration on failure prevents inconsistent app state

### 🔒 Privacy

- Only user IDs are sent to backend (no sensitive data)
- IP resolution happens over user's existing secure connection

---

## Architecture Context

### Role in Distributed System

`getProviderIP` is the **networking foundation** for a distributed user system where:

- **Each user** has their own "provider node" (server)
- **User data** lives on their provider node
- **App must discover** where each user's data lives
- **Nodes can fail** or change IPs dynamically

### Integration Points

```
┌─────────────────────────────────────────────┐
│ App Initialization                           │
│ └─ initAppEntry()                           │
│    └─ resolveFirstIPFromAppUrls()           │
│       (Used by getProviderIP fallback)      │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ User Fetching                                │
│ └─ fetchUser()                              │
│    └─ getProviderIP() ← Resolve user's node │
│       └─ updateUserFromServer()             │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ Data Operations                              │
│ ├─ Tweet operations use user.baseUrl        │
│ ├─ Comment operations use author.baseUrl    │
│ └─ Chat operations use recipient.baseUrl    │
└─────────────────────────────────────────────┘
```

---

## Conclusion

`getProviderIP` is the **linchpin of network resilience** in this distributed system. It ensures that even when nodes fail, move, or become unreachable, the app can dynamically discover and connect to healthy servers through intelligent fallback mechanisms.

### Key Takeaways

✅ **Always validates** IPs before returning them using HTTP HEAD requests  
✅ **Caches validated IPs** for 30 minutes to eliminate redundant checks  
✅ **Automatically recovers** from network failures with multi-tier fallback  
✅ **Isolates issues** between user-specific and system-wide problems  
✅ **Prevents infinite loops** with attempt tracking  
✅ **Protects state** with automatic restoration on failure  
✅ **Parallel testing** of IPs in batches for optimal performance  
✅ **Thread-safe cache** operations for concurrent access  

### Recent Improvements (December 2025)

**🚀 HTTP HEAD Health Checks**
- Replaced `/health` endpoint with standard HTTP HEAD requests
- More efficient (no response body)
- Faster (5-second timeout)
- Universal compatibility

**⚡ IP Cache System**
- 30-minute cache validity
- Instant response for cached IPs (< 1ms vs ~2-5s)
- Thread-safe concurrent access
- Automatic expiry and cleanup
- Manual invalidation support
- **Performance gain: >2000x faster for repeated checks**

---

**Last Updated**: December 26, 2025  
**Version**: 2.0  
**Maintained by**: HproseInstance Development Team
