# Claude Code Prompt — MATLAB GUI Style Refinement Round 2

## Target

```text
FlightDataDashboard.m
```

## Scope

Style-only refinement based on runtime screenshot vs MATLAB desktop reference.

Observed remaining problems (from runtime screenshot `현재 (2).png`):

```text
1. Plot tab area surrounding the chart appears BLACK (must be white).
2. dataTable values appear pale gray on white (must be near-black).
3. "+ 빈 탭 추가" / "현재 탭 지우기" buttons are plain gray (must be role-colored).
4. EditDialog status label "준비" appears washed out (must be strong dark text).
5. EditDialog tabs (Project/Files/Sync/Options/Plot Manager/Export) text is gray on dark (must be readable).
6. EditDialog bottom action buttons "적용 (즉시 반영)/project 저장/닫기" are plain gray (must be role-colored).
7. Plot Manager header buttons "캡처/재구성/Sync X→All Tabs/Sync X→Plot" are plain gray (must be role-colored).
8. Plot Manager property panel form labels (이름/Y 데이터 항목/...) appear too light (must be bold dark text).
9. Plot Manager small action buttons next to "적용" need role coloring.
10. EditDialog window background defaults to light gray (must use `t.windowBg`).
```

## Mandatory Restrictions

```text
1. Do not print full modified MATLAB file.
2. Do not print large code blocks.
3. Style-only edits. Preserve every callback, handle name, field name, layout position.
4. Do not change panel visibility defaults.
5. Do not make video display area white. Keep `UI_temp(fIdx).vidContainer.BackgroundColor = [0 0 0]` and `UI_temp(fIdx).vidAxes.Color = [0 0 0]`.
6. Do not make table/axes text white on white.
7. Use `t = app.getLightTheme()` (already exists). Do not add new theme tokens unless required below.
8. Preserve `try/catch` and `app.logCaught` patterns.
```

---

## Required Changes

Symbols `t.*` refer to fields already present in `getLightTheme()`.

---

### 1. `addPlotTab(app, fIdx)` — plot tab inner area must be white

Location: function `addPlotTab` (around line 3800).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `plotLayout` (the `uigridlayout(newTab, ...)` inside `addPlotTab`) | `BackgroundColor` | not set (defaults to dark) | `[1.00 1.00 1.00]` |

Add `BackgroundColor` to the existing `uigridlayout` call. Do not change any other layout option.

---

### 2. `boardOffAddPlotTab(app, offIdx)` / board-off plot tab creation — plot tab inner area must be white

Location: the second `plotLayout = uigridlayout(newTab, ...)` (around line 9803, board-off summary path).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `plotLayout` in board-off plot creation | `BackgroundColor` | not set (defaults to dark) | `[1.00 1.00 1.00]` |

---

### 3. Data View tab buttons inside `hPnl` — role color the "+ 빈 탭 추가" / "현재 탭 지우기" buttons

Location: inside `createLayout`, the two `uibutton(btnPnl, ...)` calls (around lines 10701–10702).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `uibutton(btnPnl, 'Text', '+ 빈 탭 추가', ...)` | `BackgroundColor` | default | `t.toolbarGreenBg` |
| same button | `FontColor` | default | `t.toolbarGreenFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(btnPnl, 'Text', '현재 탭 지우기', ...)` | `BackgroundColor` | default | `t.toolbarYellowBg` |
| same button | `FontColor` | default | `t.toolbarYellowFg` |
| same button | `FontWeight` | default | `'bold'` |

Implementation note: both `uibutton(...)` calls currently discard the returned handle. Either set the properties inline as Name/Value pairs in the existing `uibutton(...)` call, or assign to a local variable then set the properties. Do not change callbacks.

---

### 4. Board-off summary panel `+ 빈 탭 추가` / `현재 탭 지우기` buttons — same role colors

Location: inside `createBoardOffSummaryPanel`, the two `uibutton(btnRow, ...)` calls (around lines 10466–10469).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `uibutton(btnRow, 'Text', '+ 빈 탭 추가', ...)` | `BackgroundColor` | default | `t.toolbarGreenBg` |
| same button | `FontColor` | default | `t.toolbarGreenFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(btnRow, 'Text', '현재 탭 지우기', ...)` | `BackgroundColor` | default | `t.toolbarYellowBg` |
| same button | `FontColor` | default | `t.toolbarYellowFg` |
| same button | `FontWeight` | default | `'bold'` |

---

