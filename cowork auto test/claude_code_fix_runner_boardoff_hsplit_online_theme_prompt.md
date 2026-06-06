# Claude Code Prompt — Fix Remaining Runner/Test Policy Issues, Hidden BoardOff Scans, HSplit Visibility, OnlineSafeMode, and Light Theme

You are Claude Code working on a MATLAB GUI project.

## Target Files

Main app:

```text
FlightDataDashboard.m
```

Current reviewed app file:

```text
FlightDataDashboard(14).m
```

Test runner:

```text
auto_test_runner.m
```

Current reviewed runner file:

```text
auto_test_runner(1).m
```

## Background

The latest revision made several meaningful improvements:

- `auto_test_runner.m` now supports `Order`, `Skip`, and `CaseList`.
- `LoadAvi` default is now closer to a safer model, with `lazy` support.
- `CaptureScale` default was lowered.
- `index.md` is written after each completed case, improving crash resilience.
- `UserColumnWidths` remains struct-based.
- `plot/dataView` is mostly protected as `'1x'`.
- `layout-hsplit` now attempts a real 2-row layout.
- Light theme was improved, including less saturated table backgrounds in some paths.

However, strict review of `FlightDataDashboard(14).m` and `auto_test_runner(1).m` found remaining issues that must be fixed before the implementation can be considered stable.

The most important remaining problems are:

1. `auto_test_runner.m` still contains legacy `map` test actions even though the UI now has independent `mapOnly` and `altOnly`.
2. `i_validateBodyRows` still expects the old board-off summary-row policy.
3. `i_updateExpectedState` still appears to carry stale summary-related expectations such as `summaryVisible` and `sourceColumnsHidden`.
4. `FlightDataDashboard.getTestState` / `collectTestBoardState` still scans hidden `boardOffPanel` contents with `findall`, marker, line, and plot traversal.
5. `applyBoardHsplit` uses shared columns for upper and lower rows, so `info` and `dataView` hidden states may not be respected unless panel visibility is explicitly synchronized.
6. `OnlineSafeMode` is currently mostly a warning, not a real protective mode.
7. The capture pipeline still risks MATLAB Online renderer/OOM issues under full capture and AVI load.
8. The light theme is improved but may still leave saturated/legacy table or plot styles unless enforced more consistently.

Fix these issues in a scoped patch. Do not rewrite unrelated video decoding, async cache, parser, sync, or project save/load logic.

---

## Critical Output Rules

Follow these strictly.

1. Do not print the full modified MATLAB files.
2. Do not print large code blocks.
3. Keep changes scoped to:
   - `auto_test_runner.m` test matrix and validation policy,
   - board-off / hsplit test-state reporting,
   - hidden `boardOffPanel` scan prevention,
   - hsplit panel visibility synchronization,
   - MATLAB Online safe runner behavior,
   - capture memory safety,
   - light theme enforcement.
4. Do not rewrite unrelated AVI decoding, async cache, parser, sync, project save/load, or core plotting logic.
5. Preserve existing Korean UI labels and comments where possible.
6. Preserve existing `try/catch` and `app.logCaught` logging patterns.
7. Do not remove existing test hooks unless replacing them with better equivalents.
8. After editing, report:
   - files changed,
   - functions changed,
   - runner changes,
   - app layout/test-state changes,
   - OnlineSafeMode/capture changes,
   - theme changes,
   - tests performed,
   - remaining risks.
9. Do not output full source code.

---

# 1. Highest Priority Summary

The next patch should not be a broad UI rewrite.

Focus on these five issues first:

```text
1. Fix auto_test_runner board row validation to match the new board-off hsplit policy.
2. Stop getTestState / collectTestBoardState from scanning hidden boardOffPanel contents.
3. Rewrite legacy map test cases to explicit mapOnly / altOnly actions.
4. Make applyBoardHsplit explicitly synchronize panel visibility for info/dataView/attitude/mapAlt.
5. Make OnlineSafeMode and capture cleanup actually reduce MATLAB Online crash risk.
```

---

# 2. Fix `auto_test_runner.m` Legacy Map/Altitude Test Matrix

## Current Problem

The runner still contains test actions like:

```matlab
P(1,'map','보드1 지도/고도 off')
P(2,'map','보드2 지도/고도 off')
```

This is now ambiguous and unsafe.

The current UI has independent toggles:

```text
mapOnly
altOnly
```

The actual buttons are:

```text
지도 -> mapOnly
고도 -> altOnly
```

