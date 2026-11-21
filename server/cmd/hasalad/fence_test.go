package main

import (
	"bufio"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/api"
)

const module = "github.com/salehtl/hasala/server"

type listedPackage struct {
	ImportPath string
	Dir        string
	GoFiles    []string
	Imports    []string
	Standard   bool
}

func deps(t *testing.T) []listedPackage {
	t.Helper()
	return depsOf(t, module+"/cmd/hasalad")
}

func depsOf(t *testing.T, target string) []listedPackage {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Fatalf("the fences need the go tool on PATH (run inside the devShell): %v", err)
	}
	cmd := exec.Command("go", "list", "-deps", "-json", target)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list -deps: %v", err)
	}
	var pkgs []listedPackage
	dec := json.NewDecoder(strings.NewReader(string(out)))
	for dec.More() {
		var p listedPackage
		if err := dec.Decode(&p); err != nil {
			t.Fatal(err)
		}
		pkgs = append(pkgs, p)
	}
	if len(pkgs) < 20 {
		t.Fatalf("go list returned %d packages; the fences would be vacuous", len(pkgs))
	}
	return pkgs
}

func own(pkgs []listedPackage) []listedPackage {
	var out []listedPackage
	for _, p := range pkgs {
		if p.ImportPath == module || strings.HasPrefix(p.ImportPath, module+"/") {
			out = append(out, p)
		}
	}
	return out
}

func rel(importPath string) string { return strings.TrimPrefix(importPath, module+"/") }

func TestFenceTheBuildGraph(t *testing.T) {
	pkgs := deps(t)
	forbidden := []string{
		module + "/internal/authtest", module + "/internal/pgtest",
		module + "/internal/blob/blobtest", module + "/internal/oplog/opref",
		module + "/internal/oplog/oplogtest",
		module + "/internal/norm", module + "/internal/tmpl", module + "/internal/dict",
		module + "/oracle",
		module + "/internal/cryptoref",
		module + "/internal/testflight",
		"github.com/emersion/",
	}
	for _, p := range pkgs {
		for _, f := range forbidden {
			if p.ImportPath == f || strings.HasPrefix(p.ImportPath, strings.TrimSuffix(f, "/")+"/") {
				t.Errorf("hasalad links %s (spec 02 §4.4)", p.ImportPath)
			}
		}
	}
	for _, p := range depsOf(t, module+"/internal/api") {
		for _, f := range []string{module + "/internal/console", module + "/internal/testflight"} {
			if p.ImportPath == f || strings.HasPrefix(p.ImportPath, f+"/") {
				t.Errorf("internal/api links %s (spec 07 F7-1)", p.ImportPath)
			}
		}
	}
	tolerated := map[string]string{
		"golang.org/x/text/":   "github.com/jackc/pgx/v5/pgconn",
		"golang.org/x/crypto/": "github.com/go-webauthn/x/revoke",
	}
	for _, p := range pkgs {
		for _, imp := range p.Imports {
			for prefix, only := range tolerated {
				if !strings.HasPrefix(imp, prefix) || strings.HasPrefix(p.ImportPath, prefix) {
					continue
				}
				if p.ImportPath != only {
					t.Errorf("%s imports %s; only %s may, and only until spec 02 §4.4's fence can be met",
						p.ImportPath, imp, only)
				}
			}
		}
	}
}

