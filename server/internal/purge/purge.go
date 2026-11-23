package purge

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

var handledWithoutUserID = []string{
	"public.users",
}

var notUserLinked = []string{
	"public.invite_codes",
	"public.deleted_account_sessions",
	"public.goose_db_version",
	"public.email_code_pauses",
	"public.rate_counters",
	"public.device_freeze_challenges",
	"public.server_meta",
	"public.restore_ledger_held",
	"public.banks",
	"public.waitlist_entries",
	"public.waitlist_tokens",
	"public.admin_audit",
}

type Report struct {
	Users []uuid.UUID

	Rows map[string]int

	SweptWithoutCascade []string

	RefreshedViews []string

	UnownedCodes int

	Goodbyes int

	Deferred []uuid.UUID
}

func newReport() Report { return Report{Rows: map[string]int{}} }

func (r Report) Total() int {
	n := 0
	for _, v := range r.Rows {
		n += v
	}
	return n
}

var ErrIncomplete = errors.New("purge: refused: cannot account for every relation")

type Relation struct {
	Schema string
	Name   string
	Kind   byte
}

func (r Relation) String() string { return r.Schema + "." + r.Name }

func (r Relation) SQL() string { return pgx.Identifier{r.Schema, r.Name}.Sanitize() }

func (r Relation) KindName() string {
	switch r.Kind {
	case 'r':
		return "table"
	case 'p':
		return "partitioned table"
	case 'm':
		return "materialized view"
	case 'f':
		return "foreign table"
	default:
		return fmt.Sprintf("relkind %q", string(r.Kind))
	}
}

const relationFilter = `
	  cl.relkind IN ('r','p','m','f')
	  AND NOT cl.relispartition
	  AND ns.nspname NOT IN ('pg_catalog','information_schema')
	  AND ns.nspname !~ '^pg_'`

func UserScopedTables(ctx context.Context, pool *pgxpool.Pool) ([]Relation, error) {
	if pool == nil {
		return nil, errors.New("purge: pool is nil")
	}
	return scanRelations(ctx, pool, `
		SELECT ns.nspname, cl.relname, cl.relkind::text
		  FROM pg_class cl
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		  JOIN pg_attribute a ON a.attrelid = cl.oid
		 WHERE`+relationFilter+`
		   AND a.attname = 'user_id'
		   AND a.attnum > 0
		   AND NOT a.attisdropped
		 ORDER BY ns.nspname, cl.relname`, "discover user-scoped relations")
}

func allRelations(ctx context.Context, pool *pgxpool.Pool) ([]Relation, error) {
	return scanRelations(ctx, pool, `
		SELECT ns.nspname, cl.relname, cl.relkind::text
		  FROM pg_class cl
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		 WHERE`+relationFilter+`
		 ORDER BY ns.nspname, cl.relname`, "list relations")
}

func scanRelations(ctx context.Context, pool *pgxpool.Pool, sql, what string) ([]Relation, error) {
	rows, err := pool.Query(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("purge: %s: %w", what, err)
	}
	defer rows.Close()
	var out []Relation
	for rows.Next() {
		var r Relation
		var kind string
		if err := rows.Scan(&r.Schema, &r.Name, &kind); err != nil {
			return nil, fmt.Errorf("purge: %s: %w", what, err)
		}
		if kind == "" {
			return nil, fmt.Errorf("purge: %s: %s.%s has an empty relkind", what, r.Schema, r.Name)
		}
		r.Kind = kind[0]
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("purge: %s: %w", what, err)
	}
	return out, nil
}

type Classification struct {
	UserScoped           []Relation
	HandledWithoutUserID []string
	NotUserLinked        []string
	Unclassified         []string
}

func Classify(ctx context.Context, pool *pgxpool.Pool) (Classification, error) {
	if pool == nil {
		return Classification{}, errors.New("purge: pool is nil")
	}
	scoped, err := UserScopedTables(ctx, pool)
	if err != nil {
		return Classification{}, err
	}
	all, err := allRelations(ctx, pool)
	if err != nil {
		return Classification{}, err
	}
	c := Classification{UserScoped: scoped}
	isScoped := make(map[string]bool, len(scoped))
	for _, r := range scoped {
		isScoped[r.String()] = true
	}
	for _, r := range all {
		name := r.String()
		switch {
		case isScoped[name]:
		case slices.Contains(handledWithoutUserID, name):
			c.HandledWithoutUserID = append(c.HandledWithoutUserID, name)
		case slices.Contains(notUserLinked, name):
			c.NotUserLinked = append(c.NotUserLinked, name)
		default:
			c.Unclassified = append(c.Unclassified, name+" ("+r.KindName()+")")
		}
	}
	return c, nil
}

