package mail

import (
	"bytes"
	"errors"
	"log"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	out, flags, logger := log.Writer(), log.Flags(), slog.Default()
	t.Cleanup(func() {
		slog.SetDefault(logger)
		log.SetOutput(out)
		log.SetFlags(flags)
	})
	buf := &bytes.Buffer{}
	slog.SetDefault(slog.New(slog.NewTextHandler(buf, nil)))
	return buf
}

func breakLayout(t *testing.T) {
	t.Helper()
	layoutOnce.Do(loadLayout)
	saved := layoutErr
	t.Cleanup(func() {
		layoutErr = saved
		renderFaults.Clear()
	})
	layoutErr = errors.New("the layout template is broken")
}

func TestAnAccountEmailWhoseHTMLFailsGoesAsTextAndIsReportedOnce(t *testing.T) {
	logs := captureLog(t)
	breakLayout(t)
	at := time.Date(2026, 3, 4, 5, 6, 0, 0, time.UTC)

	for range 2 {
		m := Deleted("person@example.test", at)
		if m.HTML != "" {
			t.Fatalf("the HTML part is %q, want empty", m.HTML)
		}
		if !strings.Contains(m.Text, "Hi,") || !strings.Contains(m.Text, Footer) {
			t.Fatalf("the text part is %q, want the full text email", m.Text)
		}
	}
	got := logs.String()
	if n := strings.Count(got, "did not render"); n != 1 {
		t.Fatalf("%d reports for two failed renders of one kind, want 1:\n%s", n, got)
	}
	for _, want := range []string{"level=ERROR", "mail_kind=deleted", "the layout template is broken"} {
		if !strings.Contains(got, want) {
			t.Fatalf("the report lacks %q:\n%s", want, got)
		}
	}
	for _, leak := range []string{"person@example.test", "was deleted"} {
		if strings.Contains(got, leak) {
			t.Fatalf("the report carries %q:\n%s", leak, got)
		}
	}

	if _, err := Code("other@example.test", "signup", "123456", ""); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(logs.String(), "did not render"); n != 2 {
		t.Fatalf("a second kind gave %d reports in all, want 2:\n%s", n, logs.String())
	}
	if !strings.Contains(logs.String(), "mail_kind=code") {
		t.Fatalf("the second report lacks its kind:\n%s", logs.String())
	}
}

func TestAnAccountEmailThatRendersReportsNothing(t *testing.T) {
	logs := captureLog(t)
	m := Deleted("person@example.test", time.Date(2026, 3, 4, 5, 6, 0, 0, time.UTC))
	if m.HTML == "" {
		t.Fatal("the HTML part is empty")
	}
	if logs.Len() != 0 {
		t.Fatalf("a good render logged:\n%s", logs.String())
	}
}
