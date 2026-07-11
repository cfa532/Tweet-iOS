# Refresh Tweet Logging Design

## Goal

Make successful `refresh_tweet` calls visible in debug console output.

## Design

- Log immediately before invoking the `refresh_tweet` RPC, including tweet ID, author ID, and selected base URL.
- Log after a valid refreshed tweet has been parsed, cached, and recorded as successful.
- Keep existing missing-tweet and processing-error logs unchanged.
- Do not log response payloads, authentication data, or unrelated RPC calls.

## Verification

- Confirm the start log precedes `invokeRunMApp`.
- Confirm the success log follows caching and `blackList.recordSuccess`.
- Build the iOS app target for the simulator.
