# Claude Code Prompt — Fix FlightDataDashboard v13 Syntax, Board-Off Policy, and Test Runner Expectations

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

## Background

The latest implementation made progress toward the required layout behavior:

- `layout-hsplit` now attempts a real upper/lower arrangement.
- Board-off source board now appears to call `applyBoardHsplit`.
- `UserColumnWidths` remains struct-based.
- Plot/dataView column is still protected as `'1x'`.

However, strict review found several major issues:

1. There may be MATLAB syntax errors caused by broken line continuation markers.
2. The new source-board hsplit approach and the old `boardOffPanel` summary approach are mixed.
3. `auto_test_runner.m` still expects the old board-off summary behavior.
4. hsplit ↔ normal restoration must be verified.
5. Existing robust `try/catch` and `app.logCaught` patterns must be preserved.

Fix these issues in a scoped patch. Do not rewrite unrelated video decoding, async cache, parser, sync, or plotting logic.

---

## Critical Output Rules

Follow these strictly.

1. Do not print the full modified MATLAB files.
2. Do not print large code blocks.
3. Keep changes scoped to syntax repair, board-off / hsplit layout behavior, normal/hsplit restoration, and `auto_test_runner` expectation update.
4. Do not rewrite unrelated video decoding, parsing, async cache, or project save/load logic.
5. Preserve existing Korean UI labels and comments where possible.
6. Preserve existing `try/catch` and `app.logCaught` logging.
7. Do not remove existing test hooks unless replacing them with better equivalents.
8. After editing, report files changed, functions changed, syntax issues fixed, behavior changes, tests performed, and remaining risks.
9. Do not output full source code.

---

# 1. Priority 0 — Fix MATLAB Syntax First

Before any functional edit, run a strict syntax inspection.

The reviewed file appears to contain broken line continuation markers where MATLAB `...` may have been corrupted into a single dot `.`.

Examples to search for:

```matlab
|| .
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

Also search around newly added hsplit/layout functions:

```text
applyBoardHsplit
applyBoardNormal
setPanelLayoutCell
createBoardOffSummaryPanel
refreshBoardOffSummaryPanel
toggleBoardVisibility
reflowBoardColumns
```

## Required Fix

If a single dot is being used as a line continuation marker, replace it with MATLAB’s valid continuation marker:

```matlab
...
```

Do not change semantic code while doing this pass.

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

# 2. Priority 1 — Choose One Board-Off Policy and Enforce It

The intended policy is:

```text
Board-off = active source board hsplit arrangement
```

Do not mix this with the old summary panel architecture.

## Correct Board-Off Behavior

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

## Forbidden Behavior

Do not implement board-off as:

```text
old boardOffPanel summary UI
source board stretched without internal hsplit
duplicated stale summary content
summary table / summary plot tabs as the primary board-off UI
Video Player popup
focus-only layout
```

## Required Code Policy

When one board is off:

```text
source board must remain visible
source board must be in hsplit arrangement mode
off board original panel should be hidden or collapsed
boardOffPanel should not be visibly used as the primary UI
Video Player must not open
```

If `boardOffPanel` must remain for compatibility, keep it hidden or as a non-primary compatibility container. It must not be used as the visible board-off summary UI.

---

# 3. Priority 2 — Clean Up `toggleBoardVisibility`

Inspect and refactor `toggleBoardVisibility`.

It must not leave a mixed state such as:

```text
source board hsplit visible
AND off board boardOffPanel visible
AND source info/plot columns hidden as if moved to summary
```

Required behavior:

```text
When enabling board-off:
    set BoardOffState(fIdx) = true
    identify sourceIdx = 3 - fIdx
    hide/collapse off board panel
    hide/collapse boardOffPanel if present
    keep source board visible
    applyBoardHsplit(sourceIdx)
    update BodyGrid.RowHeight so source board has the active area
    do not open Video Player
    update board toggle buttons

When disabling board-off:
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

# 4. Priority 3 — Make `layout-hsplit` and Board-Off Use the Same Internal Arrangement

`layout-hsplit` and board-off source mode should share the same reliable internal arrangement helper.

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

## Critical Requirements

`applyBoardHsplit` must:

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

`applyBoardNormal` must:

```text
restore all panels to the normal dataGrid parent/row/column
restore column splitters according to current PanelVisible
restore ColumnWidth using normalizeColumnWidthsForVisiblePanels
not change PanelVisible
not open Video Player
```

---

# 5. Priority 4 — Validate Parent/Child Layout Safety

If `applyBoardHsplit` moves existing panels between rows/columns, verify:

1. All moved panels have the same parent grid, or are reparented safely.
2. MATLAB UI components are not assigned invalid `Layout.Row` or `Layout.Column`.
3. `dataGrid.RowHeight` and `dataGrid.ColumnWidth` are valid cell arrays.
4. Hidden panels do not consume blank space.
5. Normal → hsplit → normal returns every panel to a valid location.
6. Repeated hsplit/reset/grid cycles do not drift.

If current `dataGrid` cannot safely support true hsplit, introduce a minimal board-level container, but do not rewrite the whole app.

---

# 6. Priority 5 — Update `auto_test_runner.m` Expectations

The current `auto_test_runner.m` still validates old board-off summary behavior.

Old expected behavior includes:

```text
boardOffPanel visible
source info/plot columns hidden
summary table rows match source table rows
summary plot counts match source plots
summary markers/xlines are draggable
```

This is no longer the required behavior.

## Required New Test Expectation

When one board is off:

```text
off board panel is hidden/collapsed
boardOffPanel is hidden or not primary
source board panel is visible
source board arrangement mode is hsplit
source upper region contains info + plot
source lower region contains remaining visible panels
source plot/dataView remains flexible
Video Player is not visible/opened
```

## Required Test Runner Changes

Update `getTestState` in `FlightDataDashboard.m` if needed to expose:

```text
board arrangement mode per flight:
    normal | hsplit

whether source board is in hsplit
whether boardOffPanel is visible
whether Video Player dialog is visible
dataGrid RowHeight
dataGrid ColumnWidth
PanelVisible
BodyGrid.RowHeight
BodyRowSplitRatio
```

Update `auto_test_runner.m` validation logic:

```text
Remove old requirement that boardOffPanel must be visible.
Remove old requirement that source info/plot columns must be hidden.
Remove summary table / summary plot / summary marker validation as mandatory criteria.
Add validation that source board is hsplit during board-off.
Add validation that off board is hidden/collapsed.
Add validation that no Video Player is opened.
Add validation that plot remains '1x' when visible.
```

Do not rewrite the entire test matrix unless necessary.

---

# 7. Preserve Plot Flex and UserColumnWidths Rules

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

---

# 8. Preserve Video Separation

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
```

Search all `setVideoViewerVisible` calls and classify them.

---

# 9. Required Smoke Tests

After syntax repair and functional changes, run or document the following.

## Syntax and construction

```matlab
checkcode FlightDataDashboard.m
app = FlightDataDashboard;
st = app.testHook('getTestState');
delete(app);
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

## Auto test runner

After updating expectations:

```matlab
auto_test_runner('CaseList',[1 2 3],'CaptureMode','none','LoadAvi','never')
```

Then test reverse/skip support if already added:

```matlab
auto_test_runner('Order','desc','Skip',2,'CaptureMode','baseline','CaptureScale',0.6,'LoadAvi','never')
```

---

# 10. Static Review Checklist

Before final response, verify:

```text
No broken line continuation markers remain.
FlightDataDashboard.m parses.
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
auto_test_runner still writes progress/case/index files.
try/catch and app.logCaught patterns preserved.
```

---

# 11. Final Response Format

After completing the patch, respond with only:

```text
## Summary
- ...

## Files Changed
- ...

## Syntax Fixes
- ...

## Layout / Board-Off Changes
- ...

## Test Runner Changes
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
2. Board-off uses active source board hsplit as the primary UI.
3. Old `boardOffPanel` summary UI is not the primary visible board-off UI.
4. `layout-hsplit` is a real upper/lower arrangement.
5. Normal ↔ hsplit restoration works.
6. Layout and board-off operations do not open Video Player.
7. Plot/dataView remains `'1x'` whenever visible.
8. `UserColumnWidths` remains struct-based.
9. `auto_test_runner.m` validates the new board-off behavior.
10. Existing error logging and cleanup safety are preserved.
