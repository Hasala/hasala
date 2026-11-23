package privatefixtures

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const EnvVar = "HASALA_PRIVATE_FIXTURES"

const Marker = "[real-corpus]"

const Repo = "salehtl/hasala-fixtures"

func Root() string {
	return strings.TrimSpace(os.Getenv(EnvVar))
}

func Path(t testing.TB, rel string) string {
	t.Helper()
	root := Root()
	if root == "" {
		t.Skipf("%s %s is unset: %s is real bank mail, kept in the private %s repository; "+
			"set %s to a checkout of it to run this test", Marker, EnvVar, rel, Repo, EnvVar)
	}
	if !filepath.IsAbs(root) {
		t.Fatalf("%s %s=%q must be an absolute path", Marker, EnvVar, root)
	}
	p := filepath.Join(root, filepath.FromSlash(rel))
	if _, err := os.Stat(p); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("%s %s=%s, but %s is not in that checkout: it is not a complete %s checkout, "+
				"or the fixture was renamed on one side only", Marker, EnvVar, root, rel, Repo)
		}
		t.Fatalf("%s stat %s: %v", Marker, p, err)
	}
	t.Logf("%s ran against %s from %s", Marker, rel, EnvVar)
	return p
}

func ReadFile(t testing.TB, rel string) []byte {
	t.Helper()
	b, err := os.ReadFile(Path(t, rel))
	if err != nil {
		t.Fatalf("%s read %s: %v", Marker, rel, err)
	}
	return b
}
