# Claude Code Prompt — Redefine Layout Panel and Fix Layout Bugs in `FlightDataDashboard.m`

You are Claude Code working on a MATLAB GUI application.

## Target

Repository:

```text
D:\flightdashboard\...
```

Main file:

```text
FlightDataDashboard.m
```

Current review target:

```text
FlightDataDashboard(10).m
```

The current implementation added a new Layout panel and several layout/preset buttons. However, runtime screenshots show that the behavior is not aligned with the actual user requirement. There are also layout bugs, especially blank space after splitter dragging and unexpected Video Player windows.

Your task is to fix the layout feature definition and related bugs without rewriting the whole app.

---

## Critical Output Rules

Follow these rules strictly.

1. Do not print the full modified MATLAB file.
2. Do not print large code blocks.
3. Keep changes scoped to the layout panel, board-off behavior, splitters, and related layout persistence/test hooks.
4. Do not rewrite unrelated video decoding, data parsing, plotting, or project logic.
5. Preserve existing Korean UI labels and comments where possible.
6. Do not remove existing test hooks unless replacing them with equivalent or better hooks.
7. After changes, summarize:
   - files changed,
   - functions changed,
   - bugs fixed,
   - tests performed,
   - remaining risks.
8. Do not use layout buttons to open external Video Player dialogs.
9. Do not change board height from layout buttons when both boards are visible.
10. Do not make any panel “fill the whole board” unless the user explicitly toggled other panels off.

---

# 1. Correct Requirement Definition

The Layout panel is not a “focus preset” feature.

The intended requirement is:

```text
Layout buttons should optimize panel arrangement, spacing, and ratios so that the user can analyze data more easily.
```

The Layout panel must not decide which panels are visible. It must preserve the current user-selected panel visibility state.

In other words:

```text
Layout buttons = arrange currently visible panels
Panel toggle buttons = decide which panels are visible
Board off buttons = switch to single-board analysis arrangement
Video buttons = control external Video Player only
```

Do not mix these responsibilities.

---

# 2. Reference Layout Button Concept

Use MATLAB figure layout arrangement buttons as the conceptual reference.

The target layout buttons are:

```text
[Grid] [Vertical Split] [Horizontal Split] [Compact/Stack] [Reset/Auto Fit]
```

Use icon-style labels similar to MATLAB figure layout controls if possible:

```text
⊞   ▥   ▤   overlapping/stack icon   □
```

If exact icons are not safe across MATLAB versions, use short text labels:

```text
Grid | V-Split | H-Split | Compact | Reset
```

Remove the current `V` / `video-focus` behavior.

Do not remove the other arrangement buttons simply because their previous behavior was wrong. Redefine them as arrangement presets.

---

# 3. Remove / Redefine Incorrect Presets

The following existing concepts are wrong for the Layout panel and must be removed or deprecated from the user-facing Layout panel:

```text
single-top
single-bot
dual-3:1-top
dual-3:1-bot
data-focus
gauges-only
map-focus
video-focus
```

Why:

- `single-top` / `single-bot` duplicate board-off controls.
- `dual-3:1-top` / `dual-3:1-bot` change board height, which is not allowed for layout buttons when both boards are visible.
- `data-focus`, `gauges-only`, `map-focus` incorrectly force certain panels to dominate the board.
- `video-focus` opens Video Player or changes video visibility, which is not allowed.

Replace them with arrangement-only presets:

```text
layout-grid
layout-vertical-split
layout-horizontal-split
layout-compact
layout-reset
```

---

# 4. Hard Rule: Layout Buttons Must Preserve PanelVisible

For every layout preset:

```text
Do not change PanelVisible.attitude.
Do not change PanelVisible.mapOnly.
Do not change PanelVisible.altOnly.
Do not change PanelVisible.video.
Do not change PanelVisible.info.
Do not change PanelVisible.dataView.
```

The only exception is the Reset button if the current code has corrupted layout widths. Even then, Reset must reset only layout ratios and user-adjusted widths. It must not turn panels on/off.

The following calls must not occur inside layout preset application:

```text
setBoardOffDirect()
toggleBoardVisibility()
setVideoViewerVisible()
loadAviFile()
openVideoViewer
create video dialog
```

If any current layout preset calls these directly or indirectly, refactor it.

---

# 5. Hard Rule: Layout Buttons Must Not Change Board Height When Both Boards Are Visible

When both boards are visible:

```text
BoardOffState = [false false]
```

