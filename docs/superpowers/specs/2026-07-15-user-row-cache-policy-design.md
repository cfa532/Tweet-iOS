# User Row Cache Policy Design

## Goal

Stop iOS and Android follower/following screens from issuing a forced `get_user` request for every rendered cached row. Continue showing cached user data immediately, use each client's existing shared 30-minute user-cache lifespan for ordinary row loading, and keep profile opening as the explicit forced-refresh boundary.

## Context

`UserRowView` currently loads the shared `User` singleton from memory or Core Data. When that cached user has a renderable username, the row displays it immediately and then calls `fetchUser` with `forceRefresh: true`. That bypasses the existing expiry policy and creates one server refresh per rendered row.

Android follower/following batches call `UserViewModel.prefetchUsers`, which uses ordinary `fetchUser(id)`. The current Android worktree also removes the older `UserViewModel` initialization-time forced fetch and moves forced profile refresh into the profile-opening `initLoad` path. That already implements the desired row/profile separation and must be preserved without overwriting the existing in-progress route-validation changes.

The shared `fetchUser` path already treats cached users as fresh for 30 minutes. `ProfileView` separately calls `fetchUser` with `forceRefresh: true` when a profile opens. The canonical synchronization contract says routine screen opening should use normal reads and keep explicit recovery behavior separate.

## Considered Approaches

1. **Use the existing cache policy in list rows — selected.** Remove the row's forced-refresh argument and let `fetchUser` return fresh cached data or refresh expired data. This is the smallest coherent change and preserves the existing global lifespan.
2. **Change the global lifespan to one day.** This would reduce refreshes across every `fetchUser` caller, not just follower/following rows, and is broader than necessary.
3. **Add a follower-row-specific timestamp or flag.** This duplicates cache state and adds complexity without improving on the shared cache policy.

## Design

When a cached follower/following row appears:

- Render its cached singleton immediately when it has a valid username.
- Keep route preparation through `applyReadNodeBaseUrlIfAvailable`.
- Call ordinary `fetchUser(userId)` without forcing a refresh or disabling the standard expired-cache refresh.
- A cache entry younger than 30 minutes returns without a network request.
- An expired entry returns stale data immediately and starts a deduplicated background refresh.

Cold rows without renderable cached data retain their current blocking fetch behavior so the placeholder remains until a usable user arrives. List prefetching remains unchanged. Opening `ProfileView` retains its forced refresh and route validation. Pull-to-refresh continues to refresh follower/following IDs and does not become a bulk forced user refresh.

On Android, list prefetching continues to call ordinary `fetchUser(id)`: fresh entries return from cache, expired entries render stale data and start a deduplicated background refresh, and uncached entries load from the server. `UserViewModel.initLoad` continues to validate/repair the route and force-refresh user data when an actual profile opens. No additional Android production edit is required if those existing worktree changes remain present; verification must confirm both boundaries.

## Failure Behavior

If an expired cached user's background refresh fails, the cached row remains visible and its cache status records the failure. If a cold row cannot obtain a renderable user after retries, the existing failure and row-removal behavior remains unchanged.

## Verification

- Add or update focused tests where practical to verify the cached-row fetch policy.
- Confirm `UserRowView` no longer passes `forceRefresh: true`.
- Confirm `ProfileView` still passes `forceRefresh: true` on profile opening.
- Confirm Android follower/following prefetch uses ordinary `fetchUser(id)`.
- Confirm Android profile `initLoad` still reaches `refreshUserDataFromServer`, whose fetch remains forced.
- Build the affected target and run relevant tests.
- Review the final diff to ensure list loading, cold-cache recovery, cancellation, and profile refresh behavior are otherwise unchanged.
