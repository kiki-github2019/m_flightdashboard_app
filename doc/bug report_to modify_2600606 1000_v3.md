# Claude Code Prompt v3 — Redefine Layout Panel and Fix Layout Bugs in `FlightDataDashboard.m`

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

# 18. Additional Review Feedback to Incorporate in v2

A later review of the bug report and runtime screenshots concluded that the current implementation should be treated as a major behavioral regression, not a small cosmetic defect.

Estimated compliance with the intended layout behavior is roughly 40%.

The current implementation mixes:

```text
layout arrangement
panel visibility toggles
board height changes
board-off behavior
Video Player dialog control
focus-style presets
```

This is the wrong abstraction.

The required abstraction is:

```text
Layout panel = arrangement picker only
Panel toggle buttons = visibility control only
Board-off buttons = single-board analysis arrangement only
Video controls = Video Player dialog control only
```

## Required Fix Order

Apply fixes in this priority order:

```text
Priority 1: Redefine applyLayoutPreset as arrangement-only.
Priority 2: Fix reflowBoardColumns / splitter blank-space behavior.
Priority 3: Redefine board-off as active single-board arrangement.
Priority 4: Remove V / video-focus from the layout path.
Priority 5: Update project save/load and test hooks.
Priority 6: Perform static review and manual GUI regression checks.
```

Do not start with cosmetic UI label changes. Fix behavior first.

---

# 19. Critical Clarification for `normalizeColumnWidthsForVisiblePanels`

A normalization helper is strongly recommended, but it must be implemented carefully.

Do not blindly copy or paste any candidate implementation without first confirming the actual `dataGrid.ColumnWidth` mapping in the current file.

The common intended 8-column mapping appears to be similar to:

```text
1: attitude panel
2: splitter or reserved splitter
3: map/alt panel
4: splitter
5: current flight info
6: info/plot splitter
7: plot data
8: legacy/reserved/video-related column
```

However, Claude Code must verify the actual mapping in the current source before editing.

## Required Normalization Rules

Implement `normalizeColumnWidthsForVisiblePanels(fIdx, widths)` or an equivalent helper with these rules:

```text
If attitude is hidden:
    attitude column = 0
    adjacent splitter = 0

If both mapOnly and altOnly are hidden:
    map/alt column = 0
    adjacent splitter = 0

If info is hidden:
    info column = 0
    info/plot splitter = 0

If dataView / plot is visible:
    plot column must be '1x'

If dataView / plot is hidden:
    plot column = 0

If both info and plot are visible:
    info may be fixed pixel width
    info/plot splitter visible
    plot must remain '1x'

If only plot is visible:
    info = 0
    info/plot splitter = 0
    plot = '1x'

If only info is visible:
    info must use the available area appropriately
    info/plot splitter = 0
    plot = 0
```

## Safety Requirements for Normalization

The helper must:

1. Preserve existing valid widths where possible.
2. Fill only missing columns when `numel(widths) < expectedColumnCount`.
3. Avoid replacing all widths with `'1x'`, because that can destroy valid panel widths.
4. Never store or return the visible plot column as a numeric fixed width.
5. Hide splitters adjacent to hidden panels.
6. Work safely with old project files that may have legacy 5-column or partial width specs.
7. Be called after:
   - `reflowBoardColumns`,
   - splitter drag end,
   - layout preset apply,
   - board-off transition,
   - project layout restore,
   - panel visibility toggle.

---

# 20. UserColumnWidths Storage Must Be Refactored

Do not store the whole `ColumnWidth` cell array as `UserColumnWidths`.

That approach is unsafe because it can persist corrupted states such as:

```text
plot column = fixed numeric pixel width
splitter columns = stale fixed width
hidden columns = stale nonzero width
legacy video column = stale nonzero width
```

Instead, store only user-adjustable fixed-width values.

Preferred design:

