# Safer Moderation Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require clear confirmation immediately before social blocking or tweet reporting.

**Architecture:** Keep existing backend and mutation methods unchanged. Add view-local confirmation state at the three UI decision points, using existing account/tweet data to identify the target and describe the visible consequence.

**Tech Stack:** Swift 6, SwiftUI

## Global Constraints

- Preserve social blacklist and reliability blacklist behavior exactly.
- Do not change backend APIs or synchronization behavior.
- Keep Filter and Report as cancellable forms opened from the existing flat tweet menu.
- Do not run tests unless explicitly requested.

---

### Task 1: Confirm direct profile blocks

**Files:**
- Modify: `Sources/Features/Profile/ProfileView.swift`

**Interfaces:**
- Consumes: existing `showBlockUserMenu`, `user`, and `handleBlockUser()`.
- Produces: a destructive confirmation that is the only menu path to `handleBlockUser()`.

- [x] **Step 1: Change the menu action to present confirmation**

Set `showBlockUserMenu` after the existing guest check instead of starting `handleBlockUser()`.

- [x] **Step 2: Add target-aware confirmation copy**

Use `@username`, then name, then a generic fallback. The destructive button starts the unchanged async block method; Cancel makes no change.

- [x] **Step 3: Trace the mutation path**

Confirm the menu cannot call `handleBlockUser()` without the alert's destructive action.

### Task 2: Confirm blocks selected in Content Filter

**Files:**
- Modify: `Sources/Features/Legal/ContentFilterView.swift`

**Interfaces:**
- Consumes: existing `blockUser`, `applyFilters()`, and tweet author data.
- Produces: confirmation before Apply can call `blockUser`; ordinary Apply remains immediate.

- [x] **Step 1: Add confirmation state and target display fallback**

Keep the state local to `ContentFilterView` and derive the display text from the tweet author.

- [x] **Step 2: Gate Apply only when blocking is enabled**

Present the confirmation when `blockUser` is true. Otherwise call the existing `applyFilters()` directly.

- [x] **Step 3: Preserve the existing apply implementation**

The destructive confirmation calls `applyFilters()`; Cancel must not apply or block.

### Task 3: Confirm report submission

**Files:**
- Modify: `Sources/Features/Legal/ReportTweetView.swift`

**Interfaces:**
- Consumes: existing `selectedCategory`, `isSubmitting`, and `submitReport()`.
- Produces: confirmation between the enabled Submit button and the unchanged backend report call.

- [x] **Step 1: Add confirmation state**

The navigation-bar button presents confirmation only after its existing enabled-state requirements are met.

- [x] **Step 2: Add consequence-aware report confirmation**

The destructive action calls `submitReport()` and Cancel sends nothing.

- [x] **Step 3: Preserve duplicate-submission protection**

Keep the existing `isSubmitting` state and disabled button logic unchanged.

### Task 4: Static verification

**Files:**
- Review: `Sources/Features/Profile/ProfileView.swift`
- Review: `Sources/Features/Legal/ContentFilterView.swift`
- Review: `Sources/Features/Legal/ReportTweetView.swift`

**Interfaces:**
- Consumes: completed Tasks 1–3.
- Produces: evidence of scoped, internally consistent source changes.

- [x] **Step 1: Inspect all moderation call sites**

Run `rg -n "handleBlockUser|blockUser\(|submitReport|reportTweet\("` on the three files and trace each UI entry point.

- [x] **Step 2: Inspect the focused diff**

Run `git diff --check` and review the three source-file diffs. Expected: no whitespace errors and no backend, blacklist, or synchronization changes.

- [x] **Step 3: Compile without running tests**

Build the `Tweet` scheme through `Tweet.xcworkspace` with code signing disabled. Do not run a test action.

### Task 5: Connect the UIKit tweet menu

**Files:**
- Modify: `Sources/Tweet/UIKit/TweetCellContentView.swift`

