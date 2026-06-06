# ChatGPT Cowork Prompt: Strict Layout Implementation Review and Fix Plan for `FlightDataDashboard.m`

You are ChatGPT Cowork working on a MATLAB App Designer-style GUI project.

## Repository / Working File

Target file:

```text
FlightDataDashboard.m
```

Reference planning document:

```text
D:\flightdashboard\1. 최초-MVC 전\doc\layout_improvement_proposal_260605.md
```

Current implementation under review:

```text
FlightDataDashboard.m
```

The current file already contains partial changes for layout improvement, including some of the following:

- `PanelVisible` expansion
- separated `mapOnly` / `altOnly`
- layout preset buttons
- board-off summary behavior
- attitude panel reflow
- partial project save/load support for UI layout state

However, a strict review found that the implementation is incomplete against the attached layout improvement plan.

---

## Primary Goal

Bring `FlightDataDashboard.m` into strict compliance with the attached layout improvement proposal, without rewriting the whole app.

The goal is not cosmetic refactoring. The goal is to complete the missing layout behavior safely and verify that existing dashboard behavior does not regress.

---

## Important Output Rules

Follow these rules strictly:

1. Do **not** print the full modified MATLAB file.
2. Do **not** print large code blocks.
3. Do **not** rewrite unrelated parts of the app.
4. Keep all changes scoped to the layout improvement plan.
5. Preserve existing public behavior unless the plan explicitly requires a change.
6. Preserve existing Korean UI labels and comments where possible.
7. Do not remove existing test hooks unless replacing them with equivalent or better hooks.
8. Prefer small, verifiable patches.
9. After each patch, explain only:
   - what was changed,
   - why it was needed,
   - how to test it.
10. Do not output generic advice. Work directly against the uploaded/current file.

---

## Strict Findings From Prior Review

The current implementation is only a **partial implementation** of the plan.

Treat the following as confirmed issues to fix.

---

# Issue 1 — Board-off layout does not fully satisfy the plan

## Problem

The plan requires that when one board is turned off, the remaining board should use nearly all available height.

The plan specifically describes dynamic body-grid row behavior such as:

```text
normal: upper/lower board = 50:50
top off: lower board gets the available space
bottom off: upper board gets the available space
row splitter disabled when one board is off
```

The current implementation appears to use a 70:30 style source/off-summary split rather than making the active board truly use the available vertical space.

## Required Fix

Revise the board-off layout behavior so that:

1. Normal mode keeps both boards visible in a balanced layout.
2. When the upper board is off:
   - the lower board becomes the main expanded board,
   - the upper board area must not continue consuming a hidden 50% region,
   - the off-summary must not unnecessarily reduce the usable board area.
3. When the lower board is off:
   - the upper board becomes the main expanded board,
   - the lower board area must not continue consuming a hidden 50% region.
4. The behavior must be deterministic and testable through `getTestState()` or equivalent test hook state.
5. Preserve the ability to show an off-summary panel, but do not let it defeat the main purpose of using almost the full available screen.

## Acceptance Criteria

Add or update a test hook so that automated tests can verify:

- both boards on -> both visible,
- upper board off -> lower board height/visibility reflects expanded use,
- lower board off -> upper board height/visibility reflects expanded use,
- toggling off and back on restores the normal layout.

---

# Issue 2 — General column splitter required by the plan is missing

## Problem

The plan requires user-draggable column splitters between layout columns. The current file appears to retain only the older H/I splitter behavior, which is not equivalent.

The required feature is broader:

- draggable splitters between visible dashboard columns,
- hidden columns should disable adjacent splitters,
- double-click should restore default column widths,
- splitter state should not conflict with marker drag or video drag state.

## Required Fix

Implement general column splitter support in a scoped, low-risk way.

Do not reuse H/I splitter state in a way that confuses the old behavior with the new behavior.

## Required Design

Use clear state separation, for example:

```text
IsDraggingColumnSplitter
DraggedColumnSplitterInfo
ColumnSplitterStartPoint
ColumnSplitterStartWidths
```

The exact names may differ, but the logic must be explicit.

## Acceptance Criteria

At minimum, automated/manual test coverage must verify:

1. Dragging a visible splitter changes adjacent column widths.
2. Hidden panels have disabled or hidden splitters.
3. Double-click restores default widths.
4. Existing marker dragging still works before and after splitter drag.
5. Existing H/I splitter behavior, if still present, does not regress.

---

