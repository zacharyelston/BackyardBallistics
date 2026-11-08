#!/usr/bin/env bash
# Rebuilds docs/howto (the How to Play pages and the field picture) from the code.
#
#   scripts/build-howto.sh          # regenerate
#   scripts/build-howto.sh --check  # fail if the committed pages are out of date
#
# Facts come from the real modules (Packages/SpudCore, `spud-docs`) and from the app's order
# tables; the prose lives in docs/howto/src. Needs a Mac (GroupKit uses CryptoKit).
set -euo pipefail
cd "$(dirname "$0")/.."
FACTS="$(mktemp)"
trap 'rm -f "$FACTS"' EXIT
swift run -q --package-path Packages/SpudCore spud-docs courses/sample-course.yaml > "$FACTS"
python3 -I scripts/build-howto.py "$FACTS" "$@"
