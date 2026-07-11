# NodePool Log Noise Design

## Goal

Stop repeated successful access-node cache lookups from flooding the debug console.

## Design

- Remove the success print from `NodePool.getIPFromNode(for:)`.
- Continue returning the preferred pooled IP exactly as before.
- Preserve missing-node, invalid-route, update, removal, and health-related logs.
- Leave `getIPForNode(nodeMid:)` unchanged because it did not produce the reported messages.

## Verification

- Confirm the reported `Using IP from access node` string no longer exists.
- Confirm the preferred-IP return path remains unchanged.
- Run a focused whitespace and source diff check; no build is necessary for deleting a print statement.
