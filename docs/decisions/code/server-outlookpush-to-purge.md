# Postgres, test cluster, private fixtures and purge (server): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/pg`, `server/internal/pgtest`,
`server/internal/pgtx`, `server/internal/privatefixtures` and `server/internal/purge`.
Code comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Startup pins the body of the sealed-frame predicate

`SealedFunctionMD5` is the md5 of the body of the SQL function `hasala_frame_is_sealed`,
exactly as the baseline migration defines it (spec 01 §8.2, V-F). Startup check O7
(spec 02 §5.6) compares the body of the live function with this value and refuses to
serve when they differ.

The reason: the `op_log_blob_is_sealed` CHECK calls this function. A schema owner who
replaces the body with `SELECT true` keeps the CHECK and removes its effect. O7 finds
that at the next start. A test compares the constant with the migration file, so a
migration that changes the function must change the constant in the same commit. Do not
remove O7 because "the CHECK is validated": O5 examines the constraint, not the body.

Applies to: `server/internal/pg/owner.go` (`SealedFunctionMD5`, `CheckServing`).

## A database ahead of the binary may serve

`CheckServing` refuses a database that is behind the embedded migrations (O4). It does
not refuse a database that is ahead of them. It gives the two versions to `warn` and
passes.

The reason: migrations only expand the schema (spec 02 §5.5). An older binary can thus
work on a newer schema, and a rollback of the binary needs no rollback of the database.
If somebody makes "ahead" a refusal, a binary rollback after a migration cannot start.
A migration that is not expand-only breaks this rule.

Applies to: `server/internal/pg/owner.go` (`CheckServing`).

## Each call into goose holds one mutex

`gooseMu` serializes each call into goose. `goose.SetDialect` and `goose.SetBaseFS`
write package-level variables of goose with no lock, and the `Up` and `Down` calls read
them. goose was not written for concurrent calls.

Each caller sets the same dialect and the same embedded file system, so the values
never disagree. It is still a data race, and `go test -race` reports it. The test
packages migrate databases concurrently (also with `t.Parallel()` in one package), thus
the race occurs without the mutex. A new function that calls goose must take `gooseMu`.

Applies to: `server/internal/pg/pg.go` (`gooseMu`, `withGoose`, `EmbeddedVersions`).

## The migration ledger is found through the catalog

`appliedVersion` looks for `goose_db_version` in `pg_catalog.pg_class`. It does not use
`to_regclass`.

The reason: `to_regclass` gives "permission denied" to a role that has no USAGE on the
schema. The runtime role is in that state before the baseline gives its grants. The
correct answer there is "no ledger yet", not an error. With `to_regclass`, a serving
mode or `hasalad migrate --pending` on a fresh database fails with a permission error
and does not report version 0.

Applies to: `server/internal/pg/pg.go` (`appliedVersion`).

## Pending is 0 when the database has no migration ledger

`Pending` (spec 02 §5.5, `hasalad migrate --pending`) counts the embedded migrations
that are not applied. When `goose_db_version` does not exist, it returns 0, not the
number of all migrations.

The reason: the caller is the check before the pre-migration dump. Its question is "is
there something to back up before a migration runs". A fresh database has nothing to
back up. When the ledger exists and is empty, `Pending` counts against version 0 and
returns all migrations. Do not change the first case to "all migrations are pending":
the check then asks for a backup of a database that has nothing in it.

Applies to: `server/internal/pg/pg.go` (`Pending`).

## CHECK constraints run in name order, so a sealed-frame test keeps the row's own AAD

PostgreSQL evaluates the CHECK constraints of a row in the order of their names.
`op_log_aad_matches_position` thus runs before `op_log_blob_is_sealed`.

A test that must prove that `op_log_blob_is_sealed` refuses a frame (spec 01 AT-P3,
AT-DB-1) uses a real frame, sealed for the row it is inserted as, with exactly one
predicate check broken and the AAD bytes unchanged. A frame with the AAD of another row
is refused by the position CHECK first, and the test then proves nothing about the
sealed CHECK.

