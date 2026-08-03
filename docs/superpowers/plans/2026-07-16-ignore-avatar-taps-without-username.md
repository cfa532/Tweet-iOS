# Ignore Avatar Taps Without Username Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent feed tweet avatar taps from navigating when the attached user has no valid username.

**Architecture:** Keep the existing avatar rendering and tap wiring unchanged. Filter the callback once at the UIKit table-controller boundary before it reaches feed navigation, using `User.hasValidUsername` so all tweet-cell variants behave consistently.

**Tech Stack:** Swift 6, UIKit, SwiftUI interoperability

## Global Constraints

- Do not add navigation state or alter avatar loading.
- Preserve existing behavior for users with valid usernames.
- Do not run tests unless explicitly requested by the user.

---

### Task 1: Guard Feed Avatar Navigation

**Files:**
- Modify: `Sources/Tweet/UIKit/TweetTableViewController.swift`
- Test: No automated test target is configured; perform static callback-path review only unless the user requests test execution.

**Interfaces:**
- Consumes: `User.hasValidUsername` and `TweetTableViewCell.configure(..., onAvatarTap:)`
- Produces: An avatar callback that forwards only users with valid usernames.

- [ ] **Step 1: Confirm the failing callback path**

Verify that `TweetTableViewController` currently passes `onAvatarTap` directly into every feed cell without validating the supplied `User`.

- [ ] **Step 2: Add the minimal guard**

Pass a wrapper callback into `TweetTableViewCell.configure`:

```swift
onAvatarTap: { [weak self] user in
    guard user.hasValidUsername else { return }
    self?.onAvatarTap?(user)
},
```

- [ ] **Step 3: Review affected paths statically**

Confirm regular tweets, pure retweets, and quoted tweets all invoke the supplied cell callback, and confirm no other behavior changed.

- [ ] **Step 4: Inspect the final diff**

Check that only the callback boundary and this plan changed, with no unrelated edits overwritten.
