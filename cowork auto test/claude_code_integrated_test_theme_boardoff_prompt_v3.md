# Claude Code Prompt v3 — Integrate Latest Test Findings, MATLAB Online Safe Runner, Board-Off Policy, and Light Theme

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
Run A:
    CaptureMode = 'fail'
    LoadAvi = 'never'

Observed:
    Case 5 caused MATLAB Online reload/shutdown after a validation failure.
    Case 48 caused MATLAB Online hard shutdown / reload without normal cleanup records.
    Multiple captured outputs show mixed dark/light UI styling.

Run B:
    CaptureMode = 'all'
    LoadAvi = 'always'

Observed:
    Case 6 caused MATLAB Online shutdown after SETUP_DONE during BASELINE_CAPTURE_START.
    Case 37 caused MATLAB Online shutdown after ACTION_DONE board1 off during CAPTURE_START.
    This strongly suggests a MATLAB Online capture/render/OOM risk when full capture is combined with AVI resources, especially on board-off / complex UI states.
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


---

# 14. Additional Runtime Evidence — `CaptureMode='all'` + `LoadAvi='always'`

A later test was performed without applying the previous prompt changes, but with heavier runner options:

```matlab
auto_test_runner('CaptureMode','all','LoadAvi','always')
```

Observed hard shutdowns:

```text
case 6:
    SETUP_DONE
    BASELINE_CAPTURE_START
    MATLAB Online shutdown / reload

case 37:
    SETUP_DONE
    BASELINE_CAPTURE_DONE
    ACTION_START board1 off
    ACTION_DONE board1 off
    CAPTURE_START board1 off
    MATLAB Online shutdown / reload
```

## Interpretation

These shutdown points are important.

Case 6 fails before any test action starts. It dies during baseline capture after AVI resources are loaded. This strongly suggests:

```text
LoadAvi='always'
+ CaptureMode='all'
+ MATLAB Online renderer
+ full UI capture buffer
= high risk of OOM / renderer crash
```

Case 37 dies after board-off action but before validation is recorded, during capture. This suggests:

```text
board-off / hsplit / complex UI state
+ full capture
+ AVI resources loaded
= high risk of MATLAB Online hard shutdown
```

Do not treat these two shutdowns as pure app logic exceptions unless they reproduce with:

```matlab
CaptureMode='none'
```

---

# 15. Priority 9 — Add MATLAB Online Safe Runner Mode

Add an optional `OnlineSafeMode` parameter to `auto_test_runner.m`.

Suggested default:

```matlab
OnlineSafeMode = false
```

When enabled:

```text
1. Warn or prevent broad runs using CaptureMode='all' + LoadAvi='always'.
2. Recommend or force CaptureScale <= 0.6 for broad case ranges.
3. Prefer LoadAvi='never' or LoadAvi='lazy' unless the case explicitly requires AVI.
4. Write index.md after every completed case.
5. Clear capture image buffers after imwrite/export.
6. Call drawnow and a short pause after capture and cleanup, if safe.
7. Avoid heavy hidden UI scans such as findall(boardOffPanel).
8. Do not perform summary-panel marker/xline scans for the new board-off policy.
9. Keep progress.md flushing as frequent as possible.
```

## Required Warning / Guard

If the user requests a broad test run with:

```matlab
CaptureMode='all'
LoadAvi='always'
```

then the runner should warn clearly:

```text
This combination is unsafe in MATLAB Online for broad runs.
Use LoadAvi='never' or 'lazy', CaptureMode='fail' or 'none', and CaptureScale <= 0.6.
```

The runner may continue only if explicitly allowed, but the warning must be visible in `progress.md` and command output.

## Recommended Safe Defaults for MATLAB Online

For layout/theme/board-off tests:

```matlab
auto_test_runner('LoadAvi','never','CaptureMode','fail','CaptureScale',0.6)
```

For maximum stability:

```matlab
auto_test_runner('LoadAvi','never','CaptureMode','none')
```

For AVI-specific tests only:

```matlab
auto_test_runner('CaseList',[specific video cases], ...
                 'LoadAvi','always', ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.5)
```

Do not use `LoadAvi='always'` as the default for all layout/theme cases.

---

# 16. Priority 10 — Add `LoadAvi='lazy'` or Equivalent Case-Aware AVI Loading

The observed case 6 shutdown shows that loading AVI for every case is not appropriate.

If feasible, add or strengthen a `LoadAvi='lazy'` mode.

Behavior:

```text
LoadAvi='never':
    never load AVI

LoadAvi='lazy':
    load AVI only for cases that explicitly require video/AVI behavior

LoadAvi='always':
    load AVI for every case; intended only for narrow video-specific debugging
```

If `lazy` is too large a change, at least classify test cases so non-video layout/theme cases can run with `LoadAvi='never'`.

The runner should not load AVI for tests that only check:

```text
panel toggles
map/alt independent toggles
layout presets
board-off arrangement without video
theme colors
splitter geometry
plot flex
project layout state
```

---

# 17. Priority 11 — Capture Pipeline Memory Safety

Update the capture pipeline to reduce MATLAB Online shutdown risk.

Required safeguards:

```text
1. Downscale early when CaptureScale < 1.
2. Clear raw frame/image variables immediately after imwrite.
3. Avoid keeping large image arrays in result structs.
4. Avoid repeated full-size captures in broad runs.
5. Use drawnow after capture and cleanup.
6. Ensure case result markdown stores file paths, not image data.
7. If capture fails, record CAPTURE_FAILED and continue if possible.
8. If CaptureMode='fail', do not capture baseline unless needed for failure evidence.
```

