# Tweet Avatar Update Fix - January 2026

## Problem Statement

Tweet avatars were not updating promptly when the author (User) object was loaded or updated. Even though both Tweet and User use singleton patterns, the UI wasn't reflecting changes to User properties (like `avatar`, `baseUrl`, `name`, etc.) in real-time.

## Root Cause Analysis

The issue had two root causes:

### 1. Missing Notification
When `User.updateUserInstance()` was called to update a User singleton with new data, no notification was being posted to inform observing views that the user had been updated. The `Avatar` view was listening for `.userDidUpdate` notification (defined in `NotificationNames.swift`), but this notification was never being posted.

### 2. Inconsistent Singleton References
Tweet instances weren't consistently pointing to the User singleton. When a Tweet was created or updated, it might receive a User instance that wasn't the singleton, leading to different Tweet instances having different User object references for the same user.

## Solution

### 1. Post `.userDidUpdate` Notification

Modified `User.updateUserInstance()` to post a `.userDidUpdate` notification after updating the user singleton:

```swift
// Post notification to inform all observers that this user has been updated
// This ensures tweet avatars and other views observing this user refresh
NotificationCenter.default.post(
    name: .userDidUpdate,
    object: nil,
    userInfo: ["userId": instance.mid]
)
```

This notification is posted in both the synchronous (main thread) and asynchronous paths of the method.

### 2. Ensure Tweet.author Always Points to User Singleton

Modified three key methods in `Tweet.swift`:

#### a. `Tweet.getInstance()`
```swift
// CRITICAL: Always ensure tweet's author points to the User singleton
// This ensures when the User singleton is updated, all tweets referencing it see the update
if let author = author {
    // If author is provided, ensure it's the singleton instance
    let authorSingleton = User.getInstance(mid: author.mid)
    existingInstance.author = authorSingleton
} else if existingInstance.author == nil {
    // If no author is set yet, set it to the User singleton for this authorId
    existingInstance.author = User.getInstance(mid: authorId)
} else if existingInstance.author?.mid != authorId {
    // If author mid doesn't match authorId, fix it
    existingInstance.author = User.getInstance(mid: authorId)
}
```

#### b. `Tweet.update(from: Tweet)`
```swift
// CRITICAL: Always ensure tweet's author points to the User singleton
// Update author if provided, ensuring it's the singleton instance
if let otherAuthor = other.author {
    let authorSingleton = User.getInstance(mid: otherAuthor.mid)
    self.author = authorSingleton
} else if self.author == nil {
    // If no author is set yet, set it to the User singleton for this authorId
    self.author = User.getInstance(mid: self.authorId)
}
```

#### c. `Tweet.update(from: [String: Any])`
Similar logic applied to ensure consistency when updating from dictionary data.

## How It Works

### Data Flow

1. **User data is loaded/updated** (e.g., from cache, network, or background fetch)
   ```
   User.from(dict:) or User.updateUserInstance(with:)
   ```

2. **User singleton is updated** with new properties (name, avatar, baseUrl, etc.)
   ```
   User.getInstance(mid:) returns the singleton
   Properties are updated on the singleton instance
   ```

3. **Notification is posted**
   ```
   NotificationCenter.post(name: .userDidUpdate, userInfo: ["userId": mid])
   ```

4. **Avatar views receive notification**
   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .userDidUpdate)) { notification in
       // Reload avatar for this specific user
       if let userId = notification.userInfo?["userId"] as? String,
          userId == user.mid {
           // Clear cache and reload avatar
       }
   }
   ```

5. **UI updates automatically**
   - Avatar reloads with new `user.avatarUrl` (computed from `user.avatar` + `user.baseUrl`)
   - Name/username updates via `@ObservedObject` on User
   - All tweets sharing the same User singleton see the updates

### Singleton Pattern Enforcement

```
Tweet A (authorId: "user123") ──┐
                                  ├──> User Singleton (mid: "user123")
Tweet B (authorId: "user123") ──┘

When User Singleton updates:
├─> Properties change (avatar, baseUrl, name, etc.)
├─> Notification posted (.userDidUpdate)
└─> All views observing this User refresh
    ├─> Tweet A's Avatar view reloads
    └─> Tweet B's Avatar view reloads
```

## Files Modified

1. **`/Sources/DataModels/User.swift`**
   - Modified `User.updateUserInstance()` to post `.userDidUpdate` notification (lines ~445 and ~503)

2. **`/Sources/DataModels/Tweet.swift`**
   - Modified `Tweet.getInstance()` to ensure author points to User singleton (lines ~22-30)
   - Modified `Tweet.update(from: Tweet)` to maintain singleton reference (lines ~261-270)
   - Modified `Tweet.update(from: [String: Any])` to maintain singleton reference (lines ~348-356)

## Testing Scenarios

### Before Fix
1. Load tweets from cache → avatars show placeholder
2. User data loads from network → `User.updateUserInstance()` called
3. User properties update → **No notification posted**
4. Avatar views don't reload → **Avatars stay as placeholder** ❌

### After Fix
1. Load tweets from cache → avatars show placeholder
2. User data loads from network → `User.updateUserInstance()` called
3. User properties update → **Notification posted** ✅
4. Avatar views receive notification → **Avatars reload with correct image** ✅

## Benefits

1. **Immediate UI Updates**: Avatars and user info update as soon as User data is loaded
2. **Memory Efficiency**: All tweets sharing the same author use the same User singleton
3. **Data Consistency**: No risk of having stale User data in different Tweet instances
4. **Reactive Updates**: SwiftUI's `@ObservedObject` and notification system work together seamlessly

## Edge Cases Handled

1. **Tweet with nil author**: Automatically set to User singleton for authorId
2. **Tweet with wrong author**: If author.mid doesn't match authorId, it's corrected
3. **User updated off main thread**: Notification posted on correct thread
4. **Multiple tweets with same author**: All share same singleton, all update together

## Related Components

- **Avatar.swift**: Listens for `.userDidUpdate` notification
- **MediaCell.swift**: Also listens for user updates to reload media URLs
- **TweetItemHeaderView.swift**: Uses `@ObservedObject` on User for name/username
- **NotificationNames.swift**: Defines `.userDidUpdate` notification

## Future Considerations

This fix establishes a solid pattern for reactive data updates:
- User singleton updates → Notification → UI refreshes
- Can be extended to other observable properties if needed
- Notification system provides loose coupling between data layer and UI layer
