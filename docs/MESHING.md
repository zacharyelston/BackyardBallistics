# Meshing a backyard course

`spud-mesh` turns a folder of photos of a course into a georeferenced 3D mesh for the Theater
host. It runs Apple's Object Capture (RealityKit's `PhotogrammetrySession`) on an Apple silicon
Mac, then places the mesh in the course's frame from the photos' GPS. The Theater app shows the
mesh as a picture of the yard. **It is display only**: nothing in it feeds a firing solution or
SafetyKit, and ranges still come only from cleared locks ([THEATER_MODE.md](THEATER_MODE.md), Safety, rule 5).

## Shooting the photos

You need a phone with the Camera app's location turned on (iPhone: Settings → Privacy & Security →
Location Services → Camera → While Using). Every photo has to carry GPS; photos without it are
still used for the shape, but only geotagged ones place it.

- **50–200 photos** for a typical yard. More helps with trees and fences; past about 300 it only
  slows things down.
- **Walk the boundary first**, all the way round, camera pointed inwards at the yard, a photo
  every two or three steps. Then walk one or two lines across the middle. The GPS fit needs the
  cameras spread over the yard, not along one path, and the tool refuses photos taken in a line.
- **Overlap**: each photo should share about 70% of its view with the one before it. Turn slowly;
  don't jump.
- **Hold the phone at chest height** and keep it there. Unless the GPS is very good, the tool
  assumes every photo was taken about 1.5 m above the ground (see below).
- **Light**: an overcast day is best. Avoid low sun, hard shadows and wet, shiny grass. Nobody
  walking through the shots.
- Shoot the flags and firing points in place, and a few closer photos of anything you care about
  in the 3D view (the hole, a hazard edge).
- Plain photos are fine; HEIC or JPEG, no Live Photos or portrait mode needed. Don't edit or crop
  them, and copy them to the Mac without stripping location (AirDrop with **Options → All Photos
  Data**, or Image Capture).

## Running it on the host

On the Theater host (an Apple silicon MacBook Pro), from the repo:

```sh
# Check the photos and see the plan first: reads GPS only, takes seconds.
swift run --package-path Packages/SpudCore spud-mesh ~/Pictures/elm-st-spring \
    --course courses/sample-course.yaml --dry-run

# Build the mesh. `medium` takes minutes for 100 photos; `full` and `raw` take longer and are bigger.
swift run -c release --package-path Packages/SpudCore spud-mesh ~/Pictures/elm-st-spring \
    --course courses/sample-course.yaml --name "Spring" --detail medium
```

Options: `--name` labels the mesh (default: the folder's name), `--detail reduced|medium|full|raw`
(default `medium`), `--out DIR` writes to another FieldStore root, `--dry-run` stops after the plan.

It writes `~/Library/Application Support/SpudTheater/Fields/<courseID>/meshes/<uuid>/` with
`mesh.usdz` and `mesh.json` (the frame, the transform from mesh coordinates to the course's ENU
metres, the image count and the fit's RMS), where the Theater app finds it. Each run makes a new
mesh; the newest is shown first.

## How it is placed, and how to read the summary

The course file sets the frame: east-north-up metres from hole 1's flag (or the boundary's first
vertex if there are no holes). Object Capture also reports where each camera was; the tool fits
the scale, rotation and offset that best put those cameras on their GPS positions, weighting each
photo by 1/accuracy² from its EXIF position error, and drops a photo whose GPS is far off from the
rest (it is named in the summary).

Phone GPS height is poor, so by default the fit is **horizontal**: it trusts east and north, and
takes the cameras as level at chest height. That is right for a roughly flat yard; on a steep one
the mesh can come out tilted by about the yard's slope. Only if every photo has an altitude and a
position error of 3 m or better does it fit in 3D.

The summary prints the images, the poses used, the scale and the **RMS** in metres: how far the
cameras sit from their GPS on average. With phone GPS, 2–5 m is normal. More than 5 m prints a
warning; check that the flags in the mesh line up with the course map before relying on it.

If it refuses: fewer than 3 photos with GPS (turn on location for Camera), or the photos lie in a
line (walk the boundary). If Object Capture itself fails, take more photos with more overlap.
