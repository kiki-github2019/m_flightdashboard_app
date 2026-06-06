# Claude Code Prompt — MATLAB GUI Style Harmonization Only

## Target

Repository / file:

- `FlightDataDashboard.m`

Task type:

- Style-only MATLAB App UI update.
- Do not change data parsing, synchronization, plotting logic, video logic, project save/load logic, layout resizing logic, or callback behavior.
- Do not rewrite the GUI.
- Only modify existing UI component style properties and the existing theme helper methods.

Reference style:

- MATLAB desktop / editor style with a dark blue top/header area, readable white text on blue panels, black text on white content areas, and large visually distinct toolbar buttons.

Important note:

- This app is not classic `uicontrol`-based. It uses `uifigure`, `uipanel`, `uigridlayout`, `uibutton`, `uilabel`, `uitable`, `uiaxes`, `uitabgroup`, and `uitab` objects. Treat the user phrase “uicontrol” as “MATLAB UI components”.

---

## Mandatory Restrictions

1. Do not print full modified code.
2. Do not print large diffs.
3. Keep all changes scoped to visual style properties.
4. Preserve every existing callback, handle name, field name, and layout position.
5. Do not change panel visibility defaults.
6. Do not make the video image area white; keep the actual video display area black.
7. Do not make table/axes text white on white backgrounds.
8. After editing, run MATLAB syntax/static checks if available, but do not change business logic.

---

## Current Main Problems To Fix

| Area | Current state | Required state |
|---|---|---|
| Main panels | Mostly `[0.98 0.98 0.98]` or `'w'` | Titled/structural panels use dark MATLAB-like blue with white title/text |
| Content panels | Some structural/content areas are visually indistinct | Data tables, axes, and editable fields remain white/light with black/dark text |
| Plot tab area | Can appear black or visually inconsistent | Plot tab/page backgrounds must be white/light; axis text must be dark |
| Toolbar | Generic gray buttons | Larger icon/text buttons with role-based colors: yellow, blue, green, gray, red |
| Labels | Some gray text on white backgrounds is too weak | White-on-blue for blue panels; black/dark on white content |
| Theme helper | Current `applyLightTheme` normalizes dark backgrounds back to light | Do not erase intentional dark blue panel/header styling |

---

## Exact Style Changes

### 1. `getLightTheme(~)` — update theme token values only

Modify the existing fields in `getLightTheme` as follows.

