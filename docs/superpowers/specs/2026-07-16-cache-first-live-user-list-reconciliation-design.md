# Cache-First Live User List Reconciliation Design

## Goal

Follower and following screens must render cached users immediately, then update the same open screen from an asynchronous authoritative ID-list fetch. Every valid ID must own a row placeholder until its user loads; successful loads render and terminal failures remove only that row.

## Evidence and Root Cause

The observed profile reported four followers while its cached `fansList` held only three IDs. The current page-zero fetcher returns those cached IDs immediately and launches `get_followers_sorted` or `get_followings_sorted` in an unobserved background task. That task updates and persists the profile owner's `User`, but `UserListView` has already copied the old IDs into private state and never reconciles the fresh result. A newly discovered remote user therefore appears only on the next screen opening.

Android supplies the desired row lifecycle: a known ID creates a placeholder, username arrival renders the row, and terminal loading failure hides it. iOS `UserRowView` already provides the equivalent placeholder/success/failure behavior. The missing behavior is live delivery of refreshed IDs into the currently open iOS list.

## Considered Approaches

1. **Cache-first plus explicit live reconciliation — selected.** Give `UserListView` separate cache and authoritative fetch phases. Render the cached phase immediately, await the authoritative phase asynchronously, then replace the open list state. This preserves fast opening and makes new IDs visible without reopening.
2. **Wait for the authoritative list before rendering.** This guarantees complete IDs but regresses cached-first responsiveness and leaves the screen loading during slow remote calls.
3. **Broadcast a notification after the hidden background refresh.** This keeps the existing fetcher shape but adds indirect coupling, untyped payloads, and loop/race risks with existing `.userDidUpdate` notifications.

## Data Flow

### Cached phase

When page zero begins:

1. Hydrate the profile owner's cached `User` from memory or Core Data.
2. Read the cached `fansList` or `followingList`.
3. Filter empty, guest, duplicate, socially blocked, and reliability-blacklisted IDs.
4. Publish the cached first page into `UserListView` immediately.
5. Each published ID creates a `UserRowView`.
6. A row with cached renderable user data displays it immediately. A row without renderable data displays its existing placeholder.

### Authoritative phase

After the cached phase is published, and without blocking its rendering:

1. Call the ordinary sorted-list read API for the profile owner.
2. Treat a successful response, including an empty response, as authoritative.
3. Store the complete returned ID list in the owner's `fansList` or `followingList` and persist the user.
4. Slice the authoritative list for the requested page.
5. Apply the same invalid/blocked/deduplication filters.
6. Reconcile the currently open `UserListView` in server order:
   - Add newly returned IDs.
   - Remove IDs absent from the successful authoritative response.
   - Keep enough rows revealed to cover the normal visible batch.
   - Recompute pagination state.
7. Prefetch the authoritative page with the existing concurrency limit.

A newly discovered remote ID therefore appears immediately as a placeholder. Its `UserRowView` independently resolves the route and loads `fetchUser`. Published singleton fields replace cached content in place; a cold row renders on success.

## Failure and Cancellation

- If the authoritative ID-list request fails and cached IDs exist, retain the cached list and do not replace it with an error.
- If both cache and authoritative loading fail or produce no usable cached fallback, show the existing retry error.
- A terminal row-user failure invokes the existing `onLoadFailed` path, removes that ID from the current UI, and records reliability failure. It must not delete the social relationship from the owner's authoritative ID list.
- Cancel cache refresh, authoritative refresh, row loading, and prefetch work when the screen disappears.
- Pull-to-refresh uses the same cache-preserving authoritative reconciliation: existing rows stay visible while the fresh response is awaited.
- New diagnostics use the structured logger; do not add `print`.

## Scope

Modify only the iOS profile list loading boundary and the minimum caller wiring needed to expose separate cached and authoritative phases. Do not change backend APIs, synchronization/recovery APIs, user-cache lifespan, row layout, follow toggling, Android code, or the established `UserRowView` loading algorithm.

## Verification

- Reproduce the stale-cache case with a cached list missing one authoritative ID.
- Verify cached rows appear before the authoritative request completes.
- Verify the missing ID is inserted into the still-open screen as a placeholder.
- Verify its row renders after asynchronous user loading succeeds.
- Verify a terminal row failure removes the placeholder without mutating the owner's authoritative social list.
- Verify blocked IDs never receive rows.
- Verify an authoritative empty list clears cached rows.
- Verify authoritative failure preserves cached rows.
- Verify follower and following screens share the behavior.
- Build the iOS target and review the final diff for impacts to pagination, cancellation, and callers.

