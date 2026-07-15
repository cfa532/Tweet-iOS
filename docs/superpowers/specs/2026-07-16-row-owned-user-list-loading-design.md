# Row-Owned User List Loading Design

## Goal

Match Android's follower/following row lifecycle on iOS. Every accepted relationship ID must be represented by a row when its batch is presented. Cached user content renders immediately; otherwise the row renders a placeholder and owns the asynchronous load that either replaces the placeholder or dismisses the row.

## Scope

This change affects only follower/following user-object loading on iOS.

It does not change:

- authoritative follower/following ID synchronization,
- user-cache lifetime,
- profile-screen force-refresh behavior,
- blacklist persistence or cache-clearing behavior,
- backend APIs or recovery routing, or
- Android code.

## Current Conflict

`UserListView` publishes relationship IDs and immediately starts a separate prefetch task for the same users. That task can fetch, fail, or temporarily blacklist an ID before SwiftUI has rendered its `UserRowView`. Its errors are suppressed with `try?`.

This creates two owners for one lifecycle:

1. list-level prefetch, and
2. row-level loading.

The race can make an invalid or remote user disappear without an observable placeholder transition.

## Selected Design

Remove list-level user prefetching. `UserListView` owns only relationship IDs, filtering, ordering, and presentation batching. `UserRowView` exclusively owns loading the user object for an ID.

For every ID admitted to `displayedUserIds`:

1. Create `UserRowView` immediately.
2. Read the cached user.
3. If the cached user has a renderable identity, show it immediately and apply the existing cache-lifetime refresh policy.
4. If no renderable cached user exists, show the placeholder before starting the asynchronous fetch.
5. On successful fetch with a renderable identity, replace the placeholder with the user row.
6. On terminal failure or an unusable result, dismiss the row through `onLoadFailed`.

The existing visible-batch mechanism remains. IDs beyond the current batch are admitted when the user scrolls; once admitted, each gets the same row-owned lifecycle. This preserves bounded concurrent work while matching Android's lazy-list behavior.

## Blacklist Behavior

Existing blacklist filtering remains unchanged. An ID that is already considered blacklisted is excluded before row creation, consistent with the earlier requirement that all relationship IDs render except blacklisted ones.

The cache-clear action will not be changed and the blacklist will not be reset.

## Logging

`UserRowView` must not use `print`. Its structured logger records:

- an uncached user load attempt,
- a successful load,
- a terminal load failure or unusable result,
- a cached refresh failure that retains the cached row, and
- cancellation at debug level.

User IDs use explicit OSLog privacy annotations so diagnostic output is intentional and consistent.

## Failure Semantics

A failed user-object load removes only the local row. It does not remove the ID from the profile owner's authoritative `fansList` or `followingList`, because transport failure is not evidence that the social relationship was deleted.

## Verification

Source regression checks will prove that:

- `UserListView` no longer owns a prefetch task or calls `prefetchUsers`,
- `UserRowView` contains no `print`,
- uncached attempt and terminal failure paths use structured logging, and
- authoritative list reconciliation remains wired.

The dependency-aware `Tweet.xcworkspace` simulator build must pass after the change.
