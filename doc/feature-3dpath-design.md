# 3D Path Feature Design

## Scope

Phase 1 adds an external `3D Path` dialog per flight without changing the main dashboard grid.

## Coordinate Convention

- X = longitude.
- Y = latitude.
- Z = altitude.
- The convention follows the existing map panel data direction.
- Drone attitude visualization is deferred to Phase 2. If no existing attitude convention is reusable, Phase 2 will use aerospace yaw-pitch-roll order `R = Rz(yaw) * Ry(pitch) * Rx(roll)` and document it in code.

## Phase 1 Behavior

- Main board control bar includes `3D 경로`.
- Dialog is hidden and reused, not recreated on every open.
- Full trajectory is rendered once as a dotted line.
- Past trajectory up to the current time is rendered as a solid overlay.
- Waypoints from `Option#.dat` are rendered as bold points when present.
- Missing or invalid waypoint rows are skipped and logged.
- Board-off hides open 3D Path dialogs and restores them when board-on returns.
- `.fdproj` round-trip stores only desired dialog visibility in Phase 1.

## Deferred

- Drone body patch and RGB body axes.
- Edit Dialog 3D Path subsection.
- Axis range project persistence.
- ATR `K-PATH3D` automated test category.
