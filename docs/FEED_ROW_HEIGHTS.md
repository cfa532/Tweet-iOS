# Feed Row Heights

How `TweetTableViewController` decides how tall a feed row is, why that number has to match
the cell's Auto Layout **exactly**, and the failure modes that show up when it doesn't.

Applies to the main feed, profile feeds, bookmarks/favorites lists, and any other surface
backed by `TweetTableView`.

---

## 1) The invariant

> The value `heightForRowAt` returns MUST equal the height the cell's own Auto Layout would
> produce for the same width.

The feed does not self-size. `heightForRowAt` returns a concrete number for every ordinary
row, and UIKit lays the cell out into exactly that frame. `TweetTableViewCell` pins its
content to the top of the cell and its bottom constraint is only `.defaultHigh`, so a
mismatch **breaks silently**: no constraint-conflict log, no visible error — the content
just sits a fraction of a point away from where the separator is drawn.

Two rows opt out and are measured by Auto Layout (`UITableView.automaticDimension`):

- rows in `expandedTweetIds` (user tapped "More…")
- saved comments that gain an embedded parent (`originalTweetId == nil` but
  `effectiveEmbeddedTweetId(for:) != nil`) — a bookmark/favorite-list-only presentation

Neither writes to the shared height caches.

---

## 2) Two paths, one answer

`UITableView` asks two different questions and they must agree.

| Callback | Called for | Path |
| --- | --- | --- |
| `estimatedHeightForRowAt` | **every** row, including during `insertRows` | in-memory cache → persisted cache → warm-text fast path → `roughHeightEstimate` |
| `heightForRowAt` | only rows being realized | in-memory cache → persisted cache → `calculateTweetHeight` |

Both are **cache-first**, in the same order:

1. `tweet.cachedHeight` / `cachedHeightWidth` — in-memory, written by `willDisplay` from the
   rendered cell frame.
2. `TweetHeightCache.shared` — persisted across launches, keyed `mid|width`.
3. A computed value.

Serving cache-first is deliberate: it postpones any height change to a safe reconcile point
instead of letting it land mid-scroll. See `performPendingHeightRelayout`.

**Why the estimate matters.** UIKit banks the estimate to compute `contentSize`. When a row
is realized and `heightForRowAt` disagrees, `contentSize` changes underneath a running
deceleration. Rows below the viewport absorb this invisibly; a row entering from the **top**
displaces everything on screen. So `roughHeightEstimate` being "just an estimate" is not
free — it is a scroll-stability budget.

---

## 3) The row model

`contentWidth = rowWidth − cellHorizontalPadding − 3 (mainStack leading) − 46 (avatar) − 4 (stack spacing)`

Top to bottom, matching `TweetCellContentView`:

| Component | Height | Notes |
| --- | --- | --- |
| Top padding | `16`, or `6 + 18 + 2 = 26` | the larger form is the "Forwarded by" banner |
| Header | `TweetHeaderUIView.measuredHeaderHeight(for:availableWidth: contentWidth)` | **measured, not assumed** — see §4 |
| Header gap | `2` | `contentColumn.setCustomSpacing(2, after: headerView)` |
| Body | `2` + visible items + gaps | see §5 |
| Body gap | `12` (quote) / `4` (caption visible) / `10` | `updateBodyToActionSpacing` |
| Embedded card | `8 + max(32, measuredHeader) + 4 + embeddedBody + contentBottomPadding` | quote tweets only |
| — not loaded | `EmbeddedTweetUIView.placeholderHeight` (36) | |
| Embed gap | `10` | quote tweets only |
| Action bar | `30` | fixed |
| Bottom padding | `8` | `mainStack.bottom == separator.top − 8` |
| Separator | `1` | |

Widths that are easy to get wrong:

- media grid = `contentWidth − 2` (`mediaGridView.trailing == mediaContainer.trailing − 2`)
- embedded content = `contentWidth − 12`, embedded media grid = `contentWidth − 14`
- header label = `availableWidth − 48` — the hidden menu button's 44pt plus a 4pt gap stay
  in the layout even when the button is hidden

---

## 4) Rounding rule

> Round a component only where the **view** rounds it. Never "for safety".