# Issue 3 — Row splitter required by the plan is missing

## Problem

The plan requires a draggable row splitter between the upper and lower boards.

The current implementation uses a two-row body grid and does not appear to implement the planned splitter row.

## Required Fix

Implement a row splitter between board 1 and board 2.

The design should support:

```text
both boards on:
    upper board
    row splitter
    lower board

one board off:
    row splitter disabled or hidden
    active board expanded
```

## Acceptance Criteria

Test manually and/or through a test hook that:

1. Dragging the row splitter changes the upper/lower board ratio.
2. Turning one board off disables/hides the row splitter.
3. Turning both boards back on restores a sensible default ratio or the last valid user ratio.
4. Row splitter drag does not interfere with:
   - marker drag,
   - video frame drag,
   - column splitter drag,
   - figure resize.

---

# Issue 4 — `info` and `dataView` are modeled but not exposed as real user toggles

## Problem

The plan expands `PanelVisible` to include:

```matlab
attitude
mapOnly
altOnly
video
info
dataView
```

The current implementation appears to include the state fields, but only the visible header buttons for attitude/map/altitude/video are exposed.

If `info` and `dataView` are only internal state fields and cannot be toggled by the user or preset system consistently, the plan is incomplete.

## Required Fix

Complete `info` and `dataView` behavior.

Possible acceptable approaches:

1. Add header toggle buttons for `info` and `dataView`, or
2. Add them to a compact layout/options dropdown, or
3. Make them fully controlled through layout presets and edit dialog UI.

Choose the safest approach for the existing UI.

## Acceptance Criteria

Verify:

1. `togglePanel(fIdx, 'info')` works.
2. `togglePanel(fIdx, 'dataView')` works.
3. The UI exposes a practical way to trigger both states.
4. `reflowBoardColumns` respects both states.
5. State is saved/restored through project serialization.

---

# Issue 5 — Custom layout preset save exists, but picker integration is incomplete

## Problem

The plan requires user-defined presets stored in:

```text
.fdproj -> UiState.LayoutPresets
```

The current implementation appears to support saving custom preset snapshots, but the header picker still appears to expose only fixed built-in presets.

## Required Fix

Complete user-defined preset usability.

## Required Behavior

1. Built-in presets remain available.
2. User-defined presets saved from the Edit Dialog must be loadable again.
3. The user should have a clear way to apply saved custom presets.
4. At least five custom preset slots should be supported, as described by the plan.
5. If more than five are saved, define deterministic behavior:
   - reject with a user message, or
   - replace the oldest, or
   - allow deletion first.

## Acceptance Criteria

Verify:

1. Save custom preset.
2. Close and reload project.
3. Custom preset still exists.
4. Apply custom preset.
5. UI layout changes match the saved snapshot.

---

# Issue 6 — Attitude/gauge reflow is partial and needs stricter verification

## Problem

The current implementation appears to contain width-based attitude reflow, but the plan requires specific behavior for:

- narrow mode,
- medium mode,
- wide mode,
- gauges-only mode,
- readable labels and values.

## Required Fix

Audit and complete attitude panel behavior.

## Required Behavior

1. Width < 220 px:
   - vertical layout,
   - readable fallback labels,
   - no unreadable overlapping text.
2. Width 220–440 px:
   - compact 2x2 style layout or equivalent.
3. Width >= 440 px:
   - horizontal 1x3 gauge layout.
4. Gauges-only preset:
   - attitude panel uses available width effectively,
   - gauges should not remain stacked vertically when there is enough horizontal room.
5. Gauge values should remain readable after:
   - figure resize,
   - panel toggle,
   - board off/on,
   - applying presets.

## Acceptance Criteria

Add test hook fields or manual verification notes for:

- attitude grid row/column layout,
- gauge font size,
- active preset,
- panel widths.

---

# Issue 7 — Project save/load must include the new layout state completely

## Problem

The layout plan requires `.fdproj` serialization for:

```text
UiState.PanelVisible
UiState.LayoutPresets
UiState.RowHeights
```

The current file has partial support, but strict verification is required.

## Required Fix

Audit and complete `collectCurrentProjectState` and `applyProjectState`.

## Required State

Ensure project round-trip preserves:

1. Per-flight `PanelVisible`:
   - `attitude`
   - `mapOnly`
   - `altOnly`
   - `video`
   - `info`
   - `dataView`
