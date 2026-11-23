package norm

import "time"

type Trimmer = trimmer

func NormalizeWithTrim(version int, raw []byte, receivedAt time.Time, trim Trimmer) (Result, error) {
	return normalizeWith(version, raw, receivedAt, trim)
}

func TrimExplicit(s string) string { return trimExplicit(s) }

func HeadersOf(raw []byte) (subject, from string, ok bool) {
	_, _, _, subject, from, err := extract(raw)
	return subject, from, err == nil
}
