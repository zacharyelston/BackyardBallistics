# Backyard Ballistics

![SpudGunGolf browser prototype: a top-down hole with the flag pole, range rings, the launcher controls and the firing computer](docs/image.png)

*The browser prototype in [`prototype/spudgungolf.html`](prototype/spudgungolf.html). It plays the downrange-play variant (walk to your round and fire again); the fixed-firing-point mission loop comes with fire control (milestone 4).*

SpudGunGolf: a backyard trajectory game played with a low-power launcher on published courses. Each hole is a guyed furring-strip pole, and the pole is the hole: every hole is played as fire missions: range the pole from photos, fire, spot each round from the firing point, adjust, and score rounds fired plus metres outside the ring.

Spec: [SpudGunGolf App Spec](https://claude.ai/artifact/82Lpac7tqq2UcA4rAKZhCX)

## Layout

| Path | What it is |
| --- | --- |
| `App/` | SwiftUI iPhone app (iOS 17+): `App/` tabs and settings, `Shared/` capture and marking, `Features/` one folder per feature |
| `Packages/SpudCore/` | Platform-free core: `CoreGeo`, `SafetyKit`, `RangingKit`, with unit tests |
| `docs/ARCHITECTURE.md` | Modules, dependency rules, the safety gate and the app design |
| `docs/FLAG_KIT.md` | How to build and set up a flag |
| `docs/FIELD_TEST.md` | Field-test protocols for milestones 1 and 2 |
| `docs/COURSE_FORMAT.md` | The flat-key YAML course file a course's web server serves |
| `courses/sample-course.yaml` | Example course file |
| `prototype/spudgungolf.html` | Browser prototype of the game and firing computer |
| `scripts/typecheck-ios.sh` | Typechecks everything against the iPhone SDK without signing or a simulator |
| `project.yml` | XcodeGen spec for `SpudGunGolf.xcodeproj` |

## Build

```bash
xcodegen generate
```

```bash
open SpudGunGolf.xcodeproj
```

Set your signing team on the SpudGunGolf target, then run on an iPhone. The camera and ARKit tools need a real device.

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
2. **Ranging prototype** — built: multi-photo AR ranging with fused size range and triangulation, outlier drop, height difference, and the 10 m flag check. Device tuning pending.
3. Course file and validator
4. Fire control in Swift
5. Calibration shots
6. Missions and scorecard
7. Sight mode
8. Course server and registry

## Safety line

Low-power launchers only, inanimate targets on your own property, solutions capped at 100 yd and 45 m/s. Every limit lives in `SafetyKit` and nowhere else; see [ARCHITECTURE.md](docs/ARCHITECTURE.md#the-safety-gate). The app measures; it never covers building, fuelling or tuning a launcher.
