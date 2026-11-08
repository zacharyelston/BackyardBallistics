import Foundation

/// `spud-mesh`'s command line.
public struct MeshCommand: Equatable, Sendable {
    /// Object Capture's model detail levels.
    public enum Detail: String, CaseIterable, Sendable { case reduced, medium, full, raw }

    public var photos: URL
    public var course: URL
    public var name: String?
    public var detail: Detail = .medium
    public var out: URL?
    public var dryRun = false

    public static let usage = """
        spud-mesh: photos of a backyard course to a georeferenced 3D mesh for the Theater host.

        Usage:
          spud-mesh <photos-folder> --course <course.yaml> [--name NAME]
                    [--detail reduced|medium|full|raw] [--out <FieldStore root>] [--dry-run]

          <photos-folder>   JPEG/HEIC photos with GPS (see docs/MESHING.md for how to shoot them)
          --course FILE     the course file; its hole 1 flag (or first boundary vertex) is the frame origin
          --name NAME       a label for the mesh (default: the folder's name)
          --detail LEVEL    Object Capture detail (default: medium)
          --out DIR         FieldStore root (default: ~/Library/Application Support/SpudTheater/Fields)
          --dry-run         read the photos' GPS and print the plan; don't run photogrammetry
          -h, --help        show this help

        Writes <out>/<courseID>/meshes/<uuid>/{mesh.usdz, mesh.json}. The mesh is display only:
        nothing in it feeds a firing solution.
        """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case help
        case message(String)
        public var description: String {
            switch self {
            case .help: return MeshCommand.usage
            case .message(let m): return "\(m)\nRun spud-mesh --help for usage."
            }
        }
    }

    public init(photos: URL, course: URL, name: String? = nil, detail: Detail = .medium, out: URL? = nil, dryRun: Bool = false) {
        self.photos = photos
        self.course = course
        self.name = name
        self.detail = detail
        self.out = out
        self.dryRun = dryRun
    }

    /// Parses the arguments after the program name.
    public static func parse(_ args: [String]) throws -> MeshCommand {
        var photos: String?, course: String?, name: String?, out: String?
        var detail = Detail.medium, dryRun = false
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("--") else { throw ParseError.message("\(flag) needs a value.") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help": throw ParseError.help
            case "--course": course = try value(a)
            case "--name": name = try value(a)
            case "--out": out = try value(a)
            case "--dry-run": dryRun = true
            case "--detail":
                let v = try value(a)
                guard let d = Detail(rawValue: v.lowercased()) else {
                    throw ParseError.message("--detail must be one of \(Detail.allCases.map(\.rawValue).joined(separator: ", ")), not \(v).")
                }
                detail = d
            default:
                if a.hasPrefix("-") { throw ParseError.message("Unknown option \(a).") }
                guard photos == nil else { throw ParseError.message("Only one photos folder, please (got \(photos!) and \(a)).") }
                photos = a
            }
            i += 1
        }
        guard let photos else { throw ParseError.message("Give the folder of photos.") }
        guard let course else { throw ParseError.message("Give the course file with --course.") }
        func fileURL(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return MeshCommand(photos: fileURL(photos), course: fileURL(course), name: name, detail: detail,
                           out: out.map(fileURL), dryRun: dryRun)
    }
}