| Variable / field | Parameter | Before | After |
|---|---:|---:|---:|
| `t.windowBg` | RGB | `[0.96 0.96 0.96]` | `[0.90 0.93 0.96]` |
| `t.surfaceBg` | RGB | `[1.00 1.00 1.00]` | `[1.00 1.00 1.00]` |
| `t.surfaceAltBg` | RGB | `[0.97 0.97 0.97]` | `[0.94 0.96 0.98]` |
| `t.headerBg` | RGB | `[0.94 0.94 0.94]` | `[0.00 0.30 0.50]` |
| `t.borderColor` | RGB | `[0.78 0.78 0.78]` | `[0.30 0.48 0.65]` |
| `t.gridLine` | RGB | `[0.85 0.85 0.85]` | `[0.78 0.84 0.90]` |
| `t.textPrimary` | RGB | `[0.10 0.10 0.10]` | `[0.05 0.05 0.05]` |
| `t.textSecondary` | RGB | `[0.35 0.35 0.35]` | `[0.18 0.24 0.30]` |
| `t.textMuted` | RGB | `[0.55 0.55 0.55]` | `[0.42 0.48 0.55]` |
| `t.textInverse` | RGB | `[1.00 1.00 1.00]` | `[1.00 1.00 1.00]` |
| `t.accentBlue` | RGB | `[0.15 0.38 0.82]` | `[0.00 0.42 0.72]` |
| `t.accentBlueLite` | RGB | `[0.86 0.92 1.00]` | `[0.82 0.91 1.00]` |
| `t.accentBlueText` | RGB | `[0.05 0.15 0.32]` | `[0.00 0.18 0.35]` |
| `t.accentGreen` | RGB | `[0.06 0.65 0.50]` | `[0.00 0.58 0.22]` |
| `t.warningRed` | RGB | `[0.80 0.18 0.18]` | `[0.78 0.16 0.12]` |
| `t.successGreen` | RGB | `[0.06 0.45 0.22]` | `[0.00 0.48 0.20]` |
| `t.disabledBg` | RGB | `[0.90 0.90 0.90]` | `[0.82 0.85 0.88]` |
| `t.disabledFg` | RGB | `[0.45 0.45 0.45]` | `[0.32 0.36 0.40]` |
| `t.tableHeaderBg` | RGB | `[0.93 0.93 0.93]` | `[0.91 0.94 0.97]` |
| `t.tableRowBgA` | RGB | `[1.00 1.00 1.00]` | `[1.00 1.00 1.00]` |
| `t.tableRowBgB` | RGB | `[0.96 0.96 0.98]` | `[0.94 0.97 1.00]` |
| `t.axesBg` | RGB | `[1.00 1.00 1.00]` | `[1.00 1.00 1.00]` |
| `t.fontFamily` | string | `'Segoe UI'` | `'Segoe UI'` |
| `t.fontFamilyMono` | string | `'Consolas'` | `'Consolas'` |
| `t.fontSizeSmall` | number | `10` | `11` |
| `t.fontSizeBase` | number | `12` | `12` |
| `t.fontSizeLarge` | number | `14` | `14` |
| `t.btnActiveBg` | RGB | `t.accentBlue` | `[0.00 0.42 0.72]` |
| `t.btnActiveFg` | RGB | `t.textInverse` | `[1.00 1.00 1.00]` |
| `t.btnAccentBg` | RGB | `t.accentBlueLite` | `[0.96 0.78 0.20]` |
| `t.btnAccentFg` | RGB | `t.accentBlueText` | `[0.05 0.05 0.05]` |
| `t.btnNormalBg` | RGB | `t.surfaceAltBg` | `[0.90 0.92 0.95]` |
| `t.btnNormalFg` | RGB | `t.textPrimary` | `[0.05 0.05 0.05]` |
| `t.btnDisabledBg` | RGB | `t.disabledBg` | `[0.82 0.85 0.88]` |
| `t.btnDisabledFg` | RGB | `t.disabledFg` | `[0.32 0.36 0.40]` |
| `t.btnWarningBg` | RGB | `t.warningRed` | `[0.78 0.16 0.12]` |
| `t.btnWarningFg` | RGB | `t.textInverse` | `[1.00 1.00 1.00]` |

Add these new theme fields in `getLightTheme` only if they do not already exist.

| Variable / field | Parameter | Before | After |
|---|---:|---:|---:|
| `t.panelBlueBg` | RGB | not present | `[0.00 0.30 0.50]` |
| `t.panelBlueBg2` | RGB | not present | `[0.02 0.37 0.60]` |
| `t.panelBlueFg` | RGB | not present | `[1.00 1.00 1.00]` |
| `t.toolbarYellowBg` | RGB | not present | `[0.98 0.78 0.18]` |
| `t.toolbarYellowFg` | RGB | not present | `[0.05 0.05 0.05]` |
| `t.toolbarGreenBg` | RGB | not present | `[0.00 0.58 0.22]` |
| `t.toolbarGreenFg` | RGB | not present | `[1.00 1.00 1.00]` |
| `t.toolbarBlueBg` | RGB | not present | `[0.00 0.42 0.72]` |
| `t.toolbarBlueFg` | RGB | not present | `[1.00 1.00 1.00]` |
| `t.toolbarGrayBg` | RGB | not present | `[0.86 0.88 0.90]` |
| `t.toolbarGrayFg` | RGB | not present | `[0.05 0.05 0.05]` |
| `t.toolbarDarkBg` | RGB | not present | `[0.04 0.10 0.16]` |
| `t.toolbarDarkFg` | RGB | not present | `[1.00 1.00 1.00]` |

---

### 2. `applyThemeToPanels(app, root, t)` — do not erase intentional dark blue panel styling

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| every `uipanel` found by `findall(root,'Type','uipanel')` | `BackgroundColor` dark-color normalization rule | If `all(bg < 0.55)`, force `p.BackgroundColor = t.surfaceBg` | Do not force dark panel backgrounds to `t.surfaceBg`; preserve intentional dark/blue panel backgrounds |
| every `uigridlayout` found by `findall(root,'Type','uigridlayout')` | `BackgroundColor` dark-color normalization rule | If `all(bg < 0.55)`, force `g.BackgroundColor = t.surfaceBg` | Do not force dark grid backgrounds to `t.surfaceBg`; preserve intentional dark/blue grid backgrounds |
| every bordered `uipanel` | `BorderColor` | Only replaces very dark borders | Set bordered panels to `t.borderColor` unless the panel is a splitter or video container |