```text
UserColumnWidths{fIdx}.attitudeWidth
UserColumnWidths{fIdx}.mapAltWidth
UserColumnWidths{fIdx}.infoWidth
```

Do not store:

```text
plot column width
splitter column widths
hidden panel widths
legacy video/reserved column widths
entire ColumnWidth cell array
```

When restoring user widths:

```text
1. Build default layout widths from current PanelVisible.
2. Apply only stored adjustable fixed widths.
3. Normalize the final widths.
4. Enforce plot = '1x' whenever plot is visible.
```

---

# 21. Splitter Drag Implementation Requirements

Splitter drag must respect the flex-column design.

## Info / Plot Splitter

Dragging the splitter between `현재 비행 정보` and `plot 데이터` must change only the info width.

Required result:

```text
info width = adjusted numeric pixel width
plot width = '1x'
```

Forbidden result:

```text
info width = adjusted numeric pixel width
plot width = adjusted numeric pixel width
right-side blank area
```

## Splitter Double-Click

Double-click on a splitter must reset only the relevant stored adjustable width.

Examples:

```text
info/plot splitter double-click:
    clear UserColumnWidths{fIdx}.infoWidth
    recompute widths
    plot remains '1x'

attitude/map splitter double-click:
    clear relevant attitude/mapAlt width only
    recompute widths
```

Do not clear `PanelVisible`.

Do not open Video Player.

Do not change board height.

---

# 22. Board-Off Must Not Use an Unrelated Summary Panel

The current behavior appears to create or show a separate `boardOffPanel` summary while hiding the source board's original info/plot columns. This produced a user-visible layout that did not match the requirement.

Refactor board-off behavior as follows:

## Upper Board Off

```text
Active source = Flight 2

Upper region:
    Flight 2 current flight info + plot data

Lower region:
    Flight 2 remaining visible panels
    attitude / map / altitude / other visible non-info/plot panels
```

## Lower Board Off

```text
Active source = Flight 1

Upper region:
    Flight 1 current flight info + plot data

Lower region:
    Flight 1 remaining visible panels
    attitude / map / altitude / other visible non-info/plot panels
```

Do not create an unrelated summary experience.

Do not open Video Player.

Do not simply make the active board 90% or 100% tall.

The key is panel rearrangement, not extreme board-height expansion.

If fully replacing `boardOffPanel` is too risky in one patch, preserve it only as a temporary compatibility container, but its visual result must match:

```text
upper: info + plot
lower: remaining visible panels
```

---

# 23. Layout Buttons Must Not Be Focus Presets

The user explicitly clarified that the layout buttons are for optimizing panel spacing and arrangement, not for making a specific panel dominate or fill the board.

Therefore:

```text
Do not implement Data-only layout.
Do not implement Gauges-only layout.
Do not implement Map-only layout.
Do not implement Video-focus layout.
Do not force a panel to fill the board unless the user has manually toggled other panels off.
```

If D/G/M labels or internal mappings remain temporarily, reinterpret them as arrangement presets only:

```text
D = data-friendly arrangement, not data-only focus.
G = gauge-friendly arrangement, not gauges-only focus.
M = map-friendly arrangement, not map-only focus.
```

Preferred UI still remains MATLAB-style arrangement icons:

```text
Grid | Vertical Split | Horizontal Split | Compact | Reset
```

---

# 24. Acceptance Criteria Mapped to Runtime Screenshots

Use these screenshot groups as strict behavioral acceptance criteria.

## Splitter Blank Bug

Screenshots:

```text
33 (1).png
33 (17).png
33 (23).png
33 (24).png
```

Expected behavior:

```text
After dragging the splitter between "현재 비행 정보" and "plot 데이터",
plot data still fills all remaining horizontal space.
No right-side blank area appears.
```

## Plot-Only Blank Bug

Screenshot:

```text
33 (15).png
```

Expected behavior:

```text
If only plot data is visible, plot data fills the entire available area.
No blank area remains to the right.
```

