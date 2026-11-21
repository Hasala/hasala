package norm

import (
	"strings"
	"testing"
	"time"
)

const appleBody = `Sent from my iPhone
Begin forwarded message:
From:
DIB Notification <DIB.notification@dib.ae>
Subject:
DIB Notification
Date:
Feb 9, 2026 at 9:26 AM
To:
owner@example.com
Reply-To:
DIB Notification <DIB.notification@dib.ae>
AED 250.00
EXAMPLE MERCHANT LLC`

const gmailBody = `---------- Forwarded message ---------
From: Emirates NBD <alert@emiratesnbd.com>
Date: Mar 3, 2026 at 2:07 PM
Subject: Emirates NBD Transaction advice for account ending with 9999
To: <someone@gmail.com>

AED 12,750.00 has been withdrawn from your account 012XXX34XXX56.`

func TestUnwrapAppleMailNextLineLayout(t *testing.T) {
	got := unwrapForward("owner@example.com", "Fwd: DIB Notification", appleBody)
	if !got.Found {
		t.Fatal("marker not found")
	}
	if got.From != "DIB Notification <DIB.notification@dib.ae>" {
		t.Fatalf("From = %q", got.From)
	}
	if got.Subject != "DIB Notification" {
		t.Fatalf("Subject = %q", got.Subject)
	}
	if got.Date != "Feb 9, 2026 at 9:26 AM" {
		t.Fatalf("Date = %q", got.Date)
	}
	if got.Body != "AED 250.00\nEXAMPLE MERCHANT LLC" {
		t.Fatalf("Body = %q; the preamble and header block must be gone", got.Body)
	}
}

func TestUnwrapGmailSameLineLayout(t *testing.T) {
	got := unwrapForward("someone@gmail.com", "Fwd: Emirates NBD Transaction advice", gmailBody)
	if !got.Found {
		t.Fatal("marker not found")
	}
	if got.From != "Emirates NBD <alert@emiratesnbd.com>" {
		t.Fatalf("From = %q", got.From)
	}
	if !strings.Contains(got.Subject, "account ending with 9999") {
		t.Fatalf("Subject = %q; enbd_alert reads last4 from here", got.Subject)
	}
	if got.Body != "AED 12,750.00 has been withdrawn from your account 012XXX34XXX56." {
		t.Fatalf("Body = %q", got.Body)
	}
}

func TestUnwrapQuotedForwardFindsMarkerButRecoversNoHeaders(t *testing.T) {
	body := `Begin forwarded message:
> From: DIB Notification <DIB.notification@dib.ae>
> Subject: DIB Notification
> Date: 16 January 2026 at 1:23:45 AM GST
>
> AED 7,800.00`
	got := unwrapForward("owner@example.com", "Fwd: DIB Notification", body)
	if !got.Found {
		t.Fatal("the marker line itself is unquoted, so it must still be found")
	}
	if got.From != "owner@example.com" {
		t.Fatalf("From = %q; a quoted header block recovers nothing, so the outer From stands", got.From)
	}
	if got.Subject != "DIB Notification" {
		t.Fatalf("Subject = %q; only the Fwd: prefix is stripped", got.Subject)
	}
	if got.Date != "" {
		t.Fatalf("Date = %q; nothing is recoverable from a quoted block", got.Date)
	}
	if got.Body != body {
		t.Fatal("with no header recovered the body must be returned unchanged")
	}
}

func TestNonForwardStripsOnlyTheFwdPrefix(t *testing.T) {
	for _, subject := range []string{"Fwd: x", "FW: x", "Fw: x", "fwd:  x", "FWD :x"} {
		got := unwrapForward("a@b.c", subject, "body line\nsecond line")
		if got.Found {
			t.Fatalf("%q: no marker in the body, yet Found is true", subject)
		}
		if got.Subject != "x" {
			t.Fatalf("%q -> Subject %q, want %q", subject, got.Subject, "x")
		}
		if got.Body != "body line\nsecond line" {
			t.Fatalf("%q: body must be untouched, got %q", subject, got.Body)
		}
		if got.From != "a@b.c" {
			t.Fatalf("%q: From must be untouched, got %q", subject, got.From)
		}
	}
	got := unwrapForward("a@b.c", "Forwarding you this", "body")
	if got.Subject != "Forwarding you this" {
		t.Fatalf("a subject that merely starts with 'Forward' must not be stripped: %q", got.Subject)
	}
}

