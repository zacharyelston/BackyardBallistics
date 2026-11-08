# Backyard Ballistics

![SpudGunGolf browser prototype: a top-down hole with the flag pole, range rings, the launcher controls and the firing computer](docs/image.png)

*v1 Classic, the original browser game: walk to every round and finish within a metre of the pole.*

**Play in the browser:** [zacharyelston.github.io/BackyardBallistics](https://zacharyelston.github.io/BackyardBallistics/) · [v1 Classic](https://zacharyelston.github.io/BackyardBallistics/v1/) · [v2 Fire Missions](https://zacharyelston.github.io/BackyardBallistics/v2/)

| Prototype | Ruleset | How it plays |
| --- | --- | --- |
| [`prototype/spudgungolf.html`](prototype/spudgungolf.html) | v1 Classic | Walk to every round; shots to rest within 1 m of the pole; pick up for par + 3 |
| [`prototype/spudgungolf-v2.html`](prototype/spudgungolf-v2.html) | v2 Fire Missions | Range the pole with a reticle, fire from a firing point, call each round short, over or range correct (left/right is measured), let fire control bracket, cease fire and verify; rounds plus metres outside the ring. Four fixed-firing-point holes and five downrange-play holes |
| [`docs/GROUP_PLAY.md`](docs/GROUP_PLAY.md) (design, not built; no browser version) | v3 Squadz | v2 fire missions played by squads against squads: a commander's iPad shows the field map and the squad's mission, and members' phones range, spot and report positions |
| [`docs/THEATER_MODE.md`](docs/THEATER_MODE.md) (design, not built; no browser version) | v4 Theater Mode | v3 Squadz plus a course owner's station that observes every match and builds the field map with a GPU mapping back end; it can add course-wide holds and check fire, and never shows firing data |

v2 drives the app's requirements; v1 stays as an optional ruleset on the same engine. v3 Squadz builds on v2 for group play, and v4 Theater Mode adds a course owner's view on top of v3; both are designs so far, and solo play stays v2.

![SpudGunGolf v2 Fire Missions: two spotted rounds on the map, the mission log with fire-control corrections, and the cease-fire result](docs/image-v2.png)

v2 pars (6, 6, 6, 7, 7, 6, 6, 5, 7; par 56) come from simulating a player who uses fire control, prefers lobs, and ceases fire when a round stops improving on the best by a metre.

SpudGunGolf: a backyard trajectory game played with a low-power launcher on published courses. Each hole is a guyed furring-strip pole, and the pole is the hole: every hole is played as fire missions: range the pole with a reticle, fire, spot each round from the firing point, adjust, and score rounds fired plus metres outside the ring.

Spec: [SpudGunGolf App Spec](https://claude.ai/artifact/82Lpac7tqq2UcA4rAKZhCX)

## Layout

| Path | What it is |
| --- | --- |
| `App/` | SwiftUI iPhone app (iOS 17+): `App/` tabs and settings, `Shared/` capture and marking, `Features/` one folder per feature |
| `Packages/SpudCore/` | Platform-free core: `CoreGeo`, `SafetyKit`, `RangingKit`, with unit tests |
| `docs/howto/` | **How to play**: the game, Squadz, orders and safety, with a field picture. Rebuilt from the code by `scripts/build-howto.sh` (`--check` fails if it's out of date); edit `docs/howto/src` |
| `docs/ARCHITECTURE.md` | Modules, dependency rules, the safety gate and the app design |
| `docs/FLAG_KIT.md` | How to build and set up a flag |
| `docs/FIELD_TEST.md` | Field-test protocols for milestones 1 and 2 |
| `docs/GROUP_PLAY.md` | Design for v3 Squadz (not built): squads play squads on v2 fire missions; a commander iPad maps the field from members' phones |
| `docs/THEATER_MODE.md` | Design for v4 Theater Mode (not built): the course owner's observer station and GPU-built field map |
| `docs/COURSE_FORMAT.md` | The flat-key YAML course file a course's web server serves |
| `docs/DEV_MACHINES.md` | The development Macs and test devices, bringing a new Mac in, and SSH between them |
| `courses/sample-course.yaml` | Example course file |
| `prototype/` | Browser prototypes: v1 Classic and v2 Fire Missions |
| `site/`, `scripts/build-pages.sh` | GitHub Pages landing page and build; `.github/workflows/pages.yml` checks every PR and deploys `main` |
| `scripts/typecheck-ios.sh` | Typechecks everything against the iPhone SDK without signing or a simulator |
| `scripts/bootstrap-mac.sh`, `Brewfile` | One-command setup for a new Apple silicon Mac; see `docs/DEV_MACHINES.md` |
| `project.yml` | XcodeGen spec for `SpudGunGolf.xcodeproj` |

## Build

On a new Mac, run `scripts/bootstrap-mac.sh` first; see [DEV_MACHINES.md](docs/DEV_MACHINES.md).

```bash
xcodegen generate
```

```bash
open SpudGunGolf.xcodeproj
```

### Run on an iPhone

Signing reads your team from `Config/Local.xcconfig`, which git ignores, so team IDs stay out of the repo.

1. In Xcode, sign in under **Settings → Apple Accounts** and create an **Apple Development** certificate (**Manage Certificates… → +**). A free Personal Team works; its installs last 7 days.
2. Write your team into `Config/Local.xcconfig`:

```bash
scripts/set-team.sh
```

3. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**, then run from Xcode, or from the command line:

```bash
xcodebuild -project SpudGunGolf.xcodeproj -scheme SpudGunGolf -destination 'platform=iOS,name=<your iPhone>' -allowProvisioningUpdates build
```

If signing fails with `errSecInternalComponent`, let Apple's tools use your key once (asks for your login keychain password):

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
```

The camera and ARKit tools need a real device; in the Simulator the ranging screens use the simulated camera.

Run the core tests on the Mac:

```bash
cd Packages/SpudCore && swift test
```

Typecheck the app for iPhone without signing:

```bash
scripts/typecheck-ios.sh
```

## Milestone status

1. **Flag kit guide and setup flow** — built: lean check, pole height and the sighting field-test tool. Field results pending.
2. **Ranging** — built: reticle (stadia) ranging as the main method: crosshair on the pole's base, a CoreMotion-plumb line sized by the range dial, and a lock that records range, bearing, angle below level and GPS, then runs the 10 m flag check. The multi-photo AR solve (triangulation, outlier drop, height difference) stays as an optional cross-check. The spotting model (called long/short, measured left/right, bracketing) is in RangingKit. Device tuning pending.
3. **Course file and validator** — built: `CourseKit` reads and validates course files (every SafetyKit course check, with readable problems and line numbers), and the Play tab's **Course** screen loads the bundled sample, the course server or a typed address, and keeps the last good course for offline play.
4. **Fire control in Swift** — built: `BallisticsKit` (flight with drag and wind shear, roll-out, the low/lob solver, dispersion), matched to the browser prototype by parity tests.
5. Calibration shots. Until then real fire missions stop at initial data: SafetyKit holds every solution without a calibrated, conforming launcher.
6. **Missions and scorecard** — built: `RoundKit` plays each hole as fire missions (confirm downrange, range, initial data, fire and spot, bracketing corrections, cease fire with Resume, verify, downrange next mission) and keeps the scorecard. **Practice** plays the whole flow with simulated rounds on the loaded course. Multi-player turns are still to come.
7. Sight mode
8. Course server and registry

## Safety line

Low-power launchers only, inanimate targets on your own property, solutions capped at 100 yd and 45 m/s. Every limit lives in `SafetyKit` and nowhere else; see [ARCHITECTURE.md](docs/ARCHITECTURE.md#the-safety-gate). The app measures; it never covers building, fuelling or tuning a launcher.
