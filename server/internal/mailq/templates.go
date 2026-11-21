package mailq

import (
	"bytes"
	"context"
	"embed"
	"fmt"
	htmltemplate "html/template"
	"strings"
	"sync"
	texttemplate "text/template"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
)

//go:embed templates/*.tmpl
var templateFS embed.FS

type Content struct {
	Greeting     string
	Email        string
	BankName     string
	ConfirmURL   string
	LeaveURL     string
	Code         string
	InviteURL    string
	FallbackText string
	Until        string
	ConfirmedOn  string
	InvitedOn    string
	Why          string

	Invited          bool
	ManualTestFlight bool
	AccountAudience  bool
}

type Rendered struct {
	Subject, Text, HTML string
}

var (
	tmplOnce sync.Once
	textT    *texttemplate.Template
	htmlT    map[string]*htmltemplate.Template
	tmplErr  error
)

func loadTemplates() {
	textT, tmplErr = texttemplate.ParseFS(templateFS, "templates/*.txt.tmpl")
	if tmplErr != nil {
		return
	}
	htmlT = map[string]*htmltemplate.Template{}
	entries, err := templateFS.ReadDir("templates")
	if err != nil {
		tmplErr = err
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".html.tmpl") {
			continue
		}
		t, err := mail.Layout()
		if err == nil {
			t, err = t.ParseFS(templateFS, "templates/"+name)
		}
		if err != nil {
			tmplErr = err
			return
		}
		htmlT[strings.TrimSuffix(name, ".html.tmpl")] = t
	}
}

func RenderTemplate(kind string, c Content) (Rendered, error) {
	tmplOnce.Do(loadTemplates)
	if tmplErr != nil {
		return Rendered{}, tmplErr
	}
	if c.Greeting == "" {
		c.Greeting = "Hi,"
	}
	var tb bytes.Buffer
	if err := textT.ExecuteTemplate(&tb, kind+".txt.tmpl", c); err != nil {
		return Rendered{}, err
	}
	subject, body, _ := strings.Cut(tb.String(), "\n")
	r := Rendered{Subject: strings.TrimSpace(subject), Text: strings.TrimLeft(body, "\n")}
	if ht, ok := htmlT[kind]; ok {
		var hb bytes.Buffer
		data := struct {
			Content
			Title, Preview string
		}{c, r.Subject, ""}
		if err := ht.ExecuteTemplate(&hb, "layout", data); err != nil {
			return Rendered{}, err
		}
		r.HTML = hb.String()
	}
	return r, nil
}

var uae = time.FixedZone("UAE", 4*60*60)

func Date(t time.Time) string { return t.In(uae).Format("Monday 2 January") }

func EnqueueTest(ctx context.Context, tx pgx.Tx, q *Queue, address string) (int64, error) {
	to, err := keyproto.EmailNorm(address)
	if err != nil {
		return 0, fmt.Errorf("mailq: %q is not an email address", address)
	}
	return q.EnqueueTx(ctx, tx, Enqueue{Kind: "test", Lane: LaneTransactional, To: to})
}

var TestRenderer = RenderFunc(func(_ context.Context, _ pgx.Tx, row Row) (mail.Message, error) {
	r, err := RenderTemplate("test", Content{Why: "You're getting this because the Hasala team sent a test email to this address."})
	if err != nil {
		return mail.Message{}, err
	}
	return mail.Message{To: row.Recipient, Subject: r.Subject, Text: r.Text, HTML: r.HTML}, nil
})

var DeletedRenderer = RenderFunc(func(_ context.Context, _ pgx.Tx, row Row) (mail.Message, error) {
	at := row.CreatedAt
	if s, ok := row.Params["deleted_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			at = t
		}
	}
	return mail.Deleted(row.Recipient, at), nil
})
