# Feature Design Review — "3D Path" (3D 경로) Panel

read-only design review. **No code changed.** Targets HEAD `2138a5a`
(`FlightDataDashboard.m` ~14.4k lines, `auto_test_runner.m`). Covers the 12 feature
requirements with integration points, data model, UI, behavior, risks, and phasing.

## Requirement → coverage map
| # | Requirement | Phase |
|---|---|---|
| 1 | "3D 경로" button next to Map button | 1 |
| 2 | `Option#.dat`: `wayPoint` + Body X/Y/Z | 1 (schema) |
| 3 | 3D path diagram (drone + red waypoints + black trajectory + RGB body axes) | 1/2 |
| 4 | X/Y = lat/lon aligned with Map panel, Z = altitude | 1 |
| 5 | init waypoint=bold dots, path=dashed; on time-change dashed→solid | 1 |
| 6 | no wayPoint -> omit bold dots | 1 |
| 7 | no Body X/Y/Z -> disable attitude feature | 2 |
| 8 | Edit dialog wiring for wayPoint + Body X/Y/Z | 1/2 |
| 9 | per-axis X/Y/Z min/max buttons | 3 |
| 10 | integrate with flight-play | 3 |
| 11 | drone model (3D or 2D) reflecting current attitude | 2 |
| 12 | auto-estimate Body axes from data (optional) | 4 |

## A. Existing integration points (verified)
- **Map button / control bar**: buttons created in `createLayout` at the `glCtrl` grid
  (`btnAtt` ~L12314, `btnMap` ~L12318, `btnVid` ~L12329). Toggle dispatch in
  `pushPanelToggleButton` (~L533) maps `'map'/'attitude'/'video'/'dataView'` ->
  `togglePanel(routeName)`. **Adding `btnPath3D` requires expanding `glCtrl` ColumnWidth**
  (already trimmed 11->9 col per v2-B) -> layout-grid regression surface.
- **Map panel**: `panelMapAlt` + `mapAxes` (`updateDashboard` ~L8388). Map already uses
  `hgtransform` (`hgMapPlane`) + `patch` for a heading-rotated plane glyph -> **precedent
  for a body glyph / drone marker and transform-based attitude**.
- **Coordinate columns**: `mappedCols.Lon/Lat/Alt/Time/Heading/Roll/Pitch` exist; Map plots
  `rawData.(mappedCols.Lon)` vs `.Lat` (E->x right, N->y up). 3D must reuse these for #4.
- **Option schema**: `parseOptionFileToDraft` returns `struct(sourcePath, mappedCols,
  displayMeta[header/unit/format/scale/order])`; `writeOptionFileAtomic` persists;
  `OptionDrafts{fIdx}` holds the live draft. `applyOptionFile`/`editDialogApplyOptionDraft`
  (~L7433) apply. **New `wayPoints` + `bodyAxes` need additive draft fields + parser/writer.**
- **Time-change events** (dashed->solid trigger): `applyTimeChange(fIdx,index)` (~L1238) is
  the central entry; calls `updateDashboard(fIdx,index)`. Lightweight drag path uses
  `updateMarkersOnly`. Slider/marker/video-sync all funnel through these. Play uses
  `onFlightPlayTimer -> applyTimeChange`. So **one hook in `updateDashboard` (+ `updateMarkersOnly`
  for drag) covers all triggers**.
- **Edit dialog**: `buildEditTabOptions` (~L6561), `buildEditTabProject` (~L6418),
  apply path `editDialogApplyOptionDraft` (~L7433). Existing validate/revert/immediate-apply
  pattern reusable.
- **Project save/load**: option drafts persist through `.fdproj` (UiState/option mapping).
  New fields must round-trip (collectCurrentProjectState/applyProjectState).

