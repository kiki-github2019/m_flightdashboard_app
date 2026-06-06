# Claude Code Prompt — Final Reconciliation Review and Patch Plan for Layout, Board-Off, Normalization, Runner, and Theme

You are Claude Code working on a MATLAB GUI project.

## Target Files

Review and patch only these main files unless absolutely necessary:

```text
FlightDataDashboard.m
auto_test_runner.m
```

Recent reviewed versions:

```text
FlightDataDashboard(15).m
auto_test_runner(2).m
```

## Purpose

This prompt reconciles two strict reviews of the latest code:

1. Review A: a detailed static review of the uploaded latest files.
2. Review B: a compliance review that scored the implementation about 8.4/10 against the v3/v4 layout prompt.

The two reviews agree on many improvements, but they differ in emphasis. Your task is to verify the latest code, resolve contradictions, and apply only scoped fixes.

Do not assume the code is correct because helper names exist. Verify actual behavior and actual call paths.

---

## Critical Output Rules

Follow these strictly.

1. Do not print full modified MATLAB files.
2. Do not print large code blocks.
3. Keep changes scoped to:
   - MATLAB syntax repair,
   - board-off / hsplit behavior,
   - layout preset arrangement-only enforcement,
   - normalization call paths,
   - splitter drag/double-click normalization,
   - auto test runner expectations,
   - hidden boardOffPanel scan prevention,
   - MATLAB Online safe runner behavior,
   - light theme consistency.
4. Do not rewrite unrelated AVI decoding, async cache, data parser, project save/load internals, or core plotting logic unless directly required by the issues below.
5. Preserve Korean UI labels and comments where possible.
6. Preserve existing `try/catch` and `app.logCaught` logging patterns.
7. Preserve existing test hooks unless replacing them with equivalent or better hooks.
8. After editing, report files changed, functions changed, tests performed, and remaining risks.
9. Do not output full source code.

---

# 1. Reconciled Overall Assessment

## Review B Compliance Score

Review B rated the current implementation:

```text
Compliance score: 8.4 / 10
```

Positive findings from Review B:

```text
- normalizeColumnWidthsForVisiblePanels is implemented well.
- plot/dataView is forced to '1x' when visible.
- hidden panel -> column=0 and adjacent splitter=0.
- normalization appears idempotent.
- UserColumnWidths strategy is mostly correct:
    attitudeWidth
    mapAltWidth
    infoWidth
  and does not store plot/splitter/hidden columns.
- test hooks improved:
    compareRoundTripLayoutState
    normalizeLayoutSpecCellsForCompare
    arrangementMode
- project layout save/load calls normalization.
- legacy 6-column -> 8-column compatibility is partially handled.
```

Remaining issues from Review B:

```text
- Board-off behavior is still the largest unresolved item.
- boardOffPanel / createBoardOffSummaryPanel may still exist and conflict with source-board hsplit policy.
- Layout preset arrangement-only policy may only be partially enforced.
- Old focus-style presets may still exist or be reachable.
- normalizeColumnWidthsForVisiblePanels may not be called on every critical path.
- splitter drag end and double-click reset may not normalize.
- V/video-focus remnants may still exist.
```

## Review A Additional Findings

Review A identified stricter issues:

```text
- There may still be MATLAB syntax errors caused by single '.' used where '...' is required.
- auto_test_runner may still contain legacy 'map' actions in the test matrix.
- board-off tests may still mix old summary-row/summary-panel assumptions with new hsplit policy.
- i_applyAction may skip panel toggle actions during board-off, preventing required tests.
- collectTestBoardState avoids hidden boardOffPanel scans, but uses an early return that could block future lightweight diagnostics.
- applyBoardHsplit must explicitly sync panel Visible states because shared columns are used.
- light theme table enforcement remains too conditional.
- capture safety and OnlineSafeMode improved but may still be incomplete.
```

Your task is to verify which findings are actually true in the latest code and then patch only the confirmed issues.

---

# 2. Priority 0 — Verify MATLAB Syntax Before Any Functional Work

Review A found many suspicious patterns where MATLAB line continuation may be corrupted:

```matlab
app.EDPlotYAutoCB = uicheckbox(..., .
uibutton(actRow, 'Text', '적용', .
```

MATLAB line continuation must be:

```matlab
...
```

not a single dot.

