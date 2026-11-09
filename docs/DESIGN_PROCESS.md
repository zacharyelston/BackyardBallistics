# Design process for UI changes

Every change to a screen gets looked at as a picture before it goes on a device. The app has
**design scenes**: launch arguments that open one screen with made-up squad data. A script renders
each scene in the iOS Simulator and saves screenshots, so a reviewer (or Claude) can see the
change without a squad, a field or a second phone.

## The loop

1. **Say what the screen is for.** One line: who uses it, standing where, doing what. For
   example, "a member walking to a spot with the phone in one hand reads the order and taps one
   button." Most layout calls follow from that.
2. **Render before you change it.** Run `scripts/render-ui.sh <scene>` and keep the "before"
   pictures (copy `build/renders/` aside, or render on main first).
3. **Make the change,** then render again, in light and dark:

   ```bash
   scripts/render-ui.sh phone-orders phone-banner
   scripts/render-ui.sh --no-build --dark phone-orders phone-banner
   ```

4. **Check the pictures** against the list below. Open `build/renders/index.html` for a
   contact sheet.
5. **Put before and after in the PR description,** for each scene the change touches.
6. **Then the devices.** `scripts/install-devices.sh` puts it on the iPhone and the iPad for a
   check in the hand: sunlight, gloves, walking. Renders can't show those things.

## The scenes

Every scene uses the bundled sample course, never `courses/local`. Squad Red is Ana (gunner),
Ben and Cy. Ben has three orders: move to the tree line, range the pole from there, and spot
(this one is for the whole team).

| Scene | Device | Screen |
|---|---|---|
| `phone-orders` | iPhone 17e | Joined Play screen with Ben's current task and other orders |
| `phone-banner` | iPhone 17e | Field tab with the compact order strip above the tabs |
| `phone-order-detail` | iPhone 17e | One order: the card and the map |
| `phone-goto` | iPhone 17e | Go there: the big pointer and the map |
| `phone-spotter` | iPhone 17e | The spotter card with round 2 in the air |
| `ipad-command` | iPad (A16), landscape | The commander's squad screen |
| `phone-play` | iPhone 17e | Start screen with solo and squad choices |
| `phone-field` | iPhone 17e | Course, ranging, records and pole setup |
| `phone-kit` | iPhone 17e | Equipment and advanced tests |
| `phone-solo` | iPhone 17e | Active solo hole, progress and scorecard access |
| `phone-empty` | iPhone 17e | Joined with no pending tasks |
| `phone-reconnect` | iPhone 17e | Joined screen reconnecting to its commander |
| `ipad-invite` | iPad (A16), landscape | Invite sheet with code and QR |
| `ipad-team` | iPad (A16), landscape | Team roster and inbox |
| `ipad-order-draft` | iPad (A16), landscape | The same screen part-way through an order: Cy, Capture, a place on the map |

The defaults match the devices we test on. To render on another simulator:

```bash
RENDER_PHONE="iPhone 17 Pro Max" scripts/render-ui.sh phone-orders
```

To add a scene:

1. Add a case to `DesignScene` in `App/Sources/App/DesignScenes.swift`. A raw value starting
   with `ipad-` renders on the iPad; anything else renders on the iPhone.
2. Show its screen in `DesignSceneView.screen`.
3. If it needs more data, extend `DesignFixture`. The fixture drives the real `SquadHost`, so
   the screens get the same messages they'd get over Wi-Fi.

The script finds new cases on its own. Scenes and fixtures are `#if DEBUG` only, so they never
ship.

## What to check in a render

- **Nothing wraps or truncates by accident.** Buttons fit their labels on the smallest phone,
  and a long note or member name doesn't push buttons off the screen.
- **One obvious thing to do.** The main action stands out, and secondary actions look secondary.
  On a member's phone that action is usually one button, used outdoors with one hand.
- **The title says what it is.** An order card reads as its order ("Range the pole") before
  anything else.
- **Tap targets are at least 44 pt,** with room between destructive and constructive buttons
  (Done next to Can't).
- **Dark mode is legible,** especially text over the satellite map.
- **iPad landscape uses the width:** the map is the main pane and the controls sit in a column.
- **No firing data on a phone,** ever. If a phone render shows a range, an elevation or a
  charge, that's a bug, whatever the layout.

## How Claude uses this

When Claude changes a screen, it runs the scenes that screen appears in. It reads the PNGs
(they're images it can see), fixes what it finds, and attaches before and after renders to the
PR. It still asks for a check on the device for things renders can't show: the compass,
sunlight, touch.
