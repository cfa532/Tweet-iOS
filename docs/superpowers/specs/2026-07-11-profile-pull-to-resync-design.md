# Profile Pull-to-Resync Design

## Goal

Stop running `resync_user` automatically when a profile opens. Run it only as part of an explicit profile pull-to-refresh, and keep the refresh indicator active until the operation finishes.

## Current Behavior

`ProfileView.refreshProfileData()` fetches fresh user data whenever a profile first opens. After refreshing pinned tweets, it calls `resync_user` when the user's current read host differs from the root host. The resync response updates the cached user and supplies synchronized tweets to the profile timeline.

The profile timeline's pull-to-refresh currently refreshes page zero and then invokes an extra callback that refreshes only pinned tweets.

## Design

Give profile refresh orchestration an explicit trigger that distinguishes initial loading from a user pull.

- Initial profile loading fetches fresh user data and refreshes pinned tweets. It does not call `resync_user`.
- Profile pull-to-refresh first uses the existing timeline page-zero refresh and then invokes the profile refresh callback.
- The profile refresh callback fetches fresh user data, refreshes pinned tweets, and conditionally calls `resync_user` only when the refreshed user's read host differs from its root host.
- The pull-to-refresh callback awaits all of this work, so the refresh indicator stops only after the conditional resync succeeds or fails.

The existing `HproseInstance.resyncUser` implementation and profile resynced-tweet pipeline remain unchanged. Successful results continue to update the user and tweet caches and flow through the existing new-tweets banner behavior.

## Failure and Cancellation Behavior

- If the user fetch fails, pinned-tweet refresh and resync are skipped, matching the current dependency on a successfully refreshed route.
- If resync fails, the failure remains non-fatal. Timeline, user, and pinned-tweet results already obtained remain visible.
- Cancellation prevents a resync from starting where the existing cancellation check applies.
- Root-host profiles skip resync because no node synchronization is necessary.

## Scope

This change does not remove the resync API, alter the backend contract, change timeline pagination, or introduce retries. It only changes when the existing resync operation is triggered.

## Verification

- Verify the initial profile task invokes profile refresh without resync enabled.
- Verify the profile pull-to-refresh callback invokes profile refresh with resync enabled and awaits completion.
- Verify root-host profiles still skip `resync_user`.
- Verify non-root profiles pass returned tweets through the existing cache and timeline update path.
- Build the affected iOS target to catch Swift concurrency and closure-signature regressions.
