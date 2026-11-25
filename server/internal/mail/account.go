package mail

import (
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"
)

const Footer = "—\nWe'll never ask you to share anything from the Hasala app by email, " +
	"by phone or on a website. Questions? Reply to this email."

const DefaultFreezeURL = "https://hasala.app/freeze"

var uae = time.FixedZone("UAE", 4*60*60)

func When(t time.Time) string {
	return t.In(uae).Format("Mon 2 Jan 2006, 15:04") + " UAE time"
}

func Greeting(displayName string) string {
	name := strings.TrimSpace(displayName)
	if name == "" {
		return "Hi,"
	}
	if i := strings.IndexByte(name, ' '); i > 0 {
		name = name[:i]
	}
	return "Hi " + name + ","
}

func body(greetName string, lines ...string) string {
	var b strings.Builder
	b.WriteString(Greeting(greetName))
	b.WriteString("\n\n")
	for _, l := range lines {
		b.WriteString(l)
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(Footer)
	b.WriteString("\n")
	return b.String()
}

const (
	whyCode    = "You're getting this because someone entered this address in Hasala."
	whyAlert   = "You're getting this security alert because of a change to your Hasala account. Security alerts can't be turned off."
	whyDeleted = "You're getting this because the Hasala account for this address was deleted. We won't email you again."
)

func compose(kind, to, subject, name string, p page, lines ...string) Message {
	p.Title, p.Greeting = subject, Greeting(name)
	if p.Lead == nil && p.Paras == nil {
		p.Lead = lines
	}
	html, err := p.render()
	if err != nil {
		reportRenderFault(kind, err)
	}
	return Message{To: to, Subject: subject, Text: body(name, lines...), HTML: html}
}

var renderFaults sync.Map

func reportRenderFault(kind string, err error) {
	if _, seen := renderFaults.LoadOrStore(kind, struct{}{}); seen {
		return
	}
	slog.Error("mail: the HTML part of an account email did not render, so it goes as text only",
		"mail_kind", kind, "err", err.Error())
}

var codePurposeLines = map[string]string{
	"signup":           "Use this code to create your Hasala account.",
	"email_verify":     "Use this code to confirm this is still your Hasala email address.",
	"email_change_old": "Use this code to move your Hasala account to a new email address.",
	"email_change_new": "Use this code to make this your Hasala email address.",
	"password_reset":   "Use this code to reset your Hasala password.",
	"recovery":         "Use this code, with your recovery phrase, to get back into your Hasala account.",
}

func CodeGreetsByName(purpose string) bool {
	switch purpose {
	case "email_verify", "password_reset", "recovery", "email_change_old":
		return true
	}
	return false
}

func CodeKind(purpose string) string {
	switch purpose {
	case "password_reset":
		return "reset_code"
	case "recovery":
		return "recovery_code"
	}
	return "code"
}

func Code(to, purpose, code, name string) (Message, error) {
	line, ok := codePurposeLines[purpose]
	if !ok {
		return Message{}, fmt.Errorf("mail: no code email for purpose %q", purpose)
	}
	if !CodeGreetsByName(purpose) {
		name = ""
	}
	heading := "Your code"
	switch purpose {
	case "password_reset":
		heading = "Reset your password"
	case "recovery":
		heading = "Get back into your account"
	}
	const never = "Only type it into the Hasala app. Hasala will never ask you for it by phone, by email or on a website."
	p := page{Heading: heading, Why: whyCode, Lead: []string{line}, Code: code, Paras: []string{never}}
	return compose("code", to, "Your Hasala code", name, p,
		line, "Your Hasala code is "+code+". It works for 10 minutes. "+never), nil
}

func AddressInUse(to string) Message {
	return compose("address_in_use", to, "Your Hasala email address", "",
		page{Heading: "This address already has an account", Why: whyCode},
		"Someone tried to use this email address for a new Hasala account. It already belongs to a "+
			"Hasala account, so nothing has changed. If this was you, sign in to Hasala instead.")
}

const notYou = "If this wasn't you, open Hasala on one of your iPhones and go to Profile › Sign-in & security."

var AlertSubkinds = []string{
	"new_sign_in_passkey", "new_sign_in_password", "recovery_used_passkey", "recovery_used_password",
	"new_passkey", "password_set", "password_changed", "password_removed", "password_reset",
	"phrase_viewed", "device_removed", "email_changed_new", "email_changed_old",
	"account_frozen", "account_unfrozen",
}

func AlertCarriesFreezeLink(subkind string) bool {
	return strings.HasPrefix(subkind, "new_sign_in_") || strings.HasPrefix(subkind, "recovery_used_") ||
		subkind == "phrase_viewed"
}

func Alert(to, subkind string, at time.Time, name, freezeLink string) (Message, error) {
	when := When(at)
	if AlertCarriesFreezeLink(subkind) && freezeLink == "" {
		return Message{}, fmt.Errorf("mail: alert %s needs a freeze link", subkind)
	}
	alert := func(subject, heading string, lines ...string) (Message, error) {
		return compose("alert_"+subkind, to, subject, name, page{Heading: heading, Why: whyAlert}, lines...), nil
	}
	withFreeze := func(subject, heading string, lines ...string) (Message, error) {
		text := append(lines,
			"If it wasn't, freeze your account now. Everyone will be signed out until you confirm it's you: "+freezeLink,
			"This link works for 7 days and can only freeze your account.")
		p := page{Heading: heading, Why: whyAlert, Lead: lines, Freeze: freezeLink}
		return compose("alert_"+subkind, to, subject, name, p, text...), nil
	}
	switch subkind {
	case "new_sign_in_passkey", "new_sign_in_password":
		method := strings.TrimPrefix(subkind, "new_sign_in_")
		return withFreeze("New sign-in to Hasala", "New sign-in to your account",
			"Your Hasala account was signed in on an iPhone with your "+method+" on "+when+".",
			"If this was you, there's nothing to do.")
	case "recovery_used_passkey", "recovery_used_password":
		method := strings.TrimPrefix(subkind, "recovery_used_")
		return withFreeze("Your Hasala recovery phrase was used", "Your recovery phrase was used",
			"Your recovery phrase was used to get back into your Hasala account on "+when+
				", and a new "+method+" was added.",
			"Your old passkeys and your old password were removed, and every other device was signed out.")
	case "new_passkey":
		return alert("New passkey for Hasala", "New passkey added",
			"A new passkey was added to your Hasala account on "+when+".", notYou)
	case "password_set", "password_changed", "password_removed", "password_reset":
		verb := strings.TrimPrefix(subkind, "password_")
		return alert("Your Hasala password changed", "Your password was changed",
			"Your Hasala password was "+verb+" on "+when+". Other devices were signed out.", notYou)
	case "phrase_viewed":
		return withFreeze("Your Hasala recovery phrase was shown", "Your recovery phrase was viewed",
			"Your recovery phrase was shown in the Hasala app on "+when+".",
			"If this was you, there's nothing to do.")
	case "device_removed":
		return alert("A device was removed from Hasala", "Device removed",
			"An iPhone was removed from your Hasala account on "+when+".", notYou)
	case "email_changed_new":
		return alert("This is now your Hasala email address", "This is now your Hasala email",
			"This address became the email address of a Hasala account on "+when+".")
	case "email_changed_old":
		return alert("Your Hasala email address changed", "Your email address changed",
			"Your Hasala account stopped using this email address on "+when+
				". You won't get Hasala email here any more.", notYou)
	case "account_frozen":
		return alert("Your Hasala account is frozen", "Your account is frozen",
			"Your Hasala account was frozen on "+when+". Everyone was signed out. To unfreeze it, sign in on "+
				"one of your iPhones with a passkey, or with your password, that you had before the freeze.")
	case "account_unfrozen":
		return alert("Your Hasala account is unfrozen", "Your account is unfrozen",
			"Your Hasala account was unfrozen on "+when+".", notYou)
	}
	return Message{}, fmt.Errorf("mail: no alert %q", subkind)
}

func Deleted(to string, at time.Time) Message {
	const (
		passkey = "Your Hasala passkey may still show in the Passwords app on your iPhone. You can delete it there."
		notMe   = "Didn't do this? Tell us at hasala.app/support. We can't bring deleted data back, but we'll find out what happened."
	)
	p := page{Heading: "Your account is deleted.", Why: whyDeleted,
		Lead: []string{"Your Hasala account and its data were deleted from our server on " + When(at) + "."},
		Rows: []Row{{"Budget, plan, rules", "Erased"},
			{"Sealed backup", "Gone from backups by " + at.Add(30*24*time.Hour).In(uae).Format("2 Jan")}},
		Paras: []string{passkey}, Small: notMe}
	return compose("deleted", to, "Your Hasala account was deleted", "", p,
		"Your Hasala account and its data were deleted from our server on "+When(at)+
			". Encrypted backups expire within 30 days.", passkey, notMe)
}
