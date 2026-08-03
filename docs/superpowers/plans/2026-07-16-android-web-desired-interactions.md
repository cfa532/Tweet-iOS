# Android and Web Desired Interaction State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Android and Web send explicit desired favorite and bookmark states to the shared backend.

**Architecture:** Each UI layer determines the optimistic desired state. The Android RPC layer reads that state from its already-updated tweet, while the Web action bar passes it explicitly to the store RPC method. Both clients send the backend fields unchanged.

**Tech Stack:** Kotlin/Android, TypeScript/Vue/Pinia, Hprose.

## Global Constraints

- Preserve writable-node routing and optimistic rollback behavior.
- Send backend field names exactly as `isfavorite` and `isbookmarked`.
- Avoid unrelated refactors.

---

### Task 1: Android request parameters

**Files:**
- Modify: `/Users/cfa532/Documents/GitHub/Tweet/app/src/main/java/us/fireshare/tweet/HproseInstance.kt`

**Interfaces:**
- Consumes: optimistically updated `Tweet.isFavorite` and `Tweet.isBookmarked`.
- Produces: `isfavorite` and `isbookmarked` Hprose request fields.

- [x] Pass an explicit desired boolean from the optimistic view model into each Android RPC method.
- [x] Add `"isfavorite" to isFavorite` to `toggleFavorite` parameters.
- [x] Add `"isbookmarked" to isBookmarked` to `toggleBookmark` parameters.

### Task 2: Web explicit desired states

**Files:**
- Modify: `/Users/cfa532/Documents/GitHub/TweetWeb/src/views/TweetActionBar.vue`
- Modify: `/Users/cfa532/Documents/GitHub/TweetWeb/src/stores/tweetStore.ts`
- Modify: `/Users/cfa532/Documents/GitHub/TweetWeb/src/views/TweetActionBar.interactionState.test.ts`

**Interfaces:**
- Consumes: `nextLiked` and `nextBookmarked` from the optimistic action handlers.
- Produces: `toggleFavorite(tweet, isFavorite)` and `toggleBookmark(tweet, isBookmarked)` requests.

- [x] Pass `nextLiked` and `nextBookmarked` to the store calls.
- [x] Accept the desired boolean in both store methods and send it as the corresponding backend field.
- [x] Update interaction-state expectations for the explicit desired argument.

### Task 3: Verify

**Files:**
- Inspect all modified files and both repository diffs.

**Interfaces:**
- Produces: cross-client evidence that desired states use the same backend contract.

- [x] Run both Android debug-flavor Kotlin compilation tasks.
- [x] Run Web type-check and the focused interaction-state test.
- [x] Run `git diff --check` in both repositories.