## Upper Board-Off Misbehavior

Screenshots:

```text
33 (10).png
33 (11).png
33 (12).png
33 (13).png
33 (22).png
```

Expected behavior:

```text
No Video Player opens.
Flight 2 info + plot are placed in the upper active analysis region.
Flight 2 remaining visible panels are placed in the lower active analysis region.
No unrelated summary/focus layout is shown.
```

## Lower Board-Off Misbehavior

Screenshots:

```text
33 (20).png
33 (21).png
```

Expected behavior:

```text
No Video Player opens.
Flight 1 info + plot are placed in the upper active analysis region.
Flight 1 remaining visible panels are placed in the lower active analysis region.
No unrelated summary/focus layout is shown.
```

## Layout Preset Misuse

Screenshots:

```text
33 (3).png
33 (4).png
33 (5).png
33 (6).png
33 (7).png
33 (8).png
33 (16).png
33 (18).png
33 (19).png
```

Expected behavior when both boards are visible:

```text
Layout buttons do not change BodyGrid.RowHeight.
Layout buttons do not change BodyRowSplitRatio.
Layout buttons do not change BoardOffState.
Layout buttons do not open Video Player.
Layout buttons do not force a focus-only view.
Only internal panel spacing/arrangement changes.
```

## V Button

Screenshot:

```text
33 (2).png
```

Expected behavior:

```text
V/video-focus is removed from the layout panel.
No layout button opens Video Player.
```

## OK Cases

Screenshots:

```text
33 (9).png
33 (14).png
```

Expected behavior:

```text
Preserve the behavior that was visually acceptable in these cases, unless it conflicts with the corrected arrangement-only rules.
```

---

# 25. Do Not Overfit to a Single Suggested Code Snippet

The review includes an example implementation idea for `normalizeColumnWidthsForVisiblePanels`.

Treat that code as design guidance, not as an exact patch.

Claude Code must:

1. Inspect the actual current file.
2. Confirm column mappings.
3. Confirm which helper functions already exist.
4. Integrate normalization with existing `reflowBoardColumns`, splitter handlers, layout apply, board-off, and project restore.
5. Avoid introducing new regressions in MATLAB Online.

---

# 26. Updated Definition of Done for v2

This v2 task is complete only when:

1. The Layout panel is an arrangement picker, not a focus preset system.
2. V/video-focus is removed from the Layout panel.
3. Layout buttons preserve `PanelVisible`.
4. Layout buttons do not modify `BodyGrid.RowHeight` or `BodyRowSplitRatio` when both boards are visible.
5. Layout buttons never open Video Player.
6. Board-off mode does not show an unrelated summary/focus panel.
7. Board-off mode uses active source-board arrangement:
   - upper: current flight info + plot data,
   - lower: remaining visible panels.
8. Info/plot splitter drag never creates blank space.
9. Plot column remains `'1x'` whenever visible.
10. Plot-only mode fills available area.
11. Reset clears only layout width cache, not panel visibility.
12. UserColumnWidths stores only adjustable fixed widths.
13. Project save/load does not persist plot as a fixed width.
14. Test hooks expose enough state to verify all layout behavior.
15. Manual screenshot acceptance cases above are satisfied.
16. MATLAB Online compatibility is preserved.


---

# 27. Additional v3 Clarifications From Latest Review

The latest review confirms that the v2 direction is correct, but the prompt must be strengthened in several places so Claude Code does not misinterpret the task.

These clarifications are mandatory.

---

## 27.1 Screenshot Operation Order Must Use File Saved/Modified Time

Do not assume that screenshot filename numbering is the true chronological operation order.

The screenshot filenames such as:

```text
33 (1).png
33 (2).png
...
33 (24).png
```

are useful for symptom grouping, but they are not necessarily the actual operation sequence.

When screenshot metadata or file modified timestamps are available:

```text
Use file saved/modified time as the authoritative operation sequence.
```

