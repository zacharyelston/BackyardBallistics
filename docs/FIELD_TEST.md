# Milestone 1 field test: sighting the pole

Goal: find out how precisely a player can mark a pole's tip and base, and how good a single-photo size range is, at 10–90 m on each lens.

## What you need

- One flag set up per [FLAG_KIT.md](FLAG_KIT.md), plumb and with its height measured in the app.
- A long tape or measuring wheel.
- Your phone height while sighting, entered in the app's settings (default 1.5 m).

## Procedure

1. Mark taped distances from the pole: **10, 30, 60 and 90 m**. Keep the ground as level as you can for now; slope correction comes later.
2. At each distance, for each lens the phone has (0.5×, 1×, Telephoto):
   1. Open **Sighting test**, pick the lens, fit the whole pole in frame and tap **Capture**.
   2. Tap the tip, then switch to **Base** and tap the base. Use the loupe to nudge each mark onto the pole's edge.
   3. Enter the taped distance, add a note (light, wind, what hides the base), and tap **Log sample**.
   4. Repeat three times per lens per distance, re-marking from scratch each time.
3. Repeat the whole set once in bright sun and once overcast if you can.
4. Open **Field log** → **Export CSV** and save the file.

## What to look for

| Question | Where in the CSV |
| --- | --- |
| Do repeat marks agree? | Spread of `est_m` across the three samples at one distance |
| Is the range biased? | Mean of `error_pct` per lens and distance |
| Does the base hide in grass or behind the lid rim? | Larger errors plus notes about the base |
| Does the lens report calibration? | `approx_intrinsics` = 1 means it was estimated |

## Pass mark

The spec's targets for an 8 ft pole: 1× within about 4 cm at 10 m, 19 cm at 30 m, 65 cm at 60 m and 1.5 m at 90 m; telephoto within about 12 cm at 30 m, 27 cm at 60 m and 45 cm at 90 m. If the base is the weak point, try a white band at the bottom of the pole (open question in the spec).
