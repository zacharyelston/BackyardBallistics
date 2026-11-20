# GeoZones

Shared geometry, zone monitoring and map drawing for SpudGunGolf and Squadz.

- **CoreGeo** is SpudGunGolf's existing `GeoPoint`, `GeoPolygon` and local distance helpers, moved without changes. Both apps now compile this single source.
- **ZoneKit** adds validated circle and polygon shapes, labeled zone definitions, and `ZoneTracker<Subject>`. It depends only on CoreGeo and Foundation. Subject IDs can be any hashable type; there are no squad, golf, safety, scoring, notification or networking dependencies.
- **ZoneMapKit** provides SwiftUI `ZoneMapShape` and `ZoneShape.mapOverlay()` for UIKit/AppKit maps. Each app supplies its own colors and interaction.

SpudGunGolf uses the shared CoreGeo types and map drawing for course boundaries and goal rings. Its safety, score and arrival rules remain in their existing modules. Squadz adds member selection, commander-owned definitions, shared event history and notification delivery around the same geometry.

The transition tracker establishes an initial baseline silently, then requires two distinct fresh position reports beyond `max(3 m, GPS accuracy)` on the other side of a boundary. A goal reports arrival; an allowed area reports departure. Staying on the same side does not repeat the event. Uncertain, invalid, stale, duplicate and out-of-order fixes cannot confirm a crossing. After a gap over 120 seconds or an explicit reconnect/reset, it establishes a new baseline. Editing a definition resets its baseline. The tracker does not run background location or deliver notifications.

Shapes cover local areas away from the poles and date line. Circle radii are 10–10,000 metres; polygons have 3–64 vertices within 50 km, with no self intersections or zero-length edges.

Run `swift test --package-path Packages/GeoZones` from the BackyardBallistics repository.
