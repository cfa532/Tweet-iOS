# Detail and Fullscreen Video Audio Fades

## Goal

Replace abrupt audio changes when entering and leaving detail or fullscreen video with linear volume transitions: 0.5 seconds on entry and 0.35 seconds on exit. Video playback and visual dismissal remain immediate.

## Design

- Use a cancellable main-actor volume ramp on `AVPlayer.volume` so the behavior works for local files, remote files, HLS, and players borrowed from the feed.
- Fade in from volume 0 to 1 only for the initial playback associated with entering detail or fullscreen. User-initiated pause/resume does not restart the fade.
- On exit, begin dismissing the screen immediately while fading the active player from its current volume to 0 over 0.35 seconds.
- Keep the detail/fullscreen ownership gate active until fade-out completes so an underlying feed player cannot begin audible playback at the same time.
- Restore the outgoing player to volume 1 before pausing or clearing it. Detail and fullscreen players stay unmuted while active; before a borrowed detail player returns to the feed, apply the current global mute preference synchronously.
- Cancel stale ramps when a new entry, exit, player replacement, or teardown supersedes them. Completion work must verify it still owns the same player.

## Scope

- Fullscreen entry and every fullscreen dismissal path.
- Tweet detail and comment detail entry and final detail dismissal.
- No changes to native playback controls, seek behavior, buffering recovery, or the value of the feed mute preference.

## Verification

- Static review confirms fade state is cancelled during replacement, volume is restored before handoff, and a borrowed detail player receives the current global mute preference.
- Build the simulator target.
- Device verification should cover rapid open/close, borrowed feed players, HLS, pause/resume after entry, and nested detail navigation.
