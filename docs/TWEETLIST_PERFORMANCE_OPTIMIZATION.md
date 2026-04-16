# Tweet List Performance Optimization

## Overview

This document summarizes the tweet list performance work completed in the UIKit feed implementation.

The main goal was to reduce scroll-time work in the common feed path, with priority given to **regular tweets** because they make up the vast majority of rows. Retweet-specific cleanup was limited to cases where it materially improved the shared feed path, but retweets were not the main optimization target.

## Primary Problems Addressed

- Main-thread work during cell configuration and prefetch
- Repeated per-cell observer setup during fast scrolling
- Duplicate author-loading work across visible cells
- Repeated menu construction for cells that were already on screen
- Extra per-scroll passes over visible rows for video visibility bookkeeping
- SwiftUI controller churn in document attachment rows

## Changes Made

### 1. Reduced scroll-time work in `TweetTableViewController`

File:
- `Sources/Tweet/UIKit/TweetTableViewController.swift`

Changes:
- Removed synchronous embedded-tweet cache warming from `cellForRowAt`.
- Replaced synchronous prefetch work with async cache warming.
- Added lightweight helper methods to map rows to tweets and prefetch embedded tweet IDs only when needed.
- Narrowed embedded-tweet prefetching so feed updates only warm newly introduced quoted/retweeted tweet IDs instead of sweeping the entire list every time.
- Collapsed video visibility bookkeeping into a single pass over visible cells inside `updateVisibleTweetsForVideoPlayback()`.

Expected impact:
- Less main-thread blocking during scrolling.
- Lower repeated work during deceleration and drag updates.
- Less redundant prefetch churn during feed refreshes.

### 2. Reused document hosting instead of recreating it per cell

File:
- `Sources/Tweet/UIKit/TweetBodyUIView.swift`

Changes:
- Replaced repeated `UIHostingController` creation/removal with a reusable hosting controller per `TweetBodyUIView`.
- Reset hosted document content with `EmptyView()` during reuse/configure instead of tearing the host down each time.
- Added cleanup in `deinit` for the retained hosting controller.

Expected impact:
- Lower allocation churn for tweets with document attachments.
- Fewer child view controller attach/detach operations during feed reuse.

### 3. Reduced redundant header subscriptions

File:
- `Sources/Tweet/UIKit/TweetHeaderUIView.swift`

Changes:
- Split tweet-level subscriptions from user-level subscriptions.
- Ensured only one active set of `User` field subscriptions exists at a time.
- Avoided re-subscribing to the same author repeatedly when the author object did not actually change.

Expected impact:
- Less Combine overhead during repeated cell configuration.
- Fewer unnecessary label updates in visible rows.

### 4. Reduced unnecessary author subscriptions and deduplicated author loading

File:
- `Sources/Tweet/UIKit/TweetCellContentView.swift`

Changes:
- Regular tweets no longer subscribe for “author appeared” when the author is already present.
- Added per-author deduplication for cache loads and background refreshes across cells.
- Reused populated `User` singletons immediately when available.

Expected impact:
- Less repeated async work for authors appearing in many visible tweets.
- Lower cache and network churn during fast scrolls.

### 5. Reduced action bar update churn

File:
- `Sources/Tweet/UIKit/TweetActionBarView.swift`

Changes:
- Added `removeDuplicates()` to action bar Combine pipelines for counts and favorites state.

Expected impact:
- Fewer no-op UI refreshes when published values do not actually change.

### 6. Reduced avatar configuration churn

File:
- `Sources/Tweet/UIKit/AvatarUIView.swift`

Changes:
- Cached width/height constraints instead of searching the constraint list on every configure.
- Removed extra notification observers that duplicated existing `user.$avatar` and `userDidUpdate` handling.

Expected impact:
- Less per-cell configure overhead.
- Lower observer churn in long scrolling sessions.

### 7. Cached tweet menus and refreshed them on same-row updates

File:
- `Sources/Tweet/UIKit/TweetCellContentView.swift`

Changes:
- Added a small menu cache keyed by tweet/menu state.
- Moved menu application ahead of the “same tweet” early return.
- Ensured menu state updates correctly for visible rows when pin/privacy/delete state changes without forcing a full cell reconfigure.

Expected impact:
- Less repeated `UIMenu` construction.
- Correct menu refresh behavior for already-visible rows.

## Retweet-Specific Notes

Some retweet/quoted-tweet changes were included because they touched shared feed-path infrastructure:

- Embedded tweet loading was moved away from synchronous main-thread warming in list/controller code.
- Placeholder-based async loading remains in the embedded tweet view.

However, this optimization pass intentionally **did not** try to fully optimize retweet rendering because regular tweets are the dominant case.

## Files Changed

- `Sources/Tweet/UIKit/TweetTableViewController.swift`
- `Sources/Tweet/UIKit/TweetBodyUIView.swift`
- `Sources/Tweet/UIKit/TweetHeaderUIView.swift`
- `Sources/Tweet/UIKit/TweetCellContentView.swift`
- `Sources/Tweet/UIKit/TweetActionBarView.swift`
- `Sources/Tweet/UIKit/AvatarUIView.swift`
- `Sources/Tweet/UIKit/EmbeddedTweetUIView.swift`

## Validation

Validation completed:
- IDE lint checks on edited files
- Swift 6 concurrency warning cleanup for helper tasks and queue usage
- Manual compile-error follow-up for document-host reuse fallout

Validation not fully completed in this environment:
- Full `xcodebuild` verification was not completed successfully in the sandboxed session because of local workspace/simulator environment constraints.

## Follow-Up Candidates

If more feed work is needed later, the next likely targets are:

- Further regular-tweet-only measurement with Instruments
- Additional menu/action-bar reuse if profiling still shows hotspots
- Retweet-specific cleanup once the regular-tweet path is considered good enough