---

### 3. `applyLightPanelTitleContrast(app, root)` — title color must follow background brightness

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| titled `uipanel` with light background | `ForegroundColor` | `[0 0 0]` | `t.textPrimary` |
| titled `uipanel` with dark/blue background | `ForegroundColor` | no handling | `t.panelBlueFg` |
| `UI_temp(fIdx).vidContainer` and video image panels | `ForegroundColor` | no special handling | do not change; leave video display styling intact |

---

### 4. Constructor / main window

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `app.UIFigure` | `Color` | `[0.94 0.94 0.96]` | `app.getLightTheme().windowBg` |

---

### 5. `buildHeaderBar(app, mainLayout)` — header panel and top toolbar

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `hHeaderPanel` | `BackgroundColor` | `[0.94 0.94 0.94]` | `t.headerBg` |
| `hHeaderPanel` | `ForegroundColor` | not set | `t.textInverse` |
| `hHeaderPanel` | `BorderType` | `'line'` | `'line'` |
| `glHeader` | `BackgroundColor` | not set | `t.headerBg` |
| `glHeader.RowHeight` | value | `{'1x'}` | `{'1x'}` |
| `glHeader.Padding` | value | `[4 4 4 4]` | `[4 3 4 3]` |
| top-level file button returned by `app.createToolbarButton(... '+', '비행경로 1 선택', ...)` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarYellowBg` |
| same button | `FontColor` | `t.btnNormalFg` | `t.toolbarYellowFg` |
| top-level file button returned by `app.createToolbarButton(... '+', '비행경로 2 선택', ...)` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarYellowBg` |
| same button | `FontColor` | `t.btnNormalFg` | `t.toolbarYellowFg` |
| coastline button returned by `app.createToolbarButton(... '≋', '해안선 정보', ...)` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarGrayBg` |
| same button | `FontColor` | `t.btnNormalFg` | `t.toolbarGrayFg` |
| `app.BoardToggleButtons(1)` | `BackgroundColor` normal/off state | `t.btnNormalBg` | `t.toolbarBlueBg` |
| `app.BoardToggleButtons(1)` | `FontColor` normal/off state | `t.btnNormalFg` | `t.toolbarBlueFg` |
| `app.BoardToggleButtons(2)` | `BackgroundColor` normal/off state | `t.btnNormalBg` | `t.toolbarBlueBg` |
| `app.BoardToggleButtons(2)` | `FontColor` normal/off state | `t.btnNormalFg` | `t.toolbarBlueFg` |
| `app.SyncBtn` disabled | `BackgroundColor` | `t.btnDisabledBg` | `t.disabledBg` |
| `app.SyncBtn` disabled | `FontColor` | `t.btnDisabledFg` | `t.disabledFg` |
| `app.SyncBtn` accent/enabled | `BackgroundColor` | `t.btnAccentBg` | `t.toolbarGreenBg` |
| `app.SyncBtn` accent/enabled | `FontColor` | `t.btnAccentFg` | `t.toolbarGreenFg` |
| `app.SyncBtn` active/synced | `BackgroundColor` | `t.btnActiveBg` | `t.toolbarGreenBg` |
| `app.SyncBtn` active/synced | `FontColor` | `t.btnActiveFg` | `t.toolbarGreenFg` |
| `app.WindowMinBtn` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarGrayBg` |
| `app.WindowMinBtn` | `FontColor` | `t.btnNormalFg` | `t.toolbarGrayFg` |
| `app.WindowMaxBtn` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarGrayBg` |
| `app.WindowMaxBtn` | `FontColor` | `t.btnNormalFg` | `t.toolbarGrayFg` |
| settings/edit toolbar button returned by `app.createToolbarButton(... '⚙', '설정/편집', ...)` | `BackgroundColor` | `t.btnNormalBg` | `t.toolbarDarkBg` |
| same button | `FontColor` | `t.btnNormalFg` | `t.toolbarDarkFg` |
| every toolbar button created by `createToolbarButton` | `FontSize` | `10` | `11` |
| every toolbar button created by `createToolbarButton` | `FontWeight` | `'bold'` | `'bold'` |

Implementation note for this section:

- If a toolbar button handle is currently discarded, assign it to a local variable before styling it.
- Do not add new persistent app properties unless needed.
- Do not change callbacks.

---

### 6. `buildLayoutPresetPicker(app, parent)`

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `pnl` | `BackgroundColor` | `[0.94 0.94 0.94]` | `t.headerBg` |
| `pnl` | `ForegroundColor` | not set | `t.textInverse` |
| layout preset buttons in `app.LayoutPresetButtons(k)` | `BackgroundColor` normal | default / later normal theme | `t.toolbarGrayBg` |
| same buttons | `FontColor` normal | default / later normal theme | `t.toolbarGrayFg` |
| same buttons when selected/current preset | `BackgroundColor` | current active blue mapping | `t.toolbarYellowBg` |
| same buttons when selected/current preset | `FontColor` | current active white mapping | `t.toolbarYellowFg` |
| `app.HeaderLayoutPresetDD` | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| `app.HeaderLayoutPresetDD` | `FontColor` | default | `t.textPrimary` |
| `app.HeaderLayoutPresetDD` | `FontSize` | `10` | `10` |

---

### 7. `styleToolbarButton(app, btn, iconText, labelText, stateName)`

| State / condition | Parameter | Before | After |
|---|---|---|---|
| all states | `btn.FontSize` | `t.fontSizeSmall` | `11` |
| all states | `btn.FontWeight` | `'bold'` | `'bold'` |
| `stateName == 'active'` | `btn.BackgroundColor` | `t.btnActiveBg` | `t.toolbarGreenBg` unless `labelText` contains `보드`, then `t.toolbarBlueBg` |
| `stateName == 'active'` | `btn.FontColor` | `t.btnActiveFg` | `t.toolbarGreenFg` unless `labelText` contains `보드`, then `t.toolbarBlueFg` |
| `stateName == 'accent'` | `btn.BackgroundColor` | `t.btnAccentBg` | `t.toolbarGreenBg` |
| `stateName == 'accent'` | `btn.FontColor` | `t.btnAccentFg` | `t.toolbarGreenFg` |
| `stateName == 'disabled'` | `btn.BackgroundColor` | `t.btnDisabledBg` | `t.disabledBg` |
| `stateName == 'disabled'` | `btn.FontColor` | `t.btnDisabledFg` | `t.disabledFg` |
| default / normal, `labelText` contains `비행경로` | `btn.BackgroundColor` | `t.btnNormalBg` | `t.toolbarYellowBg` |
| default / normal, `labelText` contains `비행경로` | `btn.FontColor` | `t.btnNormalFg` | `t.toolbarYellowFg` |
| default / normal, `labelText` contains `해안선` | `btn.BackgroundColor` | `t.btnNormalBg` | `t.toolbarGrayBg` |
| default / normal, `labelText` contains `해안선` | `btn.FontColor` | `t.btnNormalFg` | `t.toolbarGrayFg` |
| default / normal, `labelText` contains `보드` | `btn.BackgroundColor` | `t.btnNormalBg` | `t.toolbarBlueBg` |
| default / normal, `labelText` contains `보드` | `btn.FontColor` | `t.btnNormalFg` | `t.toolbarBlueFg` |
| default / normal, `labelText` contains `설정` or `편집` | `btn.BackgroundColor` | `t.btnNormalBg` | `t.toolbarDarkBg` |
| default / normal, `labelText` contains `설정` or `편집` | `btn.FontColor` | `t.btnNormalFg` | `t.toolbarDarkFg` |
| default / normal, all other buttons | `btn.BackgroundColor` | `t.btnNormalBg` | `t.toolbarGrayBg` |
| default / normal, all other buttons | `btn.FontColor` | `t.btnNormalFg` | `t.toolbarGrayFg` |

---

### 8. `createLayout(app)` — main body and board panels

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `scrollBody` | `BackgroundColor` | `[0.94 0.94 0.96]` | `t.windowBg` |
| `bodyGrid` | `BackgroundColor` | default | `t.windowBg` |
| `app.BodyRowSplitter` | `BackgroundColor` | `[0.55 0.55 0.58]` | `[0.18 0.36 0.52]` |
| `panelColors{1}` | RGB | `[0.98 0.98 0.98]` | `t.panelBlueBg` |
| `panelColors{2}` | RGB | `[0.98 0.98 0.98]` | `t.panelBlueBg2` |
| `UI_temp(fIdx).panel` | `BackgroundColor` | `panelColors{fIdx}` light gray | `panelColors{fIdx}` blue |
| `UI_temp(fIdx).panel` | `ForegroundColor` | default or black | `t.panelBlueFg` |
| `fGrid` | `BackgroundColor` | default | `panelColors{fIdx}` |
| `controlPanel` | `BackgroundColor` | `'w'` | `t.headerBg` |
| `controlPanel` | `ForegroundColor` | default | `t.textInverse` |
| `glCtrl` | `BackgroundColor` | default | `t.headerBg` |
| `uilabel(glCtrl,'Text','입력 시간(s):',...)` | `FontColor` | default black | `t.textInverse` |
| `uilabel(glCtrl,'Text','실시간 현재값:',...)` | `FontColor` | default black | `t.textInverse` |
| `UI_temp(fIdx).currentTimeLabel` | `FontColor` | `[0.8 0.1 0.1]` | `[1.00 0.90 0.25]` |
| `UI_temp(fIdx).fileNameLabel` | `FontColor` | `[0.2 0.2 0.2]` | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).spinner` | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).spinner` | `FontColor` | default | `t.textPrimary` |
| `UI_temp(fIdx).btnAtt` | `BackgroundColor` | default / theme normal | `t.toolbarBlueBg` |
| `UI_temp(fIdx).btnAtt` | `FontColor` | default / theme normal | `t.toolbarBlueFg` |
| `UI_temp(fIdx).btnMap` | `BackgroundColor` | default / theme normal | `t.toolbarGreenBg` |
| `UI_temp(fIdx).btnMap` | `FontColor` | default / theme normal | `t.toolbarGreenFg` |
| `UI_temp(fIdx).btnAlt` | `BackgroundColor` | default / theme normal | `[0.00 0.42 0.72]` |
| `UI_temp(fIdx).btnAlt` | `FontColor` | default / theme normal | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).btnInfo` | `BackgroundColor` | default / theme normal | `t.toolbarYellowBg` |
| `UI_temp(fIdx).btnInfo` | `FontColor` | default / theme normal | `t.toolbarYellowFg` |
| `UI_temp(fIdx).btnDataView` | `BackgroundColor` | default / theme normal | `[0.55 0.32 0.80]` |
| `UI_temp(fIdx).btnDataView` | `FontColor` | default / theme normal | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).btnVid` | `BackgroundColor` | default / theme normal | `[0.12 0.12 0.12]` |
| `UI_temp(fIdx).btnVid` | `FontColor` | default / theme normal | `[1.00 1.00 1.00]` |
| each of `UI_temp(fIdx).btnAtt/btnMap/btnAlt/btnInfo/btnDataView/btnVid` | `FontSize` | default | `11` |
| each of `UI_temp(fIdx).btnAtt/btnMap/btnAlt/btnInfo/btnDataView/btnVid` | `FontWeight` | default | `'bold'` |
| `UI_temp(fIdx).dataGrid` | `BackgroundColor` | default | `panelColors{fIdx}` |
| `UI_temp(fIdx).colSplitters(sIdx)` | `BackgroundColor` | `[0.50 0.50 0.54]` | `[0.18 0.36 0.52]` |

---

### 9. `createLayout(app)` — internal content panels

Keep these content panels white/light because they contain plots, axes, or tables.

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `UI_temp(fIdx).panelAttitude` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).panelAttitude` | `ForegroundColor` | default | `t.textPrimary` |
| `UI_temp(fIdx).panelMapAlt` | `BackgroundColor` | `panelColors{fIdx}` | `panelColors{fIdx}` blue |
| `mapPnl` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `mapPnl` | `ForegroundColor` | default | `t.textPrimary` |
| `altPnl` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `altPnl` | `ForegroundColor` | default | `t.textPrimary` |
| `infoPanel` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `infoPanel` | `ForegroundColor` | default | `t.textPrimary` |
| `hPnl` / `UI_temp(fIdx).panelDataView` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `hPnl` / `UI_temp(fIdx).panelDataView` | `ForegroundColor` | default | `t.textPrimary` |
| `btnPnl` inside `hPnl` | `BackgroundColor` | `'w'` | `[0.94 0.96 0.98]` |
| `UI_temp(fIdx).hiSplitter` | `BackgroundColor` | `[0.75 0.75 0.80]` | `[0.18 0.36 0.52]` |
| `UI_temp(fIdx).hiSplitter` | `BorderColor` | `[0.45 0.45 0.55]` | `[0.30 0.48 0.65]` |
| `UI_temp(fIdx).vidViewerDialog` | `Color` | `[0.94 0.94 0.96]` | `t.windowBg` |
| `UI_temp(fIdx).panelVideo` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `UI_temp(fIdx).panelVideo` | `ForegroundColor` | default | `t.textPrimary` |
| `vBtnPnl` | `BackgroundColor` | `'w'` | `[0.94 0.96 0.98]` |
| `UI_temp(fIdx).vidContainer` | `BackgroundColor` | `[0 0 0]` | `[0 0 0]` |
| `UI_temp(fIdx).vidAxes.Color` | `Color` | `[0 0 0]` | `[0 0 0]` |
| `UI_temp(fIdx).vidSyncStatus` | `FontColor` | `[0.5 0.5 0.5]` | `t.textSecondary` |