## Required Action

Before any behavior edits:

```matlab
checkcode FlightDataDashboard.m
checkcode auto_test_runner.m
```

Also search both files for suspicious patterns:

```text
", ."
"|| ."
"&& ."
"= ."
") ."
"(."
"' ."
```

If these are actual source text and intended as line continuations, replace them with valid MATLAB `...`.

Do not alter behavior during this syntax-only pass.

No later test result is meaningful until both files parse.

---

# 3. Priority 1 — Board-Off Policy Must Be Singular and Enforced

## Required Product Policy

Board-off is not the old summary-panel mode.

The required board-off policy is:

```text
Board-off = active source board hsplit arrangement
```

### Upper board off

```text
active source = Flight 2

upper region:
    Flight 2 current flight info + plot data

lower region:
    Flight 2 remaining visible panels
```

### Lower board off

```text
active source = Flight 1

upper region:
    Flight 1 current flight info + plot data

lower region:
    Flight 1 remaining visible panels
```

## Forbidden Behavior

Do not implement board-off as:

```text
primary visible boardOffPanel summary UI
source board stretched without internal hsplit
duplicated stale summary content
summary table / summary plot tabs as the primary board-off UI
Video Player popup
focus-only layout
```

## Required Code Audit

Search and classify:

```text
toggleBoardVisibility
setBoardOffDirect
applyBoardHsplit
applyBoardNormal
applyBoardArrangement
applySingleBoardArrangement
boardOffPanel
createBoardOffSummaryPanel
refreshBoardOffSummaryPanel
hideBoardInfoPlotColumns
BoardOffSourceRatio
```

Determine exactly which code path is currently used when:

```text
하단 보드 off
상단 보드 off
board on restore
```

## Required Fix

If old summary behavior is still primary or mixed with source hsplit:

```text
- Keep source board visible.
- Collapse/hide off board.
- Keep boardOffPanel hidden or non-primary.
- Apply applyBoardHsplit(sourceIdx).
- Ensure source board info + plot are visible in upper region.
- Ensure remaining visible panels are placed in lower region.
- Do not open Video Player.
```

If compatibility code for `boardOffPanel` must remain, it must not be visible or required for board-off success under the new policy.

---

# 4. Priority 2 — Enforce Layout Preset Arrangement-Only Philosophy

Review B flagged that arrangement-only behavior may be incomplete.

## Required Presets

Only these user-facing layout presets should be active:

```text
layout-grid
layout-vsplit
layout-hsplit
layout-compact
layout-reset
```

Remove or fully isolate old focus-style presets:

```text
single-top
single-bot
dual-3:1-top
dual-3:1-bot
data-focus
gauges-only
map-focus
video-focus
V button
```

## Required Behavior

Layout presets must not:

```text
change PanelVisible
change BoardOffState
change BodyGrid.RowHeight when both boards are visible
change BodyRowSplitRatio when both boards are visible
open Video Player
close Video Player
force a focus-only layout
```

## Required Code Audit

Search and inspect:

```text
applyLayoutPreset
buildLayoutPresetPicker
LayoutPresetButtons
HeaderLayoutPresetDD
CurrentLayoutPreset
applyLayoutUiState
collectLayoutUiState
setVideoViewerVisible
setBoardOffDirect
toggleBoardVisibility
PanelVisible
```

## Required Guards

Add explicit guards or assertions where helpful:

```text
Before applying a layout preset:
    save PanelVisible, BoardOffState, BodyGrid.RowHeight, BodyRowSplitRatio, Video dialog state

After applying the preset:
    verify forbidden state changes did not occur
    restore or log if an illegal change happened
```

Do not over-engineer; lightweight checks are enough.

---

# 5. Priority 3 — Confirm Normalization Helper and Call Sites

Review B says `normalizeColumnWidthsForVisiblePanels` is well implemented. Preserve it.

Do not rewrite it unless a specific defect is found.

## Required Normalization Rules

The helper must still enforce:

```text
plot/dataView visible => plot column = '1x'
hidden panel => corresponding column = 0
adjacent splitter to hidden panel => 0
UserColumnWidths stores only adjustable fixed widths
```

## Required Call Sites

Verify and ensure normalization is called after every critical layout-affecting path:

```text
reflowBoardColumns
stopColumnSplitterDrag
column splitter double-click reset
applyLayoutPreset
applyLayoutUiState
applyProjectState / project layout restore
togglePanel
applyMapAltVisibility
toggleBoardVisibility / board-off transition
applyBoardHsplit
applyBoardNormal
onFigureSizeChanged / applyResponsiveLayout
```

Review B specifically notes that splitter drag end and double-click may not clearly call normalization.

## Required Fix

If missing, add:

```text
normalizeColumnWidthsForVisiblePanels
or reflowBoardColumns which internally normalizes
```

at the end of those paths.

Do not store plot, splitter, hidden, or legacy columns in `UserColumnWidths`.

---

# 6. Priority 4 — HSplit Shared-Column Visibility Must Be Explicit

Review A flagged a real structural risk.

If `applyBoardHsplit` uses shared columns such as:

```text
Row 1, Col 1 = info
Row 1, Col 3 = dataView / plot
Row 3, Col 1 = attitude
Row 3, Col 3 = map/alt
```

then width-based hiding is insufficient.

Example:

```text
info hidden but attitude visible:
    shared column 1 must remain visible for attitude
    therefore panelInfo itself must be hidden

dataView hidden but map/alt visible:
    shared column 3 must remain visible for map/alt
    therefore panelDataView itself must be hidden
```

## Required Fix

Inside `applyBoardHsplit`, explicitly sync individual panel visibility:

```text
panelInfo visible       = PanelVisible.info
panelDataView visible   = PanelVisible.dataView
panelAttitude visible   = PanelVisible.attitude
panelMapAlt visible     = PanelVisible.mapOnly || PanelVisible.altOnly
```

If board-off mode temporarily forces info/dataView visible, use the effective visibility for board-off:

```text
effectiveInfoVisible = true
effectiveDataViewVisible = true
```

but preserve the original `PanelVisible` policy for restoration if required.

## Required Tests

Add or run tests for:

```text
hsplit + info hidden
hsplit + dataView hidden
hsplit + attitude hidden
hsplit + mapOnly/altOnly hidden
board-off after info hidden
board-off after dataView hidden
board-on restoration after forced info/dataView visibility
```

---

# 7. Priority 5 — Board-Off Must Preserve Interactive Features

The earlier PNG review found that after board-off:

```text
plot star marker drag stopped working
Data View buttons disappeared:
    +빈 탭 추가
    현재 탭 지우기
```

## Required Audit

Verify both lower and upper board-off:

```text
1. Plot star marker drag callback exists before board-off.
2. Plot star marker drag callback exists after lower board off.
3. Plot star marker drag callback exists after upper board off.
4. Plot star marker drag callback exists after board-on restoration.
5. Data View +빈 탭 추가 button remains visible and callback-bound.
6. Data View 현재 탭 지우기 button remains visible and callback-bound.
7. Existing plot tabs are not destroyed by board-off/hsplit.
8. Board-off does not replace the active board with a non-interactive copy.
```

## Required Test State

Expose if missing:

```text
boards(fIdx).plotMarkerDraggable
boards(fIdx).dataViewAddTabButtonVisible
boards(fIdx).dataViewClearTabButtonVisible
boards(fIdx).dataViewAddTabButtonCallbackSet
boards(fIdx).dataViewClearTabButtonCallbackSet
```

---

# 8. Priority 6 — Auto Test Runner: Map/Altitude Must Be Explicit

Review A found that `i_updateExpectedState` may treat `map` as `mapOnly`, but test case labels/actions may still say `지도/고도 off`.

That is not acceptable.

## Required Runner Fix

Search the case matrix for:

```text
P(...,'map',...)
```

For current UI tests, replace with explicit actions:

```matlab
P(fIdx,'mapOnly','지도 off')
P(fIdx,'altOnly','고도 off')
```

If the intent is both map and altitude off, use two actions.

Only keep `map` in a dedicated legacy compatibility case if needed.

## Required Expected Logic

```text
mapOnly toggles only mapOnly
altOnly toggles only altOnly
map = mapOnly || altOnly
```

Do not call a test “지도/고도 off” unless both actions are actually executed.

---

# 9. Priority 7 — Auto Test Runner: Board-Off Validation Must Match New Policy

Review A found mixed validation.

## Required Validation

Under board-off:

