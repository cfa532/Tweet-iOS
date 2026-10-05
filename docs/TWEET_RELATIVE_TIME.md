# Tweet header relative time

iOS, TweetWeb, and Android use this same elapsed-time specification. Labels may
be abbreviated or translated; the numeric value and selected unit are the same.

iOS uses localized compact labels (for example `1mo`, `1个月`, `1ヶ月`). Web and
Android use localized relative labels (for example `1 month ago`, `1个月前`,
`1ヶ月前`). English full-unit labels select singular for 1 and plural for 0 or
multiple units. Chinese and Japanese use the same unit form for every count.

Compute elapsed seconds by flooring `(current Unix milliseconds - timestamp) / 1000`.
Use completed units with these thresholds:

| Elapsed time | Display |
| --- | --- |
| Less than 60 seconds | Seconds |
| Less than 60 minutes | Minutes |
| Less than 24 hours | Hours |
| Less than 7 days | Days |
| Less than 30 days | Weeks of 7 days |
| Less than 365 days | Months of 30 days |
| Otherwise | Years of 365 days |

These are elapsed durations, not calendar-month differences. For example, 28 days
is 4 weeks, 30 days is 1 month, 360 days is 12 months, and 365 days is 1 year.
No unit adds 1 to the completed count.

Refresh on display and foreground return. While active, refresh every minute
(iOS no longer ticks every second for posts under a minute old). Stop scheduled updates when the
header is disposed or the app/page is inactive. Labels can lag by one refresh
interval; device clock differences can also affect comparisons across clients.

Implementation locations:

- iOS: `TweetRelativeTime` in `Sources/Tweet/TweetItemHeaderView.swift`, shared by
  SwiftUI and `Sources/Tweet/UIKit/TweetHeaderUIView.swift`.
- TweetWeb: `src/lib.ts` and `src/composables/useRelativeTime.ts`, used by both
  `ItemHeader.vue` and `DetailHeader.vue`.
- Android: `localizedTimeDifference` in
  `app/src/main/java/us/fireshare/tweet/tweet/TweetItemBody.kt`.