## B. Data model design
- **wayPoints** (additive to option draft):
  `Models(fIdx).option.wayPoints = struct array {lat, lon, alt, label(optional)}` or an Nx3
  numeric + labels cell. Source: explicit `wayPoint` rows in `Option#.dat` (column-mapped),
  or a separate section. Missing -> empty -> omit bold dots (#6).
- **Body axes**: `option.bodyAxes = struct('x',colName,'y',colName,'z',colName)` mapping to
  rawData columns. Two attitude representations to support:
  - direct unit vectors (3 columns each = 9 cols) -> build rotation matrix `W=[bx by bz]`.
  - OR reuse existing `Roll/Pitch/Heading` -> rotation matrix via Euler (simpler, fewer cols).
  Recommend: **prefer existing Heading/Roll/Pitch when present** (already mapped), treat
  explicit Body X/Y/Z as an override. Missing both -> disable attitude (#7).
- **Map coordinate parity (#4)**: reuse `mappedCols.Lon/Lat` exactly; x=lon, y=lat, z=alt;
  N-up/E-right matches Map. `daspect` and lat/lon bounds reuse the Map's `calculateBounds`.

## C. UI design
- **Panel**: `path3DPanel` with a single `uiaxes` (`View=[-37.5 30]`, 3D). Placement options:
  - (rec) **swap into the Map column slot via toggle** (like map/alt share `panelMapAlt`):
    reuse the existing column; least grid disruption. `btnPath3D` toggles map<->3D in that
    column. Avoids adding a new board column.
  - alt: dedicated new column -> high layout regression risk (hsplit/board-off column math).
- **Button**: `UI_temp(fIdx).btnPath3D` in `glCtrl`, label `'3D ▸/▾'`, dispatch route
  `'path3D'` in `pushPanelToggleButton` + `togglePanel`.
- **Graphics**: trajectory `line(LineStyle '--'->'-')`; waypoints `scatter3` bold markers
  (red); drone via `hgtransform` + `patch`/`surf` (reuse hgMapPlane precedent) or a small
  STL/patch drone; body tripod via `quiver3` (RGB) parented to the transform.
- **Axis min/max buttons (#9)**: per-axis row (X/Y/Z) of `[min field][max field][apply]`
  in a thin sub-panel below the axes; apply sets `axis(ax,[...])`. Keep auto/manual toggle.

## D. Behavior
- `renderPath3DInitial(fIdx)`: full trajectory dashed + waypoint bold dots (if any) +
  drone at index 1. Build once on data/option load or first toggle-on.
- `updatePath3DAtTime(fIdx, index)`: split trajectory into solid `[1:index]` + dashed
  `[index:end]` (or set one line solid up to index, second dashed after); move drone
  transform to (lon,lat,alt)(index); apply attitude rotation. Called from `updateDashboard`
  (full) and `updateMarkersOnly` (drag, lightweight - position/attitude only).
- **Attitude rotation**: `W = R(index)`; tripod = `quiver3(origin, W(:,k))` per axis (RGB).
  R from body unit vectors or Euler(Heading,Pitch,Roll). Guard: skip if attitude disabled (#7).
- **Play (#10)**: already covered since `onFlightPlayTimer -> applyTimeChange -> updateDashboard`;
  ensure `updatePath3DAtTime` is throttle-safe (it is light if only transform+linestyle).

## E. Edit dialog wiring
- **Options tab** (`buildEditTabOptions`): add a `wayPoint` mapping (table: lat/lon/alt/label
  column pickers or a small editable grid) + Body X/Y/Z dropdowns (column name pickers over
  `VariableNames`). Reuse the existing draft + `editDialogApplyOptionDraft` validate/revert/
  immediate-apply. Persist via `writeOptionFileAtomic` + `.fdproj`.
- **Auto-estimate (#12)**: heuristic helper `i_guessBodyAxisColumns(headers)` matching name
  patterns (e.g., `ax/ay/az`, `bodyx`, `q0..q3`, `roll/pitch/yaw/heading`); waypoint guess
  from lat/lon/alt candidates. Offer as initial values, user-confirmable. Defer to Phase 4.

## F. Risk / complexity + phasing
| Phase | Scope | Files/functions (est.) | Risk |
|---|---|---|---|
| 1 (MVP) | btnPath3D + panel(swap-in-map-column) + option schema (wayPoints) + render waypoint+trajectory + dashed<->solid on time-change; no attitude | createLayout(glCtrl, panelMapAlt slot), pushPanelToggleButton, togglePanel, parseOptionFileToDraft, updateDashboard hook, getTestState | **Med-High** (layout grid + option schema migration) |
| 2 | drone model + Body axis tripod + attitude reflect (#7,#11) | new renderPath3D*/updatePath3D*, hgtransform glyph, rotation helper, buildEditTabOptions(bodyAxes) | Med (rotation correctness, graphics cost) |
| 3 | axis min/max buttons (#9) + play integration (#10) | path3DPanel sub-panel, onFlightPlayTimer (already funnels) | Low-Med |
| 4 | auto-estimate (#12) + attitude alignment + project save/load round-trip | i_guessBodyAxisColumns, collectCurrentProjectState/applyProjectState, .fdproj migration | Med |

**Top risks**
1. **Layout grid regression**: `glCtrl` column count + `panelMapAlt`/hsplit/board-off column
   math are the most regression-prone area (history shows repeated board-off layout fixes).
   Mitigation: swap 3D into the existing Map column (no new column) for Phase 1.
2. **Option schema migration**: existing `.fdproj`/`Option#.dat` without wayPoints/bodyAxes
   must load cleanly (default empty). Additive fields + version-tolerant parse.
3. **mapAxes coordinate parity**: must reuse `mappedCols.Lon/Lat` + Map bounds to keep #4.
4. **Rotation-matrix correctness**: Euler order / body-vector orthonormality; wrong R -> wrong
   tripod. Needs a unit check (e.g., det(R)≈1) and a known-attitude test.
5. **Graphics cost**: drone patch/quiver3 redraw on every time-change during drag/play -
   use a single `hgtransform` (move, don't recreate) to stay light.
6. **Test harness**: add testHooks (`togglePath3D`, `getPath3DState`) so `auto_test_runner`
   can assert panel toggle + dashed/solid state without GUI.

## G. Open questions (decision needed)
1. **Panel placement**: swap into Map column (rec, low risk) vs dedicated new column (higher
   fidelity, high layout risk)? 
2. **`wayPoint` format in `Option#.dat`**: explicit lat/lon/alt rows, a column mapping, or a
   separate file section? Affects parser + Edit UI shape.
3. **Attitude source priority**: reuse existing Heading/Roll/Pitch by default, or require
   explicit Body X/Y/Z? (affects #7 disable logic and #12 heuristic).
4. **Drone model**: lightweight 2D patch glyph (cheap, matches Map precedent) vs real 3D
   STL/patch (higher fidelity, cost + asset)?
5. **Coexistence with board-off**: is 3D allowed as the off-board source/summary, or normal
   mode only? (board-off hsplit column model is fragile.)
6. **Project persistence scope**: persist wayPoints/bodyAxes mapping in `.fdproj` from Phase 1
   or defer to Phase 4?

## Recommended split
- **Phase 1 first, behind the existing toggle pattern, swapping into the Map column** to
  minimize layout risk; ship schema as additive+optional. Get decisions on Q1/Q2/Q3 before
  Phase 2 (attitude) since they shape the data model.
