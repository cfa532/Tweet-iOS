# Refresh Tweet Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add start and success debug logs to `refreshTweet()`.

**Architecture:** Instrument the existing RPC boundary without changing request, response, caching, or error behavior.

**Tech Stack:** Swift 6, existing console debug logging.

## Global Constraints

- Do not log response payloads or authentication data.
- Do not change `refreshTweet()` behavior.
- Do not run a build, per user request.

---

### Task 1: Instrument refresh_tweet

**Files:**
- Modify: `Sources/Core/HproseInstance.swift:1478-1520`

**Interfaces:**
- Consumes: existing `tweetId`, `authorId`, and selected `baseUrl` values.
- Produces: start and success debug console messages.

- [ ] Add a start log immediately before `invokeRunMApp`.
- [ ] Add a success log immediately after caching and `blackList.recordSuccess`.
- [ ] Run `git diff --check` and inspect the focused source diff; do not build.
