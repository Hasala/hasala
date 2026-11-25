# The operator console stays minimal for the beta (2026-11-25)

**Status: decided by the owner, 2026-11-25.**

Spec 07 §8.7 and §8.8 (ledgerd design archive) describe a full operator console: entry detail
and deletion, the TestFlight screens, the broadcast, the account list and its actions, reveal
and retry in the email log, and the audit screen. `hasalad console` has less than that.

**Decision.** The minimal console is the scope for the beta. The screens of spec 07 §8.7 and
§8.8 that are not built are not a debt of the beta. Account actions, the audit log and a retry
of an email are work for the `hasalad` command line on the host, not for the console.

**What the console has.** `server/internal/console/console.go` registers all of it:

- The waitlist, with approve (`waitlist.approve`).
- The invites: mint, resend and revoke (`invite.mint`, `invite.resend`, `invite.revoke`).
- The email log, with masked recipients. It is read-only.
- The banks: add a bank and set its status (`bank.add`, `bank.status`).
- On the second listener, `GET /healthz` and `GET /metrics` (`health.go`).

**What the operator uses in place of a screen.**

- Account actions: `hasalad account review`, `account unfreeze`, `account suspend` and
  `account unsuspend`, and `hasalad purge-user` to delete an account. Each takes
  `<uuid> --confirm <uuid>`. Refer to `docs/runbooks/restore.md`.
- Audit: each console action writes an `admin_audit` row, and so does each `hasalad account`
  mode, `invite mint`, `invite revoke`, `mailbox rekey` and `email test`. `purge-user` writes
  its line in the purge ledger. The console has no screen that shows the rows.
- Mail: the mail worker of `serve` tries a failed send again by itself, up to 10 times and
  inside 24 hours (10 minutes for a code), in `server/internal/mailq/mailq.go`. After that the
  row is `failed`. For an invite, the operator queues a new email: Resend in the console, or
  `hasalad invite mint --email <address>`. `hasalad email test <address>` proves that the
  provider sends.
- The waitlist counts: `hasalad waitlist`.

**Limit.** At this date the command line has no mode that prints the `admin_audit` rows and no
mode that queues a `failed` email again, and it has no mode for the deletion of one waitlist
entry, for TestFlight or for a broadcast. The operator reads the audit rows from the database
on the host. If one of these is necessary in the beta, add it as a `hasalad` mode with its
`admin_audit` row, not as a console screen.

**Do not** add a screen or an action of spec 07 §8.7 or §8.8 to the console in the beta
without a new decision of the owner. A new action that the owner approves goes through
`Console.action`, so it has the same-origin check and its audit row. The rules of the console
that stay are in `docs/decisions/code/server-config-to-gmailpush.md` ("The console holds no
key and sends no mail itself" and the three sections after it).

Applies to: `server/internal/console/console.go` (`Console.Handler`),
`server/cmd/hasalad/main.go` (the mode table), `server/cmd/hasalad/account.go`,
`server/cmd/hasalad/invite.go`.
