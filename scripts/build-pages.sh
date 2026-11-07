#!/usr/bin/env bash
# Builds the GitHub Pages site into _site/ (or the directory given as $1):
#   /      landing page (site/index.html)
#   /v1/   prototype/spudgungolf.html     (v1 Classic)
#   /v2/   prototype/spudgungolf-v2.html  (v2 Fire Missions)
# The prototypes are page fragments, so each gets a doctype, charset and viewport head.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/_site}"

rm -rf "$out"
mkdir -p "$out/v1" "$out/v2" "$out/img"

wrap() { # $1 source fragment, $2 destination
  {
    printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
    # The fragment opens with <title>, <link> and <style>, so it continues the head; the parser
    # starts the body at its first content element.
    cat "$1"
    printf '\n</html>\n'
  } > "$2"
}

wrap "$root/prototype/spudgungolf.html" "$out/v1/index.html"
wrap "$root/prototype/spudgungolf-v2.html" "$out/v2/index.html"
cp "$root/site/index.html" "$out/index.html"
cp "$root/docs/image.png" "$out/img/v1.png"
cp "$root/docs/image-v2.png" "$out/img/v2.png"
touch "$out/.nojekyll"

# Every page must exist and be non-empty, and every local link on the landing page must resolve.
for f in index.html v1/index.html v2/index.html img/v1.png img/v2.png; do
  [[ -s "$out/$f" ]] || { echo "missing or empty: $f" >&2; exit 1; }
done
grep -oE '(href|src)="[^"#:]+"' "$out/index.html" | sed -E 's/^[a-z]+="(.*)"$/\1/' | while read -r link; do
  target="$out/$link"; [[ "$link" == */ ]] && target="${target}index.html"
  [[ -e "$target" ]] || { echo "broken link on landing page: $link" >&2; exit 1; }
done

echo "Built $out"
