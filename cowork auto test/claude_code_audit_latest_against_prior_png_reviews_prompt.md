# Claude Code Prompt — Audit Latest Code Against Prior PNG-Based Review Findings With Git Hash Mapping

You are Claude Code working on a MATLAB GUI project.

## Target Repository

```text
D:\flightdashboard\1. 최초-MVC 전
```

## Main Files to Review

```text
FlightDataDashboard.m
auto_test_runner.m
```

## Uploaded Evidence to Use

The user has uploaded prior review image archives and recent test/review artifacts. You must inspect the uploaded files available in the working directory / provided paths, including but not limited to:

```text
어제 검토결과.zip
old review2.zip
```

Also inspect any extracted PNG files and review notes available in the repository or current workspace.

## Required Git Mapping

This review must be tied to git history.

Before judging whether a bug is fixed, map each prior review item to the code version that likely produced it.

Use the Windows file saved/modified time of uploaded PNG files as the authoritative chronological order.

Then correlate the review image timestamps with git commits.

Required steps:

```text
1. Extract the uploaded ZIP files into a temporary review folder.
2. List every PNG/MD/TXT artifact with:
   - filename
   - Windows saved/modified time
   - archive source
   - inferred test sequence order
3. Run git log with timestamps around the image save times.
4. Match each prior review group to the closest relevant git commit hash.
5. Produce a mapping table:
   - review group
   - PNG filenames
   - modified/saved time
   - inferred operation sequence
   - nearest git commit hash
   - commit subject
   - whether the latest code appears to address it
```

Do not rely only on filename numbering. Filename numbering may not be chronological. Use file modified/saved time as the primary ordering signal.

If exact Windows creation time is not available after extraction, use the best available timestamp preserved by the archive and explicitly state the limitation.

---

## Core Task

Review whether the latest code implements and preserves the fixes requested in the prior review findings.

The review must be strict.

Do not assume that a feature is fixed because a function name exists.

Verify behavior from code paths, test hooks, state snapshots, and where practical, automated/manual test cases.

Do not rewrite the whole application.

If fixes are needed, propose scoped code changes and test cases.

---

# 1. Prior Review Group A — Board-Off Must Preserve Existing Features

## Evidence Group

```text
4.png -> 5.png
```

Observed prior issue:

```text
User pressed lower board off.
In 5.png, plot star marker in the moved lower-board plot could not be dragged.
The same star marker worked before board-off in 4.png.

Also, in 5.png, the Data View panel buttons:
    "+빈 탭 추가"
    "현재 탭 지우기"
disappeared after board-off.
```

## Required Audit

Check whether the latest code fixes both upper and lower board-off transitions.

When pressing:

```text
하단 보드 off
상단 보드 off
```

all functions that worked before board-off must continue to work after board-off.

Strictly verify:

```text
1. Plot star marker drag works before board-off.
2. Plot star marker drag works after lower board off.
3. Plot star marker drag works after upper board off.
4. Plot star marker drag still works after board-on restoration.
5. "+빈 탭 추가" remains visible and functional after board-off.
6. "현재 탭 지우기" remains visible and functional after board-off.
7. Existing plot tabs and plot axes are not destroyed or replaced by stale summary UI.
8. Button callbacks are preserved after reparenting or layout mode changes.
9. Board-off does not replace the active board with a non-interactive copy.
```

## Required Code Inspection Areas

Search and inspect:

```text
toggleBoardVisibility
applyBoardHsplit
applyBoardNormal
applyBoardArrangement
plotSelectedVariable
addPlotTab
clearCurrentPlotTab
boardOffAddPlotTab
boardOffClearCurrentTab
startPlotMarkerDrag
syncFrameMarkersAndLabel
getTestState
collectTestBoardState
```

## Required Test Hooks / Tests

If hooks already exist, use them. If missing, add lightweight hooks.

Required tests:

```matlab
app = FlightDataDashboard;
% load both flight data through existing test hooks
% create at least one plot in the data view
% verify marker drag callback before board-off
app.testHook('pushBoardToggleButton',2);   % lower board off
st = app.testHook('getTestState');
% verify active source board remains interactive
% verify add tab / clear tab buttons visible and callback-bound
app.testHook('pushBoardToggleButton',2);   % restore
% repeat for upper board off
delete(app);
```

Add deterministic state reporting if needed:

```text
boards(fIdx).plotMarkerDraggable
boards(fIdx).dataViewAddTabButtonVisible
boards(fIdx).dataViewClearTabButtonVisible
boards(fIdx).dataViewAddTabButtonCallbackSet
boards(fIdx).dataViewClearTabButtonCallbackSet
boards(fIdx).arrangementMode
```