func cascadeActions(ctx context.Context, pool *pgxpool.Pool) (map[string][]byte, error) {
	rows, err := pool.Query(ctx, `
		-- confdeltype is Postgres's internal "char" type, which pgx will not
		-- scan into a string; the cast is not cosmetic.
		SELECT ns.nspname, cl.relname, con.confdeltype::text
		  FROM pg_constraint con
		  JOIN pg_class cl ON cl.oid = con.conrelid
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		 WHERE con.contype = 'f'
		   AND con.confrelid = 'public.users'::regclass
		   AND EXISTS (
		       SELECT 1 FROM pg_attribute a
		        WHERE a.attrelid = con.conrelid
		          AND a.attnum = ANY (con.conkey)
		          AND a.attname = 'user_id')`)
	if err != nil {
		return nil, fmt.Errorf("purge: read foreign-key actions: %w", err)
	}
	defer rows.Close()
	out := map[string][]byte{}
	for rows.Next() {
		var schema, name, action string
		if err := rows.Scan(&schema, &name, &action); err != nil {
			return nil, fmt.Errorf("purge: read foreign-key actions: %w", err)
		}
		if action != "" {
			key := schema + "." + name
			out[key] = append(out[key], action[0])
		}
	}
	return out, rows.Err()
}

var deleteActionNames = map[byte]string{
	'a': "NO ACTION", 'r': "RESTRICT", 'c': "CASCADE", 'n': "SET NULL", 'd': "SET DEFAULT",
}

func CheckCascades(ctx context.Context, pool *pgxpool.Pool, rels []Relation) error {
	actions, err := cascadeActions(ctx, pool)
	if err != nil {
		return err
	}
	for _, r := range rels {
		for _, a := range actions[r.String()] {
			if a == 'c' {
				continue
			}
			name, known := deleteActionNames[a]
			if !known {
				name = fmt.Sprintf("confdeltype %q", string(a))
			}
			return fmt.Errorf("%w: %s.user_id references users ON DELETE %s, not CASCADE — "+
				"deleting the account would %s", ErrIncomplete, r, name,
				map[bool]string{true: "leave the rows behind with a blanked user_id",
					false: "be refused by the foreign key"}[a == 'n' || a == 'd'])
		}
	}
	return nil
}

func Purge(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) (Report, error) {
	return PurgeWith(ctx, pool, userID, Options{})
}

type Options struct {
	Tagger  mailq.Tagger
	Goodbye bool
	Now     func() time.Time
	Record  func(users []uuid.UUID) error
	Cancel  func(users []uuid.UUID) error

	armed func(users []uuid.UUID) ([]uuid.UUID, error)
}

var ErrUnsettled = errors.New("purge: the deletion did not finish and the ledger may still name the accounts")

const (
	commitWait  = 30 * time.Second
	holdRelease = 5 * time.Second
)

func PurgeWith(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, opts Options) (Report, error) {
	if pool == nil {
		return Report{}, errors.New("purge: pool is nil")
	}
	if userID == uuid.Nil {
		return Report{}, errors.New("purge: user id is zero")
	}
	if opts.Record != nil {
		hold, err := newAccountHold(ctx, pool)
		if err != nil {
			return newReport(), err
		}
		defer hold.release()
		if err := hold.wait(ctx, userID); err != nil {
			return newReport(), err
		}
	}
	return purgeUsers(ctx, pool, []uuid.UUID{userID}, opts)
}

type accountHold struct {
	conn *pgx.Conn
}

func newAccountHold(ctx context.Context, pool *pgxpool.Pool) (*accountHold, error) {
	c, err := pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("purge: open the account hold: %w", err)
	}
	return &accountHold{conn: c.Hijack()}, nil
}

func holdKey(id uuid.UUID) string { return "hasala/purge/" + id.String() }

func (h *accountHold) wait(ctx context.Context, id uuid.UUID) error {
	if _, err := h.conn.Exec(ctx, `SELECT pg_advisory_lock(hashtextextended($1, 0))`, holdKey(id)); err != nil {
		return fmt.Errorf("purge: hold the account: %w", err)
	}
	return nil
}

