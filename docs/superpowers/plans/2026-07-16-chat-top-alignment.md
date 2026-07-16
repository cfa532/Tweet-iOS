# Chat Top Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make short chat conversations start at the top while keeping overflowing conversations positioned at their newest message.

**Architecture:** Preserve `ChatScreen`'s current chronological data and auto-scroll triggers. Separate underfilled-content alignment from the existing initial scroll position with SwiftUI's role-specific default scroll anchor, and let programmatic scrolling use the minimum movement needed to reveal the newest message.

**Tech Stack:** Swift 6, SwiftUI, iOS 18

## Global Constraints

- Keep messages ordered oldest to newest.
- Short conversations align to the top and grow downward.
- Overflowing conversations open at the newest message and new messages push older content upward.
- Do not change pagination, keyboard scrolling, or message-send behavior.
- Do not run tests unless the user explicitly asks.

---

### Task 1: Separate Short-Content Alignment from Initial Scroll Position

**Files:**
- Modify: `Sources/Features/Chat/ChatScreen.swift:251`

**Interfaces:**
- Consumes: SwiftUI `View.defaultScrollAnchor(_:for:)` and the existing `ScrollViewReader` message list.
- Produces: A message list whose underfilled content aligns to the top without changing the bottom initial offset for overflowing content.

- [x] **Step 1: Record the existing behavior constraint**

Confirm the scroll view currently contains:

```swift
.defaultScrollAnchor(.bottom)
```

This is the source of the short-content bottom alignment and must remain as the initial overflowing-content position.

- [x] **Step 2: Add the minimal role-specific alignment**

Place this immediately after the existing default anchor:

```swift
.defaultScrollAnchor(.top, for: .alignment)
```

- [x] **Step 3: Perform static verification**

Inspect the focused diff and confirm it contains only the role-specific anchor plus documentation. Confirm `shouldScrollToBottom`, keyboard-triggered scrolling, chronological sorting, and `loadMoreMessages()` are untouched.

- [x] **Step 4: Leave runtime verification unexecuted**

Do not run tests under the repository instruction. The expected manual scenarios are: zero messages; one message at the top; several short messages growing downward; overflow with newest at the bottom; and another new message pushing older messages upward.

- [x] **Step 5: Remove the explicit bottom override from programmatic scrolling**

Change the newest-message and keyboard scroll calls from:

```swift
proxy.scrollTo(lastMessage.id, anchor: .bottom)
```

to:

```swift
proxy.scrollTo(lastMessage.id)
```

This preserves the auto-scroll triggers while preventing them from bottom-aligning content that is shorter than the scroll view.
