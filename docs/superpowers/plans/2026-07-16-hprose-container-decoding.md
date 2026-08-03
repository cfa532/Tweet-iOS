# Hprose Container Decoding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every shared Hprose v2 endpoint receives native Swift dictionaries and arrays, including nested containers.

**Architecture:** Add a recursive Foundation-container normalizer beside the existing response helpers and invoke it only from `unwrapV2Response`. Preserve current JSON-string parsing positions, scalar types, and v2 error semantics.

**Tech Stack:** Swift 6, Foundation, Hprose.

## Global Constraints

- Do not run tests unless explicitly requested.
- Do not reinterpret nested string fields as JSON.
- Do not change endpoint routing, request parameters, or backend behavior.

---

### Task 1: Normalize decoded Hprose containers

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:293-415`

**Interfaces:**
- Consumes: Hprose response values passed to `unwrapV2Response(_:)`.
- Produces: recursively normalized Swift dictionary and array containers.

- [x] Add `normalizeHproseContainers(_:)` that recursively maps `[String: Any]`, `NSDictionary`, `[Any]`, and `NSArray`, preserving scalars.
- [x] Apply normalization after existing root/data JSON-string parsing in every return path of `unwrapV2Response`.
- [x] Route the shared dictionary helper and raw messaging error fallbacks through the same normalizer.
- [x] Keep `success=false` error behavior unchanged.

### Task 2: Verify endpoint coverage

**Files:**
- Inspect: `Sources/Core/HproseInstance.swift`

**Interfaces:**
- Consumes: all `invokeRunMApp` call sites.
- Produces: evidence that structured endpoint parsing passes through the shared decoder.

- [x] Inventory all structured casts following `unwrapV2Response` and confirm nested dictionary/array shapes are normalized centrally.
- [x] Confirm the structured v3 response and raw messaging fallbacks use the shared dictionary/container normalizers.
- [x] Confirm no other source file invokes Hprose structured endpoints outside `HproseInstance`.
- [x] Run Swift parser and `git diff --check` on the modified source file.
