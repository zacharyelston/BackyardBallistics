import Foundation
import CoreGeo
import FieldKit

/// Bare-earth heights for a course from USGS 3DEP (public domain), cached per course in the
/// `FieldStore` so each course is fetched once. 3DEP covers the US only: elsewhere every sample
/// comes back NaN, and the 3D view says so and draws flat ground.
///
/// The 3DEP ImageServer's `getSamples` does the work, a few hundred points per request. If it
/// fails, the Elevation Point Query Service is asked point by point on a coarser grid (at most
/// `pointQueryLimit` points), which is slow but a separate service.
struct ElevationService: Sendable {
    var store = FieldStore(root: FieldStore.defaultRoot)
    var session: URLSession = .shared
    /// Metres between samples on a yard-sized course; coarsened so a big one stays under `maxSamples`.
    var preferredSpacing = 2.5
    var maxSamples = 12_000
    /// EPQS answers in several seconds a point, so its fallback grid is small (about 10 × 10).
    var pointQueryLimit = 100
    /// `getSamples` requests in flight at once.
    var concurrency = 4

    enum Failure: LocalizedError {
        case http(Int)
        case noBoundary
        case unreachable
        case refused(String)
        var errorDescription: String? {
            switch self {
            case let .http(code): return "The USGS elevation service answered HTTP \(code)."
            case .noBoundary: return "The course has no boundary to fetch heights for."
            case .unreachable: return "The USGS elevation services couldn't be reached."
            case let .refused(why): return "USGS 3DEP refused the request (\(why))."
            }
        }
    }

    /// The cached grid for the course if it still covers `boundary`, else a fresh one from USGS (then cached).
    func grid(courseID: String, boundary: [GeoPoint]) async throws -> (grid: ElevationGrid, cached: Bool) {
        if let cached = cachedGrid(courseID: courseID), cached.covers(boundary) { return (cached, true) }
        let grid = try await fetch(boundary: boundary)
        try? save(grid, courseID: courseID)
        return (grid, false)
    }

    func cachedGrid(courseID: String) -> ElevationGrid? {
        guard let data = try? Data(contentsOf: store.elevationURL(courseID: courseID)) else { return nil }
        return try? ElevationGrid.decodeJSON(data)
    }

    func save(_ grid: ElevationGrid, courseID: String) throws {
        let url = store.elevationURL(courseID: courseID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try grid.encodedJSON().write(to: url, options: .atomic)
    }

    /// Samples a grid over `boundary` (with ElevationGrid's default margin). The frame's origin is the
    /// middle of the boundary; its altitude is set to the lowest height found, so the ground sits at
    /// scene y ≥ 0 (or 0 when there is no data).
    func fetch(boundary: [GeoPoint]) async throws -> ElevationGrid {
        guard !boundary.isEmpty else { throw Failure.noBoundary }
        var frame = ElevationGrid.frame(covering: boundary)
        var spacing = ElevationGrid.spacing(covering: boundary, frame: frame, preferred: preferredSpacing, maxSamples: maxSamples)
        var s = ElevationGrid.samplePoints(covering: boundary, frame: frame, spacing: spacing)
        var heights: [Double]
        do {
            heights = try await samples(s.points)
        } catch {
            // The bulk service is down, or refused because nothing here is covered. Ask the point
            // service about the middle first (it takes seconds a point): no height there means no
            // coverage, so don't wait for the rest. Otherwise sample a coarser grid point by point.
            spacing = ElevationGrid.spacing(covering: boundary, frame: frame, preferred: spacing, maxSamples: pointQueryLimit)
            s = ElevationGrid.samplePoints(covering: boundary, frame: frame, spacing: spacing)
            if try await pointQueries([frame.origin])[0].isNaN {
                heights = Array(repeating: .nan, count: s.points.count)
            } else {
                heights = try await pointQueries(s.points)
            }
        }
        let valid = heights.filter { !$0.isNaN }
        frame.originAltitude = valid.min() ?? 0
        return ElevationGrid(frame: frame, southWest: s.southWest, spacing: spacing, columns: s.columns, rows: s.rows,
                             heights: heights, source: USGSElevation.source)
    }

    /// 3DEP `getSamples`, batched, `concurrency` requests at a time. Heights in request order, NaN for no data.
    ///
    /// The service leaves out single points it has no data for, but answers a batch with *no* covered
    /// point with an error ("Invalid or missing input parameters"), the same as a bad request. So an
    /// erroring batch counts as no data, unless every batch errors: then this throws, and `fetch`
    /// asks EPQS instead, which tells "outside the US" (no value) from "broken" (no answer).
    func samples(_ points: [GeoPoint]) async throws -> [Double] {
        let batches = stride(from: 0, to: points.count, by: USGSElevation.batchSize).map {
            ($0, Array(points[$0..<min($0 + USGSElevation.batchSize, points.count)]))
        }
        var out = Array(repeating: Double.nan, count: points.count)
        var next = 0
        var answered = 0
        var refusal: String?
        try await withThrowingTaskGroup(of: (Int, Result<[Double], USGSElevation.ParseError>).self) { group in
            func addNext() {
                guard next < batches.count else { return }
                let (start, batch) = batches[next]
                next += 1
                group.addTask { (start, try await self.sampleBatch(batch)) }
            }
            for _ in 0..<concurrency { addNext() }
            while let (start, result) = try await group.next() {
                switch result {
                case let .success(h):
                    out.replaceSubrange(start..<(start + h.count), with: h)
                    answered += 1
                case let .failure(e):
                    if case let .serviceError(m) = e { refusal = m } else { refusal = "unreadable answer" }
                }
                addNext()
            }
        }
        if answered == 0, let refusal { throw Failure.refused(refusal) }
        return out
    }

    /// One `getSamples` request. Network and HTTP errors throw (after one retry); the service's own
    /// error answer comes back as a failure (see `samples`).
    private func sampleBatch(_ points: [GeoPoint]) async throws -> Result<[Double], USGSElevation.ParseError> {
        var request = URLRequest(url: USGSElevation.samplesURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = USGSElevation.samplesBody(points)
        // One retry: the service sometimes drops a request under load.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.http(code) }
                do {
                    return .success(try USGSElevation.parseSamples(data, count: points.count))
                } catch let e as USGSElevation.ParseError {
                    return .failure(e)
                }
            } catch where attempt == 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw Failure.unreachable   // not reached
    }

    /// EPQS, one point per request, ten at a time.
    func pointQueries(_ points: [GeoPoint]) async throws -> [Double] {
        var out = Array(repeating: Double.nan, count: points.count)
        var next = 0
        var failures = 0
        await withTaskGroup(of: (Int, Double?).self) { group in
            func addNext() {
                guard next < points.count else { return }
                let i = next
                next += 1
                group.addTask {
                    guard let (data, response) = try? await self.session.data(from: USGSElevation.pointQuery(points[i])),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return (i, nil) }
                    return (i, USGSElevation.parsePointQuery(data))
                }
            }
            for _ in 0..<10 { addNext() }
            while let (i, h) = await group.next() {
                if let h { out[i] = h } else { failures += 1 }
                addNext()
            }
        }
        // Every request failing is a network problem, not "no data here".
        if failures == points.count { throw Failure.unreachable }
        return out
    }
}