Changing the expected-state logic so that `map` only toggles `mapOnly` is not enough. It makes the tests pass for the wrong reason and leaves `altOnly` insufficiently tested.

## Required Test Matrix Rewrite

Search the full `auto_test_runner.m` for all test-case definitions using:

```text
'map'
```

especially inside `P(fIdx,'map',...)`.

Replace them according to test intent.

### If the test intends “map only off”

Use:

```matlab
P(fIdx,'mapOnly','지도 off')
```

### If the test intends “altitude only off”

Use:

```matlab
P(fIdx,'altOnly','고도 off')
```

### If the test intends “map + altitude both off”

Use two explicit actions:

```matlab
P(fIdx,'mapOnly','지도 off')
P(fIdx,'altOnly','고도 off')
```

### If the test intends legacy alias compatibility

Only then keep a dedicated small legacy case, clearly named:

```text
Legacy map alias compatibility
```

Do not use legacy `map` for normal current-UI tests.

## Required Expected-State Logic

Update `i_updateExpectedState` so that:

```text
mapOnly toggles only mapOnly.
altOnly toggles only altOnly.
map = mapOnly || altOnly.
```

If the `map` legacy alias is retained, keep it isolated and explicitly documented.

## Required Validation

`i_validateState` must validate:

```text
PanelVisible.mapOnly
PanelVisible.altOnly
PanelVisible.map = mapOnly || altOnly
```

Do not fail current UI tests because `mapOnly` and `altOnly` are no longer toggled together.

---

# 3. Fix `i_validateBodyRows` to Match New Board-Off Policy

## Current Problem

`i_validateBodyRows` still appears to expect the old board-off summary-row layout.

Old policy:

```text
off board summary row visible
source board + summary row share height
boardOffPanel visible
```

New policy:

```text
board-off = active source board hsplit
old boardOffPanel summary is not primary UI
source board may occupy 100% body area
source board internal layout is hsplit
```

Therefore, body row validation must not fail merely because the summary row is collapsed.

## Required New Row Validation

When upper board is off:

```text
row1 == 0 or hidden
row2 == 0 or hidden
row3 > 0
row4 may be 0
source board = Flight 2
source arrangementMode == 'hsplit'
```

When lower board is off:

```text
row1 > 0
row2 may be 0
row3 == 0 or hidden
row4 == 0 or hidden
source board = Flight 1
source arrangementMode == 'hsplit'
```

When both boards are visible:

```text
row1 > 0
row2 splitter visible or valid
row3 > 0
row4 == 0 or hidden
BodyRowSplitRatio should be valid
```

Do not require row4 or summary-row height to be nonzero under board-off.

The key board-off validation must be:

```text
source board visible
source board arrangementMode == hsplit
off board hidden/collapsed
Video Player not visible/opened
plot column remains '1x' when visible
```

---

# 4. Remove Stale Summary Expectations From Runner State

## Current Problem

`i_updateExpectedState` still appears to use or maintain stale fields like:

```text
summaryVisible
sourceColumnsHidden
```

These are old board-off summary policy artifacts.

Under the new policy:

```text
summaryVisible should not be required.
sourceColumnsHidden should not be required.
source board info/plot should not be hidden as if moved to summary.
source board should be hsplit.
```

## Required Change

If possible, remove these expectation fields from validation.

If removing them is too risky, mark them as deprecated and stop using them for pass/fail decisions.

New expected-state fields should include:

```text
expected.BoardOffState
expected.SourceBoardIndex
expected.SourceArrangementMode = 'hsplit'
expected.OffBoardHidden = true
expected.VideoViewerVisible = false
```

The runner must not fail because:

```text
boardOffPanelVisible == false
summary table row count == 0
summary plot count == 0
source info/plot columns are not hidden
```

Those are not failures under the new policy.

---

# 5. Stop Heavy Hidden `boardOffPanel` Scans in `getTestState`

## Current Problem

`FlightDataDashboard.collectTestBoardState` still scans `boardOffPanel` contents when the handle exists.

It may call:

```matlab
findall(app.UI(fIdx).boardOffPanel)
```

and it may traverse:

```text
boardOffPlotTabs
boardOffPlotAxes
boardOffTimeMarkers
boardOffTimeLines
boardOffTable
```

This is dangerous because:

1. `boardOffPanel` is no longer primary UI.
2. It may be hidden.
3. Scanning hidden UI trees is unnecessary.
4. This can increase MATLAB Online renderer / handle traversal stress.
5. Case 48 hard shutdown was suspected to involve stale hidden summary-panel validation/scanning.

## Required Change