Use filename numbers only as symptom references.

This matters because some bug groups repeat later in the test sequence, especially:

```text
splitter drag blank-space bugs
layout preset misuse
board-off misbehavior
plot-only blank-space bug
```

---

## 27.2 Pre-Edit Code Search Is Mandatory

Before editing, search the current `FlightDataDashboard.m` for every layout-related occurrence of the following:

```text
setVideoViewerVisible
setBoardOffDirect
toggleBoardVisibility
BodyGrid.RowHeight
BodyRowSplitRatio
PanelVisible.
boardOffPanel
createBoardOffSummaryPanel
refreshBoardOffSummaryPanel
hideBoardInfoPlotColumns
applyLayoutPreset
reflowBoardColumns
UserColumnWidths
ColumnWidth
WindowButtonMotionFcn
WindowButtonUpFcn
```

Classify each occurrence into one of the following categories:

```text
1. Allowed non-layout path
2. Forbidden layout path
3. Board-off refactor target
4. Project restore / layout load path requiring normalization
5. Splitter/drag path requiring normalization
6. Test hook path requiring state exposure
```

Do not modify blindly.

First understand which paths are:

```text
layout preset path
board-off path
panel toggle path
splitter drag path
project load path
video-specific path
```

The same helper can be valid in one path and forbidden in another.

For example:

```text
setVideoViewerVisible may be valid in an explicit video-specific button handler.
setVideoViewerVisible is forbidden inside layout presets and board-off operations.
```

---

## 27.3 Board-Off Must Rearrange Existing Active Board Panels

Board-off behavior must prioritize rearranging the active board's existing panels.

Do not implement board-off primarily as:

```text
source board stretched + separate boardOffPanel summary
```

The desired behavior is:

```text
active board split into:
    upper region: current flight info + plot data
    lower region: remaining visible panels
```

When upper board is off:

```text
active source = Flight 2
upper region = Flight 2 info + plot
lower region = Flight 2 remaining visible panels
```

When lower board is off:

```text
active source = Flight 1
upper region = Flight 1 info + plot
lower region = Flight 1 remaining visible panels
```

If a compatibility container is temporarily used, it must visually behave as if the active board itself was rearranged.

The visual result must not look like:

```text
an unrelated summary panel
a focus-only preset
a board stretched to extreme height
a duplicated/inconsistent panel set
```

---

## 27.4 Column Normalization Must Be Safe and Idempotent

`normalizeColumnWidthsForVisiblePanels` or the equivalent helper must be safe and idempotent.

Idempotent means:

```text
Calling the helper repeatedly with the same PanelVisible state and same user-adjusted widths must return the same ColumnWidth result.
```

Repeated calls must not gradually:

```text
shrink panels
expand panels
move splitters
toggle hidden columns
convert plot '1x' into a numeric fixed width
```

Do not hard-code any column as unused until the actual current `dataGrid` mapping is verified.

In particular:

```text
Do not blindly set widths{2} = 0.
Do not blindly set widths{8} = 0.
```

Only set a column to 0 if the current mapping and current layout state prove that it is hidden, unused, or adjacent to a hidden panel.

If a column is a valid splitter for the current arrangement, preserve or recompute it according to the current `PanelVisible` state.

Never assume a column is legacy only because an earlier review called it legacy.

---

## 27.5 Normalize After Every Layout-Relevant State Change

After every layout-relevant operation, call the normalization helper or route through a single layout update function that includes normalization.

Required call sites include:

```text
reflowBoardColumns
stopColumnSplitterDrag
column splitter double-click reset
applyLayoutPreset
applyLayoutUiState
applyProjectState
togglePanel
applyMapAltVisibility
toggleBoardVisibility
setBoardOffDirect
project load / autosave restore
custom preset apply
```

However, avoid duplicate destructive recomputation.

Preferred structure:

```text
compute desired layout widths
apply stored adjustable user widths
normalize once
assign to dataGrid.ColumnWidth
refresh splitter visibility
refresh test state
```

