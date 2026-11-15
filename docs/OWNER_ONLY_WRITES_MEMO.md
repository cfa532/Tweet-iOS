# Owner-only writes: status memo

Updated: 2026-11-15 (Shanghai time)

Gen8 debug serves `twbe` version 1755 with owner-only enforcement enabled. The
debug package includes the Go moderation fixes and the restored TweetWeb
editor. The backend's checked-in default remains off for the release rollout.

Published branches: Tweet-iOS `owner-only-writes` at `489e4fd66`, Android Tweet
`owner-only-writes` at `f571a145`, TweetBackendApp `main` at `57cbd5e`, and
TweetWeb `main` at `236e2f1` for the existing session and moderation work.

## 1. The request

**Rule.** Only the owner of a data object may modify it. Today a user who
comments on a tweet writes directly into data that belongs to the tweet's
author; the same is true of likes, bookmarks, retweets, follows and messages.

**Direction (developer's statement).** Do not let several users modify one
shared object and merge afterwards. Split each logical object into pieces with
one owner each. The owner writes their own piece, other nodes hold read-only
copies, and what users see is a merged view that can be rebuilt and never
writes back to the raw data.

**Admin.** The admin user can edit other users' posts today and keeps that by
default. A user can reject it; once rejected, admin can no longer edit or
delete that user's posts. There is no fallback for admin after a rejection.

**Two kinds of user** (added later in the work):

- An **owner** has access to the node's machine. They run a script on it to
  generate an identity, then scan its QR code or import its file in the app.
  There can be several owners per node. An owner does not log in with a
  username and password; the device is paired with the node.
- A **guest** uses a node by the owner's courtesy. The owner can allow guest
  registration (the default) or deny it. A guest's username and password are
  kept by Leither, not in the account's own data.

The pairing mechanism follows the LifeAlbum project.

## 2. What the review found

- The backend did not know who was calling. Every object is created and
  written under one application identity, and the user id in a request was an
  unchecked claim. No layer could enforce "owner".
- Admin power was impersonation: the app sent the author's id as if it were
  the caller, gated only by `username == "admin"` in the client.
- Writes into other users' data: comment and reply, delete comment, like,
  bookmark, retweet, the follower side of a follow, and incoming messages.
- The profile update with `migrate=true` skipped the root-node check, so any
  caller could rewrite any account's host.

## 3. What is implemented

### Identity: a caller is a Leither session

A client signs in to the node's own Leither login and passes the session it
receives as `usersid`. The node resolves it to a Leither user id. Each account
records the id that controls it (`authUid`).

### Owner pairing

- `tweet-owner.sh` (TweetBackendApp), run on the node:
  - `tweet-owner.sh <username>` creates a Leither key, lists it as an owner in
    `tweet.node.json` beside the Leither executable, writes an identity file,
    and prints a QR code when `qrencode` is installed (otherwise a line to
    paste).
  - `--guests deny` / `--guests allow` sets guest registration.
  - `--list` shows owners and the guest setting.
- Backend: `login` with only `usersid` signs the owner in and creates the
  account on the first call.
- iOS: the login screen has **Pair with my node**
  (`Sources/Screens/OwnerPairingView.swift`) with a QR scanner
  (`CodeScanner.swift`, taken from LifeAlbum), identity-file import and paste.
  The key is stored in the Keychain and signs the short-lived passes used to
  open sessions (`Sources/Core/OwnerSession.swift`).

### Guests

- On a node that supports sessions (`health` reports `userSessions: true`),
  the app registers and logs in through Leither on the account's root node.
  The account stores no password. Password change goes through Leither.
- `register` is refused when the node denies guests.
- An account created before this change is bound to a Leither user on its next
  login, after its stored password is checked. The legacy password remains
  available for clients and nodes still using the legacy login flow.
- Nodes still on the old backend keep the old flow.

### Owner check on writes

Sixteen entries that write the caller's own data check the session against
the account: `add_tweet`, `update_tweet`, `delete_tweet`,
`toggle_tweet_privacy`, `toggle_pinned_tweet`, `toggle_following`,
`block_user`, `remove_blacklisted_relationship`, `set_author_core_data`
(including the migration path), `set_user_avatar`, `delete_account`,
`message_outgoing`, `message_fetch`, `share_file`, `pin_ipfs`, `upload_file`.

- An unknown or expired session is refused with `Session invalid`; the app
  signs in again and repeats the request once.
- A session that belongs to another user is refused.
- iOS attaches the session at the single point every RPC passes through, only
  for writes to the signed-in user's own data.

### Comments through the writer's own node

A comment still lives on its parent author's node, but the writer no longer
sends the request there. `add_comment` is called on the **writer's root** with
their session; that node verifies the writer, creates the quote-retweet half
locally, and asks the parent author's node to perform the parent-side write
through `apply_comment`, a peer entry that accepts only the application
author's session (no client can obtain one) and re-derives the parent's author
from the parent object rather than trusting the request's names. Deletion
splits the same way: `delete_comment` on the **deleter's root**, then
`remove_comment` on the parent author's node, and only the comment's author or
the parent's author may delete. `forgetSavedComment` moved to the deleter's
root, where those lists live. `health` advertises `commentDelegation: true`;
iOS sends the new form to a node that has it and the old form to one that does
not, so release and old debug nodes keep working.

`apply_comment` is where a parent author's comment policy — a tweet closed to
comments, or open only to selected users — will be checked. No such setting
exists yet.

**Peer guard, rebuilt 2026-11-14 after the Leither maintainers' answers**
(`requirePeerCall`): a cross-node `RunMApp` deletes `sid` before forwarding, so
the first guard — which compared sessions — would have refused every genuine
cross-node peer call; only the same-node path had been exercised. The rebuilt
guard admits the delegating node by the `nodeappcode` the platform injects on
the target (minted there under the calling node's transport session), bound to
the comment writer's (or deleter's) own root — a code minted by an ordinary
user carries that user's uid and cannot match. The same-node hop still carries
the local author session, now checked against the node-injected `author` key
instead of logging in as the author again (the `BELoginAsAuthor` freeze rules
out new call sites). If this node holds no copy of the writer's account, one is
pulled once with `MiMeiSync` to resolve their root. Residual, documented: a
code leaked from the expected node replays for about an hour, and the check
trusts that node itself.

### Admin delegation for tweets

The admin's root verifies the admin account and its bound session in
`admin_mutate_tweet`. The author's root receives
`apply_admin_tweet_mutation`, verifies the delegating node and checks the
author's permission and timeline membership before editing or deleting a
top-level tweet. Authors allow this by default. An author can change the
setting on their root through `admin_tweet_access` with their own session.
The test build exposes this through the API and has no settings UI for it.
Comment and reply deletion follows the separate ownership rules above.

If the author's root cannot be resolved during an iOS admin deletion, the
client can remove the entry from the admin's own server-side lists. It waits
for the admin's root to confirm that removal. Permanent deletion of the tweet
object still requires the author's root.

### Decisions made along the way

- The username stays in the account as the public handle. Only the password
  moved to Leither.
- One identity controls an account at a time. Issuing a new identity for the
  same username replaces the old one.
- Signing out removes the owner key from the device.

## 4. Rollout status

| Item | State |
|---|---|
| Enforcement | On for gen8 debug. The deployed `session_entries.go` sets `ownerSessionRequired()` to `true`. The Go source on `main` defaults to `false` for release. Gen8 debug rejects missing sessions and unbound accounts on the enforced owner path. |
| Admin as a delegate | Implemented in TweetBackendApp `48800ac` and integrated in iOS and TweetWeb. Admin edit and delete passed on the simulator with enforcement enabled. The author-side revocation path is implemented and awaits an end-to-end test. |
| Likes, bookmarks, retweets, followers | Done across backend, TweetWeb and iOS (2026-11-14). `toggle_favorite`/`toggle_bookmark` run on the engaging user's root with their session and delegate the tweet-side write to `apply_favorite`/`apply_bookmark`; `retweet_added`/`retweet_removed` delegate to `apply_retweet`; `toggle_follower` is peer-only (reached from `toggle_following`). The peer entries bind the injected `nodeappcode` to the acting user's root, re-derive the tweet's author from the tweet object (a check the old entries never made), and pull an unknown actor's account once. `health` advertises `engagementDelegation`; all three clients gate on it. Same residuals as comments. |
| Messages | Done (2026-11-14). `message_outgoing` on the sender's root stores the sender's copy and delivers the recipient's through the now peer-only `message_incoming` — a refused or unreachable recipient fails the send. `health` advertises `messageDelegation`; iOS probes it and stops writing the recipient's copy directly. Verified live same-node and cross-node (gen8 → ksbox, the recipient's `message_check` returned the message). Old clients that still call `message_incoming` directly are refused by the guard — same accepted breakage class as comments. |
| Comments and replies | Done (storage unchanged, writes delegated). The comment peer entries admit only the delegating node — named by the platform-injected `nodeappcode`, bound to the writer's/deleter's own root (rebuilt 2026-11-14; see §3). Residual: a code leaked from the expected node replays ≈1h, and the check trusts that node. Comments on nodes without `commentDelegation` keep the old unchecked form; old debug builds lose commenting against the new backend. |
| Node-to-node calls | Hardened for comments, engagement, the follower side and messages (all peer entries bind the injected `nodeappcode` to the expected node). `toggle_favorite_by_user`/`toggle_bookmark_by_user` are removed (2026-11-14 review): they let any caller edit any user's saved lists. A node still on the old backend that calls them on a new node is refused. The maintainers' answers (2026-11-13) are in `Leither/cfa532-docs/integrations/tweet/LEITHER_STRUCTURAL_QUESTIONS.md` and the reply beside it; follow-up questions in `LEITHER_STRUCTURAL_QUESTIONS_2.md`. |
| Structural answers | The Leither maintainers answered the questions memo (V0.24.74 baseline). Key facts: `byname` (our guests) is legacy and node-local by design — keep, but do not extend; no root-only version enforcement, so the app's misrouted-write refusals are the only protection; `MMOpenAppDataUser` is the per-user-owned data primitive for the engagement phase; a transport-set caller-node identity (`fromnid`) is judged feasible upstream, pending an author ruling. |
| Comment policy | The hook exists (`apply_comment`); no per-tweet setting is stored or checked yet. |
| Android and web clients | Both use Leither sessions on the account root. The Mate 30 passed sign-in, publish, delete and background attachment publishing against gen8 debug. TweetWeb carries the session and delegation changes on `main`. The original web editor was restored in `twbe` 1755 after the native publishing changes. |
| Release rollout | Owner-only enforcement remains off by default. A release enforcement rollout and its compatibility checks are still pending. |
| Existing data | Comments written before the change are indistinguishable from new ones — same object, same list, same reference — so nothing to migrate. Old like lists inside tweets still need a decision when engagement moves. |
| Duplicate submissions | Fixed (2026-11-14, twbe 1729). A caller-generated `requestid` names each tweet or comment submission; the object's Mimei id is derived from it, so a retry after a lost response resolves the same object instead of creating a duplicate — verified live with double-submitted tweet and comment probes (one object each). TweetWeb keeps the id per composition (Re-submit reuses it; the quote half is `<id>-quote`); iOS passes the persisted upload operation's id, so a retry after an app restart converges too. Submissions without a requestid keep the old mint-a-fresh-id behavior. |
| Backend review fixes | `a310488` was pushed to `main` and deployed to gen8 debug. Comment deletion now requires the object to be one of the parent's comments (before this, the author of any tweet on a node could have any other object there destroyed by naming it as a comment). Request ids are namespaced by kind and author, so one user's id cannot resolve to another's object. A repeated named submission no longer adds its references twice. A retweet record can be cleared or replaced only by the user it names. `message_outgoing` delivers before storing the sender's copy. Peer entries refuse a caller with nothing to show before resolving the acting user's root. Consequence of the new marks: a submission first sent to an older backend and retried against this one creates a second object. |
| Leither sign-up | Anyone who can reach a node can create a bare Leither user on it. Denying guests only blocks account creation. |

## 5. Test status

### 2026-11-15 device and simulator results

Times below are in Shanghai time.

- **Mate 30 ownership.** Two early posts were rejected after enforcement was
  enabled. The app had a legacy credential entry and sent no `usersid`.
  Signing out and back in stored the credential in the current Keystore-backed
  format. Gen8 logged completion of `add_tweet` at **15:57:07** and
  `delete_tweet` at **15:57:47** after both passed the required owner check. The Android upload error fix was pushed as `8a68f54e`.
- **iOS admin moderation.** Gen8 saved an edit to another user's tweet at
  **16:03:18**. The first delegated deletion finished after the simulator's
  30-second timeout. With the timeout raised to 60 seconds, gen8's
  `apply_admin_tweet_mutation` handler completed the retest from **16:27:00**
  to **16:27:08**. The edit and both deletes used admin delegation with
  owner-only enforcement enabled. The Go error for a tweet missing from the author's
  timeline now reads **Cannot find the tweet** (`57cbd5e`).
- **iOS admin feed removal.** For a tweet whose author's root could not be
  resolved, Tahoe, the admin's root, removed the entry from
  `followings_tweets` at **16:37:31**. It published the updated admin account
  and logged completion at **16:37:33**. This was a feed-only removal.
- **Mate 30 attachment publishing.** Both files in the first retry uploaded.
  Gen8 committed the tweet at **17:28:33**, 2 minutes 9 seconds after receiving
  `add_tweet`, which exceeded the old Android 60-second timeout. The retest
  after leaving the composer uploaded at **17:47:27** and committed at
  **17:47:38**. WorkManager marked the job successful on its first attempt
  and cleared the saved draft. The next check found neither published draft
  on the phone. Both posts appeared in the web feed and then in the
  simulator's main feed after a delay.
- **Native publishing and draft recovery.** Android `f571a145` and iOS
  `489e4fd66` allow up to 3 minutes for attachment posts to commit. Both
  save the draft before closing the composer, retain it for manual retry on
  failure, and clear it after confirmation. Publish errors stay visible
  until dismissed. The updated iOS publishing build passed the user's
  simulator retest.
- **Direct messages and media previews.** The Mate 30 and simulator exchanged
  messages both ways. The simulator resolved the Mate 30 sender after
  discovery recovered. The simulator's optimistic image preview matched
  the final size on retest, and both clients' 60% attachment widths passed.

### Earlier verification

**Passed, called directly against debug version 1715** (the reply fix in 1717
changes only what `login` returns for a session):

- owner signs in with the issued key; first `login` creates the account,
  marked owner, with no password; repeating it returns the same account
- owner write with own session accepted; unknown session refused; a guest's
  session refused
- guest registers through Leither, `register` creates an account with no
  password; `login` by session accepted; old-style password `login` refused
- guest write with own session accepted; owner's session on the guest's
  account refused

**Passed in the iOS simulator against 1717:** pairing as `pairtest1` and one
post from that session.

**Passed as backend unit tests (`go test`, comment_entries_test.go):** the
comment delegation wiring — `add_comment` on the writer's root forwards
`apply_comment` to the parent author's node with the author session and the
quote fields stripped; `apply_comment` refuses a caller without the author
session before writing anything, refuses a parent object that does not belong
to the named author, and refuses a request that is not on the parent author's
root; `remove_comment` allows the comment's author and the parent's author and
refuses anyone else; `delete_comment` on the deleter's root delegates
`remove_comment`, propagates a refusal unchanged and leaves the deleter's saved
lists alone, and runs entirely locally when the deleter is the parent author.

**Passed live against debug version 1721 with curl (same-node path):** a
comment created through `add_comment` on the writer's root appears in
`get_comments` with the right author and count; a third party's
`delete_comment` is refused with "Only the comment's author or the parent's
author may delete this comment"; the author's deletion empties the list; a
bare client call to `apply_comment` or `remove_comment` is refused with "Not
called from a peer node". No session was needed for these probes — the
authority and peer checks do not depend on `ownerSessionRequired`.

**Passed live across two nodes (2026-11-14, driven by the TweetWeb port):** a
comment posted from the web client as `gen8` (root on gen8) on `pcadmin`'s
tweet (root on ksbox) crossed the network — `RemoteRunMApp entry=apply_comment
err=<nil>` on gen8, the platform-injected node app code naming the delegating
node — and deleting it took the same path (`remove_comment`). This is the
cross-node hop the unit tests cover with a mocked transport.

### Still to verify

- Revoke admin access as the tweet author, then confirm that the delegated
  edit and delete are both refused with enforcement on. The November 15
  simulator run exercised the default permission.
- Complete real-camera QR pairing, identity-file import and paste, and
  end-to-end guest registration denial. The earlier simulator pairing used a
  temporary identity hook.
- Run the iOS guest registration and password-change checks and the native
  comment and reply checks in §6. The earlier cross-node comment test used
  TweetWeb.

## 6. How to test

### Publish the backend (debug)

Follow the gen8 debug deployment procedure in `TweetBackendApp/README.md`.
Stage the Go sources for `twbe` with the debug
`ownerSessionRequired()` override set to `true` before uploading. The
checked-in source defaults to `false`. Preserve the installed override
during web-only publications. Run the existing `twbe.sh` with
`bash -e` and capture its output privately because it can contain signing
material.

After a backend change, check the numbered debug version and `last` using
the runbook. `health` advertises session and delegation support. Exercise
the owner check separately with a disposable test account to verify that a
sessionless owner write is refused and an authenticated one succeeds.

### Owner pairing

1. Copy `tweet-owner.sh` into the node's Leither directory and run
   `./tweet-owner.sh <username>` there. Install `qrencode` first to get a QR
   code.
2. Build the iOS Debug configuration and run it on a real phone (the
   simulator has no camera).
3. On the login screen choose **Pair with my node** and scan the code. Also
   try **Import identity file** and **Paste** with the line the script prints.
4. Expected: the sheets close and the app is signed in as that username. The
   profile shows the Edit button.
5. Post a tweet, pin it, edit the profile. Each should succeed.
6. Run the script a second time with another username and pair a second
   device; both owners should work independently.
7. Sign out, then pair again with the same identity file.

### Guest

1. On a node with guests allowed, register a new account from the app, then
   log in with it.
2. Read the account back and check it carries `authUid` and no `password`:

   ```bash
   curl -s "http://gen8.leither.uk:8002/entry?aid=d4lRyhABgqOnqY4bURSm_T-4FZ4&ver=last&entry=get_user_core_data&userid=<mid>"
   ```

3. Change the password in the profile editor, sign out, and log in with the
   new one. The old one must fail.
4. Log in with an account that existed before this change. It should still
   work, and afterwards the account should carry `authUid`.
5. Leave the app idle for over an hour, then post. The write should succeed
   after one silent re-sign-in.

### Guest policy

1. On the node: `./tweet-owner.sh --guests deny`.
2. Register from the app. Expected: "This node does not accept new
   registrations". Existing guests can still log in; owners can still pair.
3. `./tweet-owner.sh --guests allow` restores registration.

### Ownership refusal

With two accounts on the same node, a write to account A carrying account B's
session must be refused with "This session does not own account …". This needs
a script or a modified client; the app never sends another user's session.

### Admin delegation and revocation

1. With enforcement enabled, sign in as admin and edit and delete test tweets
   belonging to an author who allows admin access.
2. On the author's root, call `admin_tweet_access` with the author's session
   and `allowed=false`. Repeat the edit and delete as admin and confirm that
   the author's root refuses both.
3. Confirm the author can still manage their own tweets. Restore the test
   account's default permission with `allowed=true` if needed.

### Comments through the writer's node

1. Confirm `health` reports `"commentDelegation":true`.
2. Signed in as any account, open someone else's tweet and comment on it. The
   request goes to your own root; the comment must still appear (it was written
   by the author's node) and the count must rise.
3. Delete your own comment. Reply to a comment and delete the reply the same
   way.
4. As the tweet's author, delete someone else's comment from the comment menu.
5. A third account, including admin, must get "Only the comment's author or
   the parent's author may delete this comment" when it tries.
6. A quote-comment must still produce both halves: the comment on the parent
   author's node and the retweet on the writer's.
7. Point the app at a node without `commentDelegation` (release or an older
   debug build): commenting must take the old form and keep working.

### Old nodes

Point the app at a node still on the previous backend. Registration, login
and writes must behave as before, with no session sent.

## 7. Left on the servers

- gen8, `/home/pi/demo`: `tweet-owner.sh`, `tweet.node.json` listing
  `pairtest1` as an owner, that owner's identity file, and the pre-change
  sources in `deploy-backups/twbe-go-20261111T075217Z`. The comment
  delegation probe from version 1721 was cleaned up. Current debug rollout
  and verification are recorded above.
- Debug network: test accounts `pairtest1` (one tweet) and `gt94398670`, with
  a matching Leither user for the guest on gen8.
- This Mac's Leither node: one throwaway Leither user, `twprobe_1794382923`.