### 5. EditDialog window background and outer layout

Location: function that creates the modeless settings/edit dialog (the `uifigure` named '설정/프로젝트 편집기').

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| EditDialog `fig` (local handle returned by `uifigure(...)`) | `Color` | not set | `t.windowBg` |
| EditDialog outer `uigridlayout` (the parent of the tab group) | `BackgroundColor` | not set | `t.windowBg` |

---

### 6. EditDialog status row labels

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `app.EditDialogStatusLbl` | `FontColor` | default (gray) | `t.textPrimary` |
| `app.EditDialogStatusLbl` | `FontWeight` | default | `'bold'` |
| `app.EditDialogTimeLbl` | `FontColor` | not set | `t.textSecondary` |

---

### 7. EditDialog tab text — Project / Files / Sync / Options / Plot Manager / Export

The outer tab group inside the EditDialog (`uitabgroup` named conceptually `tabGroupEdit`).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| each top-level `uitab` (`tabProject`, `tabFiles`, `tabSync`, `tabOpts`, `tabPlot`, `tabExport`) | `BackgroundColor` | default | `t.surfaceBg` |
| each top-level `uitab` | `ForegroundColor` | default | `t.textPrimary` |

If the uitab handles are locally named differently (e.g. `tabPlot`, `tabExport`), apply the same two properties to each.

---

### 8. EditDialog bottom action buttons — role colors

Location: bottom button row inside EditDialog (around lines 5705–5709).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `uibutton(bottom, 'Text', '적용 (즉시 반영)', ...)` | `BackgroundColor` | default | `t.toolbarBlueBg` |
| same button | `FontColor` | default | `t.toolbarBlueFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(bottom, 'Text', 'project 저장', ...)` | `BackgroundColor` | default | `t.toolbarGreenBg` |
| same button | `FontColor` | default | `t.toolbarGreenFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(bottom, 'Text', '닫기', ...)` | `BackgroundColor` | default | `t.toolbarGrayBg` |
| same button | `FontColor` | default | `t.toolbarGrayFg` |
| same button | `FontWeight` | default | `'bold'` |

Implementation note: assign these `uibutton(...)` calls to local variables, set Name/Value properties either inline or via property assignment. Do not change callbacks.

---

### 9. Plot Manager header action buttons

Location: function `buildEditTabPlot`, header row (around lines 6022–6028).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `uibutton(header, 'Text', '캡처', ...)` | `BackgroundColor` | default | `t.toolbarYellowBg` |
| same button | `FontColor` | default | `t.toolbarYellowFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(header, 'Text', '재구성', ...)` | `BackgroundColor` | default | `t.toolbarBlueBg` |
| same button | `FontColor` | default | `t.toolbarBlueFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(header, 'Text', 'Sync X→All Tabs', ...)` | `BackgroundColor` | default | `t.toolbarGreenBg` |
| same button | `FontColor` | default | `t.toolbarGreenFg` |
| same button | `FontWeight` | default | `'bold'` |
| `uibutton(header, 'Text', 'Sync X→Plot', ...)` | `BackgroundColor` | default | `t.toolbarGreenBg` |
| same button | `FontColor` | default | `t.toolbarGreenFg` |
| same button | `FontWeight` | default | `'bold'` |

---

### 10. Plot Manager property panel form labels

Location: function `buildEditTabPlot`, inside `pg` grid where each `uilabel(pg, 'Text', '...:')` is created (around lines 6043–6068 approx).

For every `uilabel(pg, ...)` created with these texts:

```text
'이름:'
'Y 데이터 항목:'
'Y 라벨:'
'X auto:'
'X min:'
'X max:'
'Y auto:'
'Y min:'
'Y max:'
'Plot height:'
'액션:'
```

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| each of the labels above | `FontColor` | default | `t.textPrimary` |
| each of the labels above | `FontWeight` | default | `'bold'` |

---

### 11. Plot Manager "적용" action button (small one in action row)

Location: action row inside `pg` (around line 6000 region — `uibutton(actRow, 'Text', '적용', ...)` or equivalent inside the property panel).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| Plot Manager small `적용` button | `BackgroundColor` | current (varies) | `t.toolbarBlueBg` |
| same button | `FontColor` | current | `t.toolbarBlueFg` |
| same button | `FontWeight` | default | `'bold'` |

The other small action buttons in the same row (if any) should remain or use `t.toolbarGrayBg / t.toolbarGrayFg`. Do not change their callbacks.

---

