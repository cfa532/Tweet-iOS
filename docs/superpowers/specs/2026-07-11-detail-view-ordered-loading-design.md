# Tweet Detail Ordered Loading Design

## Goal

Opening a tweet detail view must show locally cached content immediately, then let the server synchronize the tweet and its comments before the client reads the comments from the read node. The opening sequence must not issue duplicate comment requests.

## Data flow

`TweetDetailView` owns one initial-loading sequence for each displayed tweet:

1. Restore the cached tweet already supplied to the view and restore cached comments from `TweetDetailCommentsCache`.
2. Call `getTweet` with `bypassCache: true` and `fromDetailView: true`, then await its completion. The server uses this request to synchronize the tweet and its comments from the write node to the read node.
3. Attempt to fetch comments from the server after the tweet request finishes. This comment request still runs if the tweet request throws or returns no tweet.
4. Merge the returned tweet and comments into the displayed state and caches.

The initial sequence does not call `refreshTweet`. The separate opening-time resynchronization is redundant because the server performs that work for `getTweet(fromDetailView: true)`.

## Ownership

`TweetDetailView` remains responsible for initial cache restoration, the ordered server refresh, and pull-to-refresh. `CommentListUIKitView` renders the bound comments and requests later pages when the user reaches the bottom. It does not independently request page zero when it first appears.

This single-owner arrangement removes the race in which the parent view and comment list both fetch page zero and both miss the user cache concurrently.

## Refresh and pagination

Pull-to-refresh follows the same ordering: await the tweet read first, then fetch comments. It does not request both concurrently because comments must be read after the server-side synchronization opportunity.

Pagination remains owned by `CommentListUIKitView` and is unchanged. Cached comments can appear before the initial server sequence completes, but they do not suppress the subsequent server comment refresh.

## Failure behavior

Cached tweet and comments remain visible when network operations fail. Failure of the tweet request does not prevent the comment request. Existing non-blocking error behavior remains unchanged; this change does not introduce a new alert or retry policy.

## Verification

Add focused tests around an extracted loading-order helper or equivalent testable boundary. Verify that:

- cached state is served before network work starts;
- comments are fetched only after the tweet request completes;
- comments are still fetched when the tweet request fails;
- the initial open performs one page-zero comment request;
- pull-to-refresh preserves tweet-then-comments ordering.

Build the app after the focused tests pass. A server-log check should show one detail-view tweet synchronization/read followed by one `get_comments` request on an uncached open.
