# Comment System Architecture & Implementation

## Overview

The comment system in this Twitter-like app allows users to comment on tweets and replies. Comments are implemented as Tweet objects with specific properties to distinguish them from regular tweets.

## Architecture

### Comment as Tweet Objects
- **Comments are Tweet objects**: Each comment is a valid Tweet with its own `mid`, `authorId`, `content`, etc.
- **Comment identification**: Comments have `originalTweetId` set to the parent tweet's `mid`
- **Comment hierarchy**: Comments can have replies, creating a nested structure

### Tweet Types and Comment Handling

#### 1. Regular Tweets
- **Display**: Show their own content and media
- **Comments**: Load their own comment list
- **Action buttons**: Use the tweet's own action buttons

#### 2. Retweets (No Content)
- **Identification**: `tweet.content?.isEmpty == true` AND `tweet.attachments?.isEmpty == true`
- **Display**: Show the original tweet's content with "Forwarded by" indicator
- **Comments**: Load the **original tweet's comment list** (not the retweet's)
- **Action buttons**: Use the original tweet's action buttons
- **Navigation**: When tapped, open TweetDetailView with the retweet, but display original tweet's content and comments

#### 3. Quote Tweets (With Content)
- **Identification**: `tweet.content?.isNotEmpty == true` OR `tweet.attachments?.isNotEmpty == true`
- **Display**: Show their own content with embedded original tweet
- **Comments**: Load their **own comment list** (not the original tweet's)
- **Action buttons**: Use the quote tweet's own action buttons
- **Navigation**: When tapped, open TweetDetailView with the quote tweet

## Key Implementation Details

### TweetDetailView.displayTweet Logic
```swift
private var displayTweet: Tweet {
    let isRetweet = (tweet.content == nil || tweet.content?.isEmpty == true) &&
                   (tweet.attachments == nil || tweet.attachments?.isEmpty == true)
    
    if isRetweet {
        return originalTweet ?? tweet  // Use original tweet for retweets
    } else {
        return tweet  // Use tweet itself for quote tweets and regular tweets
    }
}
```

### Comment Fetching
- **Comment fetcher**: Uses `displayTweet` to fetch comments
- **For retweets**: Fetches comments from the original tweet
- **For quote tweets**: Fetches comments from the quote tweet itself
- **For regular tweets**: Fetches comments from the tweet itself

### Comment Notification System

#### Notification Types
1. **`newCommentAdded`**: Posted when a new comment is created
2. **`commentDeleted`**: Posted when a comment is deleted

#### Notification Filtering
Each view filters notifications based on the parent tweet's `mid`:

```swift
CommentListNotification(
    name: .newCommentAdded,
    key: "comment",
    shouldAccept: { comment in
        // Only accept comments that belong to this tweet
        comment.originalTweetId == displayTweet.mid
    },
    action: { comment in 
        comments.insert(comment, at: 0)
    }
)
```

### CommentItemView Parent Tweet
**Critical Fix**: CommentItemView must receive the correct parent tweet:

```swift
// CORRECT - Use displayTweet
CommentItemView(
    parentTweet: displayTweet,  // ← This ensures proper notification filtering
    comment: comment,
    // ...
)

// INCORRECT - Using tweet directly
CommentItemView(
    parentTweet: tweet,  // ← This causes notification filtering issues
    comment: comment,
    // ...
)
```

## Comment Posting Process

### 1. Comment Creation
```swift
// In HproseInstance.addComment()
let comment = Tweet(
    mid: commentId,
    authorId: appUser.mid,
    content: commentContent,
    originalTweetId: parentTweet.mid,  // ← Links to parent tweet
    originalAuthorId: parentTweet.authorId,
    // ...
)
```

### 2. Notification Posting
```swift
// Only post newCommentAdded, NOT newTweetCreated
NotificationCenter.default.post(
    name: .newCommentAdded,
    object: nil,
    userInfo: ["comment": comment]
)
```

### 3. Comment Caching
- Comments are NOT cached as regular tweets
- Comments only appear in comment sections
- Comments do NOT appear in main feed

## Issues and Solutions

### Issue 1: Comments Appearing in Main Feed
**Problem**: Comments were being posted as `newTweetCreated` notifications, causing them to appear in the main feed.

**Solution**: Modified comment posting to only post `newCommentAdded` notifications, not `newTweetCreated`.

### Issue 2: Retweets Not Showing Comments
**Problem**: When retweets were tapped, the CommentItemView was receiving the retweet as parent instead of the original tweet, causing notification filtering to fail.

**Solution**: Changed `parentTweet: tweet` to `parentTweet: displayTweet` in TweetDetailView's CommentItemView.

### Issue 3: Comment Notification Filtering
**Problem**: Comments were being accepted by all comment lists instead of only the relevant parent tweet's list.

**Solution**: Implemented proper `shouldAccept` filtering based on `comment.originalTweetId == displayTweet.mid`.

## File Structure

### Core Files
- `Sources/DataModels/Tweet.swift` - Tweet model with comment properties
- `Sources/Core/HproseInstance.swift` - Comment posting and fetching logic
- `Sources/Core/TweetCacheManager.swift` - Tweet caching (excludes comments)

### UI Components
- `Sources/Tweet/TweetDetailView.swift` - Main tweet detail view with comments
- `Sources/Tweet/CommentDetailView.swift` - Comment detail view with replies
- `Sources/Tweet/CommentItemView.swift` - Individual comment display
- `Sources/Tweet/CommentListView.swift` - Generic comment list component
- `Sources/Tweet/TweetItemView.swift` - Tweet display with retweet/quote logic
- `Sources/Tweet/TweetActionButtonsView.swift` - Action buttons (comment, retweet, like, etc.)

### View Models
- `Sources/Tweet/CommentsViewModel.swift` - Comment list management

## Best Practices

1. **Always use `displayTweet`** for comment-related operations in TweetDetailView
2. **Filter notifications properly** using `shouldAccept` based on `originalTweetId`
3. **Don't cache comments** as regular tweets
4. **Use correct parent tweet** in CommentItemView for proper notification handling
5. **Distinguish between retweets and quote tweets** for proper comment loading

## Debugging

When debugging comment issues, check:
1. `displayTweet.mid` vs `tweet.mid`
2. `comment.originalTweetId` vs parent tweet's `mid`
3. Notification filtering logic
4. Comment fetching parameters
5. Parent tweet passed to CommentItemView

## Future Considerations

- Consider adding comment threading levels
- Implement comment pagination optimization
- Add comment moderation features
- Consider comment notification preferences
- Implement comment search functionality
