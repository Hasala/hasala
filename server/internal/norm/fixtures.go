package norm

import (
	"bytes"
	"fmt"
	"strings"
	"time"
)

const RealCasesDir = "conformance/normalizer"

type ConformanceCase struct {
	Name              string `json:"name"`
	Note              string `json:"note,omitempty"`
	Source            string `json:"source"`
	NormalizerVersion int    `json:"normalizer_version"`
	ReceivedAt        string `json:"received_at"`
	RawBase64         string `json:"raw_base64"`

	ExpectTextBase64    string `json:"expect_text_base64"`
	ExpectPart          string `json:"expect_part"`
	ExpectCharset       string `json:"expect_charset"`
	ExpectSubjectBase64 string `json:"expect_subject_base64"`
	ExpectFromBase64    string `json:"expect_from_base64"`
	ExpectForwarded     bool   `json:"expect_forwarded"`
	ExpectEmailDate     string `json:"expect_email_date"`
	ExpectDateSource    string `json:"expect_date_source"`
}

type FixtureSpec struct {
	Name   string
	ID     int64
	Note   string
	Derive func([]byte) []byte
}

var CorpusFixtures = []FixtureSpec{
	{Name: "dib-arabic-01", ID: 9, Note: "DIB credit-card purchase notification, Arabic, text/html base64 utf-8 — the single most common shape in the corpus"},
	{Name: "dib-arabic-02", ID: 10, Note: "as dib-arabic-01, a different merchant and amount"},
	{Name: "dib-arabic-03", ID: 11, Note: "as dib-arabic-01, third sample"},
	{Name: "dib-arabic-04", ID: 13},
	{Name: "dib-arabic-05", ID: 15},
	{Name: "dib-arabic-06", ID: 17},
	{Name: "dib-arabic-07", ID: 2542, Note: "sent from dib.mail@dib.ae rather than DIB.notification@dib.ae"},

	{Name: "dib-windows1256-01", ID: 2695, Note: "declared charset=windows-1256; the bytes are NOT valid UTF-8 and must be converted, not replaced"},
	{Name: "dib-windows1256-02", ID: 2728},
	{Name: "dib-windows1256-03", ID: 2882},
	{Name: "dib-windows1256-04", ID: 2915},
	{Name: "dib-windows1256-05", ID: 3038},

	{Name: "enbd-local-transfer-01", ID: 2422, Note: "Emirates NBD online-banking transfer advice, quoted-printable"},
	{Name: "enbd-local-transfer-02", ID: 2423},
	{Name: "enbd-telegraphic-transfer", ID: 2434},

	{Name: "google-quoted-printable-01", ID: 1, Note: "quoted-printable body with soft line breaks"},
	{Name: "google-quoted-printable-02", ID: 2},
	{Name: "google-notice", ID: 8},
	{Name: "us-ascii-plain", ID: 6, Note: "the corpus's ONLY us-ascii part. It is pure ASCII, so the ianaindex/WHATWG disagreement over us-ascii (see the spec) is invisible here"},

	{Name: "quoted-forward-recovers-no-headers", ID: 2484, Note: "the shape 50 of the corpus's 56 forwards have: the marker line is unquoted but every header line is '>'-quoted, so Forwarded is true and NOTHING is recovered. v1 behaves identically"},
	{Name: "apple-forward-feff-line", ID: 2554, Note: "THE trim divergence. The line after the forwarded header block is a lone U+FEFF: v1's strings.TrimSpace keeps it, the explicit set drops it. Also carries the Apple-Mail iOS 12-hour-with-seconds date the four closed layouts cannot parse, so DateSource is 'received'"},
	{Name: "apple-forward-dib-01", ID: 6850, Note: "Apple Mail value-on-the-next-line header layout, with multipart/related nested inside multipart/alternative; the inner Date parses"},
	{Name: "apple-forward-feff-line-2", ID: 6853, Note: "second of the three U+FEFF messages"},
	{Name: "apple-forward-dib-02", ID: 6855, Note: "nested multipart/related, inner date parses"},
	{Name: "hair-space-lines-survive", ID: 6859, Note: "THE OTHER DIRECTION of the trim divergence. This body has lines made only of U+200A HAIR SPACE. Go's strings.TrimSpace empties them and v1 drops them; the explicit set does not contain U+200A, so v2 keeps them. It is the only corpus message of its kind, and without it the suite would pin the U+FEFF direction only"},
	{Name: "apple-forward-enbd-alert", ID: 6973, Note: "DECISION 14 IN ONE MESSAGE. An Apple-Mail forward of an Emirates NBD 'Transaction advice'. The account last4 lives ONLY in the subject, and only in the INNER subject: the outer envelope subject is 'Fwd: ...'. Its Subject header is also the corpus's only multi-word RFC 2047 case"},

	{Name: "dib-arabic-08", ID: 2425},
	{Name: "dib-arabic-09", ID: 3102},
	{Name: "dib-arabic-10", ID: 3230},
	{Name: "dib-arabic-11", ID: 5000},
	{Name: "dib-arabic-12", ID: 6000},
	{Name: "dib-arabic-13", ID: 6852},
	{Name: "dib-arabic-14", ID: 6867},

	{
		Name: "mislabelled-utf8-actually-windows-1256",
		ID:   2695,
		Note: "DERIVED from corpus id 2695 by rewriting charset=windows-1256 to charset=utf-8 and nothing else. " +
			"The corpus contains no message whose charset declaration is wrong, so this shape has to be constructed — " +
			"and it is the ONLY test of stage 3's U+FFFD placement against real bank bytes.",
		Derive: deriveMislabelCharset,
	},
	{
		Name: "broken-mime-raw-fallback",
		ID:   9,
		Note: "DERIVED from corpus id 9 by prepending one malformed header line, which makes go-message fail at the " +
			"first line and forces the stage-1 raw fallback. The corpus contains no message that fails to parse " +
			"(0 of 6998), so the fallback v2 adds over v1 has no natural sample.",
		Derive: deriveBrokenMIME,
	},
	{
		Name: "base64-continuation-indent",
		ID:   9,
		Note: "DERIVED from corpus id 9 by indenting one line of the base64 payload with two spaces. No corpus base64 " +
			"payload contains embedded whitespace, but RFC 2045 permits it; both executors must skip it rather than " +
			"fail the leaf. Text must be byte-identical to dib-arabic-01.",
		Derive: deriveBase64Indent,
	},
	{
		Name: "gmail-forward-1",
		ID:   6973,
		Note: "DERIVED. The corpus contains ZERO Gmail forwards — all 56 forwards are Apple Mail — even though Gmail " +
			"forwarding is the primary onboarding path (spec 3.2). This fixture rebuilds corpus id 6973's real ENBD " +
			"alert body under Gmail's dashed marker and same-line header layout. " +
			"WARNING: the ARC header set is copied verbatim from a real message and DOES NOT VERIFY over this body. " +
			"It is here only so the normalizer walks a realistic header block; it must never be used as an ARC fixture.",
		Derive: deriveGmailForward,
	},
}