layout buttons must not change:

```text
BodyGrid.RowHeight
BodyRowSplitRatio
BodyRowSplitter position
```

Board height may be changed only by:

1. explicit row splitter drag, or
2. explicit upper/lower board off controls.

Add guard logic if needed:

```text
if both boards are visible:
    layout preset must only call applyBoardInternalLayout(fIdx, layoutName)
```

---

# 6. Redefine Board-Off Behavior

Current bug:

When upper/lower board off is pressed, the implementation behaves like it is expanding the remaining board height or creating a separate unrelated summary panel. Runtime screenshots show this is not what the user wants.

Correct behavior:

## Upper board off

When the upper board is off:

```text
Flight 2 becomes the active single-board analysis source.

Upper area:
    Flight 2 current flight info + plot data

Lower area:
    Flight 2 remaining visible panels
    e.g. attitude, map, altitude, and other visible panels

Do not open Video Player.
Do not show unrelated summary panels.
Do not simply stretch the lower board to extreme height.
```

## Lower board off

When the lower board is off:

```text
Flight 1 becomes the active single-board analysis source.

Upper area:
    Flight 1 current flight info + plot data

Lower area:
    Flight 1 remaining visible panels
    e.g. attitude, map, altitude, and other visible panels

Do not open Video Player.
Do not show unrelated summary panels.
Do not simply stretch the upper board to extreme height.
```

This means board-off mode is a single-board analysis layout mode, not a board-height maximization mode.

If the current `boardOffPanel` implementation duplicates info/plot into a separate summary panel and hides the original source board columns, replace or refactor it so that it matches the above intended structure.

---

# 7. Fix Blank Space Bug After Info/Plot Splitter Drag

Runtime screenshots show this bug repeatedly:

```text
When dragging the splitter between "현재 비행 정보" and "plot 데이터",
the plot panel stops filling the remaining area and a blank region appears.
```

Root cause likely:

The splitter converts both info and plot columns to fixed pixel widths, and `UserColumnWidths` stores the plot column as a fixed width.

Required rule:

```text
If plot data is visible, plot data must remain the final flexible column.
```

Implement these rules:

## Both info and plot visible

```text
info width = user-adjusted fixed pixel width or default fixed width
plot width = '1x'
info/plot splitter width = LAYOUT_SPLITTER_THICKNESS
```

## Only plot visible

```text
info width = 0
info/plot splitter width = 0
plot width = '1x'
```

## Only info visible

```text
info width = '1x' or an appropriate expanded width
info/plot splitter width = 0
plot width = 0
```

## Neither info nor plot visible

```text
info width = 0
info/plot splitter width = 0
plot width = 0
```

Do not store the plot column as a fixed pixel value in `UserColumnWidths`.

Store only truly adjustable fixed-width columns, such as:

```text
attitude width
map/altitude width
info width
```

Do not store:

```text
splitter columns
plot flex column
legacy video columns
hidden columns
```

Add a normalization helper if needed:

```text
normalizeColumnWidthsForVisiblePanels(fIdx, widths)
```

The helper must enforce:

```text
plot column = '1x' whenever plot is visible
```

---

# 8. Remove V / Video-Focus Behavior

The user agrees to remove `V`.

Required changes:

1. Remove the `V` button from the Layout panel.
2. Remove or hide `video-focus` from layout presets.
3. No layout preset may call `setVideoViewerVisible`.
4. No board-off operation may open Video Player.
5. No arrangement preset may open/close `vidViewerDialog`.
6. External Video Player visibility must remain controlled only by existing video-specific controls.

If `PanelVisible.video` currently means “external Video Player dialog visible,” split the meaning if needed:

```text
PanelVisible.videoPanel or internal video layout state
VideoViewerVisible or external video dialog visibility
```

Do not let arrangement presets control external video windows.

---

# 9. New Layout Button Behavior

Implement or refactor the Layout panel around these five arrangement presets.

## 9.1 Grid / Balanced

Purpose:

```text
Arrange currently visible panels in a balanced way.
```

Rules:

- Preserve PanelVisible.
- Do not change board height when both boards are visible.
- Plot remains flexible.
- If only two panels are visible, use 50:50 or sensible balance.
- If info + plot are visible, plot should receive remaining flexible space.
- If one board is off, apply this arrangement to the active single-board analysis layout.

## 9.2 Vertical Split

Purpose:

```text
Left side = visual panels
Right side = info + plot
```