**Interfaces:**
- Consumes: the existing `parentViewController`, `ContentFilterView`, `ReportTweetView`, and shared `HproseInstance`.
- Produces: working Filter and Report presentation from the active UIKit feed menu.

- [x] **Step 1: Replace the Filter placeholder**

Present `ContentFilterView` in a page-sheet `UIHostingController` with the shared environment object.

- [x] **Step 2: Replace the Report placeholder**

Present `ReportTweetView` with the same hosting pattern after the existing guest check.

- [x] **Step 3: Preserve final-action safeguards**

Keep the forms' block/report confirmation dialogs as the only gateways to their backend mutations.

### Task 6: Stabilize Tweet Detail menu presentation

**Files:**
- Modify: `Sources/Tweet/TweetItemHeaderView.swift`
- Modify: `Sources/Tweet/TweetDetailView.swift`

**Interfaces:**
- Consumes: `TweetMenu` actions and Tweet Detail's stable root view.
- Produces: optional Filter/Report callbacks and detail-owned form sheets.

- [x] **Step 1: Add optional action callbacks to TweetMenu**

Use the callbacks when supplied and preserve local-sheet fallback behavior for existing call sites.

- [x] **Step 2: Move Tweet Detail presentation state to its root**

Own the Filter and Report sheet state beside the existing login/share presentation state.

- [x] **Step 3: Connect the detail menu callbacks**

Route Filter and Report selections to their stable detail-owned sheets.

### Task 7: Localize moderation confirmations

**Files:**
- Modify: `Tweet/en.lproj/Localizable.strings`
- Modify: `Tweet/zh-Hans.lproj/Localizable.strings`
- Modify: `Tweet/ja.lproj/Localizable.strings`

**Interfaces:**
- Consumes: existing `NSLocalizedString` keys used by block and report alerts.
- Produces: complete English, Simplified Chinese, and Japanese translations for each confirmation title, message, fallback target, and action label.

- [x] **Step 1: Add block confirmation translations**

Add translations for `Block %@?`, `this user`, both block consequence messages, and `Block and Apply Filters`.

- [x] **Step 2: Add report confirmation translations**

Add translations for `Submit this report?` and its consequence message.

- [x] **Step 3: Validate localization files**

Run `plutil -lint` against all three files and require `OK` for each.

### Task 8: Confirm every tweet and comment deletion

**Files:**
- Modify: `Sources/Tweet/TweetItemHeaderView.swift`
- Modify: `Sources/Tweet/UIKit/TweetCellContentView.swift`
- Modify: `Sources/Tweet/CommentMenu.swift`
- Modify: `Tweet/en.lproj/Localizable.strings`
- Modify: `Tweet/zh-Hans.lproj/Localizable.strings`
- Modify: `Tweet/ja.lproj/Localizable.strings`

**Interfaces:**
- Consumes: existing SwiftUI menu state, UIKit parent view controller, and unchanged delete implementations.
- Produces: localized Tweet/Comment-specific confirmation before every menu-driven deletion.

- [x] **Step 1: Gate reusable SwiftUI tweet deletion**

The menu item presents `Delete Tweet?`; only its destructive action starts the existing async deletion method.

Tweet Detail supplies a delete-confirmation presenter callback so its alert is owned by the stable detail root; other `TweetMenu` call sites retain the local alert fallback.

- [x] **Step 2: Gate UIKit tweet and comment deletion**

Present a localized `UIAlertController` from the cell's existing parent view controller, then run the unchanged optimistic deletion closure only after confirmation.

- [x] **Step 3: Gate SwiftUI comment deletion**

Use a localized confirmation dialog before setting `isDeleting` and starting the existing delete task.

- [x] **Step 4: Verify source and compile**

Trace all menu-driven delete calls, run `git diff --check`, and build the `Tweet` scheme through `Tweet.xcworkspace` without running tests.