In `collectTestBoardState`:

```text
If boardOffPanel does not exist:
    record boardOffPanelVisible = false
    do not scan children

If boardOffPanel exists but is hidden or non-primary:
    record boardOffPanelVisible only
    do not call findall(boardOffPanel)
    do not scan boardOffPlotTabs
    do not scan boardOffTimeMarkers
    do not scan boardOffTimeLines
    do not scan boardOffPlotAxes
    do not scan boardOffTable except maybe lightweight row count if visible and explicitly needed
```

Only scan boardOffPanel contents if:

```text
boardOffPanel is visible
AND the current product policy explicitly says it is primary UI
```

Under the current policy, it is not primary UI, so summary scan should normally be skipped.

## Required Lightweight State Instead

Expose lightweight source-board state:

```text
boards(fIdx).arrangementMode
boards(fIdx).isHsplit
boards(fIdx).upperRegionHasInfoPlot
boards(fIdx).lowerRegionHasRemainingPanels
boards(fIdx).panelVisible
boards(fIdx).PanelVisible
boards(fIdx).dataGridColumnWidth
boards(fIdx).videoViewerVisible
```

---

# 6. Fix `applyBoardHsplit` Panel Visibility in Shared-Column Layout

## Current Risk

`applyBoardHsplit` appears to use the same `dataGrid` columns for upper and lower rows, for example:

```text
Row 1:
    column 1 = info
    column 3 = dataView / plot

Row 3:
    column 1 = attitude
    column 3 = map/alt
```

This can work, but width-based hiding is not enough.

Example risk:

```text
info hidden but attitude visible:
    column 1 must remain visible for attitude
    therefore panelInfo must be explicitly hidden

dataView hidden but map/alt visible:
    column 3 must remain visible for map/alt
    therefore panelDataView must be explicitly hidden
```

Normal mode could hide info/dataView by setting column widths to 0, but hsplit cannot rely only on column widths because rows share columns.

## Required Change

Inside `applyBoardHsplit`, synchronize individual panel visibility explicitly:

```text
panelInfo.Visible       = PanelVisible.info
panelDataView.Visible   = PanelVisible.dataView
panelAttitude.Visible   = PanelVisible.attitude
panelMapAlt.Visible     = PanelVisible.mapOnly || PanelVisible.altOnly
```

Use the app’s safe visibility helper if one exists, for example:

```text
setUiVisible(handle, logicalValue)
```

Also ensure:

```text
info/dataView hidden state does not leave blank upper cells
attitude/mapAlt hidden state does not leave blank lower cells
plot/dataView remains flex '1x' when visible
```

## Stronger Long-Term Option

If the shared-column model becomes too fragile, introduce separate upper/lower grids:

```text
upperGrid:
    info + plot

lowerGrid:
    attitude + map/alt
```

But do not do this if it requires a large rewrite. First patch should be scoped.

---

# 7. Strengthen `OnlineSafeMode`

## Current Problem

`OnlineSafeMode` currently appears to only warn when:

```text
OnlineSafeMode == true
CaptureMode == 'all'
LoadAvi == 'always'
```

This is not enough.

## Required Behavior

When `OnlineSafeMode` is true:

1. Record a warning in command output and `progress.md` if the requested options are risky.
2. If `CaptureMode='all'` and `LoadAvi='always'` and the run is broad, warn strongly.
3. If `CaptureScale > 0.6`, either:
   - clamp it to 0.6, or
   - warn strongly and record it in `progress.md`.
4. If many cases are being run with `LoadAvi='always'`, warn that AVI should be lazy or never for layout/theme tests.
5. Avoid broad full capture with AVI resources loaded.
6. Preserve explicit user control, but make the risk visible and persistent in logs.

## Broad Run Detection

Treat as broad if:

```text
numel(caseOrder) > 5
```

or if `CaseList` is empty and many cases will run.

## Recommended Messages

Command and progress warning:

```text
MATLAB Online risk: CaptureMode='all' + LoadAvi='always' over broad case range can hard-crash.
Recommended: LoadAvi='never' or 'lazy', CaptureMode='fail' or 'none', CaptureScale<=0.6.
```

## Optional Auto-Clamp

If safe and acceptable:

```text
if OnlineSafeMode && CaptureScale > 0.6
    CaptureScale = 0.6
    log warning
end
```

Do not silently clamp. Always log.

---

# 8. Improve Capture Pipeline Memory Safety

## Current Risk

`i_capture` may perform:

```matlab
f = getframe(app.UIFigure);
img = f.cdata;
resize after full frame exists;
imwrite(img, file);
return;
```

