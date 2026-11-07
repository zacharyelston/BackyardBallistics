# Field tests

- [Milestone 1: sighting the pole](#milestone-1-field-test-sighting-the-pole) (single photo, any lens)
- [Milestone 2: multi-photo ranging](#milestone-2-field-test-multi-photo-ranging) (AR session, 1× lens)

## Milestone 2 field test: multi-photo ranging

Goal: check the fused range, its ± estimate, the height difference and the flag check at real distances.

1. Set up one plumb flag with its height measured. Stand at the pole and use **Range the flag → Save my GPS position as the flag point** (wait for GPS accuracy of ±5 m or better).
2. Tape out 10, 30, 60 and 90 m. Note if the ground slopes; measure the height difference if you can.
3. At each distance, open **Range the flag**, wait for "Tracking", and take photo 1 at the taped spot. Mark tip and base, tap **Use photo**.
4. Step sideways across the line, one step at a time, taking 2–4 more photos until the baseline bar fills (3 m).
5. Read the result, enter the taped distance and a note, and tap **Log this ranging**. Do three rangings per distance.
6. Try one deliberately bad mark (base tapped on the grass beside the pole) to see the outlier drop.
7. **Ranging log → Export** both the CSV and the full JSON. The JSON keeps every photo's pose and marks, so the solver can be re-tuned without going back outside.

What to look for: error within about 2σ of the shown ±; "Photo agreement" Good on clean marks; flag check under 10 m; height difference sign and size on sloped ground.

Ranging uses the 1× camera only, by design. If you have poles of different heights, repeat at 60 and 90 m with each to confirm taller poles range better.

# Milestone 1 field test: sighting the pole

Goal: find out how precisely a player can mark a pole's tip and base, and how good a single-photo size range is, at 10–90 m on each lens.

## What you need

- One flag set up per [FLAG_KIT.md](FLAG_KIT.md), plumb and with its height measured in the app.
- A long tape or measuring wheel.
- Your phone height while sighting, entered in the app's settings (default 1.5 m).

## Procedure

1. Mark taped distances from the pole: **10, 30, 60 and 90 m**. Keep the ground as level as you can for now; slope correction comes later.
2. At each distance, on the 1× lens (the app ranges with 1× only):
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
| Does the base hide in grass or behind a lid rim? | Larger errors plus notes about the base |
| Does the lens report calibration? | `approx_intrinsics` = 1 means it was estimated |

## Pass mark

The spec's targets for an 8 ft pole on the 1× lens: about 4 cm at 10 m, 19 cm at 30 m, 65 cm at 60 m and 1.5 m at 90 m. A 12 ft pole should cut those by about a third.