---

# 2. Prior Review Group B — Hidden Panels Must Not Leave Blank Space

## Evidence Group

```text
6.png -> 7.png
```

Observed prior issue:

```text
6.png: lower board off, then "지도/고도" panel hidden.
7.png: lower board on restored.
The hide state was preserved, but panel widths were not recomputed.
A large blank area remained.
```

## Required Behavior

Whenever any panel is hidden:

```text
No blank space should remain.
The visible panels must expand to fill the available area.
The plot data panel should normally absorb remaining flex space.
```

Important rule:

```text
If plot data is visible, plot must remain the flexible final region.
```

The same applies if the Data View panel itself is hidden:

```text
The remaining visible panels must reflow to occupy available area.
No stale fixed-width hole should remain.
```

## Special Board-Off Requirement

If `현재 비행 정보` or `plot 데이터` is hidden before pressing board-off:

```text
When upper/lower board-off is pressed,
the active single-board analysis mode must force current flight info and plot data visible.
```

Rationale:

```text
Board-off mode is intended for active single-board analysis:
    upper region = current flight info + plot data
    lower region = remaining panels
```

Thus board-off must not produce an empty upper analysis area because info/plot were previously hidden.

## Required Audit

Verify:

```text
1. Hide attitude only -> no blank hole.
2. Hide mapOnly only -> no blank hole.
3. Hide altOnly only -> no blank hole.
4. Hide mapOnly + altOnly -> no blank hole.
5. Hide info -> no blank hole in normal mode.
6. Hide dataView -> no blank hole in normal mode.
7. Hide info before board-off -> board-off shows info again.
8. Hide dataView before board-off -> board-off shows plot data again.
9. Restore board-on -> the pre-board-off visibility state is restored or handled consistently according to product policy.
```

If the product policy is to force info/dataView visible only while board-off is active, document how the previous state is restored when board-on returns.

## Required Code Inspection Areas

Search and inspect:

```text
togglePanel
applyMapAltVisibility
reflowBoardColumns
normalizeColumnWidthsForVisiblePanels
rememberUserColumnWidths
restoreUserColumnWidths
applyBoardHsplit
applyBoardNormal
toggleBoardVisibility
PanelVisible
```

Verify that hidden panel states do not persist as stale nonzero widths.

---

# 3. Prior Review Group C — Missile Figure Quality

## Evidence Group

```text
1 page missile figure
```

Prior request:

```text
Update the drawing to be at the same quality level as the missile figure on page 1.
```

## Required Audit

Find where this figure/image is generated, loaded, or documented.

Possible locations:

```text
image assets
documentation
report generation
UI icon/figure rendering
plot manager export
```

If this item is unrelated to the current MATLAB UI source, say so explicitly.

If it is in-scope, verify:

```text
1. The figure quality was actually updated.
2. Resolution, line clarity, labels, and visual consistency match the requested quality.
3. No low-resolution placeholder remains.
```

If the latest repository does not contain this asset or the relevant output file, report that the item cannot be verified from code alone.

---

# 4. Prior Review Group D — Plot X-Axis Max Becomes 1 Second During Board-Off Plot Add

## Evidence Group

```text
11.png -> 12.png
```

Observed prior issue:

```text
Start with no plotted data in the Data View panel.
Select lower board off.
In the moved lower-board current flight info table, right-click one data item and add it to the Data View panel.
The plot x-axis maximum becomes 1 second even though the data duration is over 60 seconds.

After selecting lower board on, all plot x-axis maximum values normalize to over 60 seconds.
```

This is abnormal behavior #1.

## Required Audit

Check whether latest code fixes this.

Required behavior:

```text
Adding a plot while in board-off / hsplit mode must use the full flight time range.
The x-axis max must match the underlying data duration, not collapse to 1 second.
Board-on restoration must not be required to normalize x-axis limits.
```

## Required Code Inspection Areas

Search and inspect:

```text
plotSelectedVariable
boardOffPlotSelectedVariable
createPlotPanel
createPlotAxes
setupPlotAxisLimits
updatePlotAxisLimits
applyBoardHsplit
applyBoardNormal
collectCurrentProjectState
applyProjectState
```

Check for any board-off code path that creates axes with default limits `[0 1]` and fails to apply the data range.

## Required Test

Create a deterministic test:

```matlab
app = FlightDataDashboard;
% load flight data
app.testHook('pushBoardToggleButton',2);  % lower board off
% add one variable to plot from current flight info / context menu equivalent
st = app.testHook('getTestState');
% verify created plot XLim max > 60 or matches max(Time)
delete(app);
```

Expose test state if needed:

```text
boards(fIdx).plotXLim
boards(fIdx).plotDataDuration
boards(fIdx).selectedTabPlotCount
```

---

# 5. Prior Review Group E — Video Panel Visibility State Lost After Board-On

## Evidence Group

```text
13.png -> 14.png -> 15.png
```

Observed prior issue:

```text
13.png:
    Press video button to hide upper board AVI player panel.
    Then press lower board off.
    Upper board video hidden state is preserved correctly.

14.png:
    In that state, press video button to activate AVI player panel.

15.png:
    Press upper board on.
    The layout becomes like 12.png.
    The newly activated video panel state from 14.png is not reflected.
```

This is abnormal behavior #2.

## Required Audit

Verify that the latest code preserves panel visibility changes made while board-off is active.

Required behavior:

```text
If a panel visibility state changes during board-off mode,
that state must be reflected when board-on restores normal mode.
```

Specifically:

```text
1. Hide video before board-off -> remains hidden in board-off.
2. Enable video during board-off -> remains enabled after board-on.
3. Disable video during board-off -> remains disabled after board-on.
4. Same principle applies to attitude, mapOnly, altOnly, info, and dataView unless board-off temporarily forces info/dataView visible.
```

If board-off temporarily forces info/dataView visible, then define and test restoration policy.

## Required Code Inspection Areas

Search and inspect:

```text
PanelVisible
togglePanel
toggleBoardVisibility
applyBoardHsplit
applyBoardNormal
restoreBoardPanelState
BoardPanelVisibleSnapshot
setVideoViewerVisible
vidViewerDialog
panelVideo
```

Verify that board-off does not restore stale panel visibility from an old snapshot when returning to normal mode.

---

# 6. Prior Review Group F — All Combinations of Panel Hide Buttons and Board-Off Buttons

## Prior Request

Derive all combinations created by:

```text
3 panel hide buttons
2 board-off buttons
```

and verify they behave normally.

The three panel hide buttons in the older review likely refer to:

```text
자세
지도/고도
비디오
```

But the latest UI may now split `지도/고도` into:

```text
mapOnly
altOnly
```

Therefore, the latest test matrix should include both:

```text
legacy grouped map/alt scenarios
current independent mapOnly/altOnly scenarios
```

## Required Combination Matrix

At minimum, test these for each flight board:

```text
No panel hidden
attitude hidden
mapOnly hidden
altOnly hidden
mapOnly + altOnly hidden
video hidden
attitude + mapOnly + altOnly hidden
attitude + mapOnly + altOnly + video hidden
info hidden before board-off
dataView hidden before board-off
info + dataView hidden before board-off
```

For each state, test:

```text
lower board off -> lower board on
upper board off -> upper board on
layout-hsplit -> layout-grid
resize/reflow if possible
```

## Acceptance Criteria

For every combination:

```text
No large blank area.
Visible panels expand to available space.
plot data remains flex when visible.
info/plot are forced visible during active board-off if required by policy.
Panel visibility changes made during board-off are preserved after board-on.
No Video Player opens unless explicitly requested.
Star marker drag remains functional.
Data View add/clear tab buttons remain visible and functional.
```

Add or update runner cases accordingly.

---

# 7. Prior Review Group G — Automated 50-Case Capture Runner

## Prior Request

The user asked whether Claude Code / cowork can run the 50 previously reviewed cases and capture results.

Required output location:

```text
D:\flightdashboard\1. 최초-MVC 전\cowork auto test
```

Required output style:

```text
Each test case must have one MD file.
Step screenshots must be saved as PNG files with the same base filename plus step numbers.
Each step of each case must be captured as PNG.
```

## Required Audit

Verify whether current `auto_test_runner.m` satisfies the above.

Current reviewed runner appears to save under an auto-detected folder such as:

```text
cowork_auto_test
```

But the older requirement explicitly requested:

```text
D:\flightdashboard\1. 최초-MVC 전\cowork auto test
```

## Required Changes

Add an `OutputDir` option:

```matlab
auto_test_runner('OutputDir','D:\flightdashboard\1. 최초-MVC 전\cowork auto test')
```

Behavior:

```text
If OutputDir is specified, use it exactly.
If not specified, use existing auto-detection fallback.
```

Ensure naming convention:

```text
caseNN.md
caseNN_stepMM.png
```

or, if a more descriptive base filename is used:

```text
caseNN_<safe_title>.md
caseNN_<safe_title>_stepMM.png
```

Do not include image arrays inside MD files; link to PNG files by relative path.

Ensure `index.md` is updated after each case.

---

# 8. Prior Review Group H — Plot Manager Bugs

## Evidence Group

```text
16.png
17.png
18.png
```

Observed prior issues:

```text
Start with Plot Manager: one tab, one plot.
Change plotted flight item and X min/max.
After Apply, X min becomes about -30 and X max becomes about 8.
Change -30 to 0 and Apply.
Suddenly Plot Manager adds 9 tabs automatically and plot disappears.

Changing Plot height and pressing Apply does not change plot height.

Later, after opening AVI and testing sync/slider, the plot in Tab 1 suddenly disappears.
Plot Manager also no longer shows it.
```

## Required Improvements

### H1 — Add X auto checkbox

Add an X auto checkbox analogous to Y auto.

Placement:

```text
X auto checkbox above X min
```

Behavior:

```text
If X auto is checked:
    X min/max fields are ignored or disabled.
    Plot x-axis uses full data time range.

If X auto is unchecked:
    X min/max fields are applied exactly, validated, and preserved.
```

### H2 — Plot Manager scroll support

When Plot Manager window height/width is resized and the “selected item properties” area becomes clipped:

```text
A scrollable container must allow access to all controls.
```

The user must be able to scroll to hidden menu items and controls.

### H3 — Plot height apply must work

Changing Plot height and pressing Apply must update actual plot panel height.

Verify:

```text
height value changes in model
UI plot panel RowHeight/Position changes
project save/load preserves height if supported
```

### H4 — Prevent accidental tab explosion

Changing X axis min/max must not auto-create many tabs.

Search for code that may call:

```text
addPlotTab
ensurePlotTabs
rebuildPlotManagerTree
applyPendingDialogChanges
```

Ensure Apply does not duplicate tabs.

### H5 — Prevent plot disappearance

Opening AVI, syncing frame/data, and using slider must not delete existing plots or Plot Manager entries.

Search and inspect:

```text
loadAviFileFromPath
setVideoSync
applyTimeChange
goToFrame
updateDashboard
syncFrameMarkersAndLabel
applyPendingDialogChanges
rebuildPlotManagerTree
```

Plot configuration must be stable across video operations.

## Required Tests

Add or document tests:

```text
1. One plot exists.
2. Open Plot Manager.
3. Change Y variable.
4. Set X auto off, X min=0, X max=60.
5. Apply.
6. Verify only one tab remains.
7. Verify one plot remains.
8. Verify XLim = [0 60].
9. Change plot height.
10. Apply.
11. Verify plot height changed.
12. Open AVI and perform sync/slider operations.
13. Verify plot remains in UI and Plot Manager.
```

---

# 9. Prior Review Group I — Initial UI and Label Changes

## Evidence Group

```text
111.png
```

Required changes:

```text
1. Initial visible panels should be only:
   - 현재 비행 정보
   - H : 데이터 뷰 패널 / plot 데이터
2. Rename panel title:
   "H : 데이터 뷰 패널" -> "plot 데이터"
3. Rename panel title:
   "I : AVI Video Player" -> "Video Player"
4. Remove Debug checkbox.
5. "비행시간 동기" button and adjacent input field must remain disabled until two flight data files are loaded.
```

## Required Audit

Verify these in latest code.

Search and inspect:

```text
createFlightBoard
createLayout
buildHeaderBar
btnSync / SyncBtn
SyncInput
Debug checkbox
panelDataView title
panelVideo title
PanelVisible defaults
```

Acceptance criteria:

```text
Startup only shows current flight info and plot data.
Attitude/map/alt/video panels are hidden by default unless explicitly enabled.
Panel title is "plot 데이터".
Video panel/dialog title is "Video Player".
Debug checkbox is not present.
Sync controls are disabled until both flight data files are loaded.
```

If later product decisions changed this, report conflict explicitly.

---

# 10. Prior Review Group J — Current Flight Info Table Color Must Follow Its Flight

## Evidence Group

```text
112.png
```

Observed issue:

```text
When lower board off is selected, the current flight info table shown on the upper area changes to the lower board color.
```

Required behavior:

```text
If lower board off is selected, Flight Data 1 current flight info table color must remain Flight 1 color.
If upper board off is selected, Flight Data 2 current flight info table color must remain Flight 2 color.
```

