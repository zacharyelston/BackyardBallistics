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
                    if let m = play.mission {
                        LabeledContent("Mission \(m.number)", value: String(format: "%.1f m at %03.0f°", m.lockedRange, m.bearing))
                        LabeledContent("Rounds", value: "\(play.roundsFired) of \(HoleRules.maxRoundsPerHole)")
                    } else {
                        Text("Waiting for a lock from the firing point: a member ranges the pole and the lock appears below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let v = play.verdict {
                        LabeledContent("Verified", value: String(format: "%.1f m · score %.1f", v.closest, v.score))
                    }
                    downrangeRow
                    HStack {
                        if play.phase == .firing && !round.walkingOut {
                            Button("Cease fire") { command.ceaseFire() }.buttonStyle(.bordered)
                        }
                        if play.phase == .ceased && play.verdict != nil {
                            Button("Finish hole") { command.finishHole() }.buttonStyle(.borderedProminent)
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
