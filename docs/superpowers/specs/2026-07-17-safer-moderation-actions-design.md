# Safer Moderation Actions Design

## Goal

Reduce accidental social blocks, content-filter blocks, and tweet reports without weakening the existing blacklist behavior.

## Root Cause

The profile menu invokes `blockUser` immediately after one menu selection. The content-filter form can also invoke `blockUser` as soon as Apply is tapped, and the report form submits immediately after its final button is tapped. These consequential actions do not show the affected account or explain the result at the final decision point.

The tweet menu itself is a custom flat action list. Its SwiftUI path opens cancellable Filter and Report forms, but the active UIKit feed path contained placeholder handlers that only printed to the console. Adding a submenu would require unrelated menu infrastructure changes and would not protect the actual backend operations.

## Design

- Reuse the profile view's existing block-menu state to present a destructive confirmation instead of calling the backend directly.
- Identify the affected account by `@username`, falling back to display name and then “this user.”
- In Content Filter, keep Apply immediate for ordinary filter choices. If “Block this user” is enabled, require a destructive confirmation before applying.
- In Report Tweet, require confirmation after a category is selected and before submitting the report.
- Make the UIKit feed menu present the same Content Filter and Report forms as the SwiftUI menu path.
- Route Tweet Detail's Filter and Report actions back to detail-owned sheets, matching its working Share action and avoiding presentation from the transient nested menu.
- Explain the immediate visible consequence in each confirmation and preserve Cancel as the safe default.
- Do not change blacklist storage, reliability filtering, backend APIs, or the existing block/report execution paths.

### Localization and deletion safeguards

- Add explicit English, Simplified Chinese, and Japanese entries for every block/report confirmation string introduced by this work; do not rely on English fallback values.
- Require a localized “Delete Tweet?” confirmation before the reusable SwiftUI tweet menu or UIKit feed menu starts deletion.
- Route Tweet Detail's delete request to a detail-owned alert, matching its stable Filter/Report presentation path while preserving the menu's local fallback elsewhere.
- Require a localized “Delete Comment?” confirmation before the SwiftUI or UIKit comment menu starts deletion.
- Use localized Tweet/Comment-specific consequence text and keep Cancel as the safe action.
- Preserve all existing optimistic removal, backend deletion, failure restoration, and error-reporting logic after confirmation.

## Verification

- Static review will trace every entry point to `blockUser` and `reportTweet` in these views and confirm it is gated by the intended confirmation.
- Static review will trace every menu entry point to `deleteTweet` and `deleteComment` and confirm it is gated by the appropriate confirmation.
- Validate all three `Localizable.strings` files with `plutil` and confirm the new keys exist in every locale.
- Diff and whitespace checks will confirm the change is limited to moderation UI and documentation.
- Compile through `Tweet.xcworkspace` to verify the UIKit/SwiftUI presentation integration. Do not run tests unless explicitly requested.