| Component | Rounding | Why |
| --- | --- | --- |
| Header | none | the header view's height *is* its label's fitting height |
| Text | none | ditto for `contentLabel` |
| Media grid | **`ceil`** | `MediaGridUIView.intrinsicContentSize` reports `ceil(gridWidth / aspectRatio)` |
| Caption | none | single line → the font's `lineHeight` |
| Audio / documents | already `ceil`ed | the same function sets the constraint constant, so it cannot disagree |

Rounding "up to be safe" is what produced a systematic **+1pt per row** error: `ceil` on the
header and the text, against a media grid that was *missing* its `ceil`. The errors partly
cancelled, which is exactly why it survived so long.

---

## 5) UIStackView spacing — the subtle one

`TweetBodyUIView.contentStack` is a `UIStackView` over
`[contentLabel, audioContainer, mediaContainer, captionLabel, documentContainer]`.

> A **hidden** arranged subview contributes neither its height **nor the custom spacing that
> follows it**.

So gaps must be counted between consecutive **visible** items, not once per attachment kind.
Every gap `configure()` installs is `8`, except **media → caption**, which is `2`.

```
bodyHeight = 2 (contentStack top inset)
           + Σ visible item heights
           + Σ gaps between consecutive visible items
```

The old code added `+8` whenever media was present, regardless of whether `contentLabel` was
visible — so a media-only tweet (no text) was over-reported by a full 8pt.

---

## 6) Caches and who owns them

| Cache | Lives on | Written by | Dropped by |
| --- | --- | --- | --- |
| `cachedHeight` / `cachedHeightWidth` | `Tweet` | `willDisplay`, `performPendingHeightRelayout` | `clearCachedHeight`, `invalidateRenderCaches()` |
| `TweetHeightCache.shared` | UserDefaults | `setCachedHeight` | `removeHeight` |
| `cachedMeasuredTextHeight` / `Width` | `Tweet` | `calculateTweetHeight` (UILabel), `TweetHeightPrewarmer` (background) | `invalidateRenderCaches()` |
| `cachedContentAttributedString` / `cachedContentWidth` | `Tweet` | `TweetBodyUIView.renderTextContent`, `calculateTweetHeight`, prewarmer | `invalidateRenderCaches()` |
| `cachedHeaderHeight` / `cachedHeaderWidth` | `Tweet` | `measuredHeaderHeight` | `author` didSet, `invalidateRenderCaches()` |
| `TweetHeightPrewarmer.shared` | global dictionary | background measurement, republished by `calculateTweetHeight` | `invalidate(tweetId:)` |

Two rules that follow from this table:

- **Every render-affecting mutation goes through `applyRenderAffectingUpdate`.** These caches
  live on the `Tweet` singleton and outlive any cell, so a view-layer observer only sees the
  changes that happen to land while a cell is bound.
- **Two caches holding the same quantity must not be allowed to diverge.** The prewarmer
  dictionary and `cachedMeasuredTextHeight` are read by different code paths for the same
  row; when `calculateTweetHeight` measures with UILabel it now republishes the result into
  the prewarmer so the estimate path cannot keep serving a superseded number.

`TweetHeightCache.removeHeight` deliberately does **not** write to disk. It runs from
`willDisplay` / `didEndDisplaying` during scrolling, and `saveToDisk()` JSON-encodes the
whole table (up to 2000 entries) on the main thread. Persistence happens on the
background/terminate observers.

---

## 7) Off-main text measurement

`TweetHeightPrewarmer` measures text on a background thread so the first frame of a row does
not pay for CoreText. It cannot use `UILabel` (main-thread only, TextKit2), so it lays the
string out with `NSTextStorage` + `NSLayoutManager` and takes
`layoutManager.usedRect(for: textContainer).height`.

**Do not go back to `attrStr.boundingRect(with:options:context:)`.** It returns the union of
the line-fragment rects, which:

- **omits the paragraph style's `lineSpacing` between lines** — a flat `3 × (lines − 1)`
  short, i.e. exactly **−18pt** at the 7-line cap; and
- ignores `maximumNumberOfLines` entirely.

