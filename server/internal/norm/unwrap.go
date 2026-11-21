package norm

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

var forwardMarkerRe = regexp.MustCompile(`(?i)^ *(begin forwarded message:|-+ *forwarded message *-+) *$`)

var fwdSubjectRe = regexp.MustCompile(`(?i)^ *(fwd?|fw) *: *`)

var fwdHeaderLineRe = regexp.MustCompile(`(?i)^ *(from|to|subject|date|reply-to|cc|sent) *: *(.*)$`)

type forward struct {
	From    string
	Subject string
	Date    string
	Body    string
	Found   bool
}

func unwrapForward(from, subject, body string) forward {
	return unwrapForwardWith(from, subject, body, trimExplicit)
}

func unwrapForwardWith(from, subject, body string, trim trimmer) forward {
	lines := strings.Split(body, "\n")

	marker := -1
	for i, l := range lines {
		if forwardMarkerRe.MatchString(l) {
			marker = i
			break
		}
	}
	if marker == -1 {
		return forward{
			From:    from,
			Subject: fwdSubjectRe.ReplaceAllString(subject, ""),
			Body:    body,
		}
	}

	recFrom, recSubject, recDate := "", "", ""
	end := marker + 1
	sawHeader := false
	for i := marker + 1; i < len(lines); {
		m := fwdHeaderLineRe.FindStringSubmatch(lines[i])
		if m == nil {
			if sawHeader {
				break
			}
			i++
			continue
		}
		sawHeader = true
		label := strings.ToLower(m[1])
		value := trim(m[2])
		if value == "" {
			j := i + 1
			for j < len(lines) && trim(lines[j]) == "" {
				j++
			}
			if j < len(lines) {
				value = trim(lines[j])
				i = j
			}
		}
		switch label {
		case "from":
			recFrom = value
		case "subject":
			recSubject = value
		case "date":
			recDate = value
		}
		i++
		end = i
	}

	out := forward{From: from, Subject: subject, Date: recDate, Body: body, Found: true}
	if recFrom != "" {
		out.From = recFrom
	}
	if recSubject != "" {
		out.Subject = recSubject
	} else {
		out.Subject = fwdSubjectRe.ReplaceAllString(subject, "")
	}
	if sawHeader && end < len(lines) {
		out.Body = trim(strings.Join(lines[end:], "\n"))
	}
	return out
}

var fwdDateLayouts = []string{
	"Jan 2, 2006 at 3:04 PM",
	"Mon, Jan 2, 2006 at 3:04 PM",
	"2 January 2006 at 15:04:05",
	"2 January 2006 at 15:04",
}

var nbspReplacer = strings.NewReplacer("\u202f", " ", "\u00a0", " ")

func parseForwardDate(s string) (time.Time, error) {
	return parseForwardDateWith(s, trimExplicit)
}

func parseForwardDateWith(s string, trim trimmer) (time.Time, error) {
	s = nbspReplacer.Replace(trim(s))
	candidates := []string{s}
	if i := strings.LastIndex(s, " "); i > 0 {
		candidates = append(candidates, trim(s[:i]))
	}
	for _, c := range candidates {
		for _, layout := range fwdDateLayouts {
			if t, err := time.Parse(layout, c); err == nil {
				return t, nil
			}
		}
	}
	return time.Time{}, fmt.Errorf("norm: unrecognized forward date %q", s)
}