Some refusals of the V-F set cannot carry the row's AAD (an empty frame, one byte, a
size that is not on the ladder, an `aad_len` past the end, a ledgerd v1 frame). For
these, the test requires only a CHECK violation: no stored row and no `get_byte` range
error. It does not require a constraint name.

A new CHECK on `op_log` whose name sorts before `op_log_blob_is_sealed` changes which
constraint names itself. Examine these tests when you add one.

Applies to: `server/internal/pg/pg_test.go`
(`TestADirectInsertOfARefusedFrameFailsTheCheck`).

## Tests do not change the shared roles of the cluster

Roles and role membership belong to the cluster, not to a database. The gate runs all
test packages against one cluster at the same time. Thus:

- A test that needs a role in an unusual state makes a role of its own. The O3 test
  (a member of the owner role) does this. If it gave the membership to the shared
  `hasala_runtime`, the startup check of each other package would refuse during that
  moment.
- `EnsureRoles` can run in two packages at the same time. `IF NOT EXISTS` does not
  stop the race: one package creates the role and the other gets a unique violation on
  `pg_authid`. `EnsureRoles` tries again, and the second pass finds the role. Do not
  remove the retry.

Applies to: `server/internal/pg/pg_test.go` (`TestServingRefusesAMemberOfTheOwnerRole`),
`server/internal/pgtest/pgtest.go` (`EnsureRoles`).

## Tests connect as the runtime role

Each test cluster has the two production roles (spec 02 §5.2, §5.7). `hasala_migrate`
owns each test database and its schema and applies the migrations. `pgtest.New` returns
a pool that is connected as `hasala_runtime`, with DML only.

The reason: each test then uses the grants that `hasalad serve` has: the append-only
`op_log` and `key_history`, and the revoke-once `writers`. A statement that the runtime
role cannot run fails in the test, not on the QA host. Do not change `New` to return
the owner's pool. `NewWithOwner` and `Superuser` are only for the few tests that show
what the owner or a superuser can and cannot do, or that build a hostile schema.

Applies to: `server/internal/pgtest/pgtest.go` (`New`, `NewWithOwner`, `Superuser`).

## Each test database is a copy of one migrated template

The first test of a process builds one template database: prepared as
`infra/qa/db/setup.sql` prepares a database, then migrated as `hasala_migrate`. Each
later test gets `CREATE DATABASE ... TEMPLATE` of it. This is much faster than a
migration for each test. `NewEmpty` still makes a database that is not migrated.

Two facts about PostgreSQL shape this code:

- `CREATE DATABASE` refuses a template while a session is connected to it (it waits
  up to 5 seconds first). The code closes each connection to the template and waits
  until the backends are gone before the first copy. Nothing connects to the template
  after that.
- A copy has all that is inside the database: schema, grants on tables, triggers and
  the `goose_db_version` rows. It does not have the grants on the database itself,
  because `pg_database` holds them. `copyDatabase` applies `databaseGrants` again
  (no rights for PUBLIC, CONNECT for the runtime role). Without them, a copy lets
  PUBLIC connect, and the tests no longer have the grants of production.

Applies to: `server/internal/pgtest/pgtest.go` (`migratedTemplate`, `copyDatabase`,
`databaseGrants`).

## A test DSN is rewritten as a URL

`dsnFor` changes the user and the database of the admin DSN. It parses the DSN as a
URL and replaces the user and the path.

It does not use `pgxpool.ParseConfig`, a change of `cfg.ConnConfig.Database` and
`cfg.ConnString()`. pgx's `ConnString()` returns the string that was parsed, not a new
string from the changed struct. That approach connects to the `postgres` maintenance
database for each name, with no error.

`HASALA_TEST_POSTGRES_URL` can also be a keyword/value DSN. For that form, `dsnFor`
adds `dbname=` and `user=` at the end. pgx uses the last value of a key, so the added
value wins.

Applies to: `server/internal/pgtest/pgtest.go` (`dsnFor`).

## The gate's Postgres outlives the command that starts it

`scripts/check.sh` runs `go run ./internal/pgtest/cmd/boot` one time. All test packages
then share that cluster through `HASALA_TEST_POSTGRES_URL`, and the run has one
`initdb`, not one for each package. A package that runs alone still starts its own
cluster.