Do not repeatedly assign partial widths and then normalize in multiple conflicting places in the same event path.

---

## 27.6 Fix Order Must Be Strict

Use this exact priority order.

### Priority 1A — Add Guards First

Before replacing UI labels or icons, add behavior guards so layout buttons cannot change:

```text
PanelVisible
BoardOffState
BodyGrid.RowHeight
BodyRowSplitRatio
external Video Player state
```

when both boards are visible.

This prevents additional regression while refactoring.

### Priority 1B — Replace Focus Presets With Arrangement Presets

Replace old focus-style behavior with arrangement-only behavior:

```text
layout-grid
layout-vertical-split
layout-horizontal-split
layout-compact
layout-reset
```

Do not implement:

```text
data-only
gauges-only
map-only
video-focus
```

### Priority 1C — Remove V / video-focus

Remove the `V` button and remove `video-focus` from the layout panel.

This is not enough by itself. It must be combined with Priority 1A guards.

### Priority 2 — Fix Splitter / Plot Flex Normalization

Fix the blank-space bug by ensuring:

```text
plot column = '1x' whenever plot is visible
```

and by preventing `UserColumnWidths` from storing plot as a fixed numeric width.

### Priority 3 — Refactor Board-Off Arrangement

Refactor board-off into active single-board arrangement:

```text
upper = info + plot
lower = remaining visible panels
```

No Video Player.

No unrelated summary panel.

No simple extreme board-height expansion.

### Priority 4 — Update Save/Load and Test Hooks

Update project serialization and test hooks after behavior is corrected.

Do not preserve corrupted layout states.

Normalize on project load.

Do not store plot fixed width.

---

## 27.7 Reset Behavior Must Be Narrowly Defined

Reset / Auto Fit must not behave like a visibility reset.

It must:

```text
clear only layout width cache
clear only arrangement-specific temporary ratios if needed
recompute default internal arrangement
preserve PanelVisible
preserve BoardOffState
preserve external Video Player state
```

It must not:

```text
turn panels on/off
change board-off state
open Video Player
force a focus layout
change board height when both boards are visible
```

---

## 27.8 Test Hooks Must Detect False Success

Do not let test hooks return misleading success.

If a test hook performs a round-trip or layout verification, it must compute `Ok` from actual state comparison.

At minimum compare:

```text
PanelVisible for both boards
BoardOffState
BodyGrid.RowHeight
BodyRowSplitRatio
dataGrid.ColumnWidth after normalization
UserColumnWidths adjustable fields only
vidViewerDialog visibility
current arrangement preset
active single-board source when board-off
```

For layout buttons, expose enough state to verify:

```text
PanelVisible unchanged
BodyGrid.RowHeight unchanged when both boards visible
BodyRowSplitRatio unchanged when both boards visible
no Video Player opened
plot column remains '1x'
hidden splitters are zero/hidden
```

---

## 27.9 Manual Acceptance Must Include Repeated Operations

Manual checks must include repeated operations, not just one click.

Test sequences must include:

```text
apply layout preset -> apply another preset -> reset
splitter drag -> layout preset -> splitter drag again
plot-only mode -> reset -> plot-only mode again
upper board off -> reset -> lower board off
board-off -> layout preset -> board on -> layout preset
project save -> project load -> layout preset -> splitter drag
```

The layout must remain stable after repeated operations.

No progressive drift is allowed.

---

## 27.10 Final v3 Requirement Summary

The v3 task is not merely to rename buttons.

It is to correct the layout state architecture.

The final architecture must enforce:

```text
Layout buttons arrange.
Panel buttons show/hide.
Board-off buttons switch single-board arrangement.
Video controls open/close Video Player.
Splitters adjust fixed panel widths.
Plot stays flex.
Project save/load stores only valid layout state.
```

Any code path that violates this separation must be refactored or guarded.

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
