# Saved Comment Parent Context Design

## Goal

Keep bookmarked and favorited comments meaningful by displaying each saved comment as quote content with its immediate parent tweet or comment embedded beneath it.

## Data Model

Add an optional `parentTweetId: MimeiId?` field to `Tweet` and its sendable/cache representation, `TweetRecord`. A top-level tweet leaves the field absent. Every newly created comment or reply sets it to the ID of the object passed as the parent of `add_comment`.

The field always identifies the immediate parent. Therefore, a comment on a top-level tweet points to that tweet, while a reply to a comment points to that comment. This matches the canonical one-level parent/child reference and synchronization contract.

`parentTweetId` must survive JSON encoding and decoding, singleton creation and merging, record snapshots, Core Data cache payloads, copies, and upload serialization. Its absence remains valid for top-level tweets and comments created by older clients.

## Semantics and Compatibility

`originalTweetId` and `originalAuthorId` retain their existing retweet and deliberately authored quote-tweet meaning. The feature must not copy `parentTweetId` into either property or mutate a shared `Tweet` singleton to simulate a quote tweet.

Older comments without `parentTweetId` render as ordinary saved tweets. The client does not guess or migrate a missing relationship. Backend and sibling clients may ignore the optional field until they add equivalent support; decoding must therefore remain backward compatible.

The feature does not change comment ownership, node routing, parent-to-child references, pagination lists, normal reads, or explicit recovery synchronization. Comments continue to be created on the immediate parent author's root node and referenced by that immediate parent.

## Comment Creation Flow

Both comment composition paths create the comment object with `parentTweetId` equal to the parent object's `mid` before scheduling the upload. This applies equally to a reply whose parent is itself a comment.

Quote-comment behavior remains independent. If a user deliberately posts a comment as a quote tweet, the existing upload flow may additionally populate `originalTweetId`; `parentTweetId` still records the comment relationship.

## Saved-List Presentation

Bookmark and favorite lists provide an explicit saved-list presentation context to tweet cells. In that context only, a tweet with `parentTweetId` is presented as follows:

- The saved comment is the outer item and retains its own author, content, attachments, timestamp, actions, navigation, and saved state.
- The immediate parent is resolved by `parentTweetId` and rendered using the existing embedded-tweet card beneath the comment, matching quote-tweet presentation.
- The parent is loaded from the in-memory store or cache first, then through the ordinary tweet read path when necessary.
- Missing, deleted, inaccessible, or not-yet-loaded parents use the existing unavailable/loading embedded-content behavior without hiding the saved comment.

Outside bookmark and favorite lists, `parentTweetId` has no presentation effect. Timeline, profile, tweet detail, comment detail, and reply threads continue to render comments using their existing layouts.

The implementation should centralize selection of the effective embedded reference so SwiftUI and UIKit feed paths use the same rule:

1. An actual retweet/quote continues to use `originalTweetId` and `originalAuthorId`.
2. A bookmark/favorite comment may use `parentTweetId` as a presentation-only embedded reference.
3. No other item gains an embedded reference.

Because `parentTweetId` does not include a parent author ID, the saved-list loader first resolves the parent from the cache. If a network read requires an author ID, it should use parent metadata already returned by the saved-list API/cache rather than infer an author or alter node routing. If current API responses do not provide enough metadata for an uncached parent, the comment remains visible with unavailable embedded content; expanding the backend API is outside this iOS-only change.

## Caching and Height Calculation

When loading bookmark/favorite cache entries, include the resolved parent payload the same way cached quote tweets include their original payload. Ensure the parent singleton and author are merged before the saved comment cell is configured.

Cell sizing, height prewarming, embedded media registration, and reuse invalidation must use the same effective embedded reference as rendering. This prevents clipped cards, stale reused content, and incorrect video ownership. Ordinary comment cells must not acquire an asynchronous embedded-height dependency.

## Error Handling

The optional field must never make decoding fail when absent. A parent lookup failure must not prevent the saved comment from appearing or disable its actions. Existing deleted/unavailable embedded-tweet handling should be reused rather than introducing new recovery state.

## Testing

Add focused regression coverage for:

- `Tweet` and `TweetRecord` encode/decode round trips preserving `parentTweetId` and accepting its absence.
- Record snapshots, `makeTweet`, singleton merges, updates, and copies preserving the field.
- New comments and replies assigning the immediate parent's ID.
- Saved-list embedded-reference selection preferring normal quote semantics and otherwise selecting `parentTweetId` only for bookmark/favorite presentation.
- Normal timeline/detail/comment presentation ignoring `parentTweetId`.
- Cached bookmark/favorite loading resolving the immediate parent without changing ordering.
- Height/reuse identity changing when the effective embedded reference changes.

Run the focused unit tests, the full Tweet test target, and a clean Swift build for the app scheme. Existing user changes to the shared scheme and Xcode UI state must remain untouched.

## Out of Scope

- Backfilling `parentTweetId` on historical comments.
- Embedding the root/top-level tweet for replies; replies embed their immediate parent comment.
- Changing comment storage, synchronization depth, or recovery behavior.
- Refactoring all retweet and quote-tweet architecture beyond the small shared embedded-reference selection needed by this feature.