```text
Do not require boardOffPanelVisible == true.
Do not require summary table/plot/marker counts.
Do not require old source info/plot columns to be hidden.
Do not treat collapsed summary row as failure.
```

Instead require:

```text
source board visible
source board arrangementMode == 'hsplit'
off board hidden/collapsed
Video Player not visible/opened
plot remains flexible when visible
```

## Body Row Rules

When upper board off:

```text
row1 == 0 or hidden
row2 == 0 or hidden
row3 > 0
row4 may be 0
```

When lower board off:

```text
row1 > 0
row2 may be 0
row3 == 0 or hidden
row4 == 0 or hidden
```

When both boards visible:

```text
row1 > 0
row3 > 0
row2 valid if splitter is used
row4 hidden/collapsed
```

## Column Width Rules

If source board is in hsplit during board-off:

```text
do not validate old normal-mode "moved info/plot columns hidden" rules.
validate hsplit region / panel visibility instead.
```

---

# 10. Priority 8 — Auto Test Runner Must Allow Panel Toggles During Board-Off Where Required

Review A found that `i_applyAction` may skip `togglePanel` when `BoardOffState(fIdx)` is true.

This prevents testing a required behavior:

```text
Panel visibility changes made during board-off must persist after board-on.
```

## Required Fix

Do not blindly skip panel toggles during board-off.

Instead:

```text
If action targets the active source board:
    allow the toggle.

If action targets the off/collapsed board:
    either skip intentionally with log
    or route to the source board if that is the product behavior.
```

Add explicit test actions for:

```text
board-off -> video toggle -> board-on -> video state preserved
board-off -> attitude toggle -> board-on -> attitude state preserved
board-off -> mapOnly/altOnly toggle -> board-on -> state preserved
```

If info/dataView are temporarily forced visible during board-off, document and test restoration policy.

---

# 11. Priority 9 — Hidden BoardOffPanel Scan Prevention

Review A noted that `collectTestBoardState` now skips hidden boardOffPanel scans but may use an early return.

## Required Fix

Avoid heavy scans when boardOffPanel is hidden/non-primary.

But do not use a broad early return that could skip future lightweight diagnostics.

Preferred structure:

```text
record boardOffPanelVisible

if boardOffPanelVisible && boardOffPanel is primary:
    scan summary details if needed
else:
    skip summary children only

continue collecting lightweight state
```

Do not call:

```text
findall(boardOffPanel)
boardOffPlotTabs scan
boardOffTimeMarkers scan
boardOffTimeLines scan
```

when boardOffPanel is hidden or non-primary.

---

# 12. Priority 10 — OnlineSafeMode and Capture Safety

Review A says OnlineSafeMode improved but may remain incomplete.

## Required Behavior

When `OnlineSafeMode` is true:

```text
CaptureScale > 0.6 should be clamped or strongly warned and logged.
CaptureMode='all' + LoadAvi='always' over a broad run should produce command and progress.md warnings.
LoadAvi='always' over broad case range should warn.
Warnings must be written to progress.md.
```

## Capture Memory Safety

Verify `i_capture` and related code:

```text
clear large frame/image variables after imwrite/export
do not store image arrays in results
drawnow after capture
record fallback exportapp usage in progress.md
avoid repeated full-size fallback in broad safe-mode runs
```

If missing, add scoped cleanup.

---

# 13. Priority 11 — Light Theme Must Be Role-Based, Not Conditional-Only

Review A found that table creation improved, but `applyThemeToTables` may still only fix very dark backgrounds.

## Required Fix

For dashboard-owned UI tables:

```text
BackgroundColor = white or near-white
ForegroundColor = dark gray / near black
```

Do not keep saturated blue/purple table backgrounds.

Flight identity should be a subtle accent only:

```text
panel title tint
small badge
thin accent strip
very light row tint
```

For non-video axes:

```text
Color = white or near-white
XColor/YColor = dark gray
GridColor = light gray
```

Red should be reserved for warning/error.

Active button state should use MATLAB blue/light-blue accent.

---

# 14. Priority 12 — Plot Manager and Video Prior Review Items

The latest code includes some Plot Manager improvements such as X auto and scrollable property panel. Verify, do not assume.

## Plot Manager Required Verification

Check:

```text
X auto checkbox exists above X min.
X auto disables/ignores X min/max.
Manual X min/max apply exactly and do not become [-30, 8] unexpectedly.
Apply does not auto-create 9 tabs.
Changing plot height changes actual plot panel height.
Changing plot settings preserves current marker position.
AVI load/sync/slider operations do not delete plots or Plot Manager entries.
```

## Video Dialog Required Verification

Check:

```text
Video Player is separate dialog.
Opening AVI does not distort main board layout.
Initial Video Player size avoids frame clipping.
White blank space around AVI frame is minimized.
AVI control dialog font size is increased.
Blank space below AVI control buttons is minimized.
AVI control dialog follows Video Player movement while preserving offset.
```

If not implemented, classify as not fixed and propose scoped follow-up patch. Do not mix large video dialog rewrite into the current layout/runner patch unless necessary.

---

# 15. Required Tests

After fixes, run or document:

## Syntax

```matlab
checkcode FlightDataDashboard.m
checkcode auto_test_runner.m
```

## Construction

```matlab
app = FlightDataDashboard;
st = app.testHook('getTestState');
delete(app);
```

## Map/alt explicit tests

```matlab
auto_test_runner('CaseList',5,'CaptureMode','none','LoadAvi','never')
```

## Board-off / hsplit tests

```matlab
auto_test_runner('CaseList',[37 48], ...
                 'CaptureMode','none', ...
                 'LoadAvi','never', ...
                 'OnlineSafeMode',true)
```

## Capture stress isolation

```matlab
auto_test_runner('CaseList',6, ...
                 'CaptureMode','none', ...
                 'LoadAvi','always', ...
                 'OnlineSafeMode',true)

auto_test_runner('CaseList',6, ...
                 'CaptureMode','all', ...
                 'CaptureScale',0.5, ...
                 'LoadAvi','always', ...
                 'OnlineSafeMode',true)
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

## Manual / hook tests

```text
board-off preserves plot marker drag
board-off preserves +빈 탭 추가 / 현재 탭 지우기 buttons
hsplit respects info hidden
hsplit respects dataView hidden
board-off after info hidden forces info visible if required
board-off after dataView hidden forces plot visible if required
board-on restores prior policy consistently
```

---

# 16. Static Review Checklist

Before final response, verify:

```text
No invalid single '.' line continuation remains.
normalizeColumnWidthsForVisiblePanels is preserved.
normalize is called on all critical layout paths.
UserColumnWidths stores only adjustable fixed widths.
Board-off uses source board hsplit as primary UI.
boardOffPanel is not primary visible UI.
Layout presets are arrangement-only.
Old focus presets and V/video-focus are not reachable.
Splitter drag end calls normalization.
Splitter double-click reset calls normalization.
mapOnly/altOnly test cases are explicit.
Board-off validation no longer expects old summary UI.
Panel toggles during board-off are testable where required.
Hidden boardOffPanel is not heavily scanned.
applyBoardHsplit explicitly syncs panel visibility.
OnlineSafeMode warnings are logged to progress.md.
Capture cleanup clears large image buffers.
Light theme is role-based for tables/axes/buttons/labels.
Plot Manager X auto and height apply are verified.
Video dialog requirements are classified.
```

---

# 17. Final Response Format

After completing the patch/review, respond with only:

```text
## Summary
- ...

## Files Changed
- ...

## Reconciled Review Findings
- ...

## Syntax Fixes
- ...

## Layout / Board-Off Changes
- ...

## Runner Changes
- ...

## Normalization / Splitter Changes
- ...

## Theme Changes
- ...

## Plot Manager / Video Items
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

1. Both files parse with no line-continuation syntax errors.
2. Board-off uses source-board hsplit as the primary UI.
3. Layout presets are arrangement-only.
4. Normalization is preserved and called on all critical paths.
5. Splitter drag/double-click normalize after changes.
6. UserColumnWidths remains adjustable-only.
7. mapOnly/altOnly tests are explicit.
8. Board-off runner validation matches new policy.
9. Panel toggles during board-off can be tested where required.
10. Hidden boardOffPanel is not heavily scanned.
11. HSplit respects individual panel visibility.
12. OnlineSafeMode materially reduces unsafe MATLAB Online runs.
13. Light theme uses role-based table/axes/button styling.
14. Plot Manager and video dialog prior-review items are either verified fixed or clearly classified for follow-up.
