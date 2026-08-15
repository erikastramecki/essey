#!/usr/bin/env bash
# Verify a deploy actually carries the art. app/web/public/{traits,builder} are gitignored, so a build
# from a git source produces a site where every one of those paths is missing — and the SPA rewrite
# answers each one with a 200 serving index.html. Status codes all look healthy; only the content type
# shows the failure. That is why this asserts on type and never on code.
#
#   ./app/web/check-deploy-assets.sh [url]
set -euo pipefail

SITE="${1:-${SITE:-https://essey.xyz}}"
failed=0

expect_type() {
  local path="$1" want="$2" got
  got=$(curl -s -o /dev/null -w '%{content_type}' --retry 3 --retry-delay 2 -m 30 "$SITE$path")
  if [[ "$got" == *"$want"* ]]; then
    printf 'OK    %-44s %s\n' "$path" "$got"
  else
    printf 'FAIL  %-44s want %s, got %s\n' "$path" "$want" "$got"
    failed=1
  fi
}

for f in data_male data_female web_bbox_map_male web_bbox_map_female; do
  expect_type "/builder/$f.json" application/json
done

# Named off the deployed manifest, not hardcoded: the art is regenerated and renamed, and a stale
# constant here would fail for a reason that has nothing to do with the deploy.
leaf=$(curl -s --retry 3 --retry-delay 2 -m 30 "$SITE/builder/data_male.json" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(d["gender"] + "/" + d["leaves"][0]["file"])' 2>/dev/null || true)

if [[ -n "$leaf" ]]; then
  expect_type "/traits/$leaf" image/webp
else
  printf 'FAIL  %-44s manifest unreadable, cannot name a layer\n' "/traits/…"
  failed=1
fi

# Composites server-side from the same tree and degrades to a placeholder SVG rather than erroring.
expect_type "/api/don-img/1" image/webp

if ((failed)); then
  echo "--- DEPLOY ASSETS: MISSING ---"
  echo "$SITE was built without app/web/public/{traits,builder}."
  echo "Redeploy from the repo root, on a machine that has them: vercel --prod --yes"
  exit 1
fi
echo "--- DEPLOY ASSETS: OK ---"
