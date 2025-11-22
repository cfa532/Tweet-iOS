# Video Player Architecture - Optimized for Performance

## Overview: 3 Separate Player Systems

Each video context has its own optimized player management system to prevent interference and maximize performance.

---

## 1. **MediaCell** (Feed/Grid View) - Shared Players

**Purpose**: Multiple tweets in feed showing the same video

**Cache Strategy**:
- **Player Cache Key**: `mid` (e.g., `"QmXXX"`)
- **Storage**: 
  - `SharedAssetCache` (player instances)
  - `VideoStateCache` (playback state sharing)

**How It Works**:
1. First MediaCell requests player → Creates new player, caches it
2. Other MediaCells showing same video → Reuse cached player
3. All share the same player instance (efficient memory usage)

**Performance**: ✅ **Excellent** - Maximum reuse, minimal memory

**Example**:
```
Tweet A (video QmXXX) → Creates player, caches as "QmXXX"
Tweet B (video QmXXX) → Reuses cached player "QmXXX"
Tweet C (video QmYYY) → Creates new player, caches as "QmYYY"
```

---

## 2. **TweetDetailView** (Detail Screen) - Singleton Player ⚡ OPTIMIZED

**Purpose**: Single video in detail view (isolated from feed)

**Cache Strategy**:
- **Player**: Persistent singleton instance (never recreated)
- **Storage**: `DetailVideoManager.shared.singletonPlayer`
- **Assets**: `SharedAssetCache` (for video data only)

**How It Works** (Optimized):
1. **First video**: Creates singleton player instance
2. **Switch videos**: Reuses same player, just replaces `currentItem`
3. **Exit view**: Pauses player, clears item, but keeps player instance
4. **Re-enter**: Reuses existing singleton player

**Performance**: ✅ **Excellent** - Player never recreated, only items swapped

**Key Optimization**:
- Uses `getOrCreatePlayerItem()` instead of `getOrCreatePlayer()`
- Reuses singleton player instance (like FullScreenVideoManager)
- Assets are cached, so video data is reused

**Example**:
```
Open DetailView (video QmXXX) → Creates singleton player + item
Switch to video QmYYY → Reuses player, replaces item
Exit DetailView → Pauses, clears item, keeps player
Re-open DetailView → Reuses existing player, creates new item
```

---

## 3. **MediaBrowserView** (Fullscreen) - Singleton Player

**Purpose**: Fullscreen video browser with auto-advance

**Cache Strategy**:
- **Player**: Persistent singleton instance (never recreated)
- **Storage**: `FullScreenVideoManager.shared.singletonPlayer`
- **Assets**: `SharedAssetCache` (for video data only)

**How It Works**:
1. **First video**: Creates singleton player instance
2. **Swipe to next**: Reuses same player, replaces `currentItem`
3. **Exit**: Pauses player, clears item, but keeps player instance
4. **Re-enter**: Reuses existing singleton player

**Performance**: ✅ **Excellent** - Player never recreated

---

## Why This Architecture?

### Separation of Concerns
- **MediaCell**: Needs to share players (many tweets, same video)
- **TweetDetail**: Needs isolation (shouldn't affect feed)
- **Fullscreen**: Needs persistence (smooth navigation)

### Performance Benefits

1. **No Player Recreation**:
   - DetailVideoManager: Singleton player reused
   - FullScreenVideoManager: Singleton player reused
   - MediaCell: Players cached and reused

2. **Asset Reuse**:
   - All systems use `SharedAssetCache` for assets
   - Video data downloaded once, reused everywhere
   - Disk caching for offline playback

3. **Memory Efficiency**:
   - MediaCell: Shared players = less memory
   - Detail/Fullscreen: Single player = minimal memory

### Cache Key Isolation

```
MediaCell:        "QmXXX"                    → Separate player
TweetDetail:     "tweetDetail_QmXXX"         → Separate player  
Fullscreen:      (singleton, no cache key)   → Separate player
```

**Result**: No interference between systems! ✅

---

## Performance Comparison

| System | Player Recreation | Asset Caching | Memory Usage |
|--------|------------------|---------------|--------------|
| MediaCell | Cached (reused) | ✅ Cached | Low (shared) |
| TweetDetail | **Never** (singleton) | ✅ Cached | Minimal (1 player) |
| Fullscreen | **Never** (singleton) | ✅ Cached | Minimal (1 player) |

**Best Performance Achieved!** 🚀

