# Tweet Menu Row Highlight Design

## Problem

Selecting an action in a tweet dropdown highlights the entire menu surface instead of only the touched action row. The problem occurs in both the UIKit feed menu and the SwiftUI detail menu.

## Root Cause

Both menu implementations use Apple's system menu presentation. The app-wide `UITableViewCell.appearance().backgroundColor` override also reaches UIKit's internal menu rows, interfering with their native per-row pressed-state rendering.

## Design

Remove only the global `UITableViewCell` background appearance override from `ThemeManager.configureGlobalAppearance()`.

Keep the existing window, table-view, refresh-control, switch, navigation-bar, and tab-bar appearance settings. Do not change either tweet menu implementation or any menu actions. App-owned cells that require a themed background should continue to configure their own appearance rather than applying styling to every UIKit cell process-wide.

## Verification

- Confirm the feed tweet menu highlights only the touched action row.
- Confirm the detail tweet menu highlights only the touched action row.
- Confirm app table backgrounds remain correct in light and dark mode.
- Build the app to catch compilation or integration regressions.

## Scope

This change does not alter menu contents, action behavior, layout, accessibility, or the app's selected light/dark appearance.