Even when scaled output is requested, the full-size frame buffer is created first. This may be unavoidable with `getframe`, but memory handling can still be improved.

## Required Changes

After each capture attempt:

```text
clear large image/frame variables
do not store image arrays in result structs
store only file paths in markdown/results
drawnow limitrate or drawnow after capture
short pause if needed for MATLAB Online renderer stability
```

If fallback capture such as `exportapp` is used:

```text
do not repeatedly fallback to full-size exportapp in broad OnlineSafeMode runs without warning
record fallback use in progress.md
```

For `CaptureMode='fail'`:

```text
do not capture baseline unless needed by the current design
capture only failure evidence when possible
```

If preserving existing baseline behavior is necessary, keep it but apply scaling and cleanup.

---

# 9. Reclassify Case 6 and Case 37 Correctly

## Case 6

Observed shutdown:

```text
SETUP_DONE
BASELINE_CAPTURE_START
MATLAB Online shutdown
```

This happened before action execution.

Therefore classify first as:

```text
capture/render/OOM risk under LoadAvi='always' + CaptureMode='all'
```

not as a pure app behavior failure.

Required isolated tests:

```matlab
auto_test_runner('CaseList',6,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',6,'CaptureMode','all','CaptureScale',0.5,'LoadAvi','always')
```

## Case 37

Observed shutdown:

```text
ACTION_DONE board1 off
CAPTURE_START board1 off
MATLAB Online shutdown
```

Classify first as:

```text
board-off UI + full capture + AVI resource stress
```

Required isolated tests:

```matlab
auto_test_runner('CaseList',37,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',37,'CaptureMode','fail','CaptureScale',0.5,'LoadAvi','never')
```

If `CaptureMode='none'` passes but full capture fails, prioritize capture pipeline / renderer mitigation.

If `CaptureMode='none'` also crashes, then inspect app board-off logic more deeply.

---

# 10. Keep `LoadAvi='lazy'` and Avoid AVI Loading for Layout/Theme Tests

## Required Policy

Do not load AVI for cases that only test:

```text
panel toggles
mapOnly / altOnly behavior
layout presets
board-off arrangement without video sync
theme colors
splitter geometry
plot flex
project layout state
```

`LoadAvi='always'` should be treated as video-specific debugging, not broad regression default.

## Recommended Default Commands

For layout/theme/board-off testing:

```matlab
auto_test_runner('LoadAvi','never','CaptureMode','fail','CaptureScale',0.6)
```

For maximum MATLAB Online stability:

```matlab
auto_test_runner('LoadAvi','never','CaptureMode','none')
```

For video-specific tests:

```matlab
auto_test_runner('CaseList',[videoCaseIds], ...
                 'LoadAvi','always', ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.5)
```

For broad run excluding risky cases:

```matlab
auto_test_runner('Order','desc', ...
                 'Skip',[2 5 6 37 48], ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.6, ...
                 'LoadAvi','never')
```

Document these examples in the runner header.

---

# 11. Strengthen Light Theme Enforcement

## Current Status

The light theme is improved, but do not assume it is complete.

Captured UI still showed or previously showed:

```text
black non-video plot/data areas
strong saturated blue/purple table backgrounds
white text on dark non-video UI
light gray text on white/light background
```

## Required Theme Enforcement

For dashboard-owned, non-video UI:

```text
axes background = white or near-white
plot panel background = white or very light gray
table background = white or near-white
table foreground = dark gray / near black
normal label text = dark gray / near black
muted text = medium gray, not pale gray
active button = MATLAB blue / light blue
warning/error = red/orange only when semantically warning/error
```

## Table Theme

Do not rely on “only if very dark, then fix” behavior.

For dashboard data tables and board-off tables:

```text
force light theme by role:
    BackgroundColor = white or near-white
    ForegroundColor = dark gray / near black
```

Flight identity colors must not be full saturated table backgrounds.

Allowed alternatives:

```text
subtle panel title tint
small label badge
thin border/accent strip
very light row tint
```

## Non-video Plot Area

Non-video plot/data axes must not remain black.

Video/image display axes may remain black if needed for video display, but this exception must be limited to actual video/image content.

---

# 12. Required Test State and Diagnostics

Update `getTestState` / `collectTestBoardState` if needed to expose:

