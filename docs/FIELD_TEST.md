# Field tests

- [Milestone 1: sighting the pole](#milestone-1-field-test-sighting-the-pole) (single photo, any lens)
- [Milestone 2: reticle ranging](#milestone-2-field-test-reticle-ranging) (the main method, AR session, 1× lens)
- [Milestone 2: multi-photo cross-check](#milestone-2-field-test-multi-photo-cross-check) (optional, AR session, 1× lens)

## Milestone 2 field test: reticle ranging

Goal: check that a reticle lock lands within its ± at real distances, and that the height difference and flag check come out right. This is the main ranging method; there is no tapping.

1. Set up one plumb flag with its height measured (8, 10 or 12 ft). Stand at the pole and use **Range the pole → Save my GPS position as the flag point** (wait for GPS accuracy of ±5 m or better).
2. Tape out 10, 30, 60 and 90 m. Note if the ground slopes; measure the height difference if you can.
3. At each distance, open **Tools → Range the pole**, wait for "Tracking", and check the pole height (the menu sets 8, 10 or 12 ft; a measured height is better).
4. Hold the crosshair on the pole's base. Turn the dial (or use − / + for 0.1 m) until the top of the white plumb line meets the top of the orange band. Pinch to zoom if it helps; zoom doesn't change the range.
5. Tap **Lock**. Read the range, ±, height difference and flag check, enter the taped distance and a note, and tap **Log this lock**. **Re-range** and do three locks per distance.
6. **Reticle log → Export CSV**. Each row keeps the line length in sensor pixels, focal length, angle below level, bearing and GPS, so ranges can be recomputed later.

What to look for: error within about 2σ of the shown ± (the spec's 1σ for an 8 ft pole on the 4K wide camera is about 2 cm, 16 cm, 63 cm and 1.4 m at 10/30/60/90 m); repeat locks agreeing; flag check under 10 m; the height difference sign on sloped ground; the plumb line staying plumb as you roll the phone.

No phone handy? The Simulator (or **Tools → Simulated camera for ranging**) shows a pole 40 m away with the crosshair on its base. Dial to about 40.1 m, tap **Use the simulated scene's flag point**, then **Lock** to walk through the whole flow.

## Milestone 2 field test: multi-photo cross-check

Optional. The reticle is the main method; this independent solve is a cross-check, kept in **Tools → Multi-photo cross-check**.

Goal: check the fused range, its ± estimate, the height difference and the flag check at real distances.

1. Set up one plumb flag with its height measured. Stand at the pole and use **Multi-photo cross-check → Save my GPS position as the flag point** (wait for GPS accuracy of ±5 m or better).
2. Tape out 10, 30, 60 and 90 m. Note if the ground slopes; measure the height difference if you can.
3. At each distance, open **Multi-photo cross-check**, wait for "Tracking", and take photo 1 at the taped spot. Mark tip and base, tap **Use photo**.
4. Step sideways across the line, one step at a time, taking 2–4 more photos until the baseline bar fills (3 m).
5. Read the result, enter the taped distance and a note, and tap **Log this ranging**. Do three rangings per distance.
6. Try one deliberately bad mark (base tapped on the grass beside the pole) to see the outlier drop.
7. **Multi-photo log → Export** both the CSV and the full JSON. The JSON keeps every photo's pose and marks, so the solver can be re-tuned without going back outside.

What to look for: error within about 2σ of the shown ±; "Photo agreement" Good on clean marks; flag check under 10 m; height difference sign and size on sloped ground.

Ranging uses the standard wide (1×) camera by choice. ARKit can also track on the telephoto camera on iPhones that offer it, which would help on long holes; that's a later option. If you have poles of different heights, repeat at 60 and 90 m with each to confirm taller poles range better.

No phone handy? Turn on **Tools → Simulated camera for ranging** (always on in the Simulator). It renders a pole 40 m away from known poses, so you can walk through capture, marking, the solver, the flag check (tap **Use the simulated scene's flag point**) and the log.

# Milestone 1 field test: sighting the pole

Goal: find out how precisely a player can mark a pole's tip and base, and how good a single-photo size range is, at 10–90 m on each lens.

## What you need

- One flag set up per [FLAG_KIT.md](FLAG_KIT.md), plumb and with its height measured in the app.
- A long tape or measuring wheel.
- Your phone height while sighting, entered in the app's settings (default 1.5 m).

## Procedure

1. Mark taped distances from the pole: **10, 30, 60 and 90 m**. Keep the ground as level as you can for now; slope correction comes later.
2. At each distance, on the 1× (wide) lens, the one the app ranges with:
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