func deriveMislabelCharset(raw []byte) []byte {
	return bytes.ReplaceAll(raw, []byte("windows-1256"), []byte("utf-8"))
}

func deriveBrokenMIME(raw []byte) []byte {
	return append([]byte("!!! this line is not a header field\r\n"), raw...)
}

func deriveBase64Indent(raw []byte) []byte {
	marker := []byte("Content-Transfer-Encoding: base64\r\n\r\n")
	i := bytes.Index(raw, marker)
	if i < 0 {
		return raw
	}
	start := i + len(marker)
	nl := bytes.Index(raw[start:], []byte("\r\n"))
	if nl < 0 {
		return raw
	}
	at := start + nl + 2
	out := make([]byte, 0, len(raw)+2)
	out = append(out, raw[:at]...)
	out = append(out, ' ', ' ')
	out = append(out, raw[at:]...)
	return out
}

func gmailForwardHeader(subject string) string {
	return "---------- Forwarded message ---------\r\n" +
		"From: Emirates NBD <alert@emiratesnbd.com>\r\n" +
		"Date: Mar 3, 2026 at 2:07 PM\r\n" +
		"Subject: " + subject + "\r\n" +
		"To: <ledger.beta.user@example.com>\r\n" +
		"\r\n"
}

func deriveGmailForward(raw []byte) []byte {
	inner, err := Normalize(CurrentVersion, raw, time.Unix(0, 0).UTC())
	if err != nil {
		return raw
	}
	var arc []string
	inARC := false
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n") {
		folded := strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t")
		switch {
		case strings.HasPrefix(strings.ToLower(line), "arc-"):
			inARC = true
		case folded && inARC:
		default:
			inARC = false
			if len(arc) > 0 {
				continue
			}
		}
		if inARC {
			arc = append(arc, line)
		}
	}
	var b strings.Builder
	b.WriteString("Return-Path: <ledger.beta.user@example.com>\r\n")
	for _, l := range arc {
		b.WriteString(l)
		b.WriteString("\r\n")
	}
	b.WriteString("From: Beta User <ledger.beta.user@example.com>\r\n")
	b.WriteString("Date: Tue, 3 Mar 2026 16:58:11 +0400\r\n")
	b.WriteString("Subject: Fwd: " + inner.Subject + "\r\n")
	b.WriteString("To: ingest@ledger.example\r\n")
	b.WriteString("Content-Type: text/plain; charset=utf-8\r\n")
	b.WriteString("Content-Transfer-Encoding: quoted-printable\r\n")
	b.WriteString("\r\n")
	b.WriteString(quotedPrintableEncode(gmailForwardHeader(inner.Subject) + strings.ReplaceAll(inner.Text, "\n", "\r\n") + "\r\n"))
	return []byte(b.String())
}

func quotedPrintableEncode(s string) string {
	var out strings.Builder
	col := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\r' && i+1 < len(s) && s[i+1] == '\n' {
			out.WriteString("\r\n")
			col = 0
			i++
			continue
		}
		var tok string
		if c == '=' || c < 32 || c > 126 {
			tok = fmt.Sprintf("=%02X", c)
		} else {
			tok = string(rune(c))
		}
		if col+len(tok) > 73 {
			out.WriteString("=\r\n")
			col = 0
		}
		out.WriteString(tok)
		col += len(tok)
	}
	return out.String()
}
