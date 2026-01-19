# Codebase-Wide Performance Issues Found

## Summary
Found **critical performance issues** similar to TweetListView in multiple files across the codebase.

---

## 🔥 CRITICAL: ContentView.swift

### Issue
**10 `.onReceive()` calls inside `body`** - Creates new notification observers on EVERY render

### Affected Notifications:
1. `.tweetSubmitted` 
2. `.tweetPrivacyUpdated`
3. `.navigationVisibilityChanged`
4. `.newTweetCreated`
5. `.newCommentAdded`
6. `.backgroundUploadFailed`
7. `.memoryWarningCritical`
8. `UIApplication.willEnterForegroundNotification`
9. `.deeplinkReceived`
10. `.deeplinkTweetNotFound`

### Impact:
- **HIGH** - ContentView is the root view, so it re-renders frequently
- Every state change creates 10 new observers
- After 100 state changes: **1000+ observers** processing every notification
- Affects entire app performance

### Location:
`ContentView.swift:188-348`

### Fix Required:
Move observers to `.onAppear` with proper cleanup in `.onDisappear`

---

## ⚠️ MEDIUM: ProfileView.swift

### Issue  
**1 `.onReceive()` call inside `body`** for `.tweetPinStatusChanged`

### Impact:
- **MEDIUM** - ProfileView renders less frequently than ContentView
- Still accumulates observers when switching between profiles
- Can cause slowdown after viewing many profiles

### Location:
`ProfileView.swift:111-120`

### Fix Required:
Move observer to `.onAppear` with cleanup

---

## ⚠️ LOW: TweetDetailView.swift

### Issue
**1 `.onReceive()` call inside `body`** for `.tweetDeleted`

### Impact:
- **LOW** - Detail views are short-lived
- Less frequent rendering than list views
- Still technically a leak but minimal impact

### Location:
`TweetDetailView.swift:454-459`

### Fix Required:
Move observer to `.onAppear` with cleanup

---

## ✅ GOOD: Other Files

These files handle observers **correctly**:
- `SingletonVideoManagers.swift` - Stores observers, properly cleans up
- `UploadProgressManager.swift` - Uses `weak self`, stores observers
- `TweetListView.swift` - **FIXED** in previous session

---

## Performance Impact Estimate

| File | Observers | Re-render Freq | Impact | Priority |
|------|-----------|----------------|--------|----------|
| **ContentView** | 10 | Very High | **CRITICAL** | 🔥 Fix Now |
| ProfileView | 1 | Medium | MEDIUM | ⚠️ Soon |
| TweetDetailView | 1 | Low | LOW | 🟢 Optional |

---

## Recommended Fix Order

### 1. ContentView.swift (CRITICAL)
This is likely the **main remaining cause** of performance degradation:
- Root view of entire app
- Re-renders on every tab change
- Re-renders on navigation changes
- Re-renders on state updates
- **10 observers x 100 renders = 1000 observers!**

### 2. ProfileView.swift (MEDIUM)
Fix when convenient:
- Less critical but still accumulates
- Noticeable when viewing many profiles

### 3. TweetDetailView.swift (LOW)
Lowest priority:
- Short-lived views
- Minimal accumulation
- Can defer to cleanup sprint

---

## Code Pattern to Search

To find more instances, search for:
```swift
.onReceive(NotificationCenter.default.publisher
```

Inside SwiftUI `body` or `View` computations.

**Red flag:** If `.onReceive` is not paired with `.onDisappear` cleanup

---

## Testing After Fixes

1. **Monitor observer count:**
   - Add logging to observer setup
   - Should see stable count (not growing)

2. **Memory test:**
   - Navigate through app for 5 minutes
   - Memory should plateau, not grow

3. **CPU test:**
   - Scroll feeds, switch tabs
   - CPU should stay < 40%

4. **Notification test:**
   - Send test notification
   - Check how many handlers execute (should be 1 per observer)

---

## Automation Opportunity

Consider creating a SwiftLint rule:
```yaml
custom_rules:
  no_onreceive_in_body:
    name: "No .onReceive in body"
    message: "Use .onAppear + .onDisappear for NotificationCenter observers"
    regex: '(var body.*\{(?:[^}]|\n)*\.onReceive\(NotificationCenter)'
    severity: error
```

---

## Summary

**Root cause:** SwiftUI `.onReceive()` modifier creates NEW observer on every view re-render

**Solution:** Move to `.onAppear` with proper cleanup

**Impact:** After fixing ContentView, app should feel **significantly faster** 🚀