func TestUnwrapMarkerVariants(t *testing.T) {
	for _, marker := range []string{
		"Begin forwarded message:",
		"begin forwarded message:",
		"  Begin forwarded message:  ",
		"---------- Forwarded message ---------",
		"-------- forwarded message --------",
		"- Forwarded message -",
	} {
		got := unwrapForward("a@b.c", "s", marker+"\nFrom: x@y.z\n\nbody")
		if !got.Found {
			t.Fatalf("marker %q not recognised", marker)
		}
	}
	for _, notMarker := range []string{
		"Begin forwarded message",
		"x Begin forwarded message:",
		"Begin forwarded message: see below",
		"Forwarded message",
	} {
		got := unwrapForward("a@b.c", "s", notMarker+"\nFrom: x@y.z\n\nbody")
		if got.Found {
			t.Fatalf("%q must NOT be treated as a forward marker", notMarker)
		}
	}
}

func TestUnwrapNeverAffectsTrust(t *testing.T) {
	hostile := "Begin forwarded message:\nFrom: alerts@dib.ae\nSubject: You have been paid\n\nAED 1.00"
	got := unwrapForward("attacker@evil.example", "hello", hostile)
	if got.From != "alerts@dib.ae" {
		t.Fatalf("From = %q; the content-derived value is expected here", got.From)
	}
	res := Result{}
	res.From = got.From
	if res.From == "" {
		t.Fatal("unreachable")
	}
	for _, forbidden := range []string{"SenderDomain", "Verified", "Trusted", "SigningDomain"} {
		if resultHasField(forbidden) {
			t.Fatalf("Result exposes %q; Result.From is attacker-authored content and "+
				"no trust decision may read anything from this struct", forbidden)
		}
	}
}

func TestParseForwardDateLayouts(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want time.Time
	}{
		{"Feb 8, 2026 at 12:52 PM", time.Date(2026, 2, 8, 12, 52, 0, 0, time.UTC)},
		{"Mar 3, 2026 at 2:07 PM", time.Date(2026, 3, 3, 14, 7, 0, 0, time.UTC)},
		{"Sun, Feb 8, 2026 at 12:52 PM", time.Date(2026, 2, 8, 12, 52, 0, 0, time.UTC)},
		{"8 February 2026 at 20:31:47", time.Date(2026, 2, 8, 20, 31, 47, 0, time.UTC)},
		{"8 February 2026 at 20:31", time.Date(2026, 2, 8, 20, 31, 0, 0, time.UTC)},
		{"8 February 2026 at 20:31:47 GMT+4", time.Date(2026, 2, 8, 20, 31, 47, 0, time.UTC)},
		{"Feb 8, 2026 at 12:52 PM GST", time.Date(2026, 2, 8, 12, 52, 0, 0, time.UTC)},
	} {
		got, err := parseForwardDate(tc.in)
		if err != nil {
			t.Fatalf("parseForwardDate(%q) = %v", tc.in, err)
		}
		if !got.Equal(tc.want) {
			t.Fatalf("parseForwardDate(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func TestUnwrapHandlesNarrowNoBreakSpaceBeforeAMPM(t *testing.T) {
	for _, in := range []string{
		"Feb 8, 2026 at 12:52\u202fPM",
		"Feb 8, 2026 at 12:52\u00a0PM",
		"Feb 8, 2026 at 12:52\u202fPM GST",
	} {
		got, err := parseForwardDate(in)
		if err != nil {
			t.Fatalf("parseForwardDate(%q) = %v", in, err)
		}
		if !got.Equal(time.Date(2026, 2, 8, 12, 52, 0, 0, time.UTC)) {
			t.Fatalf("parseForwardDate(%q) = %v", in, got)
		}
	}
}

func TestParseForwardDateRejectsTheiPhoneSecondsWithAMPMShape(t *testing.T) {
	for _, in := range []string{
		"14 February 2026 at 6:12:38\u202fPM GST",
		"8 February 2026 at 11:18:51\u202fPM GST",
	} {
		if _, err := parseForwardDate(in); err == nil {
			t.Fatalf("parseForwardDate(%q) now succeeds; v1 fails here and the "+
				"corpus-equivalence gate expects the same result", in)
		}
	}
}

func TestParseForwardDateRejectsGarbage(t *testing.T) {
	for _, in := range []string{"", "   ", "not a date", "2026-02-08T12:52:00Z", "Mon, 8 Feb 2026 12:52:00 +0400"} {
		if _, err := parseForwardDate(in); err == nil {
			t.Fatalf("parseForwardDate(%q) unexpectedly succeeded", in)
		}
	}
}

func TestUnwrapTrimsTheRemainderWithTheExplicitSet(t *testing.T) {
	body := "Begin forwarded message:\nFrom: a@b.c\nSubject: s\n\ufeff\nAED 1.00"
	got := unwrapForward("x@y.z", "Fwd: s", body)
	if got.Body != "AED 1.00" {
		t.Fatalf("Body = %q; the U+FEFF line must be trimmed away", got.Body)
	}
}
