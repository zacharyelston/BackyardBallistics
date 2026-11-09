# 5. Theater (v4, partly built)

[Back to How to play](README.md)

Theater is the course owner's view: a station that watches every squad on the course, keeps the course's fields, and takes notes, fields and photos from players' phones.

What works today:

- **SpudTheater** (macOS) finds squads on the network and watches one with its join code. It shows the squad's course on satellite imagery, members' positions, the squad's phase and holds, the leader's orders, and field notes, with pins for orders and notes that have a place.
- **Watching is read-only.** It can't act on a squad, and no firing data reaches it.
- **Fields.** The Theater keeps every course it's given as a field: imported from a course file with **+**, from a squad it watches, or sent from a phone. A newer version replaces the old one, which is kept. **Forget field** moves the field's folder aside; nothing is deleted.
- **Send to Theater.** The Theater shows its own six-character code. On a phone, with no squad needed: Field → Send a field note (pick **Theater**), Field → Survey a course → **Send to Theater**, or Field → Capture a target → **Send to Theater** once a capture is saved. Pick the Theater, enter its code once, and send. Each item shows **received**, **stored** or **refused**. Notes and files are saved under their field's folder. **New code** on the Theater drops connected phones, and each phone needs the new code.
- **3D view.** The toolbar switches between the map and the course in 3D on the ground's real shape (USGS 3DEP heights, US only; flat ground elsewhere). It shows the boundary, the poles and rings, the firing points, every safety fan, members, and any field meshes saved for the course. Drag to orbit, scroll or pinch to zoom.
- **Field meshes.** `spud-mesh` on the Mac turns photos of the course into a mesh for the 3D view. See [MESHING.md](../MESHING.md). A mesh is a picture only: it never feeds a range or a solution.

Planned: locks, spots and scores in the feed, course-wide holds and check fire for the owner, and a GPU mapping back end that builds the field. See [THEATER_MODE.md](../THEATER_MODE.md).
