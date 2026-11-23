#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

repo="$work/repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
lint() { bun "$ROOT/scripts/comment-lint.ts" --root "$repo" "$@"; }

expect() {
	local name="$1" want="$2" say="$3" rc=0
	shift 3
	lint "$@" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" != "$want" ]]; then
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	elif [[ -n "$say" ]] && ! grep -qF -- "$say" "$work/out"; then
		echo "FAIL $name: the output does not say '$say'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	else
		echo "ok   $name (exit $rc)"
	fi
}

same() {
	local name="$1" file="$2" want="$3"
	if [[ "$(cat "$repo/$file")" == "$want" ]]; then echo "ok   $name"; else
		echo "FAIL $name: $file is"
		sed 's/^/     /' "$repo/$file"
		failures=$((failures + 1))
	fi
}

git init -q "$repo"
mkdir -p "$repo/a" "$repo/scripts" "$repo/server/oracle/v1ref"

cat >"$repo/a/clean.go" <<'EOF'
//go:build linux

package a

import _ "embed"

//go:embed clean.go
var src string

const url = "https://example.invalid/a//b"
const raw = `// not a comment
/* nor this */`
const r = '/'
EOF

cat >"$repo/a/clean.swift" <<'EOF'
// swift-tools-version: 6.0
let url = "https://example.invalid/a//b"
let raw = #"a "quoted" // part"#
let block = """
  // text
  /* text */
  """
let n = "\(join("a//b", "/* c */"))".count
let re = /[0-9]+\/\/[a-z]/
let half = total / 2
// lint-allow: Date the clock seam
// swiftlint:disable all
EOF

cat >"$repo/a/clean.ts" <<'EOF'
// @ts-check
const url = "https://example.invalid/a//b";
const t = `a // b ${1 + 2} /* c */`;
const re = /\/\/[^/]*/g;
const half = total / 2 / 3;
EOF

cat >"$repo/a/clean.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034
n="${#items[@]}"
tail="${path#*/}"
echo "a # b" 'c # d' e#f
cat <<TEXT
# text
TEXT
cat <<-'TEXT'
	# text
	TEXT
EOF

cat >"$repo/a/clean.nix" <<'EOF'
{
  url = "https://example.invalid/#a";
  script = ''
    # text
    echo ${toString 1} ''${keep}
  '';
}
EOF

cat >"$repo/a/clean.yml" <<'EOF'
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  - name: "a # b"
    run: |
      # text
      echo a#b
EOF

cat >"$repo/a/clean.sql" <<'EOF'
-- +goose Up
SELECT '-- text', $body$ -- text $body$;
EOF

cat >"$repo/a/clean.astro" <<'EOF'
---
const url = "https://example.invalid/a//b";
---
<a href="https://example.invalid/a//b">a</a>
<style>
  a { background: url("//example.invalid/a.png"); }
</style>
EOF

cat >"$repo/a/clean.toml" <<'EOF'
a = "b # c"
d = """
# text
"""
EOF

cat >"$repo/server/oracle/v1ref/frozen.go" <<'EOF'
// Package v1ref is frozen.
package v1ref
EOF

g add -A
g commit -q -m clean
expect "code with comment marks in strings has no comment" 0 "no new comments" check

cat >"$repo/a/dirty.go" <<'EOF'
package a

// F does a thing.
// It has two lines.
func F() {} // trailing

/* block */
EOF
expect "a Go comment fails" 1 "a/dirty.go:3: comment not allowed" check
expect "a trailing Go comment fails" 1 "a/dirty.go:5: comment not allowed" check
expect "a block Go comment fails" 1 "a/dirty.go:7: comment not allowed" check
rm "$repo/a/dirty.go"

add_fails() {
	local name="$1" file="$2" text="$3" at="$4"
	cp "$repo/$file" "$work/keep"
	printf '%s\n' "$text" >>"$repo/$file"
	expect "$name" 1 "$file:$at: comment not allowed" check
	cp "$work/keep" "$repo/$file"
}
add_fails "a Swift comment fails" a/clean.swift '/// Doc.' 13
add_fails "a Swift block comment fails" a/clean.swift '/* a /* nested */ b */' 13
add_fails "a TypeScript comment fails" a/clean.ts 'const a = 1; // one' 6
add_fails "a shell comment fails" a/clean.sh 'true # yes' 12
add_fails "a Nix comment fails" a/clean.nix '# text' 8
add_fails "a YAML comment fails" a/clean.yml '# text' 7
add_fails "a YAML version note without a pin fails" a/clean.yml '  - uses: actions/checkout@v7 # v7.0.1' 7
add_fails "an SQL comment fails" a/clean.sql '-- text' 3
add_fails "an Astro markup comment fails" a/clean.astro '<!-- text -->' 8
add_fails "an Astro expression comment fails" a/clean.astro '{/* text */}' 8
add_fails "a TOML comment fails" a/clean.toml '# text' 5
expect "the tree is clean again" 0 "no new comments" check

cat >"$repo/a/old.go" <<'EOF'
package a

// Old stays for now.
func Old() {}

// Older stays too.
func Older() {}
EOF
expect "a new file with comments fails" 1 "2 new or changed comment(s)" check
expect "init writes the baseline" 0 "wrote 2 entries" ratchet --init
expect "init runs one time" 2 "init runs only one time" ratchet --init
expect "a comment in the baseline passes" 0 "2 left in the baseline" check
g add -A
g commit -q -m baseline

sed -i.bak 's/Old stays for now/Old stays for ever/' "$repo/a/old.go"
rm "$repo/a/old.go.bak"
expect "a changed comment fails" 1 "a/old.go:3: comment not allowed" check
g checkout -q -- a/old.go

printf 'a/old.go\t3\t%s\n' "$(lint list a/old.go | awk -F'\t' '$2 == 3 { print $3 }')" >"$work/strip"
expect "strip removes the named comment" 0 "removed 1 comment(s), 1 line(s)" strip "$work/strip"
same "strip keeps the code and the other comment" a/old.go 'package a

func Old() {}

// Older stays too.
func Older() {}'
expect "a baseline that lists a deleted comment fails" 1 "Run: bun scripts/comment-lint.ts ratchet" check
expect "ratchet removes the entry" 0 "removed 1 entries, 1 left" ratchet
expect "the smaller baseline passes" 0 "1 left in the baseline" check
expect "the smaller baseline passes against the commit before" 0 "1 left in the baseline" check --base HEAD
g add -A
g commit -q -m smaller

printf '\n// New arrives.\nfunc New() {}\n' >>"$repo/a/old.go"
hash="$(lint list a/old.go | awk -F'\t' '$2 == 8 { print $3 }')"
printf 'a/old.go\t%s\n' "$hash" >>"$repo/scripts/comment-baseline.txt"
LC_ALL=C sort -o "$repo/scripts/comment-baseline.txt" "$repo/scripts/comment-baseline.txt"
expect "a baseline with a new entry passes alone" 0 "2 left in the baseline" check
expect "a baseline with a new entry fails against the commit before" 1 "The baseline only gets smaller" check --base HEAD

if ((failures)); then
	echo "$failures comment lint case(s) failed"
	exit 1
fi
