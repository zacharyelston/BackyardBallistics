# Development machines

The Macs and devices SpudGunGolf is built and tested on, and how to bring a new Mac in.

## The machines

| Machine | What it is | Role |
| --- | --- | --- |
| **MBA-M3-16-Z** | MacBook Air (M3) | The main development machine. Builds the iOS app with Xcode and XcodeGen, and installs to devices with `scripts/install-devices.sh` |
| **M6Pro** (`m6pro.local`) | MacBook Pro (M6, 32 GB) | The host. Runs the back end, the computer vision that turns observations and stills into the 3D field mesh (the [render host](GROUP_PLAY.md#optional-render-host)), and the [v4 Theater Mode](THEATER_MODE.md) observer host. Also a development machine. Set it up with `--backend` |
| **Barnacle** (`barnacle.local`) | Mac mini (M1) in the barn, always on | The console: a v4 Theater observer screen in the barn. Runs Colima, as a Homebrew service, as its only Docker engine. Its external drive (`PNY1TB`) holds the archive |
| **ZFone-17** | iPhone | Test device |
| **S-Pad**, and an older iPad | iPads | Test devices |

## Bring a new Mac in

1. Clone the repo and run the bootstrap. It's safe to run again at any point; it checks each step first and skips what's done.

   ```bash
   git clone https://github.com/zacharyelston/BackyardBallistics.git
   cd BackyardBallistics
   scripts/bootstrap-mac.sh
   ```

   It needs Apple silicon and macOS 27 or later. It installs the Command Line Tools, Homebrew and the `Brewfile` (`git`, `gh`, `xcodegen`), checks for Xcode, runs Xcode's first-launch setup, writes `Config/Local.xcconfig` when it can, and finishes with the core tests and the iOS typecheck. It never asks for a password or token: anything that needs your Apple ID or GitHub login is listed at the end for you to do by hand.

   Add `--backend` for Colima, docker and docker-compose. The host (M6Pro) needs them; other development Macs only do to try the back-end containers locally.

2. Install Xcode if the bootstrap says it's missing (App Store, or `xcodes`), then sign in: **Xcode → Settings → Apple Accounts → +**, then **Manage Certificates… → + → Apple Development**. Sign in to GitHub with `gh auth login`. Run the bootstrap again; it writes your team into `Config/Local.xcconfig`, which git ignores.

3. Run the app on each iPhone and iPad once by cable, from Xcode. That pairs the device with this Mac and registers it for signing. Turn on **Developer Mode** on the device when asked.

4. From then on, install over Wi-Fi to every reachable device (same network, device unlocked):

   ```bash
   scripts/install-devices.sh            # all of them
   scripts/install-devices.sh S-Pad      # only devices whose name matches
   ```

## SSH between the machines

1. On each Mac you want to reach, turn on **System Settings → General → Sharing → Remote Login**.
2. On the Mac you connect from, make a key once if you don't have one, and copy it over:

   ```bash
   ssh-keygen -t ed25519
   ssh-copy-id zaq@barnacle.local
   ```

3. Signing over SSH: a Mac's login keychain stays locked in an SSH session, so a signed build fails at `CodeSign`. Build from that Mac's own Terminal or Xcode, or run `security unlock-keychain ~/Library/Keychains/login.keychain-db` (it asks for that Mac's password) in the SSH session first.
4. Connect by the Mac's `.local` name, which works on the local network without DNS: `ssh zaq@barnacle.local`. A Mac's local name is in **System Settings → General → Sharing**, under **Local hostname**.

Tools that reach other devices on the local network (`install-devices.sh`, `ssh`, a course server) may need macOS's **Local Network** permission for the terminal or app that runs them: **System Settings → Privacy & Security → Local Network**.
