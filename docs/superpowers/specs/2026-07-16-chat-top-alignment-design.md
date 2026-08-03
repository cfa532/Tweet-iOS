# Chat Top Alignment Design

## Goal

Render short chat conversations from the top of the message area and grow them downward. Once the content exceeds the available height, keep the newest message at the bottom so each new message pushes older messages upward.

## Root Cause

`ChatScreen` applies `.defaultScrollAnchor(.bottom)` to the message scroll view and explicitly calls `scrollTo(..., anchor: .bottom)` after asynchronous message loading, message insertion, and keyboard presentation. The explicit scroll overrides short-content alignment and moves an underfilled conversation to the bottom.

## Design

Keep the existing bottom default anchor for the initial position of overflowing conversations. Add a role-specific top anchor for underfilled-content alignment using SwiftUI's `alignment` scroll-anchor role. Programmatic scrolling to the newest message omits an explicit anchor so SwiftUI performs the minimum movement needed to reveal it instead of forcing short content to the bottom.

The existing chronological message ordering, newest-message scroll triggers, keyboard response, and older-message pagination remain unchanged.

## Verification

Statically confirm that the scroll view has a bottom default anchor followed by a top alignment-role anchor, and that newest-message scroll calls omit the explicit bottom anchor. Confirm that message ordering, scroll triggers, and pagination are unchanged. Per repository instructions, do not run tests unless explicitly requested.
