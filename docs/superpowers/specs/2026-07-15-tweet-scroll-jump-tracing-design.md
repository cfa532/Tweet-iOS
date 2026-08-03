# Tweet Scroll-Jump Tracing Design

## Goal

Identify the exact row-height mutation or table relayout that causes a visible tweet item to move upward while the user scrolls down.

## Scope

Add debug-only, event-focused console logging to `TweetTableViewController`. Do not change row heights, scrolling, anchoring, cache behavior, or update timing.

## Events

Use one searchable prefix: `🧭 [SCROLL JUMP TRACE]`.

1. When a visible cell reports a new desired height, log the feed identifier, tweet ID, row, old cached height, requested height, content offset, and scrolling state.
2. Immediately before a pending height relayout, log the pending tweet IDs, visible anchor tweet and row, anchor-relative offset, content offset, and content height.
3. Immediately after the relayout, log the same geometry plus the raw offset drift.
4. If anchor restoration changes the content offset, log the requested correction and its delta. Otherwise, explicitly log that no correction was needed.

## Noise Control

Do not log every `scrollViewDidScroll` callback. Logs are emitted only when a cell requests a height change or the controller applies a pending height relayout.

## Verification

- Confirm the app compiles for the iOS Simulator.
- Confirm all new messages share the searchable prefix.
- Confirm the change is logging-only and preserves the existing relayout and anchor-restoration logic.
