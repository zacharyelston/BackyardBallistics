# 4. Safety

[Back to How to play](README.md)

Low-power launchers only, inanimate targets, on your own property. Every limit lives in one place in the code (SafetyKit), and these numbers are read from it.

## The limits (safety limits v{{safety.version}})

| Limit | Value |
| --- | --- |
| Longest solution | {{safety.maxSolutionRangeM}} m ({{safety.maxSolutionRangeYd}} yd) |
| Fastest charge setting | {{safety.maxMuzzleVelocityMS}} m/s |
| A range lock must land within | {{safety.flagGateToleranceM}} m of the course's flag |
| Safety fan from each firing point | {{safety.fanRangeM}} m ({{safety.fanRangeYd}} yd), ±{{safety.fanHalfAngleDeg}}° of the line to the hole, all inside the boundary |

## How the app keeps to them

- **One gate.** A range or a solution reaches the screen only after SafetyKit has checked it. There's no other path, and the device that shows firing data runs the checks itself.
- **Downrange is a person's call.** Before the first shot on a hole, someone has to answer *{{safety.downrangePrompt}}* by tapping on the device that shows the firing data. No message from another device can answer it.
- **Squads only add holds.** Holds pause firing data and never lift a safety check. **Check fire** from any device stops everyone, and each commander confirms downrange again afterwards.
- **Phones never show firing data.** They send positions, locks, spot calls and order answers. The commander's iPad checks each one.
- **Every shot is within the limit.** On a hole with layup points, each leg is checked on its own: no leg may be longer than {{safety.maxSolutionRangeM}} m ({{safety.maxSolutionRangeYd}} yd), and each leg's safety fan must stay inside the boundary.
- **Practice fires nothing.** A course whose safety fan doesn't fit, or with a leg past {{safety.maxSolutionRangeM}} m, can still be used for practice and demos, but not for real rounds.