---

### 10. Data table and plot tab area

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `UI_temp(fIdx).dataTable` | `BackgroundColor` | `tblBgColor` | `[1.00 1.00 1.00; 0.94 0.97 1.00]` |
| `UI_temp(fIdx).dataTable` | `ForegroundColor` | `themeT.textPrimary` | `t.textPrimary` |
| `UI_temp(fIdx).dataTable` | `FontSize` | `11` | `11` |
| `UI_temp(fIdx).dataTable` | `FontName` | `'Consolas'` | `'Consolas'` |
| `UI_temp(fIdx).dataTable` | `RowStriping` | `'off'` | `'on'` |
| `UI_temp(fIdx).tabGroup` | child `uitab.BackgroundColor` | may be default or dark after runtime | `[1.00 1.00 1.00]` |
| each `newTab` created by `addPlotTab` | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| each `newTab` created by `addPlotTab` | `ForegroundColor` | default | `t.textPrimary` |
| plot panel `p` inside `addPlotTab` / board-off plot creation | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| plot axes `ax` inside `addPlotTab` / board-off plot creation | `Color` | default or inherited | `[1.00 1.00 1.00]` |
| plot axes `ax` | `XColor` | default | `t.textSecondary` |
| plot axes `ax` | `YColor` | default | `t.textSecondary` |
| plot axes `ax` | `GridColor` | default | `t.gridLine` |