```text
boards(fIdx).arrangementMode
boards(fIdx).isHsplit
boards(fIdx).upperRegionHasInfoPlot
boards(fIdx).lowerRegionHasRemainingPanels
boards(fIdx).boardOffPanelVisible
boards(fIdx).videoViewerVisible
boards(fIdx).dataGridColumnWidth
boards(fIdx).PanelVisible
BodyGrid.RowHeight
BodyRowSplitRatio
```

For theme diagnostics, expose only lightweight values if practical:

```text
table background/foreground colors
axes background colors
button active colors
main panel background colors
```

Do not add heavy theme scans that traverse all hidden UI objects.

---

# 13. Required Smoke Tests

After changes, run or document these tests.

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
```

## Hsplit visibility

```matlab
app = FlightDataDashboard;
app.testHook('togglePanel',1,'info');
app.testHook('applyLayoutPreset','layout-hsplit');
st = app.testHook('getTestState');
delete(app);
```

Expected:

```text
info hidden state is respected in hsplit.
dataView/plot remains flexible if visible.
No blank or stale upper info panel is shown.
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

## Board-off upper/lower

```matlab
app = FlightDataDashboard;
app.testHook('pushBoardToggleButton',1);
stUpper = app.testHook('getTestState');
app.testHook('pushBoardToggleButton',1);
app.testHook('pushBoardToggleButton',2);
stLower = app.testHook('getTestState');
delete(app);
```

Expected:

```text
Upper board off:
    source = Flight 2
    Flight 2 arrangementMode = hsplit
    Flight 1 hidden/collapsed
    boardOffPanel not primary
    Video Player not opened

Lower board off:
    source = Flight 1
    Flight 1 arrangementMode = hsplit
    Flight 2 hidden/collapsed
    boardOffPanel not primary
    Video Player not opened
```

## Runner isolated cases

```matlab
auto_test_runner('CaseList',5,'CaptureMode','none','LoadAvi','never')
auto_test_runner('CaseList',6,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',37,'CaptureMode','none','LoadAvi','always')
auto_test_runner('CaseList',48,'CaptureMode','none','LoadAvi','never')
```

## Safe broad run

```matlab
auto_test_runner('Order','desc', ...
                 'Skip',[2 5 6 37 48], ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.6, ...
                 'LoadAvi','never', ...
                 'OnlineSafeMode',true)
```

---

# 14. Static Review Checklist

Before final response, verify:

```text
FlightDataDashboard.m parses.
auto_test_runner.m no longer uses legacy map actions for normal current-UI tests.
mapOnly and altOnly expected states are independent.
i_validateBodyRows no longer expects summary row under board-off.
Board-off validation uses source arrangementMode == hsplit.
boardOffPanel hidden/non-primary does not trigger failure.
getTestState does not scan hidden boardOffPanel contents.
No heavy findall(boardOffPanel) for hidden/non-primary panels.
applyBoardHsplit explicitly syncs panel visibility.
info/dataView hidden state works in hsplit.
plot/dataView remains '1x' when visible.
UserColumnWidths remains struct-based.
OnlineSafeMode records warnings in progress.md and command output.
Capture pipeline clears large image variables after writes.
Broad CaptureMode='all' + LoadAvi='always' is warned or guarded.
No board-off/layout/reflow path opens Video Player.
Light theme removes black non-video plot/table areas.
Light theme removes low-contrast gray-on-white text.
Tables use white/near-white background and dark text.
try/catch and app.logCaught patterns are preserved.
```

---

# 15. Final Response Format

After completing the patch, respond with only:

```text
## Summary
- ...

## Files Changed
- ...

## Test Runner Changes
- ...

## App Layout / Test-State Changes
- ...

## OnlineSafeMode / Capture Changes
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

1. `auto_test_runner.m` uses explicit `mapOnly` and `altOnly` actions for current UI tests.
2. Case 5 no longer fails from stale map/alt expectations.
3. `i_validateBodyRows` matches the new board-off hsplit policy.
4. Board-off tests no longer require `boardOffPanel` summary visibility.
5. `collectTestBoardState` does not scan hidden/non-primary `boardOffPanel` contents.
6. `applyBoardHsplit` respects `info`, `dataView`, `attitude`, and `mapAlt` visibility explicitly.
7. `OnlineSafeMode` provides real warnings/logging and reduces unsafe broad-run behavior.
8. Capture cleanup reduces MATLAB Online renderer/OOM risk.
9. Case 6 and case 37 are isolated and interpreted as capture/AVI stress until proven otherwise.
10. Plot/dataView remains `'1x'` whenever visible.
11. Light theme has no black non-video plot/table areas and no low-contrast text.
12. Existing error logging and cleanup safety are preserved.
