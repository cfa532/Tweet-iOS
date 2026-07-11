# WeChat Share Crash Fix

## Problem

Selecting WeChat from the iOS share sheet crashes when sharing a tweet. The share flow currently supplies two `UIActivityItemSource` objects: a `CustomShareItem` containing the tweet text and `LPLinkMetadata`, plus a `CustomShareImage` containing the preview image.

Repository history shows this exact combination was previously removed because WeChat cannot handle multiple custom activity-item sources. A later video-preview change reintroduced it in both tweet share entry points.

## Design

Both the SwiftUI and UIKit tweet share builders will return exactly one `CustomShareItem`. The item will continue to provide:

- Tweet text and its share URL through `itemForActivityType`.
- The title and preview image through `LPLinkMetadata`.
- The attachment or app-icon preview already captured before the share sheet opens.

The separate `CustomShareImage` type will be removed because it has no remaining callers and violates the single-item compatibility contract.

## Scope and Impact

The change affects only the construction of iOS tweet share-sheet items. It does not change tweet URLs, backend contracts, media loading, authentication, or sibling clients.

The trade-off is that WeChat receives the preview only through `LPLinkMetadata`; this restores the earlier crash-free behavior. Other activities continue receiving the same text, URL, title, and metadata image.

## Verification

A source-level regression check will assert that both share builders return only their `CustomShareItem` and that `CustomShareImage` is absent. The check will be run against the current code before the fix to confirm failure and after the fix to confirm success. The iOS project will then be compiled to catch integration or concurrency errors.
