package corpus

import (
	"bytes"
	"compress/gzip"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const liveDir = "/var/lib/ledger"

var ErrLiveDatabase = errors.New("corpus: refusing to open the live v1 database")

var ErrStop = errors.New("corpus: stop iteration")

type Message struct {
	ID         int64
	ReceivedAt time.Time
	FromAddr   string
	Subject    string
	RawBody    []byte
}

type DB struct {
	db *sql.DB
}

func Open(path string) (*DB, error) {
	if err := checkNotLive(path); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		return nil, fmt.Errorf("corpus: open %s: %w", path, err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("corpus: open %s: %w", path, err)
	}
	return &DB{db: db}, nil
}

func checkNotLive(path string) error {
	candidates := []string{path}
	if abs, err := filepath.Abs(path); err == nil {
		candidates = append(candidates, abs)
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		if abs, err := filepath.Abs(real); err == nil {
			candidates = append(candidates, abs)
		}
	}
	for _, c := range candidates {
		c = filepath.Clean(c)
		if c == liveDir || strings.HasPrefix(c, liveDir+string(filepath.Separator)) {
			return fmt.Errorf("%w: %s is under %s; make a root `.backup` snapshot into scratch first", ErrLiveDatabase, path, liveDir)
		}
	}
	return nil
}

func (d *DB) Close() error { return d.db.Close() }

func (d *DB) Count() (int, error) {
	var n int
	if err := d.db.QueryRow(`SELECT count(*) FROM ingest_log`).Scan(&n); err != nil {
		return 0, fmt.Errorf("corpus: count: %w", err)
	}
	return n, nil
}

func (d *DB) Each(fn func(Message) error) error {
	rows, err := d.db.Query(`
		SELECT id, coalesce(received_at, ''), coalesce(from_addr, ''),
		       coalesce(subject, ''), raw_body
		FROM ingest_log
		ORDER BY id`)
	if err != nil {
		return fmt.Errorf("corpus: query: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var (
			m       Message
			recv    string
			rawBody []byte
		)
		if err := rows.Scan(&m.ID, &recv, &m.FromAddr, &m.Subject, &rawBody); err != nil {
			return fmt.Errorf("corpus: scan: %w", err)
		}
		if recv != "" {
			t, err := time.Parse(time.RFC3339, recv)
			if err != nil {
				return fmt.Errorf("corpus: message %d: received_at is not RFC 3339", m.ID)
			}
			m.ReceivedAt = t
		}
		body, err := gunzip(rawBody)
		if err != nil {
			return fmt.Errorf("corpus: message %d: %w", m.ID, err)
		}
		m.RawBody = body

		if err := fn(m); err != nil {
			if errors.Is(err, ErrStop) {
				return rows.Err()
			}
			return err
		}
	}
	return rows.Err()
}

func gunzip(b []byte) ([]byte, error) {
	if len(b) < 2 || b[0] != 0x1f || b[1] != 0x8b {
		return b, nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, fmt.Errorf("gunzip: %w", err)
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		return nil, fmt.Errorf("gunzip: %w", err)
	}
	return out, nil
}

func DefaultPath() string { return os.Getenv("HASALA_CORPUS_DB") }

type Rule struct {
	MatchType string
	Pattern   string
	Category  string
	Active    bool
}

func (d *DB) Rules() ([]Rule, error) {
	rows, err := d.db.Query(`
		SELECT r.match_type, r.pattern, c.name, r.is_active
		FROM rules r JOIN categories c ON c.id = r.category_id
		ORDER BY r.id`)
	if err != nil {
		return nil, fmt.Errorf("corpus: rules: %w", err)
	}
	defer rows.Close()
	var out []Rule
	for rows.Next() {
		var r Rule
		var active int
		if err := rows.Scan(&r.MatchType, &r.Pattern, &r.Category, &active); err != nil {
			return nil, fmt.Errorf("corpus: rules: %w", err)
		}
		r.Active = active != 0
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("corpus: rules: %w", err)
	}
	return out, nil
}
