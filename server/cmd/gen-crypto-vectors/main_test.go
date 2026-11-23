package main

import (
	"testing"

	"github.com/salehtl/hasala/server/internal/cryptoref/vectors"
)

func TestCommittedVectorsAreCurrent(t *testing.T) {
	files, err := vectors.Generate("../../..")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < 20 {
		t.Fatalf("generated %d files", len(files))
	}
	for _, s := range Diff("../../..", files) {
		t.Errorf("stale vector file: %s (run: cd server && go run ./cmd/gen-crypto-vectors)", s)
	}
}
