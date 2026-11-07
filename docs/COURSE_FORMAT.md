# Course file format

A course is one static YAML file, `course.yaml`, served by any plain web server on the course's local Wi-Fi at `http://spudgungolf.local/course.yaml`. The course registry lists where each course's file lives.

## Key layout

Every line is one flat, dotted key with one value, like an SNMP OID. The path says what the value is, so files are easy to hand-edit, diff and parse.

- Positions are `latitude, longitude` in decimal degrees (WGS 84). Survey each point by averaging GPS for about 60 seconds.
- Lengths are metres; angles are degrees.
- `N`, `M` and `K` are 1, 2, 3 and so on.

| Key | Example | Required | Notes |
| --- | --- | --- | --- |
| `course.meta.format` | `1` | Yes | Version of this key layout |
| `course.meta.id` | `elm-st` | Yes | Unique in the registry |
| `course.meta.name` | `Elm Street Backyard` | Yes | |
| `course.meta.version` | `3` | Yes | Bump whenever anything moves |
| `course.meta.difficulty` | `easy` | No | The designer's own label |
| `course.boundary.N` | `42.360010, -71.059010` | Yes | Property-line corners, in order |
| `hole.N.meta.name` | `The Driveway` | Yes | |
| `hole.N.meta.par` | `4` | Yes | |
| `hole.N.start.M` | `42.360120, -71.058880` | Yes | One or more start spots |
| `hole.N.flag.position` | `42.360950, -71.058810` | Yes | Lid centre |
| `hole.N.flag.pole_height_m` | `2.438` | Yes | Measured with the app at setup |
| `hole.N.flag.lean_deg` | `0.3` | Yes | From the lean check |
| `hole.N.lid.diameter_m` | `0.58` | Yes | |
| `hole.N.hazard.K.type` | `water` | No | `water`, `sand` or `ob` |
| `hole.N.hazard.K.points` | `42.36051, -71.05899; …` | No | Corners, separated by semicolons |

A full example is in [`courses/sample-course.yaml`](../courses/sample-course.yaml).

## Validation

The app validates a course file in the course tool before it's published, and again whenever a player loads it. A course that fails is refused. It checks:

- Every required key is present and parses.
- Every flag has a measured pole height and a lean under 0.5°.
- Every start spot has its lid within 100 yd, or a reachable lay-up.
- The safety fan from every start spot (105 yd, ±30° of the line to the lid) stays inside `course.boundary` (`Safety.checkFan` in SafetyKit).

The server only serves the file. Rounds stay on the players' phones.
