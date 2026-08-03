# HproseInstance Structured Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove synchronous console printing from `HproseInstance.swift`, delete repetitive hot-path noise, and retain useful diagnostics through privacy-aware `OSLog.Logger` calls.

**Architecture:** Add one file-private logger so `HproseInstance` and its nested `MediaProcessor` share one category without new instance state. Migrate contiguous sections, deleting routine loop/cache/poll/success traces and assigning retained events a structured severity and privacy level.

**Tech Stack:** Swift 6, Foundation, OSLog, Xcode workspace build

## Global Constraints

- Modify `Sources/Core/HproseInstance.swift` only for production logging changes.
- Preserve RPC, caching, routing, synchronization, retry, authentication, persistence, actor, queue, and lock behavior.
- Do not change function signatures or introduce runtime state beyond one logger.
- Keep identifiers, URLs, IPs, parameters, responses, tokens, keys, content, and raw errors private.
- Keep only safe counts, attempt numbers, booleans, and bounded state names public.
- Remove routine success, cache-hit, polling, loop-per-item, and duplicate entry/exit output.

---

### Task 1: Add logger plumbing

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:1-30`

**Interfaces:**
- Consumes: Apple's `OSLog.Logger`.
- Produces: file-private `hproseLogger: Logger`.

- [ ] **Step 1: Record the baseline**

Run `rg -c '\b(print|debugPrint|dump)\s*\(' Sources/Core/HproseInstance.swift`.
Expected: `590`.

- [ ] **Step 2: Add the logger**

```swift
import Foundation
import OSLog
@preconcurrency import hprose

private let hproseLogger = Logger(subsystem: "com.zz", category: "HproseInstance")
```

- [ ] **Step 3: Build**

Run `xcodebuild -quiet -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`.
Expected: exit 0; the existing run-script warning may remain.

### Task 2: Remove repetitive output

**Files:**
- Modify: `Sources/Core/HproseInstance.swift`

**Interfaces:**
- Consumes: existing control flow.
- Produces: identical functions without routine console side effects.

- [ ] **Step 1: Delete loop- and item-level traces**

Delete statements shaped like the following while preserving their surrounding loops, mutations, branches, returns, and errors:

```swift
print("[fetchMessages] Filtered out outgoing message from \(message.authorId)")
print("DEBUG: Cache hit for \(id)")
print("DEBUG: Processing item \(index)")
```

- [ ] **Step 2: Delete polling and routine-success traces**

Delete messages emitted on every poll/retry wait, request entry/exit, ordinary cache hit, and successful low-level step. Preserve retry warnings and terminal failures.

- [ ] **Step 3: Review the deletion diff**

Run `git diff --word-diff=porcelain -- Sources/Core/HproseInstance.swift`.
Expected: removed log expressions only; no conditions, assignments, calls, returns, or braces removed.

### Task 3: Migrate initialization, user loading, routing, and social lists

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:30-3000` (pre-migration lines)

**Interfaces:**
- Consumes: `hproseLogger`.
- Produces: structured authentication, user, routing, cache-recovery, provider, and social-list diagnostics.

- [ ] **Step 1: Convert terminal failures**

```swift
hproseLogger.error("User fetch failed for id=\(userId, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
```

- [ ] **Step 2: Convert retries and fallbacks**

```swift
hproseLogger.warning("Provider lookup retry attempt=\(attempt, privacy: .public)/\(maxRetries, privacy: .public), route=\(route, privacy: .private)")
```

- [ ] **Step 3: Convert meaningful state and detail**

```swift
hproseLogger.info("Application user session changed; guest=\(isGuest, privacy: .public)")
hproseLogger.debug("User list response count=\(ids.count, privacy: .public)")
```

- [ ] **Step 4: Build**

Run the Task 1 build. Expected: exit 0.

### Task 4: Migrate tweet, comment, media, upload, and sync diagnostics

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:3001-6500` (pre-migration lines)

**Interfaces:**
- Consumes: `hproseLogger`.
- Produces: structured content, media, upload, cache-recovery, and explicit-sync diagnostics.

- [ ] **Step 1: Keep only actionable boundaries**

Keep terminal failures, recovery fallbacks, and meaningful synchronization transitions. Delete per-object success output and raw response dumps.

- [ ] **Step 2: Apply levels and privacy**

```swift
hproseLogger.warning("Tweet refresh used cached data for id=\(tweetId, privacy: .private(mask: .hash))")
hproseLogger.error("Comment upload failed: \(String(describing: error), privacy: .private)")
hproseLogger.info("Explicit user synchronization completed; tweetCount=\(count, privacy: .public)")
```

- [ ] **Step 3: Build**

Run the Task 1 build. Expected: exit 0.

### Task 5: Migrate messaging, administration, and remaining recovery logs

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:6501-end` (pre-migration lines)

**Interfaces:**
- Consumes: `hproseLogger`.
- Produces: structured chat, domain, blocking, reporting, notification, and recovery diagnostics.

- [ ] **Step 1: Remove per-message and step chatter**

Delete per-message filtering output and routine Step 1/Step 2 success prints. Retain final failures and retry warnings.

- [ ] **Step 2: Convert retained events**

```swift
hproseLogger.warning("Message send retry attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
hproseLogger.error("Message send exhausted retries: \(String(describing: finalError), privacy: .private)")
hproseLogger.info("Upgrade domain changed")
```

- [ ] **Step 3: Build**

Run the Task 1 build. Expected: exit 0.

### Task 6: Audit and verify

**Files:**
- Verify: `Sources/Core/HproseInstance.swift`

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: static and compiler evidence for the completed migration.

- [ ] **Step 1: Confirm console calls are gone**

Run `rg -n '\b(print|debugPrint|dump)\s*\(' Sources/Core/HproseInstance.swift`.
Expected: no output, exit 1.

- [ ] **Step 2: Audit public interpolation**

Run `rg -n 'privacy:\s*\.public' Sources/Core/HproseInstance.swift`.
Expected: every match is a count, attempt number, boolean, or bounded state.

- [ ] **Step 3: Audit the diff**

Run `git diff --check` and `git diff -- Sources/Core/HproseInstance.swift`.
Expected: logger plumbing plus removed/replaced logging statements; no behavioral changes.

- [ ] **Step 4: Run the final build**

Run the Task 1 build. Expected: exit 0.

