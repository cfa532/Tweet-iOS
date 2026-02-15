# NodePool System

**Last Updated:** February 2026
**Status:** Production

---

## Overview

NodePool is a self-healing cache of recently working server IPs. Two strategies handle different reliability needs:

| Function | Strategy | Use Case |
|----------|----------|----------|
| `fetchUser` | **Trust & Go** | Reads (profiles, feed, comments) - speed first, retry on failure |
| `getHostIP` | **Verify First** | Writes (messages, uploads) - reliability first, must work on first try |

---

## Flow Comparison

### fetchUser - Trust Strategy
```
Pool -> Use Immediately -> Works? -> Done (50ms)
                        -> Fails? -> Remove bad IP -> Get fresh -> Retry -> Done (1500ms)
```

### getHostIP - Verify Strategy
```
Pool -> Test Health -> Healthy? -> Return IP (10ms)
                    -> Bad? -> Remove -> Get fresh IPs -> Test all -> Return first healthy (500ms)
```

---

## Performance

| Scenario | fetchUser | getHostIP |
|----------|-----------|-----------|
| Pool hit (good IP) | ~50ms | ~10ms |
| Pool hit (bad IP) | ~1500ms (includes retry) | ~500ms |
| Pool miss | ~500ms | ~500ms |
| Success rate | 95% fast path | 100% guaranteed |

---

## Code Patterns

### fetchUser - Using Pool IP
```swift
// In resolveAndUpdateBaseUrl (attempt 1)
if let poolIP = NodePool.shared.getIPFromNode(for: user) {
    // TRUST IT - use directly, no health check
    await applyBaseUrlIfNeeded(user, url: poolIP)
    return
}
// On failure: performUserUpdate catches error and removes bad IP
```

### getHostIP - Verifying Pool IP
```swift
// In getHostIP
if let pooledIP = NodePool.shared.getIPForNode(nodeMid: nodeId) {
    // VERIFY IT - test health first
    let isHealthy = await isServerHealthyWithTimeout(client, timeout: 10.0)
    if isHealthy {
        return pooledIP
    } else {
        NodePool.shared.removeIPFromNode(nodeMid: nodeId, ip: pooledIP)
    }
}
```

---

## Pool Operations

**IPs added on success:**
```swift
NodePool.shared.updateNodeIP(nodeMid: accessNodeMid, newIP: workingIP)
```

**IPs removed on failure:**
```swift
NodePool.shared.removeIPFromNode(nodeMid: accessNodeMid, ip: badIP)
```

---

## Debugging

```swift
let (totalNodes, totalIPs) = NodePool.shared.getStats()
NodePool.shared.logDetailedStats()
```

**Key logs:**
- `[resolveAndUpdateBaseUrl] ATTEMPT 1/2 - Using trusted IP from NodePool: ...`
- `[performUserUpdate] Removing unhealthy node ... from pool after failure`
- `[getHostIP] Found pooled IP ... testing health...`
- `[getHostIP] Pooled IP ... is unhealthy, removing from pool`

---

## Architecture

```
                    NodePool
  node_123 -> ["192.168.1.5:8002"]
  node_456 -> ["192.168.2.8:8002", "192.168.2.9:8002"]
  node_789 -> ["192.168.3.1:8002"]
              |                          |
   fetchUser (Trust & Use)    getHostIP (Verify First)
              |                          |
   If fails: Remove & Retry  If unhealthy: Remove & Skip
              |                          |
          API: Get fresh IPs, test, add working ones back
```

The pool is fully self-healing: bad entries are removed on failure, good entries are added on success. No manual maintenance needed.