If the runner currently captures baseline for every case under `CaptureMode='all'`, keep that behavior only when explicitly requested. In MATLAB Online safe mode, prefer:

```text
baseline capture only for selected cases
or scaled baseline capture
or no baseline capture
```

---

# 18. Priority 12 — Update Crash-Prone Case Strategy

Document and support isolated execution of crash-prone cases.

Required examples:

```matlab
auto_test_runner('CaseList',6, ...
                 'CaptureMode','none', ...
                 'LoadAvi','always')
```

```matlab
auto_test_runner('CaseList',37, ...
                 'CaptureMode','none', ...
                 'LoadAvi','always')
```

```matlab
auto_test_runner('CaseList',37, ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.5, ...
                 'LoadAvi','never')
```

For broad runs, recommend:

```matlab
auto_test_runner('Order','desc', ...
                 'Skip',[2 5 6 37 48], ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.6, ...
                 'LoadAvi','never')
```

This allows collecting the remaining test results even if specific cases are unstable in MATLAB Online.

---

# 19. Priority 13 — Reinterpret Case 6 and Case 37 Correctly

Do not immediately classify case 6 and case 37 as app functional failures.

## Case 6

Because the shutdown happened during:

```text
BASELINE_CAPTURE_START
```

and before action execution, classify it first as:

```text
MATLAB Online capture/render/OOM risk under LoadAvi='always' + CaptureMode='all'
```

Re-test case 6 with:

```matlab
auto_test_runner('CaseList',6,'CaptureMode','none','LoadAvi','always')
```

If it passes without capture, the primary issue is the capture pipeline, not the case action.

## Case 37

Because the shutdown happened during:

```text
CAPTURE_START after board1 off ACTION_DONE
```

classify it first as:

```text
board-off UI + full capture + AVI resource stress
```

Re-test with:

```matlab
auto_test_runner('CaseList',37,'CaptureMode','none','LoadAvi','always')
```

and:

```matlab
auto_test_runner('CaseList',37,'CaptureMode','fail','CaptureScale',0.5,'LoadAvi','never')
```

Only if it still crashes without capture should it be treated as a hard board-off app defect.

---

# 20. Priority 14 — Strengthen Light Theme Fixes Based on New Captures

The latest captures still show:

```text
black non-video plot areas
dark table-like regions
white text on dark non-video UI
strong saturated blue/purple table backgrounds
low-contrast gray text on light backgrounds
```

Strengthen the theme requirements:

## Non-video plot / axes

```text
All non-video axes must use:
    Color = white or near-white
    XColor / YColor = dark gray
    GridColor = light gray
    title/label text = dark gray
```

## Data table / data view

```text
Table BackgroundColor should be white or near-white.
Table text should be dark gray / near black.
Do not use saturated full-panel blue/purple backgrounds.
Flight identity may be shown with subtle accent only:
    thin border strip
    light header tint
    small label badge
    very light row tint
```

## Text contrast

Forbidden:

```text
light gray text on white background
white text on black non-video background
dark-mode text palette in light UI
```

Use at least:

```text
normal text: near black / dark gray
muted text: medium gray, not pale gray
disabled text: clearly disabled but still readable
```

## Buttons

```text
normal button: light gray
active/selected: MATLAB blue or light blue
warning/error only: red/orange
```

Do not use red for normal active toggle states.

---

# 21. Additional Required Smoke Tests for the New Runtime Findings

After applying runner and theme changes, perform or document these tests.

## Capture safety comparison

```matlab
auto_test_runner('CaseList',6,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',6,'CaptureMode','all','CaptureScale',0.5,'LoadAvi','always')
```

Expected:

```text
If none passes and all fails, the capture path is the likely crash trigger.
If both fail, inspect AVI load/setup and case 6 setup path.
```

## Board-off capture safety comparison

```matlab
auto_test_runner('CaseList',37,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',37,'CaptureMode','fail','CaptureScale',0.5,'LoadAvi','never')
```

Expected:

```text
No hidden summary-panel heavy scans.
No Video Player popup.
No full-size capture required for normal validation.
```

## Light theme capture

```matlab
auto_test_runner('CaseList',[3 4 5],'CaptureMode','all','CaptureScale',0.6,'LoadAvi','never')
```

Expected:

```text
No black non-video plot/data areas.
No white text on black non-video UI.
No saturated blue/purple table background.
No low-contrast gray-on-white text.
```

---

# 22. Updated Definition of Done Additions

In addition to the existing Definition of Done, this task is complete only when:

1. `auto_test_runner.m` warns or guards against broad `CaptureMode='all'` + `LoadAvi='always'` runs in MATLAB Online.
2. `OnlineSafeMode` or equivalent safe-run guidance exists.
3. Case 6 is reclassified and isolated as capture/setup stress until proven otherwise.
4. Case 37 is reclassified and isolated as board-off capture stress until proven otherwise.
5. Capture pipeline clears large image buffers and writes progress/index incrementally.
6. Broad tests can be run with `LoadAvi='never'`, `CaptureMode='fail'`, `CaptureScale<=0.6`.
7. AVI-specific tests can be isolated without forcing AVI into all layout/theme cases.
8. The light theme removes black non-video plot/table regions and low-contrast text.


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
