# 1. Playing a hole

[Back to How to play](README.md)

## Before the round

- **Load a course.** Field → Course loads the bundled course, the course server on your Wi-Fi, or a typed address. A course passes every check, or it's refused. A course whose only problems are a safety fan that leaves the boundary, or a shot longer than {{safety.maxSolutionRangeM}} m ({{safety.maxSolutionRangeYd}} yd), is **practice only**: you can practise on it, but not play real rounds.
- **Set up each flag.** A pole is {{flags.poleHeightMinM}} to {{flags.poleHeightMaxM}} m tall, with less than {{flags.maxLeanDeg}}° of lean (Field → Check pole lean, then Measure pole height). The ring around it is {{flags.defaultRingM}} m unless the course says otherwise, at most {{flags.maxRingM}} m.
- **Your own place?** Field → Survey a course records the pole's base, the firing point and the boundary corners with averaged GPS.
- **Long holes have layup points.** A hole longer than one shot gets marker poles between the firing point and the flag. Each leg (firing point to the first layup, layup to layup, the last layup to the flag) is one shot, so each must be within {{safety.maxSolutionRangeM}} m ({{safety.maxSolutionRangeYd}} yd), with its safety fan inside the boundary. Survey a course shows each leg's length and where to add a layup.

## A hole, step by step

1. **Confirm downrange.** Before the first shot on every hole: *{{safety.downrangePrompt}}*
2. **Range the pole.** Put the crosshair on the pole's base and turn the dial until the plumb line meets the top of the pole. Freeze, fine-tune on the still, and Lock. The lock is checked against the course's flag: it must land within {{safety.flagGateToleranceM}} m of it.
3. **Initial data.** Fire control solves the shot. Solutions only appear after the safety checks, and real ones stay held until your launcher is calibrated. Practice mode needs no launcher.
4. **Fire and spot.** Watch each round and call it {{range_calls}}. Left and right are measured with the crosshair.
5. **Let fire control correct.** The first range step is the larger of 2 m and 6% of the range ({{rules.fireControlStepAt30m}} m at 30 m, {{rules.fireControlStepAt60m}} m at 60 m). Once a round lands the other side of the pole, the step halves each time, down to {{rules.fireControlMinStepM}} m. Left and right correct by the average miss so far.
6. **Cease fire** when a round is in the ring, or when another round won't help. The {{rules.maxRoundsPerHole}}th round on a hole forces a cease fire.
7. **Walk out and verify.** Everyone goes downrange together. Range the pole from the closest round, or tape it.

## Scoring

Score = rounds fired + metres the closest round finished outside the ring.

For example, {{rules.scoreExample.rounds}} rounds with the closest at {{rules.scoreExample.closestM}} m from the pole and a {{rules.scoreExample.inRadiusM}} m ring scores **{{rules.scoreExample.score}}**.

**Layups.** A layup pole has no ring and isn't scored. Range it, fire at it, cease fire, then range the next pole from your closest round and fire the next leg. Only the flag's leg is scored by the ring. If the round limit ends the hole on a layup leg, the distance still to go to the flag counts as the miss.

On a **downrange** hole you may fire the next mission from your closest round instead of finishing. The app suggests it when the round is {{rules.preferAdvanceGainM}} m or more outside the ring.

## Practice

Play → Practice with simulated rounds plays the whole flow with simulated rounds on the course's real geometry. Nothing is fired.
