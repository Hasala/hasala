#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	base="$(git rev-parse -q --verify 'HEAD^1' || true)"
else
	base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
fi

args=(check)
if [[ -n "$base" ]]; then
	args+=(--base "$base")
else
	echo "check-comments: no base commit, so the baseline is not compared with an older one" >&2
fi
exec bun scripts/comment-lint.ts "${args[@]}"