- The boot command prints the DSN and the path of a stop script, and exits. The server
  must continue. `BootStandalone` thus starts `postgres` in its own session
  (`SysProcAttr.Setsid`): it is not in the process group of the caller, and a signal
  to that group does not stop it. Without `Setsid`, the end of the short `go run`
  process can stop the cluster.
- `BootStandalone` starts a goroutine that waits for the server process. A caller that
  stays alive (a test that calls `BootStandalone` in its process) otherwise keeps a
  stopped server as a zombie. A zombie still answers `kill -0`, and the stop script
  polls `kill -0`, so each stop then waits its full 10 seconds.
- The caller must run the stop script. The script removes the directory that it is in,
  so it runs one time only.

Applies to: `server/internal/pgtest/pgtest.go` (`BootStandalone`, `bootCluster`),
`server/internal/pgtest/cmd/boot/main.go`.

## The test cluster uses the C.UTF-8 locale

`initdb` for the test cluster gets `--encoding=UTF8 --locale=C.UTF-8`, as the cluster
of the QA host does. It does not use the default of `initdb`.

Do not change it to `--locale=C`. `C` compares bytes and has no case rules for
non-ASCII text. `ORDER BY`, `LIKE` and the use of indexes on text columns can then
differ between the tests and the QA host. If the locale of the QA host changes, change
this one with it.

Applies to: `server/internal/pgtest/pgtest.go` (`bootCluster`).

## The test cluster has no TCP port

The test server starts with `listen_addresses=""`. It binds no TCP port and listens
only on a unix socket in its own temporary directory.

The port number 5433 is a constant on purpose. With no TCP listener, the number is
only a part of the name of the socket file (`.s.PGSQL.5433`) in that directory. Two
clusters in two directories with the same number do not collide. Do not add a search
for a free port, and do not set `listen_addresses`: a TCP listener makes the constant
a real conflict and opens the trust-authenticated cluster to the host.

Applies to: `server/internal/pgtest/pgtest.go` (`bootCluster`).

## pgtx pins READ COMMITTED, rolls back on a detached context and imports nothing of ours

`pgtx` holds the two transaction helpers that the Postgres stores share.

- `BeginReadCommitted` sets the isolation level. A plain `Begin()` uses
  `default_transaction_isolation`, which a database, a role or a pooler can set. The
  stores serialize concurrent writers with `SELECT ... FOR UPDATE` (with or without
  `SKIP LOCKED`) or an equivalent row lock: a sweep, a registration, a rotation, a
  cutover, an append. Under `REPEATABLE READ` such a lock can give a serialization
  failure where it must wait or skip. A usual concurrent operation then fails with an
  error text that does not name the cause. `docs/decisions/code/server-auth.md`
  ("Lock-then-count transactions pin READ COMMITTED") gives a second reason.
- `BeginReadCommitted` returns the error of `pool.BeginTx` unchanged. Each caller adds
  its own prefix. A prefix here makes a doubled prefix.
- `Rollback` uses a context that the cancellation of the caller does not reach, with
  a limit of 5 seconds. When a request is cancelled, the rollback still runs and
  releases the locks of the transaction. With the cancelled context, pgx destroys the
  connection. The limit stops a server that does not answer from holding the
  connection permanently.
- `pgtx` imports only pgx, pgxpool and the standard library. It must not import
  `internal/pg` or goose. A package that needs only these helpers then does not get
  the embedded migrations in its build.

Applies to: `server/internal/pgtx/pgtx.go` (`BeginReadCommitted`, `Rollback`).

## A set HASALA_PRIVATE_FIXTURES with a missing file fails the test

A test asks `privatefixtures` for a real-mail file by its path in the repository.

- `HASALA_PRIVATE_FIXTURES` not set: the test skips. The skip reason starts with the
  marker `[real-corpus]` and names the variable, the file and the private repository.
- Set, and the file is there: the test runs and logs one marker line.
- Set, and the file is not there: the test fails. A set variable is a claim that the
  real corpus is present. A missing file is then a broken checkout. A skip here lets
  a broken checkout pass as green.
