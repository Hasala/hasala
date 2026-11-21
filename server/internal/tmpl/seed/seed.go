package seed

import (
	"embed"
	"fmt"
	"io/fs"
	"path"
	"sort"

	"github.com/salehtl/hasala/server/internal/tmpl"
)

//go:embed *.json
var files embed.FS

var IDs = []string{
	"dib.card.v1",
	"dib.account.v1",
	"dib.transfer.v1",
	"dib.money-transfer.v1",
	"dib.card-refund.v1",
	"dib.card-reversal.v1",
	"enbd.transfer.v1",
	"enbd.alert.v1",
	"adib.alert.v1",
	"adib.account.v1",
	"dib.sms.purchase.v1",
	"dib.sms.debit.v1",
	"dib.sms.credit.v1",
	"dib.sms.salary.v1",
	"dib.sms.refund.v1",
	"dib.sms.reversal.v1",
	"dib.sms.own-transfer.v1",
	"dib.sms.card-payment.v1",
	"enbd.sms.bill-payment.v1",
	"enbd.sms.card-purchase.v1",
	"enbd.sms.cash-withdrawal.v1",
	"enbd.sms.cheque-deposit.v1",
	"enbd.sms.credit.v1",
	"enbd.sms.credit-card-purchase.v1",
	"enbd.sms.debit.v1",
	"enbd.sms.funds-transfer.v1",
	"enbd.sms.refund.v1",
	"enbd.sms.transfer-in.v1",
}

func Seed() []tmpl.Definition {
	defs, err := load()
	if err != nil {
		panic("seed: " + err.Error())
	}
	return defs
}

func Raw() map[string][]byte {
	out := make(map[string][]byte, len(IDs))
	for _, id := range IDs {
		b, err := files.ReadFile(id + ".json")
		if err != nil {
			panic("seed: " + err.Error())
		}
		out[id] = b
	}
	return out
}

func load() ([]tmpl.Definition, error) {
	names, err := fileNames()
	if err != nil {
		return nil, err
	}
	want := append([]string(nil), IDs...)
	sort.Strings(want)
	if len(names) != len(want) {
		return nil, fmt.Errorf("the directory holds %v but IDs names %v", names, IDs)
	}
	for i := range names {
		if names[i] != want[i]+".json" {
			return nil, fmt.Errorf("the directory holds %v but IDs names %v", names, IDs)
		}
	}

	defs := make([]tmpl.Definition, 0, len(IDs))
	for _, id := range IDs {
		b, err := files.ReadFile(id + ".json")
		if err != nil {
			return nil, err
		}
		d, err := tmpl.ParseDefinition(b)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", id, err)
		}
		if d.ID != id {
			return nil, fmt.Errorf("%s.json declares id %q", id, d.ID)
		}
		if err := tmpl.ValidateForPublish(d); err != nil {
			return nil, fmt.Errorf("%s: %w", id, err)
		}
		defs = append(defs, d)
	}
	return defs, nil
}

func fileNames() ([]string, error) {
	var out []string
	err := fs.WalkDir(files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			out = append(out, path.Base(p))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}