### 12. dataTable readability boost — ensure values are not pale

Location: `UI_temp(fIdx).dataTable = uitable(glInfo, ...)` (around line 10678).

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `UI_temp(fIdx).dataTable` | `ForegroundColor` | `themeT.textPrimary` | `[0.00 0.00 0.00]` |
| `UI_temp(fIdx).dataTable` | `FontWeight` | `'bold'` | `'bold'` (keep) |
| `UI_temp(fIdx).dataTable` | `FontSize` | `11` | `12` |
| `UI_temp(fIdx).dataTable` | `BackgroundColor` | `[1.00 1.00 1.00; 0.94 0.97 1.00]` | `[1.00 1.00 1.00; 0.96 0.98 1.00]` |
| `UI_temp(fIdx).dataTable` | `RowStriping` | `'on'` | `'on'` (keep) |

Same for the board-off summary table `tbl` inside `createBoardOffSummaryPanel`.

---

### 13. Plot Manager dropdown / numeric field colors (improve contrast of disabled fields)

For each of: `app.EDPlotYColDD`, `app.EDPlotYLabelEdit`, `app.EDPlotXMin`, `app.EDPlotXMax`, `app.EDPlotYMin`, `app.EDPlotYMax`, `app.EDPlotHeight`:

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| each input above | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| each input above | `FontColor` | default | `t.textPrimary` |
| each input above | `FontSize` | default | `12` |

Do not change `Enable`, `Limits`, or `ValueDisplayFormat`.

---

### 14. Plot Manager X-auto / Y-auto checkboxes

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `app.EDPlotXAutoCB` | `FontColor` | default | `t.textPrimary` |
| `app.EDPlotXAutoCB` | `FontWeight` | default | `'bold'` |
| `app.EDPlotYAutoCB` | `FontColor` | default | `t.textPrimary` |
| `app.EDPlotYAutoCB` | `FontWeight` | default | `'bold'` |

---

### 15. Video control dialog buttons — ensure nav buttons are role-colored

Location: `createVideoControlDialog`, nav row (the four `uibutton(glNav, 'Text', '◄◄'/'◄'/'►'/'►►', ...)` calls around lines 8498–8509) and FPS row buttons.

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| each nav `uibutton(glNav, 'Text', '◄◄' / '◄' / '►' / '►►', ...)` | `BackgroundColor` | default | `t.toolbarGrayBg` |
| same | `FontColor` | default | `t.toolbarGrayFg` |
| same | `FontWeight` | `'bold'` | `'bold'` (keep) |
| FPS step `uibutton(glHz, 'Text', '◄', ...)` and `'►'` | `BackgroundColor` | default | `t.toolbarGrayBg` |
| same | `FontColor` | default | `t.toolbarGrayFg` |

Implementation note: assign each `uibutton(...)` to a local variable if currently discarded.

---

### 16. Video viewer dialog title-area resolution dropdown and control button

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `UI_temp(fIdx).vidResolutionDropdown` | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).vidResolutionDropdown` | `FontColor` | default | `t.textPrimary` |
| `UI_temp(fIdx).vidControlBtn` | `BackgroundColor` | default | `t.toolbarDarkBg` |
| `UI_temp(fIdx).vidControlBtn` | `FontColor` | default | `t.toolbarDarkFg` |
| `UI_temp(fIdx).vidControlBtn` | `FontWeight` | default | `'bold'` |

---

## Verification Requirements

After making the style-only changes:

```matlab
checkcode FlightDataDashboard.m
app = FlightDataDashboard;
% Visually verify:
%   - Plot tab inner area is white (no black border around the chart).
%   - dataTable values are clearly black on white.
%   - "+ 빈 탭 추가" button is green, "현재 탭 지우기" is yellow.
%   - EditDialog "준비" status is bold dark text.
%   - EditDialog tabs labels (Project/Files/...) are dark on light.
%   - EditDialog bottom buttons: 적용(blue) / project 저장(green) / 닫기(gray).
%   - Plot Manager header buttons: 캡처(yellow) / 재구성(blue) / Sync(green/green).
%   - Plot Manager form labels are bold dark text.
%   - Video display axes remain pure black.
delete(app);
```

Do not modify non-style behavior to satisfy these checks.

---

## Expected Output From Claude Code

Return only:

```text
1. Concise summary of edited style properties (one line per edit area).
2. checkcode result.
3. Visual/manual check result if possible.
4. Do not include full code.
5. Do not include large diffs.
```