- Set to a relative path: the test fails. `go test` runs each package in its own
  directory, so a relative path names a different place in each package.

`Root` does not skip and does not fail. The fixture writers use it and decide
themselves what an absent checkout means. The synthetic suites do not use this package
and always run.

The gate counts the marker lines (`docs/decisions/code/scripts-to-server.md`). A test
of `privatefixtures` itself must thus give its calls a recorder in place of the real
`testing.TB`. Its output then has no marker line, and the gate does not count it as a
real-corpus run.

Applies to: `server/internal/privatefixtures/privatefixtures.go` (`Path`, `Root`,
`Marker`), `server/internal/privatefixtures/privatefixtures_test.go`.

## The purge is one DELETE on users, and the cascade does the rest

A purge (spec 02 §15) deletes an account with one statement: `DELETE FROM users`. Each
other row goes through `ON DELETE CASCADE`. The explicit sweep and the last counts run
after this statement, in the same transaction.

This order is necessary. `op_log` and `key_history` are append-only by trigger, and
`writers` is revoke-once. The one exemption of each trigger is "the users row is
already gone", and only the cascade satisfies it. The runtime role has no DELETE on
these three tables; the cascade runs as the owner of the referencing table. A purge
that first deletes from these tables itself is refused, and that refusal is correct.
Do not give the runtime role DELETE on them to "help" the purge.

The statement uses `RETURNING`. The report thus names the accounts that were deleted,
not the accounts that were asked for.

What "delete" means: each op-log blob is ciphertext that the server cannot open. The
purge deletes the rows that hold it and the wrapped key material, in one transaction.
Backups are not written again. They age out on their schedule (spec 02 §15.5, spec 05
§5.8). The purge does not decide who may ask: the API route examines a step-up and a
writer signature, and the CLI is the operator.

Applies to: `server/internal/purge/purge.go` (`purgeUsers`).

## The purge finds its relations in pg_class

The purge does not have a written list of the tables of a user. It asks the database
which relations have a `user_id` column and uses that list. A table from a later
change is covered when it exists. A relation that the purge cannot cover by itself
must be classified by hand before any purge runs.

The query reads `pg_class`. It must not read `information_schema`, which is blind in
three ways. Each one lets a relation with the rows of a deleted person stay, with no
report:

- `information_schema.tables` does not list materialized views. A materialized view
  over `op_log` is a stored copy of the frames of a person.
- A filter on `table_schema = 'public'` does not see other schemas, for example an
  archive table that an operator makes.
- `information_schema` shows only the relations on which the current role has a
  privilege. The purge runs as the runtime role, which is not the owner. `pg_class`
  has no such filter. A relation that the role cannot read is found, and the count
  on it fails with an error. "I am not allowed to look" must be a loud answer.

The filter keeps the kinds `r`, `p`, `m` and `f` (table, partitioned table,
materialized view, foreign table) in each schema that is not a system schema. It
leaves out indexes, sequences, views, composite types and TOAST tables: none of them
stores rows that a DELETE addresses, and a view is a query over relations that are
already in the list. It leaves out partitions: a delete on the parent covers them,
and a list with partitions needs a classification for each new partition.

Applies to: `server/internal/purge/purge.go` (`relationFilter`, `UserScopedTables`,
`allRelations`, `countFor`).

## A purge is idempotent, and all or nothing

A purge of an account that does not exist reports no rows and gives no error. A client
that lost the answer to a successful deletion sends the request again, and the second
answer must not look like a failure or like a second deletion.

All deletions are in one transaction. Each failure rolls all of it back, also "a
relation exists that this package cannot account for". A partial purge is worse than
no purge: it leaves a live account whose op log has holes in its gap-free sequence.
The invariant check reports that corruption permanently, and only some of the data
that the person asked to delete is gone.

Applies to: `server/internal/purge/purge.go` (`Purge`, `PurgeWith`, `Report.Users`).

## One unclassified relation stops every purge

`Classify` puts each relation of the database in one of three groups: it has a
`user_id` (found by the query), the purge handles it by hand (`handledWithoutUserID`),
or it holds nothing of one person (`notUserLinked`). A relation in no group makes
each purge fail with `ErrIncomplete`, before it deletes anything. The same call does
not succeed on a retry: the correction is a change of the schema or of the lists.

