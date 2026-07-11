# Detail Pull-to-Refresh Tweet Design

## Goal

Call `refresh_tweet` only from explicit pull-to-refresh gestures in Tweet Detail and Comment Detail. Opening a detail view and the Tweet Detail five-minute timer must use ordinary server reads instead.

## Tweet Detail Behavior

- Opening the view keeps the existing ordered `get_tweet` followed by `get_comments` sequence.
- Pull-to-refresh calls `refresh_tweet` for the displayed tweet data, then refreshes comments.
- Pull-to-refresh replaces its current `get_tweet` call with `refresh_tweet`; it does not call both APIs.
- Retweet and quoted-tweet handling continues through the existing `doResyncTweet` implementation, including its current original-tweet behavior.
- The five-minute timer calls the existing server-read helper with `fromDetailView` disabled. It reloads tweet data with `get_tweet` and does not call `refresh_tweet` or refresh comments.

## Comment Detail Behavior

- Opening the view keeps its existing `get_tweet` detail-view read.
- The outer comment-detail scroll view gains pull-to-refresh.
- Pull-to-refresh calls `refresh_tweet` for the displayed comment, applies the returned data to the existing comment model, and then calls `get_comments` for page zero of that comment's replies.
- The refreshed page-zero replies replace the bound reply list. A small external refresh token tells the embedded comment list to reset its page and `hasMoreComments` state so subsequent pagination continues from the refreshed page zero.

## Failure and Cancellation Behavior

- All operations remain best-effort, matching the existing `try?` behavior.
- Pull-to-refresh awaits the requested operation so the system spinner reflects completion.
- A failed tweet/comment refresh does not clear the currently displayed model or comments.

## Scope

This change does not alter `HproseInstance`, backend request models, comment pagination, timer frequency, or initial ordered loading. Existing uncommitted changes in Tweet Detail and the UIKit comment list must be preserved.

## Verification

- Confirm initial detail loading contains no `refresh_tweet` call.
- Confirm Tweet Detail pull-to-refresh reaches `doResyncTweet` and then comments.
- Confirm the five-minute timer reaches `doReadTweet(isInitialLoad: false)` instead of `doResyncTweet`.
- Confirm Comment Detail pull-to-refresh reaches `refreshTweet` while its open-time task still reaches `getTweet`.
- Confirm Comment Detail pull-to-refresh subsequently fetches page-zero replies with `fetchComments` and resets embedded pagination state.
- Build the iOS app target for the simulator.
