package norm

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/mail"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/emersion/go-message"
	_ "github.com/emersion/go-message/charset"

	"golang.org/x/text/encoding/htmlindex"
)

const CurrentVersion = 1

func Versions() []int { return []int{1} }

const (
	PartHTML  = "html"
	PartPlain = "plain"
	PartRaw   = "raw"
)

const (
	DateSourceForwardHeader = "forward_header"
	DateSourceReceived      = "received"
)

var (
	ErrUnknownVersion = errors.New("norm: unknown normalizer version")
	ErrNoTextPart     = errors.New("norm: no text/html or text/plain part found")
)

type Result struct {
	Text       string
	PartUsed   string
	Charset    string
	Subject    string
	From       string
	Forwarded  bool
	EmailDate  time.Time
	DateSource string
}

func Normalize(version int, raw []byte, receivedAt time.Time) (Result, error) {
	return normalizeWith(version, raw, receivedAt, trimExplicit)
}

var ErrInvalidText = errors.New("norm: the text is not valid UTF-8")

func NormalizeText(version int, text string) (string, error) {
	if version != CurrentVersion {
		return "", fmt.Errorf("%w: %d (supported: %v)", ErrUnknownVersion, version, Versions())
	}
	if !utf8.ValidString(text) {
		return "", ErrInvalidText
	}
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	return collapseWith(text, trimExplicit), nil
}

func normalizeWith(version int, raw []byte, receivedAt time.Time, trim trimmer) (Result, error) {
	if version != CurrentVersion {
		return Result{}, fmt.Errorf("%w: %d (supported: %v)", ErrUnknownVersion, version, Versions())
	}

	body, part, charset, subject, from, err := extract(raw)
	if err != nil {
		return Result{}, err
	}

	if part == PartHTML {
		body = stripHTML(body)
	}
	text := collapseWith(body, trim)

	fwd := unwrapForwardWith(from, subject, text, trim)

	res := Result{
		Text:       fwd.Body,
		PartUsed:   part,
		Charset:    charset,
		Subject:    fwd.Subject,
		From:       fwd.From,
		Forwarded:  fwd.Found,
		EmailDate:  receivedAt,
		DateSource: DateSourceReceived,
	}
	if t, derr := parseForwardDateWith(fwd.Date, trim); derr == nil {
		res.EmailDate = t
		res.DateSource = DateSourceForwardHeader
	}
	return res, nil
}

func extract(raw []byte) (body, part, charset, subject, from string, err error) {
	ent, rerr := message.Read(bytes.NewReader(raw))
	if rerr != nil && !message.IsUnknownCharset(rerr) && !message.IsUnknownEncoding(rerr) {
		subject, from = scanRawHeaders(raw)
		return decodeUTF8WHATWG(rawBodyAfterHeaders(raw)), PartRaw, "", subject, from, nil
	}

	subject = decodeWords(ent.Header.Get("Subject"))
	from = bareAddress(decodeWords(ent.Header.Get("From")))

	var w walker
	werr := w.walk(ent)

	switch {
	case w.html != "":
		return w.html, PartHTML, w.htmlCharset, subject, from, nil
	case w.plain != "":
		return w.plain, PartPlain, w.plainCharset, subject, from, nil
	case werr != nil:
		s, f := scanRawHeaders(raw)
		return decodeUTF8WHATWG(rawBodyAfterHeaders(raw)), PartRaw, "", s, f, nil
	default:
		return "", "", "", "", "", ErrNoTextPart
	}
}

type walker struct {
	html, plain               string
	htmlCharset, plainCharset string
}

func (w *walker) walk(e *message.Entity) error {
	if mr := e.MultipartReader(); mr != nil {
		for {
			part, perr := mr.NextPart()
			if perr == io.EOF {
				return nil
			}
			if perr != nil {
				return fmt.Errorf("norm: next part: %w", perr)
			}
			if werr := w.walk(part); werr != nil {
				return werr
			}
		}
	}

	ct, params, _ := e.Header.ContentType()
	if ct != "text/html" && ct != "text/plain" {
		return nil
	}
	b, rerr := io.ReadAll(e.Body)
	if rerr != nil {
		return nil
	}
	text := decodeUTF8WHATWG(b)
	cs := strings.ToLower(trimExplicit(params["charset"]))
	switch ct {
	case "text/html":
		if w.html == "" {
			w.html, w.htmlCharset = text, cs
		}
	case "text/plain":
		if w.plain == "" {
			w.plain, w.plainCharset = text, cs
		}
	}
	return nil
}

func rawBodyAfterHeaders(raw []byte) []byte {
	crlf := bytes.Index(raw, []byte("\r\n\r\n"))
	lf := bytes.Index(raw, []byte("\n\n"))
	switch {
	case crlf >= 0 && (lf < 0 || crlf < lf):
		return raw[crlf+4:]
	case lf >= 0:
		return raw[lf+2:]
	default:
		return raw
	}
}

