import SwiftUI
import CoreGeo
import SafetyKit
import RangingKit
import BallisticsKit
import CourseKit
import RoundKit

/// One hole, played as fire missions from the firing point:
/// confirm downrange → range the pole → initial data → fire and spot, with fire control's corrections →
/// cease fire → walk out and verify → finish, resume, or fire the next mission from the closest round.
///
/// Practice plays the same flow with simulated rounds on the course's geometry. Real missions get their
/// initial data only through `Safety.clearSolution`, which holds them until a launcher profile exists.
struct HoleMissionView: View {
    @EnvironmentObject private var rounds: RoundStore
    @AppStorage(Settings.playerNameKey) private var player = Settings.defaultPlayerName

    /// The player's wind estimate, fed to the firing computer.
    @State private var windSpeed = 0.0
    @State private var windFrom = 0.0
    @State private var chargeName: String?
    @State private var arc: Arc?
    /// The call and left/right miss being entered for the next round.
    @State private var call: RangeCall?
    @State private var lateral = 0.0
    @State private var message: String?
    /// Live: ceased fire, walking out to verify (the hole isn't scored until the distance is in).
    @State private var verifying = false
    @State private var verifyDistance: Double?
    @State private var ranging: RangingPurpose?
    @State private var measuring = false

    enum RangingPurpose: Identifiable {
        case firstMission, nextMission
        var id: Self { self }
    }

    private var active: RoundStore.Active? { rounds.active }
    private var practice: Bool { active?.practice ?? false }
    private var hole: Hole? { active?.currentHole }
    private var play: HolePlay? { active?.hole }

