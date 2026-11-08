# 5. Theater (v4, in design)

[Back to How to play](README.md)

Theater is the course owner's view: a station that watches every squad on the course, with the field built up from what members observe.

What works today:

- **SpudTheater** (macOS) finds squads on the network and watches one with its join code.
- It shows the squad's course on satellite imagery, members' positions, and the squad leader's latest orders, with pins for orders that have a place.
- It's read-only: it can't act on a squad.

Planned: course-wide holds and check fire for the owner, and a GPU mapping back end that builds the 3D field. See [THEATER_MODE.md](../THEATER_MODE.md).