func TestFenceGoMod(t *testing.T) {
	f, err := os.Open("../../go.mod")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.Contains(line, module+"/oracle") {
			t.Errorf("server/go.mod requires the oracle module: %q", line)
		}
		if strings.HasPrefix(line, "golang.org/x/crypto ") && !strings.HasSuffix(line, "// indirect") {
			t.Errorf("server/go.mod requires golang.org/x/crypto directly: %q", line)
		}
		for _, gone := range []string{"emersion/go-smtp", "emersion/go-msgauth", "webpush-go", "xuri/excelize"} {
			if strings.Contains(line, gone) {
				t.Errorf("server/go.mod still requires a retired module: %q", line)
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
}

type sourceFile struct {
	pkg, path string
	file      *ast.File
	imports   map[string]string
}

func reachableSources(t *testing.T) []sourceFile {
	t.Helper()
	var out []sourceFile
	fset := token.NewFileSet()
	for _, p := range own(deps(t)) {
		for _, name := range p.GoFiles {
			path := filepath.Join(p.Dir, name)
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				t.Fatal(err)
			}
			imps := map[string]string{}
			for _, is := range f.Imports {
				ip, _ := strconv.Unquote(is.Path.Value)
				local := ip[strings.LastIndex(ip, "/")+1:]
				if is.Name != nil {
					local = is.Name.Name
				}
				imps[local] = ip
			}
			out = append(out, sourceFile{pkg: rel(p.ImportPath), path: path, file: f, imports: imps})
		}
	}
	return out
}

func TestFenceTheSource(t *testing.T) {
	files := reachableSources(t)
	banned := []string{
		"gmail.googleapis.com", "oauth2.googleapis.com/token", "authentication-results",
		"/.well-known/", "smtp", "vapid", "x-forwarded-for", "true-client-ip",
		"graph.microsoft.com", "/oauth2/v2.0/token", "/oauth2/v2.0/authorize",
	}
	onlyIn := map[string]string{
		"api.cloudflare.com":            "internal/mail",
		"api.appstoreconnect.apple.com": "internal/testflight",
		"challenges.cloudflare.com":     "internal/turnstile",
		"login.microsoftonline.com":     "internal/msjwt",
	}
	bypass := regexp.MustCompile(`(?i)(dev|demo|review)[-_]?(auth|login|bypass)`)
	reviewAllowed := func(pkg, path string) bool {
		base := filepath.Base(path)
		return pkg == "internal/accounts" || pkg == "internal/console" || pkg == "internal/invites" ||
			(pkg == "internal/auth" && base == "signup.go") || (pkg == "internal/api" && base == "account.go")
	}
	scanned := 0
	for _, sf := range files {
		scanned++
		for _, is := range sf.file.Imports {
			if ip, _ := strconv.Unquote(is.Path.Value); ip == "crypto/pbkdf2" && sf.pkg != "internal/authkeys" {
				t.Errorf("%s imports crypto/pbkdf2 outside internal/authkeys", sf.path)
			}
		}
		ast.Inspect(sf.file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				s, err := strconv.Unquote(x.Value)
				if err != nil {
					s = x.Value
				}
				lower := strings.ToLower(s)
				for _, b := range banned {
					if strings.Contains(lower, b) {
						t.Errorf("%s: string literal contains %q (spec 02 §4.4 fence 3)", sf.path, b)
					}
				}
				for lit, pkg := range onlyIn {
					if strings.Contains(lower, lit) && sf.pkg != pkg {
						t.Errorf("%s: %q outside %s", sf.path, lit, pkg)
					}
				}
				if bypass.MatchString(s) {
					t.Errorf("%s: string literal %q looks like a review or dev bypass (fence 6)", sf.path, s)
				}
				if (strings.Contains(lower, "review_account") || strings.Contains(lower, "invite_codes.review")) &&
					!reviewAllowed(sf.pkg, sf.path) {
					t.Errorf("%s: reads the review flag (fence 6)", sf.path)
				}
			case *ast.Ident:
				if x.Name == "PlaintextSealer" {
					t.Errorf("%s: identifier PlaintextSealer (fence 3)", sf.path)
				}
				if bypass.MatchString(x.Name) {
					t.Errorf("%s: identifier %s looks like a review or dev bypass (fence 6)", sf.path, x.Name)
				}
				if x.Name == "ReviewAccount" && !reviewAllowed(sf.pkg, sf.path) {
					t.Errorf("%s: identifier ReviewAccount (fence 6)", sf.path)
				}
			case *ast.CallExpr:
				sel, ok := x.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				id, ok := sel.X.(*ast.Ident)
				if !ok {
					return true
				}
				switch call := sf.imports[id.Name] + "." + sel.Sel.Name; call {
				case "crypto/aes.NewCipher", "crypto/cipher.NewGCM":
					t.Errorf("%s: calls %s; the server never encrypts or decrypts user data (fence 3)", sf.path, call)
				case "crypto/ecdsa.Sign", "crypto/ecdsa.SignASN1":
					t.Errorf("%s: calls %s (fence 3)", sf.path, call)
				}
			}
			return true
		})
	}
	if scanned < 20 {
		t.Fatalf("scanned %d files; the fence would be vacuous", scanned)
	}
}

