# 3D Path Feature Design

## Scope

The 3D Path feature adds an external dialog per flight without changing the main dashboard grid.

## Coordinate Source

- Body position is not read from a separate `# WayPoint` section.
- Body position comes from the loaded flight data columns selected by `Option#.dat` `# RequiredColumns`:
  - `Lon` -> X
  - `Lat` -> Y
  - `Alt` -> Z
- This is the same position/altitude source used by the main `Map` and `Altitude` panels.
- `Option#.dat` therefore controls body position by mapping `Lat`, `Lon`, and `Alt` to the correct flight-data columns.

## Coordinate Convention

- X = longitude.
- Y = latitude.
- Z = altitude.
- The convention follows the existing map panel data direction.
- Full and past trajectories use the mapped body position series.

## Optional Waypoints

- `# WayPoint` is optional reference/annotation data.
- Waypoints are rendered as separate bold points.
- Waypoints do not replace the body position trajectory.
- Missing or invalid waypoint rows are skipped and logged.

## Drone Attitude

- Phase 2 adds a lightweight drone glyph using `hgtransform`, a quad patch, and RGB body axes.
- Attitude source priority:
  1. Optional `# BodyAttitude` mappings if all configured columns exist.
  2. Fallback to `RequiredColumns` `Roll`, `Pitch`, and `Heading`.
- `# BodyAttitude` must reference attitude angle columns, not body position columns and not angular-rate columns.
- Rotation convention is yaw-pitch-roll:
  `R = Rz(yaw) * Ry(pitch) * Rx(roll)`.
- Heading/yaw is converted from NED heading semantics to the 3D path ENU-style view direction before rendering.
- If no valid attitude source exists, the glyph remains at the correct body position with identity rotation.

## Rendering Policy

- Full trajectory is rendered once as a dotted decimated line.
- Past trajectory up to the current time is rendered as a solid decimated overlay.
- Current body pose is updated by changing existing graphic object data/matrices, not by recreating objects.
- The drone glyph uses a uniform visual scale to avoid attitude-axis distortion across mixed degree/meter units.

## Board-Off And Project State

- Board-off hides open 3D Path dialogs.
- Board-on restores dialogs only when the stored desired visibility state is true.
- `.fdproj` layout state stores desired `Path3DVisible` as a backward-compatible 1x2 logical value.

## Automated Test Coverage

- ATR `K-PATH3D` cases are appended after existing panel-capture cases to avoid shifting established case numbers.
- Test state exposes desired/actual visibility, axes validity, full/past trajectory counts, X/Y/Z consistency, finite data checks, drone transform validity, and body-axis validity.
