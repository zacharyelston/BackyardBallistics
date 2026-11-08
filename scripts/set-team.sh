#!/usr/bin/env bash
# Writes Config/Local.xcconfig with your development team, read from the "Apple Development"
# certificate Xcode created when you signed in. Usage: scripts/set-team.sh [TEAM_ID]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
team="${1:-}"
if [[ -z "$team" ]]; then
  teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{print c | "openssl x509 -noout -subject -nameopt multiline"; close("openssl x509 -noout -subject -nameopt multiline")}' \
    | awk -F' = ' '/organizationalUnitName/{print $2}' | sort -u)
  count=$(printf '%s\n' "$teams" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "No Apple Development certificate found. In Xcode: Settings > Accounts > + > Apple ID, then Manage Certificates > + > Apple Development." >&2; exit 1
  elif [[ "$count" -gt 1 ]]; then
    echo "Several teams have certificates here; pass the one to use: scripts/set-team.sh TEAM_ID" >&2; printf '  %s\n' $teams >&2; exit 1
  fi
  team="$teams"
fi
printf '// Local signing, not committed.\nDEVELOPMENT_TEAM = %s\n' "$team" > "$root/Config/Local.xcconfig"
echo "Wrote Config/Local.xcconfig with DEVELOPMENT_TEAM = $team"
