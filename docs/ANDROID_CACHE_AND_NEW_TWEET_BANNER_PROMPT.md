# Android Cache Scheme And New-Tweet Banner Prompt

Use this prompt when updating the Android client to match the current iOS tweet cache and new-tweet banner behavior.

```text
Update the Android tweet cache scheme and new-tweet banner behavior to match the current iOS design.

First, review the existing Android timeline/profile/cache code and identify where tweets are cached, loaded from cache, merged into visible lists, and where new-tweet banners are shown.

Cache scheme requirements:

1. Cache keys must describe the list being cached, not only the tweet or current user.
2. One device may be used by multiple signed-in users, so cached timeline rows must not mix across accounts.
3. Use these cache keys:
   - Main feed: main_feed_<appUserId>
   - User profile timeline: <profileUserMid>
   - Bookmarks: bookmark_list_<userId>
   - Favorites: favorite_list_<userId>
   - Original/embedded tweet lookup: save the tweet under its authorId
4. A tweet may belong to multiple cached lists at the same time. Store list membership by (tweetId, cacheKey), not by tweetId alone.
5. Saving a tweet into one cache list must not move it out of another cache list.
6. If the same tweet exists in multiple cache lists, refresh the tweet payload across cached copies while preserving each row's own cache key.
7. Direct tweet lookup by tweetId should search across cache keys and prefer the newest cached copy.
8. If Android currently used appUserId as the main-feed cache key, add a temporary legacy fallback: read main_feed_<appUserId> first, and if empty, read the old appUserId cache.

New-tweet banner requirements:

Main feed:
1. On initial open, load cached main-feed tweets immediately from main_feed_<appUserId>.
2. Results from normal get_tweet_feed should merge into the visible tweet list.
3. Results from get_followings_tweet / update_following_tweets should go through the new-tweet banner path.
4. The main-feed banner count should count only tweets not already visible in the main feed.
5. If the banner disappears without being tapped, cache those new tweets anyway.
6. When the user taps the banner, merge the pending tweets and scroll to the first new tweet.

Profile screen:
1. On profile open, load cached profile tweets immediately from <profileUserMid>.
2. Normal profile fetch and resync results should follow the same rule:
   - If the profile tweet list is at its natural top, render new tweets directly.
   - If the profile tweet list is not at top, cache/stage the new tweets and show a profile new-tweet banner.
3. "At top" means the profile header is still visible. Do not scroll the first tweet to the top in a way that hides the profile header.
4. The profile banner count should count only new tweets not already visible in that profile list.
5. When the profile banner is tapped, merge the pending tweets and scroll to the first new tweet. If that tweet is the first regular tweet in the profile, preserve the natural profile top/header behavior.
6. Do not reset scroll position when newly fetched tweets arrive after the user has started scrolling. Scroll stability wins.

Implementation guidance:
1. Prefer simplifying existing conflicting code before adding new flags.
2. Keep RecyclerView/Compose scrolling stable: no automatic scroll jumps after background fetch, profile fetch, pinned tweet refresh, or resync.
3. Make sure all backend-fetched tweets that are staged behind a banner are also cached under the correct list key.
4. Add or update tests if the Android project has cache/timeline tests.
5. After implementation, verify:
   - Main feed cache does not mix between two different logged-in users.
   - Profile cache survives main-feed refreshes.
   - Main feed banner only counts unseen new tweets.
   - Profile banner/direct-render behavior depends on current scroll position.
   - Opening a profile at top does not jump so the header disappears.
```