func (h *accountHold) try(ctx context.Context, ids []uuid.UUID) (free, busy []uuid.UUID, err error) {
	for _, id := range ids {
		var got bool
		if err := h.conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtextextended($1, 0))`, holdKey(id)).Scan(&got); err != nil {
			return nil, nil, fmt.Errorf("purge: hold the account: %w", err)
		}
		if got {
			free = append(free, id)
		} else {
			busy = append(busy, id)
		}
	}
	return free, busy, nil
}

func (h *accountHold) release() {
	ctx, cancel := context.WithTimeout(context.Background(), holdRelease)
	defer cancel()
	_, _ = h.conn.Exec(ctx, `SELECT pg_advisory_unlock_all()`)
	_ = h.conn.Close(ctx)
}

func purgeUsers(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID, opts Options) (Report, error) {
	rep := newReport()
	if len(users) == 0 {
		return rep, nil
	}

	c, err := Classify(ctx, pool)
	if err != nil {
		return rep, err
	}
	if len(c.Unclassified) != 0 {
		return rep, fmt.Errorf("%w: unclassified relations %v — give them a user_id column, "+
			"or classify them in internal/purge", ErrIncomplete, c.Unclassified)
	}

	if err := CheckCascades(ctx, pool, c.UserScoped); err != nil {
		return rep, err
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return rep, fmt.Errorf("purge: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id = ANY($1) ORDER BY id FOR UPDATE`, users); err != nil {
		return rep, fmt.Errorf("purge: lock the accounts: %w", err)
	}
	if opts.armed != nil {
		if users, err = opts.armed(users); err != nil {
			return rep, err
		}
		if len(users) == 0 {
			return rep, nil
		}
	}

	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		rep.Rows[r.String()] = n
	}

	if err := eraseAddress(ctx, tx, users, opts, &rep); err != nil {
		return rep, err
	}

	rows, err := tx.Query(ctx, `DELETE FROM users WHERE id = ANY($1) RETURNING id`, users)
	if err != nil {
		return rep, fmt.Errorf("purge: delete users: %w", err)
	}
	deleted, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return rep, fmt.Errorf("purge: delete users: %w", err)
	}

	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if n == 0 {
			continue
		}
		if r.Kind == 'm' {
			if _, err := tx.Exec(ctx, `REFRESH MATERIALIZED VIEW `+r.SQL()); err != nil {
				return rep, fmt.Errorf("%w: materialized view %s holds %d rows for the purged "+
					"accounts and could not be refreshed (%v) — a matview is a stored COPY, so "+
					"the rows survive the cascade; drop it, or grant the purge role ownership",
					ErrIncomplete, r, n, err)
			}
			rep.RefreshedViews = append(rep.RefreshedViews, r.String())
		} else if _, err := tx.Exec(ctx,
			`DELETE FROM `+r.SQL()+` WHERE user_id = ANY($1)`, users); err != nil {
			return rep, fmt.Errorf("purge: sweep %s: %w", r, err)
		} else {
			rep.SweptWithoutCascade = append(rep.SweptWithoutCascade, r.String())
		}
		left, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if left != 0 {
			return rep, fmt.Errorf("%w: %s %s still holds %d rows after an explicit %s",
				ErrIncomplete, r.KindName(), r, left,
				map[bool]string{true: "refresh", false: "delete"}[r.Kind == 'm'])
		}
	}

	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if n != 0 {
			return rep, fmt.Errorf("%w: %s %s still holds %d rows for the purged accounts",
				ErrIncomplete, r.KindName(), r, n)
		}
	}
	var left int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = ANY($1)`, users).Scan(&left); err != nil {
		return rep, fmt.Errorf("purge: verify users: %w", err)
	}
	if left != 0 {
		return rep, fmt.Errorf("%w: %d of the accounts survived their own deletion", ErrIncomplete, left)
	}

	if opts.Record != nil && len(deleted) > 0 {
		if err := opts.Record(deleted); err != nil {
			if errors.Is(err, purgeledger.ErrNotWritten) {
				return rep, fmt.Errorf("purge: record the deletion: %w", err)
			}
			if opts.Cancel == nil {
				return rep, fmt.Errorf("%w: record the deletion: %w", ErrUnsettled, err)
			}
			if cerr := opts.Cancel(deleted); cerr != nil {
				return rep, fmt.Errorf("%w: record the deletion: %w; cancel the line: %v", ErrUnsettled, err, cerr)
			}
			return rep, fmt.Errorf("purge: record the deletion: %w", err)
		}
	}

	commitCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitWait)
	defer cancel()
	if err := tx.Commit(commitCtx); err != nil {
		if opts.Record == nil || len(deleted) == 0 {
			return rep, fmt.Errorf("purge: commit: %w", err)
		}
		committed, serr := settleFailedCommit(ctx, pool, deleted, opts, err)
		if !committed {
			return rep, serr
		}
	}
	rep.Users = deleted
	return rep, nil
}

func settleFailedCommit(ctx context.Context, pool *pgxpool.Pool, deleted []uuid.UUID, opts Options, cause error) (bool, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitWait)
	defer cancel()
	tx, err := pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("%w: commit: %v; read back: %v", ErrUnsettled, cause, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	rows, err := tx.Query(ctx, `SELECT id FROM users WHERE id = ANY($1) FOR UPDATE`, deleted)
	if err != nil {
		return false, fmt.Errorf("%w: commit: %v; read back: %v", ErrUnsettled, cause, err)
	}
	survived, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return false, fmt.Errorf("%w: commit: %v; read back: %v", ErrUnsettled, cause, err)
	}
	if len(survived) == 0 {
		return true, nil
	}
	if opts.Cancel == nil {
		return false, fmt.Errorf("%w: commit: %v", ErrUnsettled, cause)
	}
	if err := opts.Cancel(survived); err != nil {
		return false, fmt.Errorf("%w: commit: %v; cancel the line: %v", ErrUnsettled, cause, err)
	}
	return false, fmt.Errorf("purge: commit: %w", cause)
}

func Replay(ctx context.Context, pool *pgxpool.Pool, ids []uuid.UUID) (Report, error) {
	return replayIDs(ctx, pool, ids, Options{})
}

func ReplayLedger(ctx context.Context, pool *pgxpool.Pool, path string) (Report, error) {
	entries, err := purgeledger.Read(path)
	if err != nil {
		return newReport(), err
	}
	return replayIDs(ctx, pool, purgeledger.IDs(entries), Options{armed: func(users []uuid.UUID) ([]uuid.UUID, error) {
		return stillArmed(path, users)
	}})
}

func stillArmed(path string, users []uuid.UUID) ([]uuid.UUID, error) {
	entries, err := purgeledger.Read(path)
	if err != nil {
		return nil, err
	}
	armed := make(map[uuid.UUID]bool, len(entries))
	for _, id := range purgeledger.IDs(entries) {
		armed[id] = true
	}
	kept := make([]uuid.UUID, 0, len(users))
	for _, u := range users {
		if armed[u] {
			kept = append(kept, u)
		}
	}
	return kept, nil
}

func replayIDs(ctx context.Context, pool *pgxpool.Pool, ids []uuid.UUID, opts Options) (Report, error) {
	if pool == nil {
		return Report{}, errors.New("purge: pool is nil")
	}
	if len(ids) == 0 {
		return newReport(), nil
	}
	rows, err := pool.Query(ctx, `SELECT id FROM users WHERE id = ANY($1) ORDER BY id`, ids)
	if err != nil {
		return newReport(), fmt.Errorf("purge: replay: %w", err)
	}
	live, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return newReport(), fmt.Errorf("purge: replay: %w", err)
	}
	if len(live) == 0 {
		return newReport(), nil
	}
	hold, err := newAccountHold(ctx, pool)
	if err != nil {
		return newReport(), err
	}
	defer hold.release()
	free, busy, err := hold.try(ctx, live)
	if err != nil {
		return newReport(), err
	}
	rep, err := purgeUsers(ctx, pool, free, opts)
	rep.Deferred = busy
	return rep, err
}

func countFor(ctx context.Context, tx pgx.Tx, r Relation, users []uuid.UUID) (int, error) {
	var n int
	err := tx.QueryRow(ctx,
		`SELECT count(*) FROM `+r.SQL()+` WHERE user_id = ANY($1)`, users).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("purge: count %s: %w", r, err)
	}
	return n, nil
}

func eraseAddress(ctx context.Context, tx pgx.Tx, users []uuid.UUID, opts Options, rep *Report) error {
	type account struct {
		id   uuid.UUID
		addr string
		tag  []byte
	}
	rows, err := tx.Query(ctx, `SELECT id, email_norm FROM users WHERE id = ANY($1) AND email_norm IS NOT NULL ORDER BY id`, users)
	if err != nil {
		return fmt.Errorf("purge: read the address: %w", err)
	}
	accts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (account, error) {
		var a account
		err := r.Scan(&a.id, &a.addr)
		return a, err
	})
	if err != nil {
		return fmt.Errorf("purge: read the address: %w", err)
	}
	var tags [][]byte
	if opts.Tagger != nil {
		for i := range accts {
			accts[i].tag = opts.Tagger.EmailTag(accts[i].addr)
			tags = append(tags, accts[i].tag)
		}
		tag, err := tx.Exec(ctx, `DELETE FROM email_codes WHERE user_id IS NULL AND email_tag = ANY($1::bytea[])`, tags)
		if err != nil {
			return fmt.Errorf("purge: delete the address's codes: %w", err)
		}
		rep.UnownedCodes = int(tag.RowsAffected())
		if _, err := tx.Exec(ctx,
			`DELETE FROM waitlist_entries WHERE state = 'joined' AND email_tag = ANY($1::bytea[])`, tags); err != nil {
			return fmt.Errorf("purge: erase the address: %w", err)
		}
	}
	const addrs = `(SELECT email_norm FROM users WHERE id = ANY($1) AND email_norm IS NOT NULL)`
	if _, err := tx.Exec(ctx,
		`WITH revoked AS (
		   UPDATE invite_codes SET state = 'revoked', closed_at = now(), email_tag = NULL, link_key_hash = NULL
		    WHERE state IN ('awaiting_testflight','queued','active')
		      AND ((email_tag IS NOT NULL AND email_tag = ANY($2::bytea[]))
		        OR id IN (SELECT invite_id FROM mail_log WHERE invite_id IS NOT NULL AND recipient IN `+addrs+`))
		   RETURNING id, waitlist_entry_id)
		 UPDATE waitlist_entries e SET state = 'confirmed', invited_at = NULL, updated_at = now()
		  WHERE e.state = 'invited' AND e.id IN (SELECT waitlist_entry_id FROM revoked WHERE waitlist_entry_id IS NOT NULL)
		    AND NOT EXISTS (SELECT 1 FROM invite_codes i WHERE i.waitlist_entry_id = e.id
		                     AND i.state IN ('awaiting_testflight','queued','active')
		                     AND i.id NOT IN (SELECT id FROM revoked))`,
		users, tags); err != nil {
		return fmt.Errorf("purge: revoke the address's invites: %w", err)
	}
	for _, q := range []string{
		`DELETE FROM mail_log WHERE status = 'queued' AND recipient IN ` + addrs,
		`UPDATE mail_log SET status = 'suppressed', recipient = NULL, lease_until = NULL, final_at = now(), error = 'purged'
		  WHERE status = 'sending' AND recipient IN ` + addrs,
		`UPDATE mail_log SET recipient = NULL WHERE final_at IS NOT NULL AND recipient IN ` + addrs,
		`UPDATE mail_log SET recipient = NULL WHERE final_at IS NOT NULL AND user_id IS NULL AND recipient IN
		   (SELECT recipient FROM mail_log WHERE user_id = ANY($1) AND kind = 'alert' AND subkind = 'email_changed_old'
		       AND recipient IS NOT NULL)`,
		`DELETE FROM waitlist_entries WHERE state = 'joined'
		    AND id IN (SELECT waitlist_entry_id FROM invite_codes WHERE redeemed_by = ANY($1))`,
		`DELETE FROM signup_ceremonies WHERE email_norm IN ` + addrs,
		`DELETE FROM email_change_ceremonies WHERE new_email_norm IN ` + addrs,
	} {
		if _, err := tx.Exec(ctx, q, users); err != nil {
			return fmt.Errorf("purge: erase the address: %w", err)
		}
	}
	if !opts.Goodbye {
		return nil
	}
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}
	q := mailq.New(nil, nil, opts.Tagger)
	for _, a := range accts {
		if _, err := q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "deleted", Lane: mailq.LaneTransactional, To: a.addr,
			Tag: a.tag, Params: map[string]any{"deleted_at": now().UTC().Format(time.RFC3339Nano)}}); err != nil {
			return fmt.Errorf("purge: queue the goodbye: %w", err)
		}
		rep.Goodbyes++
	}
	return nil
}
