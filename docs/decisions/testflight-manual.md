# TestFlight invitations stay manual for the beta (2026-11-25)

**Status: decided by the owner, 2026-11-25** (issue #365).

## Context

A person on the waitlist gets into the beta in two steps. The operator approves the entry in
the console, and the server emails a Hasala invite code. The person also needs Apple's
invitation to Hasala's TestFlight beta, which Apple sends when the address is added to the
beta group in App Store Connect.

The ledgerd design archive (spec 07 §7, §2.7 and §3.1 step 3) planned an automation for the
second step: the console holds an App Store Connect key, adds the tester when it approves an
entry, keeps `testflight_enrolments` and `testflight_status` tables, and the join hook marks
the enrolment. None of that was built. What existed was the wiring for it:

- `invites.Renderer.ManualTestFlight`, which `wireExtras` always set to `true`, and a second
  branch of the invite templates that never ran in production;
- `HASALA_TESTFLIGHT_MODE` (`external` or `manual`), which the console checked and nothing
  read;
- `services.hasala.asc.*` in the QA module, which gave the console an App Store Connect key
  and nine `HASALA_ASC_*` variables that no server code read.

## Decision

The operator adds each invited tester to Hasala's TestFlight beta by hand in App Store
Connect. This stays for the beta. The automation is not built, and the unused wiring is
removed:

- The invite email has one text. Step 2 says "We'll add you to Hasala's TestFlight beta
  ourselves, and Apple then emails you the invitation". The mail that a tester gets did not
  change by one byte. `TestInviteSaysWeAddTheTesterOurselves`
  (`server/internal/mailq/mailq_test.go`) holds the sentence.
- `Renderer.ManualTestFlight` and `mailq.Content.ManualTestFlight` are gone.
- `hasalad console` does not read `HASALA_TESTFLIGHT_MODE`. A unit that still sets it gets
  the warning for a variable that the build does not read.
- The QA module has no `services.hasala.asc` options, sets no `HASALA_ASC_*` variable and
  no `HASALA_TESTFLIGHT_MODE`, and loads no App Store Connect credential. A host that still
  sets `services.hasala.asc` fails its evaluation with a message that names this document.
  Remove the setting from the host before the host takes this revision.

## What stays

- The fences. `hasalad serve` still refuses to start with a `HASALA_ASC_*` variable or
  `HASALA_TESTFLIGHT_MODE` in its environment, and the QA module still refuses those
  prefixes in `extraEnvironment` (M4, M20). No unit has a reason to carry them now, so one
  that does has incorrect wiring. `server/cmd/hasalad/fence_test.go` still keeps the App
  Store Connect host and an `internal/testflight` package away from `serve`.
- The console's `/healthz` still reports `"asc": "disabled"`.
- The `awaiting_testflight` state of `invite_codes` (migration 00021). No code writes it.
  Removing it needs a migration, and this decision does not need one.
- The console's dashboard tells the operator to add the person to Hasala Beta in App Store
  Connect.
- The privacy policy already describes the manual step ("we add your email address to
  Hasala's beta on Apple's TestFlight").

## What the operator does

1. Approve the entry in the console. The server sends the invite email.
2. In App Store Connect, add the same address to the external group Hasala Beta. Apple
   emails the invitation.

No record on the server says that step 2 was done. The join hook
(`waitlist.OnInviteRedeemedTx`) has no TestFlight step.

## If this changes

To automate the step later, start from spec 07 §7 in the ledgerd design archive and write a
new decision. It needs a dedicated App Store Connect key that is not the upload key of the
Mac, the tables of spec 07 §2.7, and tests that do not call Apple. Spec 07 itself is in the
private archive and still describes the automation; this document is the record for this
repository.
