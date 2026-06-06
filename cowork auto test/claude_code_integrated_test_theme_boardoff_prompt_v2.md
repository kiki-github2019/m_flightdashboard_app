# Claude Code Prompt — Integrate Latest Test Findings, Fix Runner Expectations, Board-Off Policy, and Light Theme

You are Claude Code working on a MATLAB GUI project.

## Target Files

Main app:

```text
FlightDataDashboard.m
```

Current reviewed version:

```text
FlightDataDashboard(13).m
```

Test runner:

```text
auto_test_runner.m
```

Recent prompt to integrate:

```text
claude_code_fix_flightdashboard_v13_boardoff_runner_prompt.md
```

Recent runtime evidence:

```text
auto_test_runner run with:
    CaptureMode = 'fail'
    LoadAvi = 'never'

Observed:
    Case 5 caused MATLAB Online reload/shutdown after a validation failure.
    Case 48 caused MATLAB Online hard shutdown / reload without normal cleanup records.
    Multiple captured outputs show mixed dark/light UI styling.
```

---

## Background

The previous Claude Code prompt already identified several important problems:

1. Possible MATLAB syntax errors caused by broken line continuation markers.
2. Mixed board-off policies: new active source-board hsplit and old `boardOffPanel` summary behavior coexist.
3. `auto_test_runner.m` still expects old board-off summary behavior.
4. `layout-hsplit` / normal restoration requires verification.
5. Existing `try/catch` and `app.logCaught` patterns must be preserved.

The latest runtime results add new findings:

1. `case 5` failed because the test runner still expects legacy `map` behavior, while the app now has independent `mapOnly` and `altOnly` toggles.
2. `case 48` appears to trigger MATLAB Online hard shutdown after board-off action, most likely due to a conflict between new board-off UI behavior and old heavy summary-panel validation.
3. Board-off-related failures are partly stale test expectations, not necessarily app failures.
4. The light theme is incomplete: black plot/table backgrounds and white text remain in non-video UI areas; some text appears too light on white background.
5. `49–65` results indicate that many layout/splitter/plot-flex behaviors have improved, so do not revert those improvements.

Fix these issues in a scoped patch. Do not rewrite unrelated video decoding, async cache, parsing, flight data loading, or project save/load logic.

---

## Critical Output Rules

Follow these strictly.

1. Do not print the full modified MATLAB files.
2. Do not print large code blocks.
3. Keep changes scoped to:
   - syntax repair,
   - `auto_test_runner.m` expectation correction,
   - map/alt independent toggle test correction,
   - board-off / hsplit validation and behavior,
   - MATLAB Online crash-risk reduction,
   - light theme contrast and background correction.
4. Do not rewrite unrelated AVI decoding, async cache, parser, sync, project save/load, or data plotting internals.
5. Preserve existing Korean UI labels and comments where possible.
6. Preserve existing `try/catch` and `app.logCaught` logging.
7. Do not remove existing test hooks unless replacing them with better equivalents.
8. After editing, report:
   - files changed,
   - functions changed,
   - syntax issues fixed,
   - test runner expectation changes,
   - board-off / hsplit behavior changes,
   - theme changes,
   - tests performed,
   - remaining risks.
9. Do not output full source code.

---

# 1. Priority 0 — Fix MATLAB Syntax First

Before any functional edit, run a strict syntax inspection.

The reviewed file may contain broken line continuation markers where MATLAB `...` was corrupted into a single dot `.`.

Examples to search for:

```matlab
|| .
&& .
, .
= .
'Title', '...', .
if ... || .
```

These are invalid if they are actual source text.

## Required Search

Search the entire `FlightDataDashboard.m` for suspicious continuation patterns:

```text
"|| ."
"&& ."
", ."
"(."
"= ."
"' ."
") ."
```

Also search around newly added layout functions:

```text
applyBoardHsplit
applyBoardNormal
setPanelLayoutCell
createBoardOffSummaryPanel
refreshBoardOffSummaryPanel
toggleBoardVisibility
reflowBoardColumns
applyLayoutPreset
normalizeColumnWidthsForVisiblePanels
```

## Required Fix

If a single dot is being used as a line continuation marker, replace it with MATLAB’s valid continuation marker:

```matlab
...
```

Do not change semantic code during this syntax-only pass.

After syntax repair, run:

```matlab
checkcode FlightDataDashboard.m
```