2. Board on/off state.
3. Current layout preset.
4. Built-in/custom preset state where appropriate.
5. Row splitter ratio or body grid row state.
6. Column splitter widths, if implemented.
7. User custom layout presets.

## Acceptance Criteria

Add or update a save/load verification routine that:

1. Sets a non-default layout.
2. Saves project.
3. Creates a fresh app instance.
4. Loads project.
5. Verifies that visible layout state is equivalent.

---

# Issue 8 — Regression test coverage is not sufficient

## Problem

The plan explicitly recommends adding new layout regression tests such as `G-LAYOUT-*`.

The current file has test hook support, but there is no clear evidence that dedicated regression cases for all new layout behavior exist.

## Required Fix

Add or update tests. Keep them lightweight and runnable in MATLAB Online if possible.

## Required Test Cases

Create or update tests with names similar to:

```text
G-LAYOUT-01 map/altitude independent toggle
G-LAYOUT-02 board-off active board expansion
G-LAYOUT-03 gauges-only attitude reflow
G-LAYOUT-04 built-in preset application
G-LAYOUT-05 custom preset save/load round-trip
G-LAYOUT-06 info/dataView toggle
G-LAYOUT-07 row splitter drag state
G-LAYOUT-08 column splitter drag state
G-LAYOUT-09 marker drag still works after splitter drag
G-LAYOUT-10 project save/load preserves layout
```

If full GUI drag automation is difficult in MATLAB Online, provide deterministic test hooks for the internal state and document remaining manual checks.

---

## Implementation Priority

Follow this priority order.

---

## Priority 1 — Complete L1 requirements

1. Fix board-off active board expansion.
2. Complete `mapOnly` / `altOnly` behavior if any edge case remains.
3. Ensure `reflowBoardColumns` respects all six `PanelVisible` fields.
4. Add basic test hooks for the above.

---

## Priority 2 — Complete missing user-facing toggles

1. Make `info` and `dataView` actually user-controllable.
2. Ensure they work through:
   - direct toggle,
   - presets,
   - save/load.

---

## Priority 3 — Complete presets

1. Verify all built-in presets.
2. Complete custom preset load/apply/delete or slot behavior.
3. Ensure `.fdproj` round-trip.

---

## Priority 4 — Complete splitter support

1. Implement row splitter.
2. Implement general column splitter.
3. Avoid callback conflicts with existing drag systems.
4. Add state cleanup on mouse-up and figure close/delete.

---

## Priority 5 — Complete gauge readability

1. Strictly verify all attitude panel modes.
2. Improve label/value readability only where required.
3. Avoid large visual rewrites.

---

## Required Static Analysis Checklist

Before finalizing, perform a strict static review for:

1. Undefined variables.
2. Dynamic field access that may fail when old project files are loaded.
3. Missing `isfield` guards for backward compatibility.
4. Callback state conflicts:
   - marker drag,
   - video frame drag,
   - H/I splitter drag,
   - new column splitter drag,
   - new row splitter drag.
5. Figure resize reentrancy.
6. `WindowButtonMotionFcn` / `WindowButtonUpFcn` overwrite hazards.
7. Timer cleanup.
8. Delete/close cleanup.
9. Project save/load schema compatibility.
10. MATLAB Online compatibility.
11. UI handles that may be empty or invalid after toggles.
12. `RowHeight` / `ColumnWidth` formats mixing numeric, char, and cell values.
13. Hidden panels still consuming space.
14. Preset application leaving stale button text or visual state.
15. Board-off state conflicting with per-panel visibility state.

---

## Required Final Response Format

After applying the changes, respond with the following sections only:

```text
## Summary
- ...

## Files Changed
- ...

## Implemented Requirements
- ...

## Remaining Limitations
- ...

## Static Analysis Findings
- ...

## Tests Performed
- ...

## Manual Tests Still Recommended
- ...
```

Do not include full source code in the final response.

---

## Definition of Done

This task is complete only when all of the following are true:

1. The implementation satisfies the attached layout improvement proposal, not just part of it.
2. All six `PanelVisible` states are functional and restorable.
3. Board-off mode uses screen space correctly.
4. Built-in layout presets work.
5. Custom presets are usable after save/load.
6. Row splitter and general column splitter are either implemented or explicitly deferred with a clear reason and no misleading partial implementation.
7. New layout behavior has test coverage or deterministic test hooks.
8. Existing marker drag and video sync behavior do not regress.
9. MATLAB Online compatibility is preserved.
10. The final response does not print the full modified MATLAB file.
