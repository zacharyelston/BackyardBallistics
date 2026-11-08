# Developer tools for SpudGunGolf. Installed by scripts/bootstrap-mac.sh, or: brew bundle
brew "git"
brew "gh"
brew "xcodegen"

# Back-end tools, only with scripts/bootstrap-mac.sh --backend (or HOMEBREW_BACKYARD_BACKEND=1 brew bundle).
# Barnacle runs the back end, with Colima as its Docker engine, so a development Mac doesn't
# need these. Install them to run the back-end containers locally before they go to Barnacle.
# Colima is a free, command-line Docker engine and matches Barnacle.
if ENV["HOMEBREW_BACKYARD_BACKEND"] == "1"
  brew "colima"
  brew "docker"
  brew "docker-compose"
end
