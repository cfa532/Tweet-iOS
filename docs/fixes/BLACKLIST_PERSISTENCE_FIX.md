# BlackList Persistence Enhancement

**Date:** October 20, 2025  
**Status:** ✅ Complete

---

## Problem

The BlackList system, which tracks and blocks repeatedly failed media resources, was lost when:
1. User cleared the app cache
2. User reinstalled the app

This meant the app would retry loading known-broken content after these events, wasting bandwidth and degrading performance.

---

## Root Cause

BlackList was originally using `UserDefaults` for persistence, which:
- ✅ Survives cache clearing
- ❌ Does NOT survive app reinstallation (stored in app sandbox)

---

## Solution

Implemented **dual-storage strategy** with UserDefaults as primary and iCloud Key-Value Store as backup.

### Storage Architecture

```
┌─────────────────────────────────────────────┐
│           BlackList.swift                   │
├─────────────────────────────────────────────┤
│                                             │
│  Load Priority:                             │
│  1. UserDefaults (authoritative)            │
│  2. iCloud (fallback if local missing)      │
│                                             │
│  Save Strategy:                             │
│  1. UserDefaults (immediate write)          │
│  2. iCloud (background sync)                │
│                                             │
└─────────────────────────────────────────────┘
```

### Key Design Decisions

1. **UserDefaults as Primary**
   - Fast, local, immediate reads/writes
   - Source of truth for runtime behavior
   - No network dependency
   - Survives cache clearing

2. **iCloud as Backup**
   - Best-effort sync across devices
   - Survives app reinstallation
   - Graceful degradation if unavailable
   - No user configuration required
   - `NSUbiquitousKeyValueStore.default`

3. **Load Order**
   ```swift
   if let data = UserDefaults.standard.data(forKey: "BlackList.blacklist") {
       // Use local data (fast, authoritative)
   } else if let data = NSUbiquitousKeyValueStore.default.data(forKey: "BlackList.blacklist") {
       // Fallback to iCloud (reinstall recovery)
   }
   ```

4. **Save Order**
   ```swift
   // Write to UserDefaults first (immediate)
   UserDefaults.standard.set(data, forKey: "BlackList.blacklist")
   
   // Mirror to iCloud (background, best-effort)
   NSUbiquitousKeyValueStore.default.set(data, forKey: "BlackList.blacklist")
   NSUbiquitousKeyValueStore.default.synchronize()
   ```

---

## Implementation

### File Modified
- `Sources/Core/BlackList.swift`

### Changes

**loadFromStorage():**
```swift
// Prefer UserDefaults, fallback to iCloud
if let blacklistData = localStore.data(forKey: "BlackList.blacklist"),
   let blacklistArray = try? JSONDecoder().decode([String].self, from: blacklistData) {
    blacklist = Set(blacklistArray.map { MimeiId($0) })
    print("[BlackList] Loaded \(blacklist.count) blacklisted items from UserDefaults")
} else if let blacklistData = iCloudStore.data(forKey: "BlackList.blacklist"),
          let blacklistArray = try? JSONDecoder().decode([String].self, from: blacklistData) {
    blacklist = Set(blacklistArray.map { MimeiId($0) })
    print("[BlackList] Loaded \(blacklist.count) blacklisted items from iCloud (local missing)")
}
```

**saveToStorage():**
```swift
// Save to UserDefaults first (authoritative)
let localStore = UserDefaults.standard
localStore.set(blacklistData, forKey: "BlackList.blacklist")
localStore.set(candidatesData, forKey: "BlackList.candidates")

// Mirror to iCloud as backup (best-effort)
let iCloudStore = NSUbiquitousKeyValueStore.default
iCloudStore.set(blacklistData, forKey: "BlackList.blacklist")
iCloudStore.set(candidatesData, forKey: "BlackList.candidates")
iCloudStore.synchronize()
```

---

## Benefits

### User Experience
- ✅ **No Bandwidth Waste**: BlackList persists after reinstall
- ✅ **Faster Loading**: Blocked resources stay blocked
- ✅ **Zero Config**: Works automatically (no user action)
- ✅ **Cross-Device**: iCloud syncs blacklist across devices

### Technical
- ✅ **Resilient**: Dual-storage with fallback
- ✅ **Performant**: UserDefaults for fast reads
- ✅ **Graceful**: Works offline, handles iCloud unavailability
- ✅ **Simple**: No special setup or entitlements needed

### Network Efficiency
- ✅ **Server-Friendly**: Stops retrying known-broken IPFS content
- ✅ **Bandwidth Savings**: No repeated failed requests
- ✅ **Performance**: Less time wasted on dead resources

---

## Testing Scenarios

### Scenario 1: Cache Clear
**Steps:**
1. App has blacklisted resources
2. User clears cache
3. Restart app

**Expected:**
- ✅ BlackList loads from UserDefaults
- ✅ Blacklisted resources remain blocked

### Scenario 2: Reinstall (iCloud ON)
**Steps:**
1. App has blacklisted resources
2. Delete and reinstall app
3. Launch app

**Expected:**
- ✅ BlackList loads from iCloud
- ✅ Blacklisted resources remain blocked

### Scenario 3: Reinstall (iCloud OFF)
**Steps:**
1. App has blacklisted resources
2. Disable iCloud
3. Delete and reinstall app
4. Launch app

**Expected:**
- ✅ BlackList starts fresh
- ⚠️ Resources can be retried (expected behavior)

### Scenario 4: Multiple Devices (iCloud ON)
**Steps:**
1. Device A blacklists resource
2. Sync to iCloud
3. Device B launches app

**Expected:**
- ✅ Device B loads blacklist from iCloud
- ✅ Same resources blocked on both devices

---

## User Requirements

**NONE!** 🎉

The system works automatically:
- ❌ No prompts
- ❌ No permissions
- ❌ No iCloud setup required
- ❌ No user configuration
- ✅ Just works

---

## Documentation Updates

- ✅ Updated `FEATURES.md` - BlackList description
- ✅ Updated `NETWORK_RESILIENCE.md` - Added BlackList system section
- ✅ Updated `INDEX.md` - Added recent update entry
- ✅ Created `BLACKLIST_PERSISTENCE_FIX.md` - This document

---

## Related Files

- `Sources/Core/BlackList.swift` - Implementation
- `docs/FEATURES.md` - Feature overview
- `docs/NETWORK_RESILIENCE.md` - Detailed documentation
- `docs/INDEX.md` - Change log

---

*This fix ensures the BlackList system remains effective even after cache clearing or app reinstallation, improving performance and reducing wasted bandwidth on known-broken resources.*

