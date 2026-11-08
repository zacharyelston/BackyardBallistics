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
| `course.boundary.N` | `42.360010, -71.059010` | Yes | Property-line corners, in order; include neighbouring land only with its owner's agreement |
| `hole.N.meta.name` | `The Driveway` | Yes | |
| `hole.N.meta.par` | `3` | Yes | Rounds a good player needs to land one in the ring |
| `hole.N.meta.downrange_play` | `false` | No | `true` lets players fire further missions from their closest round; default `false` |
| `hole.N.firing_point.M` | `42.360120, -71.058880` | Yes | One or more; farther points make harder versions of the hole |
| `hole.N.flag.position` | `42.360950, -71.058810` | Yes | Base of the pole: the hole |
| `hole.N.flag.pole_height_m` | `2.438` | Yes | Measured with the app at setup |
| `hole.N.flag.lean_deg` | `0.3` | Yes | From the lean check |
| `hole.N.flag.in_radius_m` | `1.0` | No | Ring radius around the pole; default 1.0 m |
| `hole.N.lid.diameter_m` | `0.58` | No | Optional lid at the base; audible only |
| `hole.N.hazard.K.type` | `water` | No | `water`, `sand` or `ob` |
| `hole.N.hazard.K.points` | `42.36051, -71.05899; …` | No | Corners, separated by semicolons |

A full example is in [`courses/sample-course.yaml`](../courses/sample-course.yaml).

## Reading the file

The app reads the file with its own small parser (`CourseFile` in CourseKit), not a YAML library, so only this layout works:

- The file is UTF-8 text, at most 256 KB. Unix or Windows line endings both work.
- Each line is blank, a comment or `key: value`. The key ends at the first colon, so values may contain colons. Spaces around the key and value are ignored, and one pair of matching quotes around a value is dropped (`name: "Elm St: Back"` reads `Elm St: Back`).
- A comment is a whole line starting with `#`. A `#` later in a line is part of the value.
- Keys use lower-case letters, digits, `_` and `.` only.
- `N`, `M` and `K` start at 1 and run without gaps or leading zeros: `hole.01`, `hole.0` and a missing `hole.2` beside `hole.3` are all errors.
- Numbers are plain decimals such as `2.438` or `-71.05901`; no exponents, `nan` or `inf`. Whole-number keys (`format`, `version`, `par`) take whole numbers only.
- `downrange_play` is `true` or `false`.
- A position is `latitude, longitude`, with latitude within ±90 and longitude within ±180.
- Hazard points need at least 3 corners; a trailing semicolon is fine.
- A key that appears twice is an error, and the first value is kept for showing the course.
- An unknown key is a warning and is ignored, so the course still loads.
- `course.meta.format` must be `1`. A file in any other format is refused without reading the rest.

## Validation

## Validation

The app validates a course file in the course tool before it's published, and again whenever a player loads it, including a course restored from the phone's cache. A course with any error is refused; warnings don't stop play. Each problem names its line and key where it has one. The checks (`CourseValidator` in CourseKit):

- Every required key is present and parses, as above.
- The boundary has at least 3 corners, and the course has at least one hole.
- Every hole has a name, a par of 1 or more, and at least one firing point.
- Every flag has a measured pole height between 2.33 and 3.76 m (the flag kit's 8 to 12 ft poles, with 10 cm of slack for measurement) and a lean of at least 0° and under 0.5°.
- A ring radius, if given, is over 0 and at most 5 m. A lid diameter, if given, is over 0 and under 2 m.
- Every flag and every firing point is inside `course.boundary`.
- Every firing point is at least 1 m from its flag and has its hole within 100 yd (`maxSolutionRange` in SafetyKit).
- The safety fan from every firing point (105 yd, ±30° of the line to the hole) stays inside `course.boundary` (`Safety.checkFan` in SafetyKit).

A 105 yd fan is wide: about 96 m across at ±30°, so a firing point needs roughly 48 m of property either side of the line to its hole and 96 m beyond it. Hazards aren't checked against the boundary, since an `ob` area may follow it.

The server only serves the file. Rounds stay on the players' phones.
