# Repository Instructions

- Before changing code, consider multiple plausible fixes and choose the one with the smallest coherent scope.
- Prefer removing or simplifying conflicting logic before adding new state, variables, flags, or branches. Minus first, addition second.
- When a fix needs new code, keep it directly tied to the observed bug and avoid broad refactors unless they are required for correctness.
- Find root cause of a bug first before fixing it.
- Review the user's requested change before implementing it. If it may remove important recovery behavior, degrade reliability, or create other negative side effects, call that out and challenge the request before editing.
- After refactoring any code, review the finished change, especially what the refactor might break by checking the impact to callers of the modified code. Write comments to explain the purpose of the refactor whenever necessary.

# Related Projects

- `TweetAppBackend` is the shared backend companion project for this app and its sibling clients.
- It lives at `/Users/cfa532/Documents/GitHub/TweetBackendApp`.
- `Tweet` lives at `/Users/cfa532/Documents/GitHub/Tweet` and also accesses `TweetBackendApp`.
- `TweetWeb` lives at `/Users/cfa532/Documents/GitHub/TweetWeb` and also accesses `TweetBackendApp`.
- When changing API calls, request or response models, authentication, posting, timeline loading, media upload, or sync behavior, consider the shared backend contract and the impact across `Tweet-iOS`, `Tweet`, and `TweetWeb`.
- If backend or sibling project files are needed, ask for read access or have the user attach/open those projects too.

# Swift 6 Concurrency Rules

`Tweet` and `User` are `@MainActor ObservableObject` classes; most managers are
`@unchecked Sendable` singletons. These rules keep that architecture safe — violations
of the first three have each caused shipped crashes or freezes.

- **Pass values, not models, across concurrency boundaries.** Background code must not
  read `Tweet`/`User`/`MimeiFileType` properties. Snapshot on the main actor first: use
  the `Sendable` structs in `Sources/DataModels/Records.swift` (`TweetRecord.init(tweet:)`,
  `UserRecord.init(user:)`, `MediaRecord.init(media:)`, with `makeTweet`/`makeMedia`/
  `merge` for the way back), or a small tuple in a single `await MainActor.run { (…) }`
  hop for 2–3 scalars. One hop per function — don't pepper a function with repeated hops.
- **`MainActor.assumeIsolated` needs a main-thread guarantee by contract** (UIKit
  delegate/KVO dispatched via `DispatchQueue.main.async`, notification observers with
  `queue: .main`). Never use it in `deinit` — deinit runs on whatever thread drops the
  last reference and `assumeIsolated` traps (the build-117 App Store rejection class).
  If a deinit body needs main-actor work, declare `isolated deinit` (SE-0371, iOS 18+);
  if it only needs thread-safe calls (`Timer.invalidate`, `NotificationCenter.removeObserver`),
  mark the stored properties `nonisolated(unsafe)` and call directly.
- **Selector-based `NotificationCenter` observers on `@MainActor` classes** must be
  `@objc private nonisolated func` (order matters: `nonisolated` after `@objc`) that hops
  via `Task { @MainActor in … }` — unless the notification is documented to post on main.
  `UserDefaults.didChangeNotification` is NOT (PencilKit posts it off-main on iPad).
- **Never mutate a client returned by `HproseClientPool`** (`timeout`, `uri`, headers).
  Clients are shared per (URL, timeout); ask the pool for the class you need:
  `getClientByUrl(for:timeout:)` / `user.writableClient(timeout:)`.
- **Blocking I/O must be pushed off the main actor explicitly.** `@MainActor` isolation
  makes naive call sites block main, and `Task.detached` does NOT move a `@MainActor`
  function's body off main. hprose RPC goes through `invokeRunMApp`; CoreData uses
  `context.perform`/`await context.perform` (not `performAndWait` from main); image
  decode and `Data(contentsOf:)` go in `Task.detached`.
- Actors are for state with mostly-async callers (`NodeConnectionPool`,
  `ActiveDownloadsActor`). Managers called from synchronous `filter`/`guard`/cell-config
  paths (`BlackList`, `NodePool`, `TweetDeletionRegistry`) stay `@unchecked Sendable`
  with locks — do not convert them to actors.
