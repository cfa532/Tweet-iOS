# Tweet Body Tap Enhancement

## Summary
Implemented simplified tweet content interaction:
1. Tapping tweet body content navigates to tweet detail view
2. "More..." indicator appears when text is truncated (intelligent detection)
3. Tapping "More..." button also navigates to tweet detail view
4. Clean, simple implementation without expansion/collapse complexity

## Changes Made

### 1. TweetItemBodyView.swift
- **Added Parameters:**
  - `onTweetBodyTap: (() -> Void)?` - Callback to navigate to tweet detail when body or "More..." is tapped
  - `isTruncated: Bool` - State to track if text is actually truncated

- **Added PreferenceKey:**
  - `TruncationPreferenceKey` - Detects when text exceeds 7 lines by comparing full height vs limited height
  - Uses hidden GeometryReader to measure text in both states
  - Updates `isTruncated` state when truncation is detected

- **Text Tap Gesture:**
  - Taps on body text call `onTweetBodyTap()` to navigate to tweet detail view
  - Simple, direct navigation without expansion logic

- **"More..." Button:**
  - Changed from "Show more" to "More..." for better consistency
  - Shown when text is **actually truncated** (not just character count > 500)
  - Uses GeometryReader-based truncation detection
  - Compares full text height vs 7-line limited height
  - Button action: Calls `onTweetBodyTap()` to navigate to detail view
  - No debouncing needed - direct navigation is instant

### 2. TweetItemView.swift
- **Updated 4 instances of TweetItemBodyView:**
  1. Regular tweets (line ~422)
  2. Retweets with content (line ~297)
  3. Retweets without content showing original tweet (line ~261)
  4. Loading placeholder for retweets (line ~356)

- **Added onTweetBodyTap callback** that:
  - Checks if `onTap` callback exists
  - Calls `onTap` with the appropriate tweet (original tweet for retweets)
  - Works with existing navigation system (NavigationLink or callback-based)

### 3. EmbeddedTweetView (in TweetItemView.swift)
- **Updated 1 instance of TweetItemBodyView** (line ~531)
- Added `onTweetBodyTap` callback for embedded tweets
- Navigates to embedded tweet detail when body is tapped

### 4. CommentItemView.swift
- **Updated 1 instance of TweetItemBodyView** (line ~64)
- Added `onTweetBodyTap` callback for comment tweets
- Navigates to comment detail when body is tapped

### 5. NotificationNames.swift
- **Added new notification:**
  ```swift
  static let tweetHeightDidChange = Notification.Name("tweetHeightDidChange")
  ```
- Posted when tweet content expands/collapses
- Includes `tweetId` in userInfo dictionary

### 6. Localization Files
- **Updated 3 language files:**
  - `en.lproj/Localizable.strings`: Added "More..." = "More..."
  - `zh-Hans.lproj/Localizable.strings`: Added "More..." = "更多..."
  - `ja.lproj/Localizable.strings`: Added "More..." = "続きを見る..."

### 7. TweetTableViewController.swift
- **Added observer setup (infrastructure for future use):**
  - `tweetHeightObserver` property to store observer
  - `setupTweetHeightObserver()` method to register for notifications
  - Cleanup in `deinit` to remove observer
  - `handleTweetHeightChange(_ notification: Notification)` method
  - Currently not actively used (no expansion/collapse), but available for future features

## How It Works

### Truncation Detection Flow
1. Text is rendered with `.lineLimit(7)` to show maximum 7 lines
2. Hidden GeometryReader measures the same text with `.lineLimit(nil)` (full height)
3. Background GeometryReader compares:
   - Full text height (unlimited lines)
   - Limited text height (7 lines max)
4. If full height > limited height, text is truncated
5. TruncationPreferenceKey propagates truncation state to `isTruncated`
6. "More..." button appears when `isTruncated && !isExpanded`

### Navigation Flow
1. User taps tweet body text OR "More..." button
2. `TweetItemBodyView` calls `onTweetBodyTap()`
3. Callback invokes `TweetItemView.onTap` with the tweet
4. In `HomeView`, `onTap` appends tweet to `navigationPath`
5. Navigation system shows `TweetDetailView` for the tweet
6. User can read full content in detail view

## Benefits

### User Experience
- **Intuitive navigation**: Tap tweet text or "More..." to view full details
- **Accurate truncation indicator**: "More..." appears only when text is actually truncated
- **Consistent across languages**: Localized "More..." in English, Chinese, and Japanese
- **Simple and fast**: Direct navigation without complex expansion logic
- **Clear intent**: Both tap targets lead to same destination (detail view)

### Technical
- **Simpler code**: Removed expansion/collapse logic and debouncing complexity
- **Reusable**: Works for tweets, retweets, embedded tweets, and comments
- **Efficient**: Intelligent truncation detection without character count guessing
- **Clean**: Single responsibility - navigate to detail view

## Testing Recommendations

1. **Truncation Detection**:
   - Tweet with < 7 lines → should NOT show "More..."
   - Tweet with exactly 7 lines → should NOT show "More..."
   - Tweet with > 7 lines → should show "More..."
   - Tweet with 200 chars but long lines → should show "More..." if > 7 lines
   - Tweet with 600 chars but short lines → should show "More..." if > 7 lines
   - Test in English, Chinese, and Japanese to verify localization

2. **Navigation**:
   - Tap tweet body → should navigate to detail view
   - Tap "More..." button → should navigate to detail view
   - Both actions should have same result
   - Test with regular tweets, retweets, and comments

3. **Edge Cases**:
   - Very short tweets (1-2 lines) → no "More..." button, body tap still works
   - Tweets with exactly 7 lines → no "More..." button (not truncated)
   - Tweets with mixed text and media → verify "More..." only for text
   - Pinned tweets vs regular tweets → both should show "More..." when truncated
   - Retweets with/without original content → verify proper truncation detection
   - Wide characters (CJK) → verify line counting works correctly
   - Emojis and special characters → verify truncation detection
