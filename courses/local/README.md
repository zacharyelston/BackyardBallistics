# Local course (not in git)

Put your own course here as `course.yaml` to make it the app's default course on every device you build for. Git ignores everything in this folder except this README, so your property's coordinates stay out of the public repo.

The easiest way to make one: in the app, **Tools → Survey a course**. Record the pole's base, the firing point and the boundary corners, check that it validates, then **Share course file** and AirDrop it here as `courses/local/course.yaml`. Rebuild, and the app loads it on a fresh install instead of the Elm Street sample.
