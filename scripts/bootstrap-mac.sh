#!/usr/bin/env bash
# Sets up a new Apple silicon Mac for SpudGunGolf development. Safe to re-run: every step
# checks first and skips what is already done. See docs/DEV_MACHINES.md.
#
#   scripts/bootstrap-mac.sh             # developer tools, then the core tests and iOS typecheck
#   scripts/bootstrap-mac.sh --backend   # also Colima, docker and docker-compose
#
# It never asks for, stores or prints a password or token. Steps that need your Apple ID or
# GitHub login are printed for you to do by hand. The Homebrew installer and macOS's own
# installers may ask for your Mac password themselves; this script never sees it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BACKEND=0
for arg in "$@"; do
  case "$arg" in
    --backend) BACKEND=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

MIN_MACOS=27
TODO=()   # steps left for you, printed at the end

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
run()  { printf '    $ %s\n' "$*"; "$@"; }
todo() { TODO+=("$*"); printf '    to do: %s\n' "$*"; }

# --- Machine -----------------------------------------------------------------------------
step "Checking this Mac"
# hw.optional.arm64 is 1 on Apple silicon even when this shell runs under Rosetta.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
  echo "This script is for Apple silicon Macs." >&2; exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This shell is running under Rosetta. Open a native Terminal and run it again." >&2; exit 1
fi
ok "Apple silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64))"
macos="$(sw_vers -productVersion)"
if (( ${macos%%.*} < MIN_MACOS )); then
  echo "macOS $macos is too old: this project expects macOS $MIN_MACOS or later. Update in System Settings > General > Software Update." >&2
  exit 1
fi
ok "macOS $macos"

# --- Command Line Tools ------------------------------------------------------------------
step "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "installed at $(xcode-select -p)"
else
  echo "    Not installed. macOS will open an installer window; finish it and this script carries on."
  run xcode-select --install || true
  until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  ok "installed at $(xcode-select -p)"
fi

# --- Homebrew ----------------------------------------------------------------------------
step "Homebrew"
if [[ -x /opt/homebrew/bin/brew ]]; then
  ok "installed at /opt/homebrew"
else
  echo "    Not installed. Running the official installer (it asks for your Mac password itself)."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
# shellcheck disable=SC2016
if ! grep -qs 'brew shellenv' "$HOME/.zprofile"; then
  echo "    Adding Homebrew to your PATH in ~/.zprofile"
  printf '\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >> "$HOME/.zprofile"
fi

# --- Brewfile ----------------------------------------------------------------------------
step "Homebrew packages (Brewfile)"
export HOMEBREW_NO_AUTO_UPDATE=1   # check and install what is listed; upgrades are up to you
if (( BACKEND )); then
  echo "    --backend: including Colima, docker and docker-compose"
  export HOMEBREW_BACKYARD_BACKEND=1
fi
if brew bundle check --no-upgrade --file "$ROOT/Brewfile" >/dev/null 2>&1; then
  ok "everything in the Brewfile is installed"
else
  run brew bundle install --file "$ROOT/Brewfile" --no-upgrade
fi
if (( BACKEND )); then
  echo "    Colima is installed but not started. To run it now: colima start"
  echo "    To start it at login, as on Barnacle: brew services start colima"
  echo "    For 'docker compose' (not just docker-compose), follow the caveat in: brew info docker-compose"
fi

# --- Xcode -------------------------------------------------------------------------------
step "Xcode"
XCODE=""
if [[ "$(xcode-select -p 2>/dev/null)" == *.app/Contents/Developer ]]; then
  XCODE="$(xcode-select -p)"
else
  for app in /Applications/Xcode.app /Applications/Xcode*.app; do
    [[ -d "$app/Contents/Developer" ]] && { XCODE="$app/Contents/Developer"; break; }
  done
fi
if [[ -z "$XCODE" ]]; then
  echo "    Full Xcode is not installed. This script doesn't install it (it's large and needs your Apple ID)."
  todo "Install Xcode from the App Store, or with xcodes (brew install xcodes; xcodes install --latest), then run this script again."
else
  ok "found $XCODE"
  if [[ "$(xcode-select -p)" != "$XCODE" ]]; then
    todo "Point the command line tools at Xcode: sudo xcode-select -s \"$XCODE\""
  fi
  export DEVELOPER_DIR="$XCODE"
  if ! xcodebuild -license check >/dev/null 2>&1; then
    todo "Accept the Xcode license: open Xcode once, or run: sudo xcodebuild -license"
  elif xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    ok "first-launch setup already done"
  elif run xcodebuild -runFirstLaunch; then
    ok "first-launch setup done"
  else
    todo "Finish Xcode's first-launch setup: sudo xcodebuild -runFirstLaunch"
  fi
fi

# --- Accounts (by hand) ------------------------------------------------------------------
step "Accounts"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  ok "GitHub CLI is signed in"
else
  todo "Sign in to GitHub: gh auth login"
fi
if security find-certificate -c "Apple Development" >/dev/null 2>&1; then
  ok "an Apple Development certificate is in the keychain"
else
  todo "Sign in to Xcode: Xcode > Settings > Apple Accounts > +, then Manage Certificates > + > Apple Development."
fi

# --- Signing -----------------------------------------------------------------------------
step "Signing (Config/Local.xcconfig, ignored by git)"
if [[ -f Config/Local.xcconfig ]]; then
  ok "Config/Local.xcconfig exists; leaving it alone"
elif security find-certificate -c "Apple Development" >/dev/null 2>&1 && scripts/set-team.sh; then
  ok "written by scripts/set-team.sh from your Apple Development certificate"
else
  # Copying Config/Local.xcconfig.example as-is would sign with its placeholder team, so don't.
  todo "After signing in to Xcode, run scripts/set-team.sh (or copy Config/Local.xcconfig.example to Config/Local.xcconfig and put in your team ID)."
fi

# --- Checks ------------------------------------------------------------------------------
step "Checks"
if [[ -z "$XCODE" ]]; then
  echo "    Skipped: the core tests and iOS typecheck need full Xcode."
  FAILED=0
else
  FAILED=0
  (cd Packages/SpudCore && run swift test) || FAILED=1
  run scripts/typecheck-ios.sh || FAILED=1
fi

# --- Summary -----------------------------------------------------------------------------
step "Done"
if (( ${#TODO[@]} )); then
  echo "    Left for you:"
  for t in "${TODO[@]}"; do printf '      - %s\n' "$t"; done
fi
echo "    Then run the app on each iPhone and iPad once by cable; see docs/DEV_MACHINES.md."
if (( FAILED )); then
  echo "    A check failed; see the output above." >&2; exit 1
fi