The refusal is for all accounts, not for one. One stray relation (a backup table that
an operator made, a materialized view that somebody left) makes
`DELETE /api/v1/account` answer 500 for each person. App Review 5.1.1(v) requires that
route. The cause is only in the operator log; the answer does not give it.

The owner accepts this. The alternative is a report of a deletion that did not occur.
The results for the operator:

- Run `hasalad purge-user <uuid> --confirm <uuid> --dry-run` after each schema
  change. It does the same classification and deletes nothing.
- The correction is one line in `handledWithoutUserID` or `notUserLinked`, or a
  `user_id` column with `ON DELETE CASCADE`.
- The message names the kind of the relation, because the action differs: a stray
  table gets a `user_id` or a line in `notUserLinked`, and a stray materialized view
  usually must be dropped.

Applies to: `server/internal/purge/purge.go` (`ErrIncomplete`, `Classify`).

## Purge lists hold schema-qualified names, and SQL gets two quoted identifiers

The names in `handledWithoutUserID` and `notUserLinked` include the schema
(`public.users`). With bare names, a table `archive.users` (a snapshot of all
accounts) is classified as "the account table, handled", through a list entry that
was written about a different object.

A relation is a struct with a schema and a name, not one `schema.name` string. The
display form goes into messages and into the keys of the report. The SQL form is two
quoted identifiers (`pgx.Identifier{schema, name}.Sanitize()`). One identifier that
contains a dot names a relation that does not exist, and the count on it fails.

The code does not examine a name with a pattern and does not put a raw name into SQL.
The quoting is correct for each name that PostgreSQL permits, also a name with a
quote or a dot. A regex screen refuses legal names and adds no protection.

Applies to: `server/internal/purge/purge.go` (`Relation`, `Relation.SQL`,
`handledWithoutUserID`, `notUserLinked`).

## The relations that a purge leaves alone

Each entry of `notUserLinked` is a decision. The reasons:

- `deleted_account_sessions`: the tombstone of a deleted account (the SHA-256 of the
  session tokens that were live). The deletion writes it, so it is the one table
  that must stay after a deletion. It has no user id, no subject, no address and
  nothing made from them.
- `goose_db_version`: the migration ledger of goose.
- `email_code_pauses`, `rate_counters`: pauses and counters with an `email_tag` or a
  writer hash as the key (spec 02 §5.3, §15.3). A sweep removes them within a day.