---

### 11. `createGaugePanel(~, parentPnl, titleStr)`

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `lbl` | `FontColor` | default | `t.textPrimary` if available through app; otherwise `[0.05 0.05 0.05]` |
| `lbl` | `FontSize` | `12` | `12` |
| `axPnl` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `ax` | `Color` | `'none'` | `'none'` |

If needed, change method signature from `function [ax, lbl, grid] = createGaugePanel(~, parentPnl, titleStr)` to `function [ax, lbl, grid] = createGaugePanel(app, parentPnl, titleStr)` only to access `app.getLightTheme()`. Do not change callers except preserving the same call arguments.

---

### 12. `createBoardOffSummaryPanel(app, parentGrid, fIdx)`

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `pnl` | `BackgroundColor` | `[0.98 0.98 0.98]` | `t.panelBlueBg` |
| `pnl` | `ForegroundColor` | default | `t.panelBlueFg` |
| `root` | `BackgroundColor` | default | `t.panelBlueBg` |
| `infoPanel` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `infoPanel` | `ForegroundColor` | default | `t.textPrimary` |
| `tbl` | `BackgroundColor` | `tblBgColor` | `[1.00 1.00 1.00; 0.94 0.97 1.00]` |
| `tbl` | `ForegroundColor` | `themeT.textPrimary` | `t.textPrimary` |
| `tbl` | `RowStriping` | `'off'` | `'on'` |
| `plotPanel` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `plotPanel` | `ForegroundColor` | default | `t.textPrimary` |
| `btnRow` | `BackgroundColor` | default | `[0.94 0.96 0.98]` |
| `blankTab` | `BackgroundColor` | default | `[1.00 1.00 1.00]` |
| blank placeholder label | `FontColor` | `[0.45 0.45 0.45]` | `t.textSecondary` |