Visual panels include:

```text
attitude
mapOnly
altOnly
```

Data panels include:

```text
info
dataView / plot
```

Rules:

- Preserve PanelVisible.
- Plot remains flexible.
- Do not alter board height when both boards are visible.
- If a category has no visible panels, the other category should use the available area.

## 9.3 Horizontal Split

Purpose:

```text
Upper area = current flight info + plot data
Lower area = remaining visible visual panels
```

This is especially important for board-off mode.

Rules:

- Preserve PanelVisible.
- Do not open Video Player.
- When both boards are visible, apply this inside each board only.
- When one board is off, apply this to the active single-board layout across the available GUI area.

## 9.4 Compact / Stack

Purpose:

```text
Reduce spacing and arrange currently visible panels compactly for small screens or MATLAB Online.
```

Rules:

- Preserve PanelVisible.
- Do not change board height when both boards are visible.
- Do not hide panels.
- Do not open Video Player.
- Minimize blank space.

## 9.5 Reset / Auto Fit

Purpose:

```text
Reset layout ratios and user-adjusted widths while preserving current visible panels.
```

Rules:

- Clear `UserColumnWidths` for the affected board(s).
- Recompute default widths.
- Plot column remains `'1x'` if visible.
- Do not toggle panel visibility.
- Do not change BoardOffState.
- Do not open Video Player.

---

# 10. Suggested Function Structure

Refactor toward this structure.

```text
applyLayoutPreset(layoutName)
    if any(BoardOffState)
        sourceFIdx = active board index
        applySingleBoardArrangement(sourceFIdx, layoutName)
    else
        applyBoardInternalArrangement(1, layoutName)
        applyBoardInternalArrangement(2, layoutName)
    end
```

```text
applyBoardInternalArrangement(fIdx, layoutName)
    read current PanelVisible
    compute visible panel groups
    apply column/row arrangement only inside this board
    do not change PanelVisible
    do not change BodyGrid.RowHeight
    do not open Video Player
```

```text
applySingleBoardArrangement(fIdx, layoutName)
    used only when one board is off
    arrange active board as:
        upper: info + plot
        lower: remaining visible panels
    preserve PanelVisible
    do not open Video Player
```

```text
normalizeColumnWidthsForVisiblePanels(fIdx, widths)
    enforce plot flex behavior
    hide splitters adjacent to hidden panels
    prevent blank space
```

```text
clearUserColumnWidthsForReset(fIdx)
    clear only layout width cache
    do not change PanelVisible
```

---

# 11. Splitter Rules

Fix column splitter behavior.

General rules:

1. Splitter drag must never create unused blank space.
2. If plot is visible, plot remains `'1x'`.
3. Dragging the info/plot splitter changes only info width.
4. Hidden panels must hide adjacent splitters.
5. Double-click on splitter should reset the relevant user width cache, then recompute layout.
6. Do not let splitter drag overwrite `WindowButtonMotionFcn` in a way that breaks marker dragging.
7. Existing marker drag must still work after splitter drag.

---

# 12. Existing D/G/M Behavior Must Not Be Treated as Focus Fill

The user does not want D/G/M-style behavior that makes a specific panel dominate or fill the board.

If keeping D/G/M internally, reinterpret them only as arrangement shortcuts:

```text
D = data-friendly arrangement, not data-only focus
G = gauge-friendly arrangement, not gauge-only focus
M = map-friendly arrangement, not map-only focus
```

However, the preferred UI is to replace letter labels with MATLAB-style arrangement icons.

Do not implement:

```text
data-only
gauges-only
map-only
video-focus
```

unless the user explicitly toggles those panels manually.

---

# 13. Project Save / Load Compatibility

Update project layout state if needed.

Layout state may include:

```text
current arrangement preset name
user column widths for adjustable fixed panels only
board-off state
body row split ratio if both boards are visible
single-board arrangement state if one board is off
```

Do not save plot width as fixed pixel width.

On load:

1. Restore PanelVisible.
2. Restore board-off state.
3. Restore arrangement preset.
4. Restore user adjustable widths.
5. Normalize layout so plot remains `'1x'` if visible.
6. Do not open Video Player as a side effect of project load layout restoration.

---

# 14. Regression Tests / Test Hooks

Add or update test hooks and tests.

Required tests:

