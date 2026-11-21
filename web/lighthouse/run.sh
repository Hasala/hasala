#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-$here/reports}" && cd "${1:-$here/reports}" && pwd)
cd "$here"
[[ -d ../dist ]] || { echo "no web/dist: run \`bun run build\` first" >&2; exit 1; }
command -v node >/dev/null || { echo "Lighthouse CI needs Node (and Chrome) on PATH" >&2; exit 1; }
[[ -x node_modules/.bin/lhci ]] || { echo "run \`bun install --frozen-lockfile\` in web/lighthouse first" >&2; exit 1; }

status=0
for preset in mobile desktop; do
  rm -rf .lighthouseci "${out:?}/$preset"
  flags=(--upload.target=filesystem "--upload.outputDir=$out/$preset")
  [[ $preset == desktop ]] && flags+=(--collect.settings.preset=desktop)
  echo "== Lighthouse: $preset"
  node node_modules/.bin/lhci autorun "${flags[@]}" || status=1
  cp .lighthouseci/assertion-results.json "$out/$preset/" 2>/dev/null || true
done
rm -rf .lighthouseci
exit $status