If MATLAB runtime is available, also run:

```matlab
app = FlightDataDashboard;
delete(app);
```

No layout behavior work is valid until the file parses.

---

# 2. Priority 1 — Fix `auto_test_runner.m` Legacy Map/Altitude Expectations

## Current Runtime Failure

`case 5` failed with:

```text
board 1 altOnly PanelVisible expected=1 actual=0
```

This indicates that the test runner still treats legacy `map` action as if map/altitude combined behavior is always expected.

The app now has independent toggles:

```text
mapOnly
altOnly
```

The UI buttons are separate:

```text
지도 -> mapOnly
고도 -> altOnly
```

Therefore the test runner must stop using legacy `P(fIdx,'map',...)` unless it explicitly intends the backward-compatible combined alias path.

## Required Test Matrix Changes

Replace ambiguous legacy map actions with explicit actions.

Wrong for current UI tests:

```text
P(fIdx,'map','지도/고도 off')
```

Use explicit tests instead:

```text
P(fIdx,'mapOnly','지도 off')
P(fIdx,'altOnly','고도 off')
```

For “map + altitude both off” tests, use two actions:

```text
P(fIdx,'mapOnly','지도 off')
P(fIdx,'altOnly','고도 off')
```

For “map only off” tests:

```text
P(fIdx,'mapOnly','지도 off')
```

For “altitude only off” tests:

```text
P(fIdx,'altOnly','고도 off')
```

## Required Expected-State Logic Changes

Update `i_updateExpectedState` so that:

```text
mapOnly toggles only mapOnly.
altOnly toggles only altOnly.
map = mapOnly || altOnly.
```

Do not make `mapOnly` and `altOnly` both flip unless the action is explicitly intended to test the legacy `map` alias.

If the legacy `map` alias is retained for backward compatibility, isolate it in a small number of specific legacy tests. Do not use it in normal current-UI tests.

## Required Validation

`i_validateState` must check independent map and altitude visibility correctly.

Do not fail a current-UI test merely because `mapOnly` and `altOnly` are no longer toggled together.

---

# 3. Priority 2 — Update Board-Off Test Expectations to the New Policy

## Current Problem

Many board-off failures are caused by stale test expectations.

Old expected behavior in `auto_test_runner.m` includes:

```text
boardOffPanel visible
source info/plot columns hidden
summary table rows match source table rows
summary plot counts match source plots
summary markers/xlines are draggable
```

This is no longer the required behavior.

The current product requirement is:

```text
Board-off = active source board hsplit arrangement
```

## New Board-Off Requirement

### Upper board off

```text
active source = Flight 2

upper region:
    Flight 2 current flight info + plot data

lower region:
    Flight 2 remaining visible panels
    e.g. attitude, map, altitude, other non-info/plot panels
```

### Lower board off

```text
active source = Flight 1

upper region:
    Flight 1 current flight info + plot data

lower region:
    Flight 1 remaining visible panels
    e.g. attitude, map, altitude, other non-info/plot panels
```

## Required New Test Expectations

When one board is off:

```text
off board panel is hidden/collapsed
boardOffPanel is hidden or non-primary
source board panel is visible
source board arrangement mode is hsplit
source upper region contains info + plot
source lower region contains remaining visible panels
source plot/dataView remains flexible
Video Player is not visible/opened
```

## Required Runner Changes

Update `auto_test_runner.m` validation logic:

```text
Remove old requirement that boardOffPanel must be visible.
Remove old requirement that source info/plot columns must be hidden.
Remove mandatory summary table / summary plot / summary marker validation.
Add validation that source board is hsplit during board-off.
Add validation that off board is hidden/collapsed.
Add validation that no Video Player is opened.
Add validation that plot remains '1x' when visible.
```

Do not treat “summary panel not visible” as failure under the new board-off policy.

Do not treat `[0 0 100 0]` BodyGrid row allocation as failure if the source board is in correct hsplit mode and the old summary row is intentionally collapsed.

---

# 4. Priority 3 — Reduce MATLAB Online Hard-Crash Risk in Case 48

## Runtime Observation

`case 48` appears to stop after:

```text
ACTION_START 보드2 off
ACTION_DONE 보드2 off
CAPTURE_START 보드2 off
CAPTURE_SKIPPED fail
```

No normal FAIL, EXCEPTION, cleanup, or index-finalization record follows.

This indicates MATLAB Online hard shutdown / reload, not a catchable MATLAB exception.