## Required Audit

Check whether the table color is tied to:

```text
visual board location
```

instead of:

```text
flight identity
```

The correct rule is:

```text
Table color / flight identity accent must follow the source flight data, not the display location.
```

However, the latest theme direction says table backgrounds should be light/near-white. If flight colors are now subtle accents, those accents must still follow the source flight identity.

Search and inspect:

```text
getFlightTableBgColor
setupDataUI
applyLightTheme
applyThemeToTables
applyBoardHsplit
toggleBoardVisibility
```

---

# 11. Prior Review Group K — Plot Manager Must Preserve Current Marker Position

## Evidence Group

```text
117.png
```

Observed issue:

```text
In Plot Manager, changing plot height caused the current-position star marker to move to time 0.
```

Required behavior:

```text
Changing plot settings in Plot Manager must preserve the current marker position.
```

The marker should remain at:

```text
current flight time / current frame-aligned time
```

not reset to 0.

## Required Audit

Search and inspect:

```text
applyPendingDialogChanges
applyPlotManagerChanges
rebuildPlotPanels
initPlots
updateDashboard
syncFrameMarkersAndLabel
goToFrame
currentIndex
selectedRow
```

Ensure plot rebuild does not reset:

```text
Models(fIdx).currentIndex
Models(fIdx).selectedRow
VideoSyncState(fIdx).CurrentFrame
current marker X
```

## Required Test

```matlab
app = FlightDataDashboard;
% load flight data, move to nonzero time
% open/apply plot manager height change
st = app.testHook('getTestState');
% verify currentIndex/time unchanged
% verify star marker X unchanged
delete(app);
```

---

# 12. Prior Review Group L — Video Player as Separate Dialog and AVI Control Dialog Improvements

## Evidence Groups

```text
112.png -> 113.png
120.png
```

Observed issues and required changes:

```text
1. When lower board off is selected, the I : AVI Video Player area expands.
   Opening AVI then changes layout inconsistently.
2. Video Player should be separated into its own dialog.
3. Initial Video Player dialog size must avoid frame clipping.
4. When AVI opens, white blank space around frame should be minimized.
5. AVI control dialog font size should be increased by 25%.
6. Blank space below the four buttons under the AVI control dialog slider should be minimized.
7. When both Video Player and AVI control dialog are visible, dragging the Video Player title bar should move the AVI control dialog together.
   Relative distance and position must be preserved.
```

## Required Audit

Search and inspect:

```text
setVideoViewerVisible
createVideoViewerDialog
createVideoControlDialog
positionVideoControlDialog
VideoDialogFollowTimer
VideoDialogLastViewerPos
startVideoDialogFollowTimer
stopVideoDialogFollowTimer
loadAviFileFromPath
applyVideoLoadedUI
togglePanel('video')
```

Acceptance criteria:

```text
Video display is a separate dialog, not an embedded panel that distorts board layout.
Opening AVI does not change main board layout unexpectedly.
Initial dialog size fits the frame without clipping.
Frame margins are minimized.
AVI control dialog font size is 25% larger than before.
Unnecessary blank space below control buttons is minimized.
Control dialog follows Video Player when Video Player moves.
Relative offset is preserved.
```

Do not let layout/board-off operations open Video Player automatically. Only explicit video user actions should show it.

---

# 13. Prior Review Group M — Board-Off Space Utilization and Gauge/Map Readability

## Evidence Group

```text
123.png, 124.png, 125.png, 126.png
```

Observed issues:

```text
In lower board off mode, when hiding/showing "자세" and "지도/고도":
- Attitude gauge numbers inside the circles are nearly unreadable.
- Upper board space is wasted.
- If only attitude is visible, the gauges keep vertical layout and readability does not improve.
- Altitude becomes too wide horizontally while map is too small.
- Info/plot upper area does not use vertical space enough.
```

## Required Behavior

Board-off mode must adapt internal arrangement based on which panels are visible.

### If only attitude is visible in the lower remaining-panel region

```text
Use a layout that increases gauge size and readability.
Avoid keeping a cramped vertical gauge stack if horizontal or larger arrangement is better.
Increase font size inside gauge circles if needed.
```

### If map and altitude are visible

```text
Use a balanced map/altitude layout.
Map should not be a tiny square.
Altitude should not consume excessive horizontal width.
```

### If only info + plot are effectively important

```text
Use upper area height better.
Current flight info and plot data should become taller and more readable.
```

## Required Audit

Search and inspect:

