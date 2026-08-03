# HproseInstance Structured Logging Design

## Goal

Replace synchronous `print`, `debugPrint`, and `dump` calls in `HproseInstance.swift` with a smaller, structured `OSLog.Logger` signal set. The refactor must reduce hot-path logging overhead without changing RPC, caching, routing, synchronization, retry, authentication, or persistence behavior.

## Scope

- Modify `Sources/Core/HproseInstance.swift` only for production logging changes.
- Add one `Logger` category dedicated to `HproseInstance`.
- Remove routine, repetitive diagnostics that fire per item, per poll, per cache hit, or per successful low-level operation.
- Convert retained diagnostics to structured log calls with appropriate severity and privacy.
- Preserve existing control flow, state mutation, error propagation, retry behavior, and recovery behavior.

This phase does not migrate logging in other files and does not introduce a shared logging facade.

## Logging Policy

Retained messages use these levels:

- `error`: terminal operation failures and violated invariants that prevent the requested operation from completing.
- `warning`: retries, degraded fallback paths, malformed responses, and recoverable unexpected states.
- `info`: meaningful lifecycle or state transitions that are useful in ordinary diagnostics.
- `debug`: detailed routing, RPC, cache, and synchronization context needed during investigation.

Routine success messages, repeated cache hits, polling progress, loop-per-item messages, and duplicate entry/exit traces are removed unless they are necessary to reconstruct a failure.

## Privacy

- Counts, bounded status names, attempt numbers, and non-sensitive boolean state may be public.
- User IDs and other Mimei identifiers are private and masked where correlation is useful.
- URLs, IP addresses, request parameters, response bodies, tokens, keys, credentials, message content, and raw errors are private.
- No message may make sensitive values public merely to preserve the current console output.

## Implementation Shape

`HproseInstance.swift` imports `OSLog` and defines one stable logger using the repository's existing subsystem convention and the `HproseInstance` category. Calls use direct logger interpolation so OSLog can defer formatting and apply privacy metadata.

The migration proceeds by subsystem-sized sections within the file—initialization/authentication, user loading and routing, tweet operations, social lists, comments, uploads, messaging, and recovery/synchronization. Each section is compiled before proceeding so mechanical mistakes remain localized.

## Safety Constraints

- Do not change function signatures or introduce new runtime state beyond the logger.
- Do not move code across actor, task, queue, or lock boundaries.
- Do not change which errors are thrown, caught, retried, or ignored.
- Do not change client-pool usage or mutate pooled clients.
- Do not alter normal-read versus explicit-resynchronization policy.
- Avoid broad formatting or unrelated cleanup while editing logging statements.

## Verification

- Confirm `HproseInstance.swift` contains no remaining `print`, `debugPrint`, or `dump` calls.
- Review the diff for accidental control-flow or data-flow changes.
- Scan retained logs for public sensitive interpolation.
- Build the complete CocoaPods workspace with Swift 6 and code signing disabled.
- Report any pre-existing build warnings separately from errors introduced by this migration.