- `device_freeze_challenges`: nonces that name a writer id and no account.
- `server_meta`: the key fingerprints.
- `banks`: the bank catalog (spec 07 §2.12).
- `waitlist_entries`, `waitlist_tokens`: an entry is an address that is not an
  account yet, or, after the person joined, a tag with no address. The purge erases
  the joined entry and the mail rows of the account by the address ("The purge erases
  the address from rows that have no user_id"), and the 30-day sweep deletes joined
  entries in each case.
- `admin_audit`: refer to `docs/decisions/code/scripts-to-server.md`.
- `invite_codes`: refer to the next section.

Before you add a table to this list, make sure that no column of it can be traced to
one person.

Applies to: `server/internal/purge/purge.go` (`notUserLinked`).

## The link from an invite code to its account is not named user_id

An `invite_codes` row is a code hash, a note of the operator and, after the code is
spent, the link `redeemed_by` to the account. The schema removes that link itself:
`redeemed_by uuid REFERENCES users(id) ON DELETE SET NULL`. After a purge, the row
says only that some code was spent.

Do not rename the column to `user_id`. The purge then finds the table as a table of
a user, and the cascade check refuses each purge, because `SET NULL` is the silent
survival that it guards against. `CASCADE`, which the check requires, deletes the row
and makes a spent code usable again. The two results are wrong. Thus the table is in
`notUserLinked`.

Applies to: `server/internal/purge/purge.go` (`notUserLinked`), the `invite_codes`
table.

## Each foreign key from a user_id to users must cascade

Before it writes anything, the purge examines each foreign key from a found relation
to `users` (`CheckCascades`). It accepts only `ON DELETE CASCADE`.

- `NO ACTION` or `RESTRICT` makes `DELETE FROM users` fail with a foreign-key error.
  That is loud, but it comes in the middle of the transaction and in the words of
  the database. The check refuses earlier, with a clear message.
- `SET NULL` or `SET DEFAULT` is the reason for the check. The rows stay with an
  empty `user_id`. Each count by `user_id` is then zero, and the purge reports full
  success while the table still holds the data of the deleted person.

The check keeps all actions of a relation, not one. A relation can have more than one
foreign key on a `user_id` column. With one action for each relation, a `SET NULL`
can hide behind a `CASCADE`. The query covers each schema, because a relation in any
schema can reference `public.users`.

A relation with a `user_id` and no foreign key is not refused here. The sweep handles
it.

Applies to: `server/internal/purge/purge.go` (`CheckCascades`, `cascadeActions`).

## After the cascade, a sweep deletes rows with no foreign key and refreshes materialized views

Two kinds of relation still hold rows after `DELETE FROM users`:

- A table with a `user_id` and no foreign key. Nothing cascades into it. The purge
  deletes its rows and names the table in `SweptWithoutCascade`. An entry there means
  that each other path that deletes a user leaves those rows. The purge corrects its
  own case and reports the schema defect. One table has no foreign key on purpose:
  `signup_ceremonies` holds the reserved id of an account that does not exist yet
  (spec 02 §5.3), and the sweep is what erases its plaintext address.
- A materialized view. It is a stored copy of a query, and a DELETE on it is not
  possible. The purge runs `REFRESH MATERIALIZED VIEW` after the rows below it are
  gone, and names the view in `RefreshedViews`. An entry there means that a stored
  copy of user data exists; examine it. `REFRESH` takes an ACCESS EXCLUSIVE lock, and
  PostgreSQL refuses it to a role that is not the owner. Thus a view that somebody
  made without a plan for deletion makes the purge fail loudly (`ErrIncomplete`). It
  does not stay as a copy of the data of a deleted person. The person who makes such
  a view must let the purge reach it.

The purge counts each relation again after the sweep. A relation that is not empty
refuses the whole purge.

Applies to: `server/internal/purge/purge.go` (`purgeUsers`,
`Report.SweptWithoutCascade`, `Report.RefreshedViews`).

## The purge erases the address from rows that have no user_id

The address of an account is also in rows that never had its `user_id` (spec 02
§15.2 steps 2 to 4, spec 07 §6.6): the signup code and the invite were sent before
the account existed, and a notice of another account can name the address.
`eraseAddress` runs before the account row is deleted, because it reads the address
from that row.

- The matches on the plaintext address run for each caller: queued mail to the
  address is deleted, mail in the send state is suppressed with no address, final
  mail keeps only its hint and tag, the joined waitlist entry and a signup or
  email-change ceremony with the address go.
- The matches on the `email_tag` need the auth key of the server (`Options.Tagger`).
  `hasalad serve` has it. The CLI and the console do not (spec 02 §15.4), and they
  skip the codes that belong to no account and the tag search for joined waitlist
  entries. The owner accepts this: those rows expire in 70 minutes and in 30 days.
- The `deleted` email is queued to the address with no account, because the row must
  stay after the account is gone. It loses the address when its send is final. The
  API and `purge-user` ask for it. A purge that the restore replay applies again does
  not.

Applies to: `server/internal/purge/purge.go` (`eraseAddress`, `Options`).

## Purge tests seed each discovered table with raw INSERTs

The completeness test of the purge puts one row or more for a new user in each
relation that `UserScopedTables` finds. The seeders are found by table name from that
list, not from a list in the test. A table from a later change thus fails the test
with "no seeder for user-scoped table X".

The seeders are raw INSERT statements, run as the runtime role. They do not call the
`auth` or `oplog` packages. The test is about the schema. Through the packages, a
table whose package has no writer yet gets no row, and the completeness proof passes
because the table was never filled.

Applies to: `server/internal/purge/purge_test.go` (`seeders`,
`seedAFullyPopulatedUser`).