---

### 13. `createVideoControlDialog(app, fIdx)`

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `syncPnl` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `syncPnl` | `ForegroundColor` | default | `t.textPrimary` |
| `ctrl.vidSyncBtn` | `BackgroundColor` | `[0.58 0.0 0.83]` | `t.toolbarGreenBg` |
| `ctrl.vidSyncBtn` | `FontColor` | `'w'` | `t.toolbarGreenFg` |
| `vdubGroupPnl` | `BackgroundColor` | `[0.97 0.97 0.99]` | `[0.94 0.96 0.98]` |
| `vdubGroupPnl` | `ForegroundColor` | default | `t.textPrimary` |
| `ctrl.vidVdubLabel` | `FontColor` | `[0.1 0.2 0.5]` | `t.accentBlueText` |
| `navPnl` | `BackgroundColor` | `[0.97 0.97 0.99]` | `[0.94 0.96 0.98]` |
| `hzPnl` | `BackgroundColor` | `'w'` | `[1.00 1.00 1.00]` |
| `hzPnl` | `ForegroundColor` | default | `t.textPrimary` |
| navigation buttons `◄◄`, `◄`, `►`, `►►` | `BackgroundColor` | default | `t.toolbarGrayBg` |
| same navigation buttons | `FontColor` | default | `t.toolbarGrayFg` |
| small FPS/cache buttons `◄`, `►` | `BackgroundColor` | default | `t.toolbarGrayBg` |
| same small buttons | `FontColor` | default | `t.toolbarGrayFg` |

