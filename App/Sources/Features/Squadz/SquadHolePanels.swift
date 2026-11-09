import SwiftUI
import CoreGeo
import SafetyKit
import RangingKit
import CourseKit
import RoundKit
import GroupKit

/// The hole in play on the commander's iPad: open it from a firing point, confirm downrange
/// (the commander's own tap), and follow its phase. The iPad is the squad's firing display, so it
/// shows the locked range; firing data itself only ever comes through `Safety.clearSolution` and
/// `GroupGate`, and stays held while no launcher profile conforms.
struct SquadHolePanel: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var firingPoint = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let host = command.host {
                let round = host.round
                Text("Hole").font(.headline)
                if let play = round.hole, play.phase != .finished, let hole = round.currentHole {
                    LabeledContent("Hole \(hole.number)", value: "\(hole.name) · par \(hole.par)")
                    LabeledContent("Firing point", value: "\(round.firingPoint + 1) of \(hole.firingPoints.count)")
                    LabeledContent("Phase", value: Self.phase(play.phase, walkingOut: round.walkingOut))
                    if play.legs > 1 {
                        legRow(hole: hole, play: play)
                    }
                    if let m = play.mission {
                        LabeledContent("Mission \(m.number)", value: String(format: "%.1f m at %03.0f°", m.lockedRange, m.bearing))
                        LabeledContent("Rounds", value: "\(play.roundsFired) of \(HoleRules.maxRoundsPerHole)")
                    } else {
                        Text(hole.layups.isEmpty
                             ? "Waiting for a lock from the firing point: a member ranges the pole and the lock appears below."
                             : "Waiting for a lock from the firing point: a member ranges layup 1's marker pole and the lock appears below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let v = play.verdict {
                        if play.onFlagLeg {
                            LabeledContent("Verified", value: String(format: "%.1f m · score %.1f", v.closest, v.score))
                        } else {
                            layupVerdict(v, hole: hole, play: play)
                        }
                    }
                    downrangeRow
                    if play.phase == .firing && !round.walkingOut {
                        roundInFlight(host, play: play)
                    }
                    HStack {
                        if play.phase == .firing && !round.walkingOut {
                            Button("Cease fire") { command.ceaseFire() }.buttonStyle(.bordered)
                        }
                        if play.phase == .ceased && play.verdict != nil {
                            if play.onFlagLeg {
                                Button("Finish hole") { command.finishHole() }.buttonStyle(.borderedProminent)
                            } else {
                                // Mid-hole on a layup leg: the next lock carries play on; ending here
                                // scores the distance still to go.
                                Button("End the hole here") { command.finishHole() }.buttonStyle(.bordered)
                            }
                        }
                    }
                } else if let next = round.currentHole {
                    Text("Next: hole \(next.number), \(next.name) · par \(next.par)").font(.subheadline)
                    if next.firingPoints.count > 1 {
                        Picker("Firing point", selection: $firingPoint) {
                            ForEach(next.firingPoints.indices, id: \.self) { i in
                                Text(String(format: "%d · %.0f m", i + 1, next.firingDistances[i])).tag(i)
                            }
                        }
                    } else if let d = next.firingDistances.first {
                        LabeledContent("Firing point", value: String(format: "1 · %.0f m to the flag", d))
                    }
                    if !next.layups.isEmpty {
                        Label("\(next.layups.count + 1) legs: \(Self.legNames(next))", systemImage: "mappin.and.ellipse")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        command.startNextHole(firingPoint: firingPoint)
                    } label: {
                        Label("Start hole \(next.number)", systemImage: "flag.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Every hole is finished. Total \(String(format: "%.1f", round.card.total)).")
                        .foregroundStyle(.secondary)
                }
                if let problem = host.lastProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Fired, then the members' calls for that round, and the commander records one (or Lost).
    @ViewBuilder private func roundInFlight(_ host: SquadHost, play: HolePlay) -> some View {
        if let n = host.roundInFlight {
            VStack(alignment: .leading, spacing: 6) {
                Label("Round \(n) in the air: spot calls", systemImage: "eye.fill").font(.subheadline.weight(.semibold))
                if host.spotReports.isEmpty {
                    Text("Waiting for members' calls…").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(host.spotReports, id: \.member) { spot in
                    let who = host.round.squad.members.first { $0.id == spot.member }?.name ?? "A member"
                    HStack {
                        Text("\(who): \(spot.report.call.label)").font(.footnote.weight(.semibold))
                        if let l = spot.report.lateral { Text(String(format: "%+.1f m", l)).font(.footnote).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Use") { command.commitSpot(from: spot.member) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                Button("Lost (not found)") { command.commitLost() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else if play.mission != nil, !play.atRoundLimit {
            Button {
                command.fired()
            } label: {
                Label("Fired round \(play.roundsFired + 1)", systemImage: "flame.fill")
            }
            .buttonStyle(.bordered).tint(.red)
            Text("Or the gunner calls Fired from their phone. Members then get the spotter card.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Which leg is in play on a hole with layups, and what it aims at.
    private func legRow(hole: Hole, play: HolePlay) -> some View {
        let t = hole.targets
        let target = t[min(play.targetIndex, t.count - 1)]
        return Label {
            Text("Leg \(min(play.targetIndex, t.count - 1) + 1) of \(play.legs): aiming at \(target.name)")
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: target.isFlag ? "flag.fill" : "mappin.and.ellipse")
        }
        .foregroundStyle(target.isFlag ? Color.primary : .orange)
    }

    /// Cease fire on a layup leg: no ring, no score yet. Play goes on from the closest round.
    @ViewBuilder private func layupVerdict(_ v: HoleVerdict, hole: Hole, play: HolePlay) -> some View {
        let t = hole.targets
        let i = min(play.targetIndex, t.count - 1)
        let here = t[i]
        let next = t[min(i + 1, t.count - 1)]
        let onward = play.onToFlag?[i] ?? 0
        LabeledContent("Closest to \(here.name)", value: String(format: "%.1f m", max(0, v.closest - onward)))
        if v.canAdvance {
            VStack(alignment: .leading, spacing: 4) {
                Label("Next leg: from the closest round toward \(next.name)", systemImage: "arrow.forward.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("A member stands at the closest round, ranges \(next.name)'s pole and sends it as Next mission. Use that lock and leg \(i + 2) starts from there.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(String(format: "No round found to go on from. Ending the hole here scores %.1f m still to go (score %.1f).", v.closest, v.score))
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    /// "layup 1 → layup 2 → the flag".
    static func legNames(_ hole: Hole) -> String {
        hole.targets.map(\.name).joined(separator: " → ")
    }

    @ViewBuilder private var downrangeRow: some View {
        if command.host?.isDownrangeConfirmed() == true {
            Label("Downrange confirmed", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    command.confirmDownrange()
                } label: {
                    Label("Confirm downrange", systemImage: "eye.fill")
                }
                .buttonStyle(.bordered)
                Text(DownrangeLog.prompt).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func phase(_ p: HolePlay.Phase, walkingOut: Bool) -> String {
        if walkingOut { return "Cease fire, walking out" }
        switch p {
        case .setup: return "Setting up: needs a lock"
        case .firing: return "Firing"
        case .ceased: return "Verifying"
        case .finished: return "Finished"
        }
    }
}

/// Locks from members' phones, newest first. Each is untrusted until the commander taps Use:
/// then this iPad recomputes it with the hole's pole height and runs `Safety.clearRange`.
struct SquadLocksPanel: View {
    @EnvironmentObject private var command: SquadCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Locks").font(.headline)
            if let host = command.host {
                let locks = Array(host.locks.reversed())
                if locks.isEmpty {
                    Text("No locks yet. When a member ranges the pole on their phone, the lock arrives here.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        VStack(spacing: 0) {
                            ForEach(locks, id: \.report.id) { lock in
                                row(lock, host: host, now: context.date)
                                if lock.report.id != locks.last?.report.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ received: ReceivedLock, host: SquadHost, now: Date) -> some View {
        let lock = received.report.lock
        let who = host.round.squad.members.first { $0.id == received.member }?.name ?? "A member"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(who) · \(Self.purpose(received.report.purpose))").font(.subheadline.weight(.semibold))
                Text(String(format: "%.1f m ± %.1f · %03.0f° · %@", lock.range, lock.sigma, lock.bearing, Self.age(lock.date, now: now)))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            switch received.status {
            case .received:
                Button("Use") { command.useLock(received.report.id) }
                    .buttonStyle(.borderedProminent)
            case .used:
                Label("Used", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
            case .refused:
                Label("Refused", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(.vertical, 8)
    }

    static func purpose(_ p: LockPurpose) -> String {
        switch p {
        case .initial: return "from the firing point"
        case .nextMission: return "next mission"
        case .verify: return "verify"
        case .observation: return "observation"
        }
    }

    static func age(_ d: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(d)))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}