## Likely Cause

The most likely cause is a conflict between:

```text
new board-off hsplit behavior
old boardOffPanel summary validation
heavy findall / marker / xline scanning of hidden or stale UI handles
```

## Required Crash-Mitigation Changes

In `auto_test_runner.m`:

1. Stop heavy validation of hidden `boardOffPanel` content.
2. Do not call `findall(boardOffPanel)` for hidden/non-primary board-off panels.
3. Do not count summary table rows, summary plots, summary markers, or summary xlines as mandatory validation under the new board-off policy.
4. Validate lightweight source-board state instead:
   - source board visible,
   - arrangement mode = hsplit,
   - off board hidden/collapsed,
   - plot column remains `'1x'`,
   - video dialog not visible.
5. Continue writing `progress.md`, `caseNN.md`, and `index.md` after each completed case.
6. Ensure reverse/skip/case-list execution remains available if previously added.

## Crash-Prone Case Strategy

Support and document running case 48 separately with minimal load:

```matlab
auto_test_runner('CaseList',48,'CaptureMode','none','LoadAvi','never')
```

For bulk tests, recommend skipping crash-prone cases until fixed:

```matlab
auto_test_runner('Order','desc','Skip',[2 5 48],'CaptureMode','fail','LoadAvi','never')
```

Do not rely on `try/catch` to handle hard MATLAB Online shutdown.

---

# 5. Priority 4 — Enforce One Board-Off Policy in `FlightDataDashboard.m`

The app must not mix:

```text
source board hsplit visible
AND off board boardOffPanel visible
AND source info/plot columns hidden as if moved to summary
```

## Correct Policy

When one board is off:

```text
source board must remain visible
source board must be in hsplit arrangement mode
off board original panel should be hidden or collapsed
boardOffPanel should not be visibly used as the primary UI
Video Player must not open
```

If `boardOffPanel` must remain for compatibility, keep it hidden or non-primary.

## Required `toggleBoardVisibility` Behavior

When enabling board-off:

```text
set BoardOffState(fIdx) = true
sourceIdx = 3 - fIdx
hide/collapse off board panel
hide/collapse boardOffPanel if present
keep source board visible
applyBoardHsplit(sourceIdx)
update BodyGrid.RowHeight so source board has active area
do not open Video Player
update board toggle buttons
```

When disabling board-off:

```text
set BoardOffState(fIdx) = false
restore both original board panels
hide/collapse any boardOffPanel
applyBoardNormal(1)
applyBoardNormal(2)
restore normal BodyGrid row heights / row splitter
update board toggle buttons
```

Do not call old summary refresh logic as the primary board-off implementation.

---

# 6. Priority 5 — Make `layout-hsplit` and Board-Off Share the Same Internal Arrangement

`layout-hsplit` and board-off source mode should use the same reliable helper.

Preferred structure:

```text
applyBoardHsplit(fIdx)
    upper: info + plot
    lower: attitude + map/alt + other visible non-info/plot panels

applyBoardNormal(fIdx)
    restore original one-row board layout

applyBoardArrangement(fIdx, mode)
    dispatch normal/grid/vsplit/compact/hsplit
```

## `applyBoardHsplit` Must

```text
preserve PanelVisible
not open Video Player
not change BoardOffState
not change BodyGrid.RowHeight directly
not destroy plot tabs or table data
not recreate heavy data unnecessarily
keep plot/dataView flexible '1x'
hide splitters that are invalid in hsplit mode
```

## `applyBoardNormal` Must

```text
restore all panels to normal dataGrid parent/row/column
restore column splitters according to current PanelVisible
restore ColumnWidth using normalizeColumnWidthsForVisiblePanels
not change PanelVisible
not open Video Player
```

## Parent/Child Safety

If hsplit moves existing UI panels:

1. Confirm all moved panels have the same parent grid or are reparented safely.
2. Do not assign invalid `Layout.Row` or `Layout.Column`.
3. Use valid `RowHeight` and `ColumnWidth` cell arrays.
4. Ensure hidden panels do not consume blank space.
5. Ensure normal → hsplit → normal restores every panel to a valid location.
6. Ensure repeated hsplit/reset/grid cycles do not drift.

---

# 7. Priority 6 — Preserve Plot Flex and UserColumnWidths Rules

Keep the existing improvements:

```text
plot/dataView visible => plot width = '1x'
UserColumnWidths stores only adjustable fixed widths:
    attitudeWidth
    mapAltWidth
    infoWidth
```

Do not revert to full `ColumnWidth` cell storage.

Do not store:

```text
plot width
splitter widths
hidden panel widths
legacy/reserved column widths
```

`normalizeColumnWidthsForVisiblePanels` or equivalent must remain idempotent:

```text
repeated calls with the same PanelVisible and stored user widths must return the same result
```

Resize, reflow, project restore, splitter drag, and layout preset application must preserve:

```text
plot/dataView visible => plot width = '1x'
```

---

# 8. Priority 7 — Preserve Video Separation

No board-off, layout preset, reflow, resize, project restore, or hsplit helper may open Video Player.

Allowed `setVideoViewerVisible` paths:

```text
explicit video button / video-specific action
video dialog close handler
```

Forbidden paths:

```text
toggleBoardVisibility
applyLayoutPreset
applyBoardHsplit
applyBoardNormal
reflowBoardColumns
syncBoardPanelHandles
applyProjectState layout restore
auto layout / resize
auto_test_runner validation
theme application
```

Search all `setVideoViewerVisible` calls and classify them.

---

# 9. Priority 8 — Fix MATLAB Editor Light Theme / Contrast Problems

## Runtime Observation

Captured results still show mixed dark/light styling:

```text
black plot/table-like regions with white text
strong blue/purple table backgrounds
white or light gray text on light background
dark-mode remnants in a nominal light theme
```

This is not acceptable for the requested MATLAB Editor-like light theme.

## Required Theme Policy

Use a consistent MATLAB coding editor-like light theme:

```text
overall background: light neutral gray
panel background: white or very light gray
normal text: dark gray / near black
muted text: medium gray, not too light
axes background: white
plot panel background: white or very light gray
table background: white or near-white
table text: dark gray
active/selected button: MATLAB blue accent
warning/error text: red/orange only when semantically warning/error
```

## Required Fixes

1. Force all non-video axes and plot panels to white/light background.
2. Remove black plot backgrounds from non-video panels.
3. Remove white font on black background from non-video UI.
4. Remove light gray font on white background when contrast is poor.
5. Replace strong blue/purple table backgrounds with:
   - white or near-white table background,
   - dark text,
   - subtle flight identity accent such as header tint, border strip, or very light row tint.
6. Use red only for warning/error states.
7. Active toggle buttons should use MATLAB blue or light-blue accent, not red.
8. Ensure `applyLightTheme` applies to:
   - panels,
   - buttons,
   - labels,
   - tables,
   - axes,
   - tabs,
   - input controls,
   - edit/project dialogs.
9. Do not restyle actual video/image display axes in a way that breaks video display.

## Contrast Acceptance Criteria

The UI must not contain:

```text
white text on black non-video UI background
light gray text on white/light background
black plot background in normal light theme
strong saturated table background with white text
```

Flight identity color may remain only as subtle accent, not full saturated table background.

---

# 10. Required Test State Additions

Update `getTestState` / `collectTestBoardState` if needed to expose:

```text
boards(fIdx).arrangementMode = 'normal' | 'hsplit'
boards(fIdx).isHsplit
boards(fIdx).upperRegionHasInfoPlot
boards(fIdx).lowerRegionHasRemainingPanels
boards(fIdx).videoViewerVisible
boards(fIdx).dataGridColumnWidth
boards(fIdx).PanelVisible
BoardOffState
BodyGrid.RowHeight
BodyRowSplitRatio
CurrentLayoutPreset
```

For theme testing, expose only lightweight diagnostics if practical:

```text
axes background colors
table foreground/background colors
main panel background colors
button active colors
```

Do not make theme diagnostics expensive.

---

# 11. Required Smoke Tests

After syntax repair and functional changes, run or document the following.

## Syntax and construction

```matlab
checkcode FlightDataDashboard.m
app = FlightDataDashboard;
st = app.testHook('getTestState');
delete(app);
```

## Map/alt independent toggles

```matlab
app = FlightDataDashboard;
app.testHook('pushPanelToggleButton',1,'mapOnly');
st1 = app.testHook('getTestState');
app.testHook('pushPanelToggleButton',1,'altOnly');
st2 = app.testHook('getTestState');
delete(app);
```

Expected:

```text
mapOnly and altOnly toggle independently.
map = mapOnly || altOnly.
No unexpected crash.
```

