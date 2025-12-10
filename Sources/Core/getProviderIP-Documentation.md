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

4. **Health Check**
   - Tests each IP sequentially via `isServerHealthy()`
   - Returns first IP that passes health check

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
│ 2. Temporarily set appUser.baseUrl = firstIP │
│ ↓                                             │
│ 3. Query backend for appUser's provider IP   │
│    (recursive call with attemptNumber: 2)    │
│ ↓                                             │
│ 4. Update appUser.baseUrl to resolved IP     │
│ ↓                                             │
│ 5a. If target == appUser:                    │
│     └─ Return appUser IP ✓                   │
│                                               │
│ 5b. If target != appUser:                    │
│     └─ Query again for target user's IP      │
│        └─ Return target IP ✓                 │
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
During fallback, `appUser.baseUrl` is temporarily modified and restored on failure to prevent inconsistent state.

---

## Related Functions

### `handleProviderIPFallback(for targetUserId:)`
**Purpose**: Implements the fallback resolution strategy

**Flow**:
1. Resolve `firstIP` via `resolveFirstIPFromAppUrls()`
2. Temporarily set `appUser.baseUrl = firstIP`
3. Resolve `appUser`'s provider IP (attempt 2)
4. Update `appUser.baseUrl` to resolved IP
5. If target ≠ appUser, resolve target's IP with updated baseUrl

### `resolveFirstIPFromAppUrls(avoidInfiniteLoop:)`
**Purpose**: Emergency fallback that resolves IPs directly from app initialization URLs

**Usage**: Called only when normal resolution fails

**Protection**: `avoidInfiniteLoop` flag prevents recursive calls

### `isServerHealthy(_:logFailures:)`
**Purpose**: Health check validation for IP addresses

**Returns**: `true` if server responds correctly, `false` otherwise

**Method**: Calls `health` endpoint or checks for valid response

---

## Performance Considerations

### ⚡ Optimizations

1. **Fast Path**: Returns immediately on first healthy IP found
2. **Lazy Evaluation**: Stops checking IPs once one passes
3. **Cached State**: Attempt 1 uses cached baseUrl (no DNS resolution)

### ⏱️ Timeout Strategy

- Health checks use short timeouts (typically 3-5 seconds)
- Total function time: ~5-15 seconds worst case
  - Fast path (cached): ~1-3 seconds
  - Full fallback: ~10-15 seconds

### 🔄 Retry Budget

- **Max attempts**: 2
- **No exponential backoff**: Each attempt is qualitatively different
  - Attempt 1: Use cached connection
  - Attempt 2: Full re-resolution

---

## Debugging Tips

### Enable Verbose Logging

The function already includes comprehensive logging. Look for these patterns:

```
DEBUG: [getProviderIP] Attempt #1 for user: <userId>
DEBUG: [getProviderIP] Retrieved 3 IP address(es)...
DEBUG: [getProviderIP] Testing IP 1/3: 192.168.1.1
DEBUG: [getProviderIP] ✅ Found healthy IP on attempt #1: 192.168.1.1
```

### Common Issues

| Problem | Log Pattern | Solution |
|---------|-------------|----------|
| All IPs unhealthy | `❌ IP ... failed health check` | Check network connectivity |
| No IPs returned | `WARN: No provider IPs returned` | Check backend `get_provider_ips` API |
| Fallback triggered | `trying fallback mechanism` | Normal - indicates primary resolution failed |
| Guest ID error | `ERROR: Refusing to get provider IP for GUEST_ID` | Don't call for guest users |

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

✅ **Always validates** IPs before returning them  
✅ **Automatically recovers** from network failures  
✅ **Isolates issues** between user-specific and system-wide problems  
✅ **Prevents infinite loops** with attempt tracking  
✅ **Protects state** with automatic restoration on failure  

---

**Last Updated**: December 10, 2025  
**Version**: 1.0  
**Maintained by**: HproseInstance Development Team
