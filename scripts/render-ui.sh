#!/usr/bin/env bash
# Renders the app's design scenes (App/Sources/App/DesignScenes.swift) in the iOS Simulator and
# screenshots each one, so a UI change can be looked at before it goes on a device.
# See docs/DESIGN_PROCESS.md.
#
#   scripts/render-ui.sh                    # every scene, light mode
#   scripts/render-ui.sh --dark             # every scene, dark mode
#   scripts/render-ui.sh phone-orders       # just these scenes
#   scripts/render-ui.sh --no-build ...     # reuse the last build
#
# Writes build/renders/<scene>[-dark].png and build/renders/index.html (a contact sheet).
# Devices default to the ones we test on; override with RENDER_PHONE / RENDER_PAD (simulator names).
set -euo pipefail
cd "$(dirname "$0")/.."

PHONE="${RENDER_PHONE:-iPhone 17e}"
PAD="${RENDER_PAD:-iPad (A16)}"
OUT="${RENDER_OUT:-build/renders}"
WAIT="${RENDER_WAIT:-90}"   # longest to wait for a scene to say it is drawn (a cold iPad is slow)
BUNDLE_ID=com.backyardballistics.spudgungolf
APP=build/sim/Build/Products/Debug-iphonesimulator/SpudGunGolf.app
SRC=App/Sources/App/DesignScenes.swift

APPEARANCE=light
BUILD=1
SCENES=()
for a in "$@"; do
  case "$a" in
    --dark) APPEARANCE=dark ;;
    --no-build) BUILD=0 ;;
    -h|--help) sed -n 2,13p "$0"; exit 0 ;;
    *) SCENES+=("$a") ;;
  esac
done

# Every scene, from the enum's raw values.
ALL=($(sed -n 's/^ *case [a-zA-Z]* = "\([a-z-]*\)".*/\1/p' "$SRC"))
[ ${#SCENES[@]} -eq 0 ] && SCENES=("${ALL[@]}")
for s in "${SCENES[@]}"; do
  [[ " ${ALL[*]} " == *" $s "* ]] || { echo "No design scene '$s'. Scenes: ${ALL[*]}" >&2; exit 1; }
done

if [ "$BUILD" = 1 ]; then
  echo "== Building for the Simulator"
  xcodegen -q
  xcodebuild -project SpudGunGolf.xcodeproj -scheme SpudGunGolf -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim \
    CODE_SIGNING_ALLOWED=NO build -quiet
fi
[ -d "$APP" ] || { echo "No Simulator build at $APP; run without --no-build." >&2; exit 1; }

# The newest-runtime available simulator with this exact name.
udid_for() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
best = None
for runtime, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"] == name and (best is None or runtime > best[0]):
            best = (runtime, d["udid"])
print(best[1] if best else "")' "$1"
}

prepared=""
prepare() { # udid
  local u="$1"
  [[ " $prepared " == *" $u "* ]] && return
  xcrun simctl boot "$u" 2>/dev/null || true
  xcrun simctl bootstatus "$u" -b >/dev/null
  xcrun simctl status_bar "$u" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularMode active --cellularBars 4 >/dev/null 2>&1 || true
  xcrun simctl ui "$u" appearance "$APPEARANCE"
  xcrun simctl install "$u" "$APP"
  xcrun simctl privacy "$u" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
  # Somewhere on the sample course, so the phone's own position is drawn there.
  xcrun simctl location "$u" set 42.36020,-71.05810 >/dev/null 2>&1 || true
  prepared="$prepared $u"
}

mkdir -p "$OUT"
suffix=$([ "$APPEARANCE" = dark ] && echo "-dark" || echo "")
for s in "${SCENES[@]}"; do
  case "$s" in ipad-*) device="$PAD" ;; *) device="$PHONE" ;; esac
  u=$(udid_for "$device")
  [ -n "$u" ] || { echo "No simulator named '$device' (xcrun simctl list devices)." >&2; exit 1; }
  prepare "$u"
  # The scene writes Documents/design-ready once it's drawn (DesignSceneView.markReady).
  marker="$(xcrun simctl get_app_container "$u" "$BUNDLE_ID" data)/Documents/design-ready"
  rm -f "$marker"
  xcrun simctl launch --terminate-running-process "$u" "$BUNDLE_ID" -designScene "$s" >/dev/null
  waited=0
  until [ -f "$marker" ]; do
    sleep 1; waited=$((waited + 1))
    [ "$waited" -lt "$WAIT" ] || { echo "   $s: never said it was drawn after ${WAIT}s; screenshotting anyway" >&2; break; }
  done
  xcrun simctl io "$u" screenshot --type=png "$OUT/$s$suffix.png" >/dev/null 2>&1
  # simctl saves the portrait framebuffer; turn landscape iPad pictures upright.
  case "$s" in ipad-*)
    w=$(sips -g pixelWidth "$OUT/$s$suffix.png" | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight "$OUT/$s$suffix.png" | awk '/pixelHeight/{print $2}')
    [ "$w" -lt "$h" ] && sips -r 270 "$OUT/$s$suffix.png" >/dev/null ;;
  esac
  echo "   $s ($device) -> $OUT/$s$suffix.png"
done

# A contact sheet of every render in the folder.
python3 - "$OUT" <<'EOF'
import os, sys, html
out = sys.argv[1]
pngs = sorted(f for f in os.listdir(out) if f.endswith(".png"))
cards = "\n".join(
    f'<figure><img src="{html.escape(p)}" loading="lazy"><figcaption>{html.escape(p[:-4])}</figcaption></figure>'
    for p in pngs)
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8">
<title>SpudGunGolf renders</title>
<style>body{{font:14px -apple-system,sans-serif;margin:16px;background:#f2f2f7}}
main{{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}}
figure{{margin:0;background:#fff;padding:8px;border-radius:12px}}
img{{max-height:640px;max-width:90vw;display:block;border-radius:6px}}
figcaption{{padding-top:6px;color:#555}}</style>
<h1>Design scenes</h1><main>{cards}</main>""")
EOF
echo "== Contact sheet: $OUT/index.html"
