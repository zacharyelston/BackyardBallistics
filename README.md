# Backyard Ballistics

SpudGunGolf: a backyard trajectory game played with a low-power potato launcher on published courses. Flags are guyed furring-strip poles standing in a trash can lid; the iPhone app ranges the lid from photos of the pole, runs a firing computer and keeps score.

Spec: [SpudGunGolf App Spec](https://claude.ai/artifact/82Lpac7tqq2UcA4rAKZhCX)

## Layout

| Path | What it is |
| --- | --- |
| `App/` | SwiftUI iPhone app (iOS 17+): `App/` tabs and settings, `Shared/` capture and marking, `Features/` one folder per feature |
| `Packages/SpudCore/` | Platform-free core: `CoreGeo`, `SafetyKit`, `RangingKit`, with unit tests |
| `docs/ARCHITECTURE.md` | Modules, dependency rules, the safety gate and the app design |
| `docs/FLAG_KIT.md` | How to build and set up a flag |
| `docs/FIELD_TEST.md` | Field-test protocols for milestones 1 and 2 |
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
4. Firing computer in Swift
5. Calibration shots
6. Play flow and scorecard
7. Sight mode
8. Course sharing

## Safety line

Low-power launchers only, inanimate targets on your own property, solutions capped at 100 yd and 45 m/s. Every limit lives in `SafetyKit` and nowhere else; see [ARCHITECTURE.md](docs/ARCHITECTURE.md#the-safety-gate). The app measures; it never covers building, fuelling or tuning a launcher.