func decodeUTF8WHATWG(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	var out strings.Builder
	out.Grow(len(b))

	var codepoint, needed, seen int
	lower, upper := byte(0x80), byte(0xBF)

	for i := 0; i < len(b); i++ {
		c := b[i]
		if needed == 0 {
			switch {
			case c <= 0x7F:
				out.WriteByte(c)
			case c >= 0xC2 && c <= 0xDF:
				needed, codepoint = 1, int(c&0x1F)
			case c >= 0xE0 && c <= 0xEF:
				if c == 0xE0 {
					lower = 0xA0
				}
				if c == 0xED {
					upper = 0x9F
				}
				needed, codepoint = 2, int(c&0x0F)
			case c >= 0xF0 && c <= 0xF4:
				if c == 0xF0 {
					lower = 0x90
				}
				if c == 0xF4 {
					upper = 0x8F
				}
				needed, codepoint = 3, int(c&0x07)
			default:
				out.WriteRune('�')
			}
			continue
		}
		if c < lower || c > upper {
			codepoint, needed, seen = 0, 0, 0
			lower, upper = 0x80, 0xBF
			out.WriteRune('�')
			i--
			continue
		}
		lower, upper = 0x80, 0xBF
		codepoint = codepoint<<6 | int(c&0x3F)
		seen++
		if seen < needed {
			continue
		}
		out.WriteRune(rune(codepoint))
		codepoint, needed, seen = 0, 0, 0
	}
	if needed != 0 {
		out.WriteRune('�')
	}
	return out.String()
}

var (
	scriptRe = regexp.MustCompile(`(?is)<script[^>]*>.*?</script>`)
	styleRe  = regexp.MustCompile(`(?is)<style[^>]*>.*?</style>`)
	tagRe    = regexp.MustCompile(`(?s)<[^>]+>`)
	wsRe     = regexp.MustCompile(`[ \t\x{00a0}]+`)
)

var blockTags = []string{"<br>", "<br/>", "</p>", "</tr>", "</div>"}

func stripHTML(s string) string {
	s = scriptRe.ReplaceAllString(s, " ")
	s = styleRe.ReplaceAllString(s, " ")
	for _, t := range blockTags {
		s = strings.ReplaceAll(s, t, "\n")
	}
	return tagRe.ReplaceAllString(s, "\n")
}

var entities = strings.NewReplacer(
	"&nbsp;", " ",
	"&amp;", "&",
	"&lt;", "<",
	"&gt;", ">",
	"&quot;", `"`,
	"&#39;", "'",
)

const trimCut = "\t\n\v\f\r \u00a0\ufeff"

func trimExplicit(s string) string { return strings.Trim(s, trimCut) }

type trimmer func(string) string

func collapseWith(s string, trim trimmer) string {
	s = entities.Replace(s)
	s = wsRe.ReplaceAllString(s, " ")
	var lines []string
	for _, l := range strings.Split(s, "\n") {
		if t := trim(l); t != "" {
			lines = append(lines, t)
		}
	}
	return strings.Join(lines, "\n")
}

var wordDecoder = mime.WordDecoder{
	CharsetReader: func(label string, input io.Reader) (io.Reader, error) {
		enc, err := htmlindex.Get(label)
		if err != nil || enc == nil {
			return nil, fmt.Errorf("norm: unsupported charset %q", label)
		}
		return enc.NewDecoder().Reader(input), nil
	},
}

func decodeWords(v string) string {
	v = trimExplicit(v)
	if v == "" {
		return ""
	}
	if out, err := wordDecoder.DecodeHeader(v); err == nil {
		return out
	}
	return v
}

func bareAddress(v string) string {
	v = trimExplicit(v)
	if v == "" {
		return ""
	}
	if list, err := mail.ParseAddressList(v); err == nil && len(list) > 0 {
		return list[0].Address
	}
	if a, err := mail.ParseAddress(v); err == nil {
		return a.Address
	}
	if i := strings.LastIndex(v, "<"); i >= 0 {
		if j := strings.Index(v[i:], ">"); j > 0 {
			return trimExplicit(v[i+1 : i+j])
		}
	}
	return v
}

func scanRawHeaders(raw []byte) (subject, from string) {
	head := raw
	if b := rawBodyAfterHeaders(raw); len(b) < len(raw) {
		head = raw[:len(raw)-len(b)]
	}
	s := strings.ReplaceAll(string(head), "\r\n", "\n")

	var fields []string
	for _, line := range strings.Split(s, "\n") {
		if line == "" {
			continue
		}
		if (line[0] == ' ' || line[0] == '\t') && len(fields) > 0 {
			fields[len(fields)-1] += " " + trimExplicit(line)
			continue
		}
		fields = append(fields, line)
	}
	for _, f := range fields {
		i := strings.Index(f, ":")
		if i < 0 {
			continue
		}
		name := strings.ToLower(trimExplicit(f[:i]))
		value := f[i+1:]
		switch name {
		case "subject":
			if subject == "" {
				subject = decodeWords(value)
			}
		case "from":
			if from == "" {
				from = bareAddress(decodeWords(value))
			}
		}
	}
	return subject, from
}
