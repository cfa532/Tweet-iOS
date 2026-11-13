# Owner-only writes: status memo

Date: 2026-11-13
Branches: `owner-only-writes` in Tweet-iOS and TweetBackendApp. Nothing is pushed.
Live on: the debug backend only (`twbe`, version 1721). Release, Android and web are unchanged.

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
  login, after its stored password is checked. The stored password is left in
  place so Android and web can still sign in.
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

### Decisions made along the way

- The username stays in the account as the public handle. Only the password
  moved to Leither.
- One identity controls an account at a time. Issuing a new identity for the
  same username replaces the old one.
- Signing out removes the owner key from the device.

## 4. What is missing

| Item | State |
|---|---|
| Enforcement | Off. A request without `usersid`, or for an account with no `authUid`, is still accepted. One function in the backend, `ownerSessionRequired`, turns it on. It must wait until Android and web send sessions and existing accounts are bound. |
| Admin as a delegate | Not started. Admin still poses as the author. There is no per-user setting to reject admin, and no check for it. On a node with `commentDelegation`, admin can no longer delete another user's comment: the server refuses with "Only the comment's author or the parent's author may delete this comment". |
| Likes, bookmarks, retweets, followers | Not started. Still written into the tweet's or the followed user's data. |
| Comments and replies | Done (storage unchanged, writes delegated). The comment peer entries (`apply_comment`, `remove_comment`) accept only the application author's session. What that guard does not do is authenticate *which* node is calling: any instance of the app holding the author identity can ask, so a compromised node could still attach or remove comments. Comments on nodes without `commentDelegation` keep the old unchecked form; old debug builds lose commenting against the new backend. |
| Messages | Not started. The sender still writes into the recipient's store. |
| Node-to-node calls | Partly hardened. The comment peer entries check the author session; `toggle_follower`, `toggle_favorite_by_user` and `toggle_bookmark_by_user` remain callable by any client. The structural facts this rests on (author-identity scope, the `BELoginAsAuthor` freeze, node app codes) are posed to the Leither developers in `Leither/cfa532-docs/integrations/tweet/LEITHER_STRUCTURAL_QUESTIONS.md`. |
| Comment policy | The hook exists (`apply_comment`); no per-tweet setting is stored or checked yet. |
| Android and web clients | Unchanged, and not reviewed. They keep the old comment form, which only works against nodes without `commentDelegation`. |
| Release backend | Unchanged. |
| Existing data | Comments written before the change are indistinguishable from new ones — same object, same list, same reference — so nothing to migrate. Old like lists inside tweets still need a decision when engagement moves. |
| Leither sign-up | Anyone who can reach a node can create a bare Leither user on it. Denying guests only blocks account creation. |

## 5. Test status

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

**Not tested:** guest registration, login and password change from the app's
screens; sign-out; QR scanning on a real camera; paste and file import (the
identity was fed in through a temporary hook, now removed); the
`--guests deny` path end to end; commenting from the app's screens against
1721 (the simulator run below); and the cross-node `apply_comment` hop on a
real two-node setup.

## 6. How to test

### Publish the backend (debug)

From TweetBackendApp:

```bash
rsync -av -e 'ssh -p 220' --exclude='*_test.go' --include='*.go' --exclude='*' ./ pi@gen8.leither.uk:/home/pi/demo/twbe/
```

```bash
ssh -p 220 pi@gen8.leither.uk 'cd /home/pi/demo && ./twbe.sh'
```

Confirm the new version answers with the session fields:

```bash
curl -s "http://gen8.leither.uk:8002/entry?aid=d4lRyhABgqOnqY4bURSm_T-4FZ4&ver=last&entry=health"
```

The reply must contain `"userSessions":true` and `"guestRegistration":true`.

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

### Comments through the writer's node

1. Confirm `health` reports `"commentDelegation":true`.
2. Signed in as any account, open someone else's tweet and comment on it. The
   request goes to your own root; the comment must still appear (it was written
   by the author's node) and the count must rise.
3. Delete your own comment. Reply to a comment and delete the reply the same
   way.
4. As the tweet's author, delete someone else's comment from the comment menu.
5. A third account (not the comment's author, not the parent's author, not
   admin) must get "Only the comment's author or the parent's author may delete
   this comment" when it tries.
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
  delegation change is live as version 1721; the probe comment it created on
  pairtest1's tweet was deleted again.
- Debug network: test accounts `pairtest1` (one tweet) and `gt94398670`, with
  a matching Leither user for the guest on gen8.
- This Mac's Leither node: one throwaway Leither user, `twprobe_1794382923`.
