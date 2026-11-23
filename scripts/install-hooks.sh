#!/usr/bin/env bash
set -u

if [ "${GITHUB_ACTIONS:-}" = true ]; then
	exit 0
fi
if ! command -v git >/dev/null 2>&1; then
	exit 0
fi

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars 2>/dev/null)

top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
if [ ! -f "$top/.githooks/pre-push" ] || [ ! -f "$top/scripts/pre-push.sh" ]; then
	exit 0
fi

current="$(git -C "$top" config --get core.hooksPath 2>/dev/null || true)"
case "$current" in
.githooks) ;;
"")
	if git -C "$top" config core.hooksPath .githooks 2>/dev/null; then
		echo "hasala: git now runs the hooks in .githooks/ for this clone (core.hooksPath=.githooks)" >&2
	else
		echo "hasala: could not set core.hooksPath, so git does not run .githooks/pre-push" >&2
	fi
	;;
*)
	echo "hasala: core.hooksPath is '$current', so git does not run .githooks/pre-push; unset it or set it to .githooks" >&2
	;;
esac
exit 0