```text
applyBoardHsplit
applyResponsiveAttitudeLayout
applyMapAltVisibility
reflowBoardColumns
panelAttitudeGrid
panelMapAlt
altAxes
mapAxes
```

Add adaptive layout rules for board-off/hsplit:

```text
visible remaining panels = attitude only:
    use larger gauge layout, likely horizontal or 2x2 depending available space

visible remaining panels = mapOnly + altOnly:
    use balanced split, not tiny map + overly wide altitude

visible remaining panels = mapOnly only:
    map uses most remaining region

visible remaining panels = altOnly only:
    altitude plot uses most remaining region but with readable aspect

visible remaining panels = none:
    upper info+plot region expands vertically
```

## Required Tests

Add deterministic tests for:

```text
board-off + attitude only
board-off + mapOnly only
board-off + altOnly only
board-off + mapOnly + altOnly
board-off + no remaining panels
```

Expose test state if needed:

```text
attitudeGridRows
attitudeGridColumns
attitudeLabelFontSize
mapAxes.Position
altAxes.Position
upperRegionHeight
lowerRegionHeight
```

---

# 14. Required Final Review Matrix

Create a review matrix that maps each prior issue to latest code status.

Columns:

```text
Review group
PNG evidence
Inferred operation sequence
Windows saved/modified time
Nearest git commit hash
Relevant functions/files
Latest code status:
    fixed / partially fixed / not fixed / cannot verify
Evidence from code
Recommended next action
Test case ID
```

This matrix is required in the final response.

---

# 15. Required Test Runner Additions

Update `auto_test_runner.m` or create supplemental test cases for the above review groups.

Do not use overly heavy capture settings by default.

Recommended runner modes:

```matlab
auto_test_runner('LoadAvi','never','CaptureMode','fail','CaptureScale',0.6,'OnlineSafeMode',true)
```

For visual evidence only:

```matlab
auto_test_runner('CaseList',[selected cases], ...
                 'LoadAvi','never', ...
                 'CaptureMode','all', ...
                 'CaptureScale',0.6, ...
                 'OnlineSafeMode',true)
```

For video-specific tests:

```matlab
auto_test_runner('CaseList',[video cases], ...
                 'LoadAvi','always', ...
                 'CaptureMode','fail', ...
                 'CaptureScale',0.5, ...
                 'OnlineSafeMode',true)
```

Avoid broad:

```matlab
CaptureMode='all'
LoadAvi='always'
```

because MATLAB Online has repeatedly hard-shutdown under this condition.

---

# 16. Static Review Checklist

Before final response, verify:

```text
PNG saved/modified times were used for ordering.
Each review group is mapped to nearest git commit hash.
Latest code was checked against every prior review group.
Board-off preserves interactive plot marker drag.
Data View add/clear tab buttons remain visible after board-off.
Hidden panels do not leave blank space.
Board-off forces info/plot visible if required and restores prior state consistently.
Board-off plot creation uses full data time range.
Panel visibility changes during board-off persist after board-on.
All panel-hide + board-off combinations are covered.
Plot Manager X auto was added or explicitly marked missing.
Plot Manager scroll behavior is implemented or marked missing.
Plot height changes actually affect plot height.
Plot Manager apply does not create extra tabs.
Video operations do not delete plots.
Initial visible panels and labels match requested defaults.
Debug checkbox removed.
Sync controls disabled until both flight data files load.
Flight identity table/accent follows source flight, not display position.
Plot Manager changes preserve current marker position.
Video Player is separate dialog and AVI control dialog follows it.
Board-off adaptive layout improves gauge/map/altitude readability.
Light theme has readable titles and no low-contrast gray text on white.
```

---

# 17. Final Response Format

After completing the audit, respond with only:

```text
## Summary
- ...

## Git / Evidence Mapping
- include the required matrix

## Findings by Prior Review Group
- ...

## Code Areas Reviewed
- ...

## Fixed / Partial / Not Fixed Classification
- ...

## New or Updated Tests
- ...

## Recommended Patches
- ...

## Remaining Risks
- ...
```

Do not print full source code.

---

## Definition of Done

This audit is complete only when:

1. Uploaded PNG/ZIP artifacts are ordered by Windows saved/modified time.
2. Prior review items are mapped to git commit hashes.
3. Every prior review group listed in this prompt is classified.
4. The latest code is checked against each group.
5. Contradictions between old requirements and current product policy are explicitly called out.
6. Recommended fixes are scoped and prioritized.
7. Missing evidence is reported honestly instead of guessed.
