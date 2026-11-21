package seed

import (
	"testing"

	"github.com/salehtl/hasala/server/internal/tmpl"
)

func TestWhichSeedTemplatesCanWitnessTheirOwnDecode(t *testing.T) {
	want := map[string]bool{
		"dib.card.v1":                      true,
		"dib.account.v1":                   false,
		"dib.transfer.v1":                  true,
		"dib.money-transfer.v1":            false,
		"dib.card-refund.v1":               true,
		"dib.card-reversal.v1":             false,
		"enbd.alert.v1":                    false,
		"enbd.transfer.v1":                 false,
		"adib.alert.v1":                    false,
		"adib.account.v1":                  false,
		"dib.sms.purchase.v1":              false,
		"dib.sms.debit.v1":                 false,
		"dib.sms.credit.v1":                false,
		"dib.sms.salary.v1":                false,
		"dib.sms.refund.v1":                false,
		"dib.sms.reversal.v1":              false,
		"dib.sms.own-transfer.v1":          false,
		"dib.sms.card-payment.v1":          false,
		"enbd.sms.bill-payment.v1":         false,
		"enbd.sms.card-purchase.v1":        false,
		"enbd.sms.cash-withdrawal.v1":      false,
		"enbd.sms.cheque-deposit.v1":       false,
		"enbd.sms.credit.v1":               false,
		"enbd.sms.credit-card-purchase.v1": false,
		"enbd.sms.debit.v1":                false,
		"enbd.sms.funds-transfer.v1":       false,
		"enbd.sms.refund.v1":               false,
		"enbd.sms.transfer-in.v1":          false,
	}
	seen := map[string]bool{}
	for _, d := range Seed() {
		w, ok := want[d.ID]
		if !ok {
			t.Errorf("published template %s is not in this table; decide whether its gate "+
				"literal witnesses its decode and record the answer here", d.ID)
			continue
		}
		seen[d.ID] = true
		got := len(d.DecodeWitnesses()) > 0
		if got != w {
			t.Errorf("%s: DecodeWitnesses() non-empty = %v, want %v (body_contains = %q)",
				d.ID, got, w, d.Match.BodyContains)
		}
	}
	for id := range want {
		if !seen[id] {
			t.Errorf("%s is in this table but is no longer published", id)
		}
	}
}

func TestDIBCardWitnessIsItsOwnGateLiteral(t *testing.T) {
	var card tmpl.Definition
	for _, d := range Seed() {
		if d.ID == "dib.card.v1" {
			card = d
		}
	}
	if card.ID == "" {
		t.Fatal("dib.card.v1 is no longer published")
	}
	ws := card.DecodeWitnesses()
	if len(ws) != 1 || len(card.Match.BodyContains) != 1 || ws[0] != card.Match.BodyContains[0] {
		t.Fatalf("witnesses = %q, body_contains = %q; they must be the same single literal",
			ws, card.Match.BodyContains)
	}
	if ws[0] != "إشعار مشتريات" {
		t.Errorf("dib.card.v1 gates on %q; the auto-trust exception for DIB rests on this "+
			"literal being the Arabic one a mis-decode destroys", ws[0])
	}
}
