import SwiftUI
import CourseKit

/// The loaded course: its holes and pars, the distance from each firing point to its flag, and
/// anything the validator found. Also where a course is downloaded from the course Wi-Fi.
struct CourseView: View {
    @EnvironmentObject private var store: CourseStore
    @State private var typedURL = ""

    var body: some View {
        List {
            if let loaded = store.loaded {
                summary(loaded)
                if !loaded.result.problems.isEmpty { problems(loaded.result) }
                if let course = loaded.result.course {
                    ForEach(course.holes) { h in hole(h) }
                }
            } else {
                Section { Text("No course loaded.").foregroundStyle(.secondary) }
            }
            loadSection
        }
        .navigationTitle("Course")
        .refreshable { await store.fetch() }
    }

    // MARK: Sections

    private func summary(_ loaded: CourseStore.Loaded) -> some View {
        Section {
            if let course = loaded.result.course {
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.name).font(.title3.weight(.semibold))
                    Text("\(course.holes.count) holes · par \(course.totalPar)" + (course.difficulty.map { " · \($0)" } ?? ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                LabeledContent("Course id", value: "\(course.id) v\(course.version)")
            } else {
                Text("This file doesn't describe a course.").font(.headline)
            }
            LabeledContent("Status") { status(loaded.result) }
            LabeledContent("From", value: loaded.source.label)
                .lineLimit(1).truncationMode(.middle)
            LabeledContent(loaded.fromCache ? "Cached" : "Loaded",
                           value: loaded.loadedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func status(_ result: CourseLoadResult) -> some View {
        let ok = result.playableCourse != nil
        return Text(ok ? "Ready to play" : "Refused")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2), in: Capsule())
    }

    private func problems(_ result: CourseLoadResult) -> some View {
        Section {
            ForEach(Array(result.problems.enumerated()), id: \.offset) { _, problem in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.message).font(.footnote)
                        if problem.line != nil || problem.key != nil {
                            Text([problem.line.map { "Line \($0)" }, problem.key].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: problem.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(problem.severity == .error ? .red : .orange)
                }
            }
        } header: {
            Text("Problems (\(result.errors.count) errors, \(result.warnings.count) warnings)")
        } footer: {
            Text("A course with any error is refused. Fix the file on the course server and reload.")
        }
    }

    private func hole(_ hole: Hole) -> some View {
        Section {
            ForEach(Array(hole.firingDistances.enumerated()), id: \.offset) { index, distance in
                LabeledContent("Firing point \(index + 1)") {
                    Text("\(Units.metres(distance)) · \(Units.yards(distance))").monospacedDigit()
                }
            }
            LabeledContent("Pole", value: "\(Units.feetInches(hole.flag.poleHeightM)) · lean \(String(format: "%.1f°", hole.flag.leanDeg))")
            LabeledContent("Ring radius", value: Units.metres(hole.flag.inRadiusM))
            if let lid = hole.lidDiameterM { LabeledContent("Lid", value: Units.metres(lid)) }
            if !hole.hazards.isEmpty {
                LabeledContent("Hazards", value: hole.hazards.map { $0.kind.label }.joined(separator: ", "))
            }
            if hole.downrangePlay {
                Label("Downrange play: fire again from your closest round", systemImage: "arrow.up.forward")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hole \(hole.number) · \(hole.name) · par \(hole.par)")
        }
    }

    private var loadSection: some View {
        Section {
            Button {
                Task { await store.fetch() }
            } label: {
                Label("Download from the course Wi-Fi", systemImage: "wifi")
            }
            HStack {
                TextField("Course file address", text: $typedURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(loadTyped)
                Button("Load", action: loadTyped)
                    .disabled(CourseStore.url(fromTyped: typedURL) == nil)
            }
            Button {
                store.loadBundledSample()
            } label: {
                Label("Use the bundled sample course", systemImage: "doc.text")
            }
            if store.isFetching {
                HStack { ProgressView(); Text("Downloading…").foregroundStyle(.secondary) }
            }
            if let error = store.fetchError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Load a course")
        } footer: {
            Text("The course server is \(CourseStore.courseServerURL.absoluteString). The last course that passed every check is kept for offline play.")
        }
    }

    private func loadTyped() {
        guard let url = CourseStore.url(fromTyped: typedURL) else { return }
        Task { await store.fetch(from: url) }
    }
}

private extension Hazard.Kind {
    var label: String {
        switch self {
        case .water: return "water"
        case .sand: return "sand"
        case .ob: return "out of bounds"
        }
    }
}
