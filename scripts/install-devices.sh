#!/usr/bin/env bash
# Builds the app once and installs it on every paired iPhone and iPad that the Mac can reach,
# by cable or over Wi-Fi (same network, device unlocked, paired with this Mac once by cable).
#
#   scripts/install-devices.sh            # build, install and launch on all reachable devices
#   scripts/install-devices.sh S-Pad      # only devices whose name matches
set -euo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"
BUNDLE_ID=com.backyardballistics.spudgungolf
APP=build/dev/Build/Products/Debug-iphoneos/SpudGunGolf.app

xcodegen -q
xcodebuild -project SpudGunGolf.xcodeproj -scheme SpudGunGolf -destination 'generic/platform=iOS' \
  -derivedDataPath build/dev -allowProvisioningUpdates build -quiet

JSON=$(mktemp)
trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null

# name<TAB>identifier for physical iPhones/iPads that are paired and reachable
python3 - "$JSON" "$FILTER" <<'EOF' | while IFS=$'\t' read -r name id; do
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
flt = sys.argv[2].lower()
for d in devices:
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") != "physical" or hw.get("platform") != "iOS":
        continue
    if conn.get("pairingState") != "paired" or conn.get("tunnelState") == "unavailable":
        continue
    name = props.get("name", "?")
    if flt and flt not in name.lower():
        continue
    print(f"{name}\t{d['identifier']}")
EOF
  echo "== $name"
  if xcrun devicectl device install app --device "$id" "$APP" >/dev/null 2>&1; then
    xcrun devicectl device process launch --device "$id" "$BUNDLE_ID" >/dev/null 2>&1 && echo "   installed and launched" \
      || echo "   installed (unlock it to launch)"
  else
    echo "   install failed: is it unlocked, on this Wi-Fi, and in the signing profile?"
  fi
done