## Layout hsplit / normal restoration

```matlab
app = FlightDataDashboard;
app.testHook('applyLayoutPreset','layout-hsplit');
st1 = app.testHook('getTestState');
app.testHook('applyLayoutPreset','layout-grid');
st2 = app.testHook('getTestState');
delete(app);
```

Expected:

```text
No exception.
PanelVisible unchanged.
No Video Player opened.
Normal restoration valid.
```

## Board-off upper

```matlab
app = FlightDataDashboard;
app.testHook('pushBoardToggleButton',1);
st = app.testHook('getTestState');
delete(app);
```

Expected:

```text
BoardOffState = [true false]
Flight 2 source board visible
Flight 2 arrangement mode = hsplit
Flight 1 original/off panel hidden
boardOffPanel not used as visible summary
Video Player not opened
```

## Board-off lower

```matlab
app = FlightDataDashboard;
app.testHook('pushBoardToggleButton',2);
st = app.testHook('getTestState');
delete(app);
```

Expected:

```text
BoardOffState = [false true]
Flight 1 source board visible
Flight 1 arrangement mode = hsplit
Flight 2 original/off panel hidden
boardOffPanel not used as visible summary
Video Player not opened
```

## Auto test runner low-risk subset

```matlab
auto_test_runner('CaseList',[1 2 3],'CaptureMode','none','LoadAvi','never')
```

## Crash-risk case 5 isolated

```matlab
auto_test_runner('CaseList',5,'CaptureMode','none','LoadAvi','never')
```

## Crash-risk case 48 isolated

```matlab
auto_test_runner('CaseList',48,'CaptureMode','none','LoadAvi','never')
```

## Bulk run avoiding crash-prone cases

```matlab
auto_test_runner('Order','desc','Skip',[2 5 48],'CaptureMode','fail','LoadAvi','never')
```

---

# 12. Static Review Checklist

Before final response, verify:

```text
No broken line continuation markers remain.
FlightDataDashboard.m parses.
auto_test_runner.m no longer uses legacy map action incorrectly.
mapOnly and altOnly expected states are independent.
No board-off path opens Video Player.
No layout path opens Video Player.
Board-off does not visibly use old summary panel as the primary UI.
Source board enters hsplit during board-off.
Off board is hidden/collapsed.
layout-hsplit does not change PanelVisible.
layout-hsplit does not change BodyGrid.RowHeight when both boards are visible.
applyBoardNormal restores valid panel locations.
plot/dataView remains '1x' when visible.
UserColumnWidths remains struct-based.
auto_test_runner no longer expects old summary panel behavior.
auto_test_runner does not do heavy hidden boardOffPanel findall scans.
auto_test_runner still writes progress/case/index files.
try/catch and app.logCaught patterns are preserved.
No black non-video plot/table background remains in light theme.
No white text remains on non-video black UI panels.
No low-contrast light gray text remains on white background.
Strong blue/purple table backgrounds are replaced with light theme-compatible colors.
```

---

# 13. Final Response Format

After completing the patch, respond with only:

```text
## Summary
- ...

## Files Changed
- ...

## Syntax Fixes
- ...

## Test Runner Changes
- ...

## Layout / Board-Off Changes
- ...

## Theme / Contrast Changes
- ...

## Tests Performed
- ...

## Remaining Risks
- ...

## Manual Tests Recommended
- ...
```

Do not print full source code.

---

## Definition of Done

This task is complete only when:

1. `FlightDataDashboard.m` has no MATLAB syntax errors from broken continuation markers.
2. `auto_test_runner.m` correctly handles independent `mapOnly` and `altOnly`.
3. Case 5 no longer fails from stale map/alt expectations.
4. Board-off uses active source board hsplit as the primary UI.
5. Old `boardOffPanel` summary UI is not the primary visible board-off UI.
6. `auto_test_runner.m` validates the new board-off behavior.
7. Case 48 validation no longer performs heavy stale summary-panel scans.
8. `layout-hsplit` is a real upper/lower arrangement.
9. Normal ↔ hsplit restoration works.
10. Layout and board-off operations do not open Video Player.
11. Plot/dataView remains `'1x'` whenever visible.
12. `UserColumnWidths` remains struct-based.
13. Light theme has no dark non-video plot/table areas or low-contrast text.
14. Existing error logging and cleanup safety are preserved.
