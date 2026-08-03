# Hprose Container Decoding Design

## Problem

Hprose can return JavaScript objects and arrays as Foundation `NSDictionary` and `NSArray` containers. `unwrapV2Response` normalizes the v2 envelope but not the complete returned payload, so endpoint code that expects `[String: Any]` or `[[String: Any]]` can reject a successful response. Nested objects such as `tweet`, `user`, and `file` have the same problem.

## Design

Add one recursive container normalizer at the shared v2 decoding boundary. It converts Swift/Foundation dictionaries to `[String: Any]`, converts Swift/Foundation arrays to `[Any]`, and recursively normalizes their children. Scalar values remain unchanged.

JSON parsing remains limited to the same root and v2 `data` positions currently supported. Strings nested inside returned objects are not interpreted as JSON, preventing tweet content such as `"{}"` from changing type.

`unwrapV2Response` applies the normalizer to successful v2 data, successful envelopes without data, and legacy/non-v2 container responses. The existing dictionary helper uses the same recursive normalization for structured v3 responses such as `resync_user`. Messaging error fallbacks normalize raw envelopes when v2 error unwrapping throws. Existing error detection and endpoint return semantics remain unchanged.

## Scope

The change is limited to `Sources/Core/HproseInstance.swift`. It covers every endpoint using the shared `unwrapV2Response` path, including nested dictionaries and arrays, plus the identified structured v3 and raw error-fallback paths. Transport behavior itself is not changed.

## Verification

Per repository instructions, do not run tests unless explicitly requested. Verify Swift syntax, diff integrity, and audit that all Hprose `runMApp` response paths use `unwrapV2Response` before structured payload parsing.
