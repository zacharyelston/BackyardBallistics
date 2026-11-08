import Foundation
import CourseKit

/// The course the app is playing: your own bundled course (courses/local/course.yaml, never in git),
/// the bundled sample, a course surveyed on this device, the course server's file, or a typed URL.
/// The last course that passed every check is cached as JSON and restored on launch, so a round
/// can start without the course Wi-Fi. Restored courses are re-validated against today's limits.
@MainActor
final class CourseStore: ObservableObject {
    enum Source: Codable, Equatable {
        case bundledSample
        /// courses/local/course.yaml, bundled at build time when present.
        case bundledLocal
        /// Made with Tools → Survey a course on this device.
        case surveyed
        case url(URL)

        var label: String {
            switch self {
            case .bundledSample: return "Bundled sample"
            case .bundledLocal: return "Your bundled course"
            case .surveyed: return "Surveyed on this device"
            case let .url(url): return url.absoluteString
            }
        }
    }

    struct Loaded: Codable, Equatable {
        var result: CourseLoadResult
        var source: Source
        var loadedAt: Date
        /// True when this came from the on-device cache rather than a fresh read.
        var fromCache = false
    }

    /// The file a course server serves on the course's local Wi-Fi.
    nonisolated static let courseServerURL = URL(string: "http://spudgungolf.local/course.yaml")!

    /// What's loaded now, problems and all.
    @Published private(set) var loaded: Loaded?
    /// A download that failed before there was a file to check (no network, 404, …).
    @Published private(set) var fetchError: String?
    @Published private(set) var isFetching = false

    /// The course to play, only if it passed every check. Mission screens read this.
    var playableCourse: Course? { loaded?.result.playableCourse }
    /// The course for practice: playable, or refused only for problems practice can live with (a fan
    /// leaving the boundary, a firing point past the solution range).
    var practiceCourse: Course? { loaded?.result.practiceCourse }

    private let cacheURL: URL

    init(cacheFileName: String = "course-cache.json") {
        cacheURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFileName)
        if !restoreCache() && !loadBundledLocal() { loadBundledSample() }
    }

    // MARK: Loading

    func loadBundledSample() {
        fetchError = nil
        guard let url = Bundle.main.url(forResource: "sample-course", withExtension: "yaml"),
              let data = try? Data(contentsOf: url) else {
            fetchError = "The sample course is missing from the app bundle."
            return
        }
        accept(CourseFile.load(data: data), from: .bundledSample)
    }

    /// Your own course from courses/local/course.yaml, if the build bundled one.
    nonisolated static var bundledLocalURL: URL? {
        Bundle.main.url(forResource: "course", withExtension: "yaml", subdirectory: "local")
    }

    /// Loads your bundled course. False when the build has none.
    @discardableResult
    func loadBundledLocal() -> Bool {
        guard let url = Self.bundledLocalURL, let data = try? Data(contentsOf: url) else { return false }
        fetchError = nil
        accept(CourseFile.load(data: data), from: .bundledLocal)
        return true
    }

    /// Checks and loads a course file written on this device (the course survey).
    func loadSurveyed(_ text: String) {
        fetchError = nil
        accept(CourseFile.load(text), from: .surveyed)
    }

    /// Downloads and checks a course file. Keeps the current course if the download fails.
    func fetch(from url: URL = CourseStore.courseServerURL) async {
        guard url.scheme == "http" || url.scheme == "https" else {
            fetchError = "Use an http:// or https:// address."
            return
        }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("text/yaml, text/plain", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                fetchError = "The server answered \(http.statusCode) for \(url.absoluteString)."
                return
            }
            accept(CourseFile.load(data: data), from: .url(url))
        } catch {
            fetchError = "Couldn't download the course: \(error.localizedDescription)"
        }
    }

    /// Typed addresses: a bare host such as `spudgungolf.local` means its `/course.yaml` over http.
    nonisolated static func url(fromTyped text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var parts = URLComponents(string: withScheme), parts.host?.isEmpty == false else { return nil }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/course.yaml" }
        return parts.url
    }

    private func accept(_ result: CourseLoadResult, from source: Source) {
        let next = Loaded(result: result, source: source, loadedAt: Date())
        loaded = next
        if result.practiceCourse != nil { saveCache(next) }
    }

    // MARK: Cache

    private func saveCache(_ loaded: Loaded) {
        guard let data = try? JSONEncoder().encode(loaded) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func restoreCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              var cached = try? JSONDecoder().decode(Loaded.self, from: data),
              let course = cached.result.course,
              cached.source != .bundledSample, cached.source != .bundledLocal else { return false } // the bundle's copy is always current
        // Re-check: the safety limits may have changed since this course was cached.
        cached.result = CourseLoadResult(course: course, problems: CourseValidator.problems(for: course))
        cached.fromCache = true
        loaded = cached
        return true
    }
}