That number is what `estimatedHeightForRowAt` banks, so it disagreed with the later UILabel
measurement by a whole line gap and moved `contentSize` under the scroll every time such a
row was realized.

A residual TextKit1-vs-TextKit2 disagreement of up to ~1pt is expected and accepted; it is
the price of measuring off the main thread.

### Cold estimate

Before any measurement lands, `TweetBodyUIView.estimatedTextHeight` advances characters by
script — CJK / fullwidth / emoji at one em, everything else at half — and adds
`contentLineSpacing`. The previous heuristic assumed a flat 8.5pt per character, which
counts roughly twice as many characters per line as a Chinese tweet actually fits, so
estimates came out one to five whole lines short.

---

## 8) Diagnosing a suspected height bug

Do this before assuming heights are the cause. Three throwaway probes answer it in one run:

1. **Ledger over `heightForRowAt`** — `[tweetId: (height, sourceTag)]`; log whenever the same
   tweet is served a different number. *If this is silent, heights are stable and the problem
   is elsewhere.*
2. **Estimate-drift log** — record what `roughHeightEstimate` returned, compare against the
   first real `heightForRowAt` for that tweet, and tag which branch produced the estimate
   (prewarm vs cold). This is what moves `contentSize`.
3. **Predicted-vs-actual breakdown** — emit `calculateTweetHeight`'s components, and from
   `TweetTableViewCell.layoutSubviews` (**not** `willDisplay` — frames are stale there) emit
   the laid-out heights of `headerView` / `bodyView` / each `contentStack` item. Line them up
   and the wrong component is obvious.

Gate all three behind an environment variable and launch with
`SIMCTL_CHILD_<VAR>=1 xcrun simctl launch --console-pty <udid> com.example.Tweet`. The app's
Run configuration is **Release**, so `#if DEBUG` code never reaches the device — traces must
be unconditional.

Note that frame values are snapped to the screen's pixel grid (⅓pt at 3×), so component sums
can be off by ±0.33 without anything being wrong.

---

## 9) What this subsystem is *not* responsible for

Measured on an iPhone 17 Pro simulator (Release), 3 down + 3 up swipes, before and after
making the calculator exact:

| | Before | After |
| --- | --- | --- |
| `calculateTweetHeight` vs cell Auto Layout | +0.05 … +1.33pt on every row | **0.00** |
| Estimate-drift events | 12 | **2** |
| `contentSize` changes mid-scroll | present | **none** (pagination inserts only) |
| Height flips (same row, different height) | 0 | 0 |
| Dropped frames during coast | 5.5% | 5.9% |

The last row is the important one: **fixing the heights did not change the frame-to-frame
shake.** 44 of 46 dropped frames in the baseline had nothing logged during the gap. The
residual shake is per-cell work when a row enters the viewport — image decode, player
acquisition and attach — not height arithmetic.

For that class of problem see [VIDEO_PLAYBACK_PIPELINE.md](./VIDEO_PLAYBACK_PIPELINE.md) and
the stall-sampler approach in [ENGINEERING_NOTES.md](./ENGINEERING_NOTES.md). Simulator
figures overstate it considerably; profile on device.

The other half of the residual scroll-**down** cost turned out not to be layout at all but
runaway pagination — see *Feed Pagination Must Be Driven by Content, Not by State
Transitions* in [ENGINEERING_NOTES.md](./ENGINEERING_NOTES.md). Worth checking first when
scroll-down is rougher than scroll-up, since auto-load is inherently one-directional.

---

## Source of truth

- `Sources/Tweet/UIKit/TweetTableViewController.swift` — `calculateTweetHeight`,
  `roughHeightEstimate`, `addAttachmentHeights`, `performPendingHeightRelayout`
- `Sources/Tweet/UIKit/TweetCellContentView.swift` — the constraints the calculator mirrors
- `Sources/Tweet/UIKit/TweetBodyUIView.swift` — `contentStack`, `estimatedTextHeight`
- `Sources/Tweet/UIKit/TweetHeaderUIView.swift` — `measuredHeaderHeight`
- `Sources/Tweet/UIKit/TweetHeightPrewarmer.swift` — background measurement
- `Sources/Core/TweetHeightCache.swift` — persistence
