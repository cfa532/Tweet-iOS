# Chat Top Alignment Design

## Goal

Render short chat conversations from the top of the message area and grow them downward. Once the content exceeds the available height, keep the newest message at the bottom so each new message pushes older messages upward.

## Root Cause

`ChatScreen` applies `.defaultScrollAnchor(.bottom)` to the message scroll view. That single anchor controls both the initial position of overflowing content and the alignment of content that is shorter than the viewport, so a one-message conversation is bottom-aligned.

## Design

Keep the existing bottom default anchor for the initial position of overflowing conversations. Add a role-specific top anchor for underfilled-content alignment using SwiftUI's `alignment` scroll-anchor role.

The existing chronological message ordering, explicit scroll-to-bottom triggers, keyboard response, and older-message pagination remain unchanged.

## Verification

Statically confirm that the scroll view has a bottom default anchor followed by a top alignment-role anchor, and that no message ordering or scroll-trigger code changes. Per repository instructions, do not run tests unless explicitly requested.
