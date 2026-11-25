# Decisions from the code

These decisions were code comments. Code comments are not permitted
(`scripts/comment-lint.ts`), so each decision that a comment recorded is in one
of these documents. Each section names the files and symbols it applies to.
Search this directory for a file name or a symbol before you change that code.

The decisions of record of each area are one level up, in `docs/decisions/`.

| Document | Sections |
| --- | --- |
| [CI, the flake, the QA module and the app shell](github-to-ios.md) | 29 |
| [iOS crypto core](ios-crypto.md) | 16 |
| [iOS core, Domain to Mail](ios-domain-to-mail.md) | 18 |
| [iOS account, accounts, activity and bills screens](ios-hasala-features-account-to-bills.md) | 13 |
| [iOS Home and Mailbox screens](ios-hasala-features-home-to-mailbox.md) | 12 |
| [iOS onboarding](ios-hasala-features-onboarding-to-mocks.md) | 14 |
| [iOS app, Plan, Profile, Review and Search screens](ios-hasala-features-plan-to-search.md) | 13 |
| [iOS app, Security to SignIn features](ios-hasala-features-security-to-signin.md) | 14 |
| [iOS app, transaction sheet and Live layer](ios-hasala-features-to-live.md) | 15 |
| [iOS platform adapters, package layout, API client and categorization](ios-hasala.md) | 13 |
| [HasalaDesign foundation and icons](ios-hasalakit-hasaladesign-to-hasalamocks.md) | 10 |
| [HasalaModels engines and read models](ios-hasalakit-hasalamodels-engines.md) | 6 |
| [HasalaKit ledger models and tests](ios-hasalakit-to-tests.md) | 5 |
| [iOS app unit tests](ios-hasalatests.md) | 2 |
| [iOS UI tests](ios-hasalauitests.md) | 7 |
| [iOS mailbox lane and model](ios-mailbox-to-model.md) | 23 |
| [iOS core, money to projection](ios-money-to-projection.md) | 22 |
| [iOS replay, soft auth and store](ios-replay-to-store.md) | 28 |
| [iOS scripts and tools](ios-scripts-to-tools.md) | 15 |
| [iOS sync, account ceremonies and bank templates](ios-sync-to-template.md) | 26 |
| [iOS core tests, mailbox to Keychain](ios-tests-coremailboxtests-to-hasalakeychaintests.md) | 7 |
| [Sample seed generator and HasalaDesign components](ios-to-hasalakit.md) | 9 |
| [iOS core test support, text, time and wire](ios-to-tests.md) | 14 |
| [The gate scripts and the hasalad command](scripts-to-server.md) | 17 |
| [Account, passkey, mailbox and hook routes (api)](server-api-2.md) | 26 |
| [Sync routes (api)](server-api-3.md) | 14 |
| [API routes (api)](server-api.md) | 21 |
| [Passkeys, passwords, sessions and recovery (auth)](server-auth-2.md) | 20 |
| [Server step-up, writers, server keys, blob framing and storage budget](server-auth-to-budget.md) | 20 |
| [Server auth (accounts, codes, freeze, invites, passkeys)](server-auth.md) | 21 |
| [Server config, console, crypto reference, dictionary and Gmail push](server-config-to-gmailpush.md) | 19 |
| [Google tokens, the disk fuse and invites](server-googlejwt-to-invites.md) | 19 |
| [Server key protocol, outbound mail and the Microsoft token verifier](server-keyproto-to-msjwt.md) | 17 |
| [Go normalizer (norm)](server-norm.md) | 9 |
| [Op log append and hash chains (oplog)](server-oplog-to-oplogtest.md) | 16 |
| [Op log reads, the op reference model and operator notices](server-oplog-to-opsnotify.md) | 9 |
| [Postgres, test cluster, private fixtures and purge (server)](server-outlookpush-to-purge.md) | 26 |
| [Push wakes (pushv2)](server-pushv2.md) | 8 |
| [Template executor, seeds and fixtures](server-tmpl-2.md) | 13 |
| [Bank templates (tmpl)](server-tmpl.md) | 12 |
| [Verify, the waitlist and the oracle tools](server-to-oracle.md) | 15 |
| [The oracle corpus gates and the website build](server-to-web.md) | 15 |
| [Website components, pages, scripts and styles](web-components-to-styles.md) | 24 |
