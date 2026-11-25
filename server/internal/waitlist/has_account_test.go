package waitlist

import (
	"context"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/mailq"
)

func TestTheHasAccountEmailGreetsTheAccountByName(t *testing.T) {
	for _, c := range []struct {
		name, addr, want string
		account          bool
	}{
		{name: "an address with an account", addr: "maya@example.test", want: "Hi Maya,", account: true},
		{name: "an address with no account", addr: "nobody@example.test", want: "Hi,"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newRetryRig(t)
			if c.account {
				if _, err := r.pool.Exec(context.Background(), `INSERT INTO users (user_handle, created_at, email_norm,
					email_verified_at, display_name) VALUES (decode(md5('a') || md5('b'), 'hex'), now(), $1, now(), 'Maya Test')`,
					c.addr); err != nil {
					t.Fatal(err)
				}
			}
			id := r.enqueue(t, mailq.Enqueue{Kind: "waitlist_has_account", Lane: mailq.LaneWaitlist, To: c.addr})
			if did, err := r.q.ProcessOne(context.Background()); err != nil || !did {
				t.Fatalf("process: %v %v", did, err)
			}
			if status, _ := r.status(t, id); status != "sent" {
				t.Fatalf("the row is %s, want sent", status)
			}
			sent := r.fake.Sent()
			if len(sent) != 1 {
				t.Fatalf("%d emails sent, want 1", len(sent))
			}
			if !strings.HasPrefix(sent[0].Text, c.want+"\n") {
				t.Fatalf("the text starts %q, want %q", strings.SplitN(sent[0].Text, "\n", 2)[0], c.want)
			}
		})
	}
}