    var body: some View {
        Group {
            if let hole, let play {
                List {
                    switch play.phase {
                    case .setup: setupSections(hole)
                    case .firing:
                        if verifying { verifySections(hole, play) } else { firingSections(hole, play) }
                    case .ceased: verdictSections(hole, play)
                    case .finished: finishedSection(hole, play)
                    }
                    roundsSection(play)
                }
            } else {
                ContentUnavailableView("No hole in play", systemImage: "flag.slash")
            }
        }
        .toolbar(.hidden, for: .tabBar) // the floating tab bar would cover the buttons
        .onAppear {
            rounds.startNextHole()
            if let a = active, a.practicePending != nil { lateral = a.practicePendingLateral ?? 0 }
        }
        .navigationTitle(hole.map { "Hole \($0.number)" + (practice ? " · Practice" : "") } ?? "Hole")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $ranging) { purpose in
            if let hole {
                ReticleRangingView(mission: MissionRangingContext(
                    title: purpose == .firstMission ? "Range from the firing point" : "Range from your closest round",
                    poleHeight: hole.flag.poleHeightM, flag: hole.flag.position) { lock in
                        useLock(lock, purpose: purpose, hole: hole)
                    })
            }
        }
        .fullScreenCover(isPresented: $measuring) {
            if let m = play?.mission {
                CrosshairSpotView(range: m.lockedRange) { lateral = ($0 * 10).rounded() / 10 }
            }
        }
    }

    // MARK: Setup

    @ViewBuilder private func setupSections(_ hole: Hole) -> some View {
        Section {
            LabeledContent("Name", value: hole.name)
            LabeledContent("Par", value: "\(hole.par)")
            if hole.firingPoints.count > 1 {
                Picker("Firing point", selection: firingPointBinding) {
                    ForEach(Array(hole.firingDistances.enumerated()), id: \.offset) { i, d in
                        Text("\(i + 1) · \(Units.metres(d))").tag(i)
                    }
                }
            } else if let d = hole.firingDistances.first {
                LabeledContent("From the firing point", value: "\(Units.metres(d)) · \(Units.yards(d))")
            }
            LabeledContent("Pole", value: Units.feetInches(hole.flag.poleHeightM))
            LabeledContent("Ring", value: String(format: "%.1f m radius", hole.flag.inRadiusM))
            LabeledContent("Downrange play", value: hole.downrangePlay ? "Yes" : "No")
        } header: {
            Text(hole.name)
        } footer: {
            Text(hole.downrangePlay
                 ? "After a cease fire you may fire the next mission from your closest round."
                 : "Every round on this hole is fired from the firing point.")
        }

        if !practice {
            Section {
                Toggle(DownrangeLog.prompt, isOn: downrangeBinding(hole))
            } header: {
                Text("Confirm downrange")
            } footer: {
                Text("Needed before the firing computer will give initial data on this hole.")
            }
        }

        Section {
            if practice {
                Button {
                    practiceLock(hole: hole, from: firingOrigin(hole), purpose: .firstMission)
                } label: {
                    Label("Range the pole (simulated)", systemImage: "scope").font(.headline)
                }
            } else {
                Button {
                    ranging = .firstMission
                } label: {
                    Label("Range the pole", systemImage: "scope").font(.headline)
                }
            }
        } footer: {
            Text(practice
                 ? "Practice locks the range with the error of a frozen full-resolution still."
                 : "Crosshair on the base, dial the plumb line to the top of the orange band, Freeze, fine-match, Lock. The lock must land within 10 m of this hole's flag.")
        }
    }

    private var firingPointBinding: Binding<Int> {
        Binding(get: { active?.firingPoint ?? 0 }, set: { v in rounds.update { $0.firingPoint = v } })
    }

    private func downrangeBinding(_ hole: Hole) -> Binding<Bool> {
        Binding(get: { active?.downrange.isConfirmed(player: player, hole: hole.number) ?? false },
                set: { on in if on { rounds.update { $0.downrange.confirm(player: player, hole: hole.number) } } })
    }

    // MARK: Firing

    @ViewBuilder private func firingSections(_ hole: Hole, _ play: HolePlay) -> some View {
        if let m = play.mission {
            Section {
                LabeledContent("Locked range", value: "\(Units.metres(m.lockedRange)) · \(Units.yards(m.lockedRange))")
                LabeledContent("Aim range", value: Units.metres(m.fireControl.aimRange))
                if abs(m.fireControl.lateralCorrection) >= 0.05 {
                    LabeledContent("Aim off", value: sideText(m.fireControl.lateralCorrection))
                }
                LabeledContent("Rounds", value: "\(play.roundsFired) of \(HoleRules.maxRoundsPerHole)")
            } header: {
                Text(m.number == 1 ? "Mission 1 · from the firing point" : "Mission \(m.number) · from your closest round")
            }

            // Solve once per update; both sections use the same table.
            let t = table(m)
            firingDataSection(hole, play, m, t)
            spotSection(hole, play, m, canFire: chosen(t) != nil)

            Section {
                Button(role: .destructive) {
                    ceaseFire(hole, play)
                } label: {
                    Label("Cease fire", systemImage: "hand.raised.fill").frame(maxWidth: .infinity)
                }
                .disabled(play.roundsFired == 0 || active?.practicePending != nil)
            } footer: {
                Text("Cease fire when a round looks in, or when you'd rather walk out and take what you have.")
            }
        }
    }

    private var windEstimate: Wind { Wind(speed: windSpeed, fromBearing: windFrom) }

    private func table(_ m: Mission) -> [Solution] {
        let a = m.aimPoint
        return Solver.table(target: Ground(a.east, a.north), wind: windEstimate, landHeight: m.heightDifference)
    }

    private func chosen(_ table: [Solution]) -> Solution? {
        if let chargeName, let arc, let s = table.first(where: { $0.charge.name == chargeName && $0.arc == arc && $0.ok }) { return s }
        return InitialData.recommended(table)
    }

    @ViewBuilder private func firingDataSection(_ hole: Hole, _ play: HolePlay, _ m: Mission, _ t: [Solution]) -> some View {
        let pick = chosen(t)
        Section {
            HStack {
                Text("Wind")
                Spacer()
                Text(windSpeed < 0.05 ? "Calm" : String(format: "%.1f m/s from %@", windSpeed, compass(windFrom)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $windSpeed, in: 0...6, step: 0.5) { Text("Wind speed") }
            if windSpeed >= 0.05 {
                Picker("From", selection: $windFrom) {
                    ForEach(Array(stride(from: 0.0, to: 360, by: 45)), id: \.self) { Text(compass($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let s = pick {
                if practice {
                    solutionRows(s)
                } else {
                    switch clear(s, hole: hole, play: play, m: m) {
                    case .success(let cleared): solutionRows(cleared.value)
                    case .failure(let block):
                        ForEach(Array(block.reasons.enumerated()), id: \.offset) { _, r in
                            Label(r.description, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                Menu {
                    ForEach(t.filter(\.ok), id: \.menuID) { s in
                        Button("Charge \(s.charge.name) · \(s.arc.label) · \(String(format: "%.1f°", s.elevation))") {
                            chargeName = s.charge.name; arc = s.arc
                        }
                    }
                } label: {
                    Label("Charge \(s.charge.name) · \(s.arc.label)", systemImage: "slider.horizontal.3")
                }
            } else {
                Text("No charge reaches this aim point.").foregroundStyle(.orange)
            }
        } header: {
            Text(play.roundsFired == 0 ? "Initial data" : "Firing data")
        } footer: {
            Text(practice
                 ? "Practice uses the game's launcher model. The real wind is hidden: set your estimate and let fire control take out the rest."
                 : "Uncalibrated charges until calibration shots (milestone 5). Every solution goes through the safety checks.")
        }
    }

    private func clear(_ s: Solution, hole: Hole, play: HolePlay, m: Mission) -> Result<Cleared<Solution>, SafetyBlock> {
        Safety.clearSolution(s, distance: m.fireControl.aimRange, muzzleVelocity: s.charge.velocity,
                             launcher: LauncherProfile.current, roundID: active?.card.id.uuidString ?? "",
                             downrange: active?.downrange ?? DownrangeLog(), player: player, hole: hole.number)
    }

    @ViewBuilder private func solutionRows(_ s: Solution) -> some View {
        LabeledContent("Elevation", value: String(format: "%.1f°", s.elevation)).font(.title3.weight(.semibold))
        LabeledContent("Aim", value: abs(s.aimOffset) < 0.05 ? "On the line" : String(format: "%.1f° %@", abs(s.aimOffset), s.aimOffset > 0 ? "right" : "left"))
        LabeledContent("Time of flight", value: String(format: "%.1f s", s.timeOfFlight))
        LabeledContent("Predicted rest", value: s.miss < 0.05 ? "On the pole" : String(format: "%.1f m from the pole", s.miss))
    }

    @ViewBuilder private func spotSection(_ hole: Hole, _ play: HolePlay, _ m: Mission, canFire: Bool) -> some View {
        Section {
            // From the saved round, so it survives a relaunch.
            if active?.practicePending == nil, let last = play.missionRounds.last, let ad = last.addDrop, let rl = last.rightLeft {
                Text("Fire control: \(correctionText(addDrop: ad, rightLeft: rl))")
                    .font(.headline).foregroundStyle(.orange)
            }
            if practice, let a = active, !a.practiceRests.isEmpty || a.practicePending != nil { PracticeSketch(active: a, hole: hole) }
            if practice && active?.practicePending == nil {
                Button {
                    practiceFire(hole: hole, play: play, m: m)
                } label: {
                    Label("Fire (simulated)", systemImage: "flame").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(play.atRoundLimit || !canFire)
            } else {
                Picker("Call", selection: $call) {
                    ForEach(RangeCall.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Left/right")
                    Spacer()
                    Text(abs(lateral) < 0.05 ? "On line" : sideText(lateral)).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("Left/right", value: $lateral, in: -20...20, step: 0.1).labelsHidden()
                }
                if !practice {
                    Button { measuring = true } label: { Label("Measure with the crosshair", systemImage: "scope") }
                }
                Button {
                    recordSpot()
                } label: {
                    Text("Record round \(play.roundsFired + 1)").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(call == nil || play.atRoundLimit)
                if !practice {
                    Button("Round lost (water, over the fence, not found)") { recordLost() }
                        .disabled(play.atRoundLimit)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Spot round \(play.roundsFired + 1)")
        } footer: {
            Text("Call long/short by eye: short, over, or range correct. Left/right is measured: + right of the pole.")
        }
    }

    // MARK: Verify and verdict

    @ViewBuilder private func verifySections(_ hole: Hole, _ play: HolePlay) -> some View {
        Section {
            Text("Everyone walks out together. Find your closest round and range the pole from it, or tape it.")
            LabeledContent("Closest round to the pole") {
                HStack {
                    TextField("m", value: $verifyDistance, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                    Text("m")
                }
            }
            Button("Score with this distance") { scoreVerified(verifyDistance) }
                .disabled(verifyDistance == nil)
            Button("It's in the ring") { scoreVerified(min(verifyDistance ?? 0, hole.flag.inRadiusM)) }
            Button("No round found") { scoreVerified(nil) }
            Button("Back to firing") { verifying = false }
        } header: {
            Text("Ceased fire · verify")
        }
    }

    @ViewBuilder private func verdictSections(_ hole: Hole, _ play: HolePlay) -> some View {
        if let v = play.verdict {
            Section {
                if practice, let a = active, !a.practiceRests.isEmpty { PracticeSketch(active: a, hole: hole) }
                Text(v.inRing ? (play.roundsFired == 1 ? "First-round hit!" : "Hit on round \(play.roundsFired)") : "Ceased fire")
                    .font(.title2.weight(.bold))
                LabeledContent("Closest round", value: Units.metres(v.closest) + (v.inRing ? " · in the ring" : ""))
                Text(sumText(play, v)).monospacedDigit()
            }
            Section {
                if v.canAdvance {
                    Button {
                        advance(hole, play)
                    } label: {
                        Label("Next mission from your closest round", systemImage: "arrow.up.forward")
                            .font(v.preferAdvance ? .headline : .body)
                    }
                }
                Button {
                    finish()
                } label: {
                    Text(v.canAdvance ? String(format: "Finish hole at %.1f", v.score) : "Finish hole")
                        .font(v.preferAdvance ? .body : .headline)
                }
                if v.canResume {
                    Button("Resume firing from the same spot") {
                        rounds.update { try? $0.hole?.resume() }
                        message = "Resumed: same mission, same rounds."
                    }
                }
            } footer: {
                if !v.canResume && !v.inRing { Text("Ten rounds fired: this hole is done.") }
            }
        }
    }

    @ViewBuilder private func finishedSection(_ hole: Hole, _ play: HolePlay) -> some View {
        Section {
            Text(String(format: "Hole %d: %.1f on a par %d", hole.number, play.score ?? 0, hole.par)).font(.title3.weight(.semibold))
            if let a = active, a.card.isComplete {
                Text(String(format: "Round complete: %.1f against par %d.", a.card.total, a.card.totalPar))
            } else {
                Button {
                    resetForNextHole()
                    rounds.startNextHole()
                } label: {
                    Label("Next hole", systemImage: "arrow.right").font(.headline)
                }
            }
        }
    }

    @ViewBuilder private func roundsSection(_ play: HolePlay) -> some View {
        if !play.rounds.isEmpty {
            Section("Rounds on this hole") {
                ForEach(play.rounds.reversed()) { r in
                    HStack {
                        Text("\(r.number)").font(.headline.monospacedDigit()).frame(width: 24)
                        if let s = r.spot {
                            Text(s.call.label)
                            Text(abs(s.lateral) < 0.05 ? "on line" : sideText(s.lateral)).foregroundStyle(.secondary)
                        } else {
                            Text("Lost").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if play.missions.count > 1 { Text("M\(r.mission)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: Actions

    private func useLock(_ lock: ReticleLock, purpose: RangingPurpose, hole: Hole) {
        let en = lock.eastNorth
        // The firing computer only takes a range that SafetyKit has checked against the course flag.
        guard case .success(let cleared) = Safety.clearRange(lock, lie: lock.location, east: en.east, north: en.north,
                                                            flag: hole.flag.position) else { return }
        let l = cleared.value
        rounds.update { a in
            if purpose == .firstMission {
                try? a.hole?.begin(lockedRange: l.range, bearing: l.bearing, heightDifference: l.heightDifference, from: l.location)
            } else {
                try? a.hole?.advance(lockedRange: l.range, bearing: l.bearing, heightDifference: l.heightDifference, from: l.location)
            }
        }
        resetForMission()
        ranging = nil
    }

    private func practiceRange(hole: Hole, salt: UInt64) -> PracticeRange {
        let seed = (active?.seed ?? 1) &+ UInt64(hole.number) &* 1_000_003 &+ UInt64(play?.roundsFired ?? 0) &* 7919 &+ salt
        return PracticeRange(pole: poleLocal(hole), poleHeight: hole.flag.poleHeightM,
                             wind: PracticeRange.randomWind(seed: (active?.seed ?? 1) &+ UInt64(hole.number)), seed: seed)
    }

    private func firingOrigin(_ hole: Hole) -> Ground { .zero }

    /// The pole in the practice frame: metres east/north of the chosen firing point.
    private func poleLocal(_ hole: Hole) -> Ground {
        let fp = hole.firingPoints[min(active?.firingPoint ?? 0, hole.firingPoints.count - 1)]
        let en = Geo.eastNorth(of: hole.flag.position, from: fp)
        return Ground(en.east, en.north)
    }

    private func practiceLock(hole: Hole, from: Ground, purpose: RangingPurpose) {
        var r = practiceRange(hole: hole, salt: purpose == .firstMission ? 11 : 13)
        let l = r.lock(from: from)
        rounds.update { a in
            a.practiceOrigins.append(from)
            if purpose == .firstMission {
                try? a.hole?.begin(lockedRange: l.range, bearing: l.bearing, from: nil)
            } else {
                try? a.hole?.advance(lockedRange: l.range, bearing: l.bearing, from: nil)
            }
        }
        resetForMission()
        message = String(format: "Locked %@ ± %@.", Units.metres(l.range), Units.metres(l.sigma))
    }

    private func practiceFire(hole: Hole, play: HolePlay, m: Mission) {
        guard let s = chosen(table(m)), let origin = active?.practiceOrigins.last else { return }
        var r = practiceRange(hole: hole, salt: 17)
        let shot = r.fire(s, from: origin)
        let fp = hole.firingPoints[min(active?.firingPoint ?? 0, hole.firingPoints.count - 1)]
        let where_ = Geo.offset(fp, east: shot.rest.x, north: shot.rest.y)
        if let hz = hole.hazards.first(where: { ($0.kind == .water || $0.kind == .ob) && $0.area.contains(where_) }) {
            rounds.update { a in
                a.practiceRests.append(shot.rest)
                try? a.hole?.recordLost()
            }
            message = hz.kind == .water ? "Splash: that round is lost in the water." : "Over the fence: that round is lost."
            return
        }
        // The crosshair measures left/right; the long/short call is the player's.
        lateral = (r.spot(rest: shot.rest, from: origin).lateral * 10).rounded() / 10
        call = nil
        rounds.update { a in
            a.practicePending = shot.rest
            a.practicePendingLateral = lateral
        }
        message = "Round \(play.roundsFired + 1) is down. Look at the sketch and call it."
    }

    private func recordSpot() {
        guard let call else { return }
        rounds.update { a in
            let recorded = (try? a.hole?.record(Spot(call: call, lateral: lateral))) != nil
            if recorded, let p = a.practicePending { a.practiceRests.append(p) }
            a.practicePending = nil
        }
        message = nil
        self.call = nil
        lateral = 0
        if let p = rounds.active?.hole, p.atRoundLimit {
            message = "Ten rounds fired: cease fire."
        } else if call == .rangeCorrect, abs(lateralOfLast()) <= (hole?.flag.inRadiusM ?? 1) {
            message = "Looks in! Cease fire to verify."
        }
    }

    private func lateralOfLast() -> Double { rounds.active?.hole?.rounds.last?.spot?.lateral ?? .infinity }

    private func recordLost() {
        rounds.update { try? $0.hole?.recordLost() }
        message = "Lost round counted. Fire control stays where it was."
    }

    private func ceaseFire(_ hole: Hole, _ play: HolePlay) {
        if practice {
            // Walk out: the exact distance of the closest round that wasn't lost.
            let pole = poleLocal(hole)
            let found = zip(play.rounds, active?.practiceRests ?? []).filter { !$0.0.lost }.map { length($0.1 - pole) }
            rounds.update { try? $0.hole?.ceaseFire(closest: found.min()) }
        } else {
            verifying = true
            verifyDistance = nil
        }
    }

    private func scoreVerified(_ d: Double?) {
        rounds.update { try? $0.hole?.ceaseFire(closest: d) }
        verifying = false
    }

    private func advance(_ hole: Hole, _ play: HolePlay) {
        if practice {
            let pole = poleLocal(hole)
            let rests = zip(play.rounds, active?.practiceRests ?? []).filter { !$0.0.lost }.map(\.1)
            guard let closest = rests.min(by: { length($0 - pole) < length($1 - pole) }) else { return }
            practiceLock(hole: hole, from: closest, purpose: .nextMission)
        } else {
            ranging = .nextMission
        }
    }

    private func finish() {
        rounds.update { try? $0.hole?.finish() }
        rounds.recordFinishedHole()
    }

    private func resetForMission() {
        call = nil
        lateral = 0
        chargeName = nil
        arc = nil
    }

    private func resetForNextHole() {
        resetForMission()
        message = nil
        verifying = false
        windSpeed = 0
    }

    // MARK: Text

    private func length(_ p: Ground) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }

    private func sideText(_ v: Double) -> String { String(format: "%@ %.1f m", v > 0 ? "right" : "left", abs(v)) }

    private func correctionText(addDrop: Double, rightLeft: Double) -> String {
        let ad = abs(addDrop) < 0.05 ? "range stays" : String(format: "%@ %.1f m", addDrop > 0 ? "add" : "drop", abs(addDrop))
        let rl = abs(rightLeft) < 0.05 ? "line stays" : sideText(rightLeft)
        return "\(ad), \(rl)"
    }

    private func sumText(_ play: HolePlay, _ v: HoleVerdict) -> String {
        let r = "\(play.roundsFired) round\(play.roundsFired == 1 ? "" : "s")"
        return v.inRing ? String(format: "%@ = %.1f", r, v.score)
                        : String(format: "%@ + %.1f m outside the ring = %.1f", r, v.outsideRing, v.score)
    }

    private func compass(_ b: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((b / 45).rounded()) % 8]
    }
}

private extension Solution {
    var menuID: String { "\(charge.name)-\(arc.rawValue)" }
}

/// Practice only: the rounds around the pole, turned so the line from the firing position points up.
/// Short is below the pole, over above, right is right.
struct PracticeSketch: View {
    let active: RoundStore.Active
    let hole: Hole

    var body: some View {
        Canvas { ctx, size in
            guard let play = active.hole, let origin = active.practiceOrigins.last else { return }
            let fp = hole.firingPoints[min(active.firingPoint, hole.firingPoints.count - 1)]
            let en = Geo.eastNorth(of: hole.flag.position, from: fp)
            let pole = Ground(en.east, en.north)
            let line = pole - origin
            let d = max(0.01, (line.x * line.x + line.y * line.y).squareRoot())
            let u = line / d, n = Ground(u.y, -u.x)
            let rests = active.practiceRests + (active.practicePending.map { [$0] } ?? [])
            let far = rests.map { r -> Double in let m = r - pole; return max(abs((m * u).sum()), abs((m * n).sum())) }.max() ?? 0
            let span = max(hole.flag.inRadiusM * 3, min(far * 1.25, 40))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let s = min(size.width, size.height) / 2 / span
            func pt(_ g: Ground) -> CGPoint {
                let m = g - pole
                return CGPoint(x: c.x + (m * n).sum() * s, y: c.y - (m * u).sum() * s)
            }
            let r = hole.flag.inRadiusM * s
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.green.opacity(0.18)))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.green), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.orange))
            var arrow = Path()
            arrow.move(to: CGPoint(x: c.x, y: size.height - 4)); arrow.addLine(to: CGPoint(x: c.x, y: size.height - 22))
            ctx.stroke(arrow, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text("from you").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: c.x + 30, y: size.height - 10))
            for (i, rest) in rests.enumerated() {
                let p = pt(rest)
                let lost = i < play.rounds.count ? play.rounds[i].lost : false
                let latest = i == rests.count - 1
                let dot = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                if lost {
                    ctx.stroke(Path(ellipseIn: dot), with: .color(.blue), lineWidth: 1.5)
                } else {
                    ctx.fill(Path(ellipseIn: dot), with: .color(latest ? .brown : .brown.opacity(0.5)))
                }
                ctx.draw(Text("\(i + 1)").font(.caption2.bold()), at: CGPoint(x: p.x + 10, y: p.y - 8))
            }
            ctx.draw(Text(String(format: "±%.0f m", span)).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: 26, y: 10))
        }
        .frame(height: 220)
        .accessibilityLabel("Sketch of the rounds around the pole")
    }
}