func TestFenceCorpusDatabase(t *testing.T) {
	name := "HASALA_" + "CORPUS_DB"
	root := "../.."
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && path == filepath.Join(root, "oracle") {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(b), name) {
			t.Errorf("%s names %s outside server/oracle (fence 4)", path, name)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestFenceServeHasNoConsole(t *testing.T) {
	h := (&api.Server{}).Handler()
	for _, path := range []string{"/console", "/console/", "/console/login", "/admin", "/admin/", "/ui/", "/"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusNotFound {
			t.Errorf("serve answered %d for %s, want 404", w.Code, path)
		}
	}
}

func TestFenceNoDataKeyDerivationAndNoRetiredDomain(t *testing.T) {
	dataKey := map[string]bool{
		"DomainRecoveryKey": true, "DomainWrapRecovery": true, "DomainWrapPRF": true, "DomainWrap": true,
		"DomainPRFSaltUnlock": true, "DomainAMKCommitment": true, "DomainEpochKey": true, "DomainBlobKey": true,
		"DomainBlob": true, "DomainKeyringKey": true, "DomainKeyring": true, "DomainPassword": true,
		"DomainPhraseBoxKey": true, "DomainPhraseBox": true,
	}
	dataKeyLiterals := []string{
		"hasala/v1/recovery-key", "hasala/v1/wrap", "hasala/v1/prf-salt/unlock", "hasala/v1/amk-commitment",
		"hasala/v1/epoch-key", "hasala/v1/blob", "hasala/v1/keyring", "hasala/v1/password", "hasala/v1/phrase-box",
	}
	retired := []string{
		"ledger-v2-writer-registration", "ledger-v2-writer-revocation", "ledger/v2 account-delete",
		"ledger-v2-account-keys", "ledger-v2-prf-wrap-v1", "ledger-v2-prf-unlock-v1", "ledger-v2-ingest-key",
		"ledger-v2-device-comparison", "ledger-phase2-encv2", "ledger/dict/key-epoch/v1", "hasala-stepup-v1",
	}
	tolerated := map[string]string{"ledger/v2 account-delete": "internal/purge"}
	for _, sf := range reachableSources(t) {
		isRegistry := sf.pkg == "internal/keyproto" && filepath.Base(sf.path) == "domains.go"
		ast.Inspect(sf.file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.SelectorExpr:
				if id, ok := x.X.(*ast.Ident); ok && sf.imports[id.Name] == module+"/internal/keyproto" && dataKey[x.Sel.Name] {
					t.Errorf("%s references keyproto.%s: hasalad derives no data or wrap key (spec 01 §12.2)", sf.path, x.Sel.Name)
				}
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				s, err := strconv.Unquote(x.Value)
				if err != nil {
					s = x.Value
				}
				for _, r := range retired {
					if strings.Contains(s, r) && tolerated[r] != sf.pkg {
						t.Errorf("%s: retired domain string %q (spec 01 §3, AT-X4)", sf.path, r)
					}
				}
				if !isRegistry {
					for _, d := range dataKeyLiterals {
						if strings.HasPrefix(s, d) {
							t.Errorf("%s: data-key domain literal %q outside keyproto's registry", sf.path, s)
						}
					}
				}
			}
			return true
		})
	}
}

func TestFenceMailIsSentOnlyByTheQueue(t *testing.T) {
	scanned := 0
	for _, sf := range reachableSources(t) {
		if sf.pkg == "internal/mail" || sf.pkg == "internal/mailq" {
			continue
		}
		usesMail := false
		for _, ip := range sf.imports {
			if ip == module+"/internal/mail" {
				usesMail = true
			}
		}
		if !usesMail {
			continue
		}
		scanned++
		ast.Inspect(sf.file, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Send" {
					t.Errorf("%s calls .Send outside internal/mailq (spec 07 F7-5)", sf.path)
				}
			}
			return true
		})
	}
	if scanned == 0 {
		t.Fatal("no file outside mailq imports internal/mail; the fence is vacuous")
	}
}