---

### 14. Edit dialog style labels and action buttons

| Variable / object | Parameter | Before | After |
|---|---|---|---|
| `app.EditDialogStatusLbl` | `FontColor` | default | `t.textPrimary` |
| `app.EditDialogDirtyLbl` clean state | `FontColor` | `[0.4 0.4 0.4]` | `t.textSecondary` |
| `app.EditDialogDirtyLbl` dirty state | `FontColor` | `[0.8 0.2 0.2]` | `t.warningRed` |
| `app.EditDialogTimeLbl` | `FontColor` | `[0.4 0.4 0.4]` | `t.textSecondary` |
| `app.EDProjectPathLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| `app.EDProjectStatusLbl` | `FontColor` | `[0.4 0.4 0.4]` | `t.textSecondary` |
| `app.EDProjectLastSaveLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| `app.EDProjectLayoutLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| `app.EDSyncOffsetLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| `app.EDExpPreviewLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| `app.EDExpMissingLbl` | `FontColor` | `[0.3 0.3 0.7]` | `t.accentBlueText` |
| green export/apply buttons | `BackgroundColor` | `[0.06 0.65 0.50]` | `t.toolbarGreenBg` |
| green export/apply buttons | `FontColor` | `'w'` | `t.toolbarGreenFg` |
| blue apply buttons | `BackgroundColor` | `[0.15 0.38 0.82]` | `t.toolbarBlueBg` |
| blue apply buttons | `FontColor` | `'w'` | `t.toolbarBlueFg` |
| red delete/warning buttons | `BackgroundColor` | `[0.75 0.20 0.20]` | `t.btnWarningBg` |
| red delete/warning buttons | `FontColor` | `'w'` | `t.btnWarningFg` |

---

## Verification Requirements

After making the style-only changes:

1. Run a MATLAB syntax check for `FlightDataDashboard.m`.
2. Launch the app once if possible.
3. Verify visually:
   - Header area is dark blue.
   - Toolbar buttons are large and role-colored.
   - Flight board titled panels are blue with white title text.
   - Tables and axes remain white/light with dark text.
   - Plot tab area is not black.
   - Video display area remains black.
   - No white text appears on white background.
   - No dark gray text appears on dark blue background.
4. Do not modify non-style behavior to satisfy these checks.

---

## Expected Output From Claude Code

Return only:

1. A concise summary of edited style properties.
2. Any MATLAB syntax check result.
3. Any visual/manual check result.
4. Do not include full code.
5. Do not include large diffs.