```text
G-LAYOUT-01: layout buttons preserve PanelVisible.
G-LAYOUT-02: layout buttons do not change BodyGrid.RowHeight when both boards are visible.
G-LAYOUT-03: V/video-focus is removed and no layout operation opens Video Player.
G-LAYOUT-04: info/plot splitter drag keeps plot column as '1x'.
G-LAYOUT-05: plot-only mode fills all remaining area with no blank space.
G-LAYOUT-06: board-off upper mode arranges active Flight 2 as upper info+plot and lower remaining panels.
G-LAYOUT-07: board-off lower mode arranges active Flight 1 as upper info+plot and lower remaining panels.
G-LAYOUT-08: reset clears UserColumnWidths but preserves PanelVisible.
G-LAYOUT-09: project round-trip preserves arrangement layout and does not store plot fixed width.
G-LAYOUT-10: marker drag still works after column splitter drag and layout preset changes.
```

If full GUI drag automation is difficult, add deterministic test hooks that expose:

```text
PanelVisible
BodyGrid.RowHeight
BodyRowSplitRatio
dataGrid.ColumnWidth
UserColumnWidths
VideoViewerVisible or vidViewerDialog visibility
active layout preset
board-off source board
single-board arrangement state
```

---

# 15. Manual Verification Against Runtime Screenshots

Use the following runtime screenshot issues as acceptance criteria.

## Fix for 33 (1), 33 (17), 33 (23), 33 (24)

After dragging the splitter between `현재 비행 정보` and `plot 데이터`:

```text
plot 데이터 must still fill the remaining horizontal space.
No blank area should appear to the right of plot 데이터.
```

## Fix for 33 (15)

When only `plot 데이터` is visible:

```text
plot 데이터 must use the full available area.
No right-side blank area should remain.
```

## Fix for 33 (10) ~ 33 (13)

When upper board off is pressed:

```text
No Video Player should open.
Flight 2 info + plot should appear in the upper analysis area.
Flight 2 remaining visible panels should appear in the lower analysis area.
This must not behave like an unrelated focus preset.
```

## Fix for 33 (20) ~ 33 (22)

When lower board off is pressed:

```text
No Video Player should open.
Flight 1 info + plot should appear in the upper analysis area.
Flight 1 remaining visible panels should appear in the lower analysis area.
```

## Fix for 33 (3) ~ 33 (8), 33 (16), 33 (18), 33 (19)

When layout buttons are pressed while both boards are visible:

```text
Board heights must not change.
BoardOffState must not change.
Only internal panel arrangement should change.
No Video Player should open.
No panel should be forced to fill the whole board.
```

---

# 16. Static Review Checklist

Before final response, perform a strict static review for:

1. Undefined variables.
2. Invalid MATLAB UI property usage.
3. Invalid `RowHeight` / `ColumnWidth` cell formats.
4. Plot column accidentally stored as numeric fixed width.
5. Layout presets changing PanelVisible.
6. Layout presets changing BodyGrid.RowHeight when both boards are visible.
7. Layout presets opening Video Player.
8. Board-off opening Video Player.
9. Hidden panels still consuming space.
10. Splitters visible next to hidden columns.
11. Marker drag broken after splitter drag.
12. Project load opening video dialogs.
13. `UserColumnWidths` storing hidden/splitter/plot columns.
14. Test hooks returning misleading success.
15. MATLAB Online small-screen layout compatibility.

---

# 17. Final Response Format

After completing the changes, respond with only these sections:

```text
## Summary
- ...

## Files Changed
- ...

## Key Behavior Changes
- ...

## Bugs Fixed
- ...

## Tests Performed
- ...

## Remaining Risks
- ...

## Manual Tests Recommended
- ...
```

Do not print the full source code.

---

## Definition of Done

This task is complete only when:

1. The Layout panel is redefined as an arrangement picker, not a focus preset system.
2. `V` / `video-focus` is removed from the Layout panel.
3. Layout buttons preserve current PanelVisible states.
4. Layout buttons do not change board height when both boards are visible.
5. Layout buttons never open Video Player.
6. Board-off mode arranges the active board as:
   - upper area: current flight info + plot data,
   - lower area: remaining visible panels.
7. Info/plot splitter drag never creates right-side blank space.
8. Plot data remains `'1x'` whenever visible.
9. Plot-only mode fills the available area.
10. Reset clears layout widths but preserves visible panels.
11. Project save/load preserves layout without storing plot fixed width.
12. Marker drag still works after splitter drag and layout changes.
13. MATLAB Online compatibility is preserved.
