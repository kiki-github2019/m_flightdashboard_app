# Regression Checklist

Run from the folder that contains `FlightDataDashboard.m`, `auto_test_runner.m`, and the sample data files.

## Fast Smoke

```matlab
auto_test_runner('CaseList',[115 116 118 149:158], ...
    'LoadAvi','lazy', ...
    'CaptureMode','fail', ...
    'OnlineSafeMode',true)
```

Expected: all selected cases pass.

## Board-Off And Layout

```matlab
auto_test_runner('CaseList',[7 8 9 10 11 16 19 22 23 24 25 26 31 34 38 39 42 44 70 71 76 77 78], ...
    'LoadAvi','lazy', ...
    'CaptureMode','fail', ...
    'OnlineSafeMode',true)
```

Expected: board-off/on restores panel visibility and does not leave blank layout gaps.

## Full Runner

```matlab
auto_test_runner('LoadAvi','lazy', ...
    'CaptureMode','fail', ...
    'OnlineSafeMode',true)
```

Use `LoadAvi='never'` when testing in a constrained MATLAB Online session and video-specific cases can be skipped.

## 3D Path

K-PATH3D cases are appended after K-PANEL-CAPTURE cases so existing case numbers remain stable.

```matlab
auto_test_runner('CaseList',166:174, ...
    'LoadAvi','never', ...
    'CaptureMode','all', ...
    'CaptureScale',1, ...
    'OnlineSafeMode',true)
```

Expected:

- 3D Path dialog opens, closes, hides during board-off, and restores after board-on.
- Full trajectory is present and X/Y/Z data lengths match.
- Past trajectory is present after time changes and X/Y/Z data lengths match.
- Trajectory data contains finite coordinates.
- Drone transform and RGB body axes exist when flight data is loaded.
- `Path3DVisible` round-trips through in-memory project layout state.
- `# RequiredColumns` `Lat`/`Lon`/`Alt` remain the body position source.
- Optional `# WayPoint` rows render only as reference points and do not replace body trajectory.

## 3D Path Manual Check

```matlab
app = FlightDataDashboard;
```

Manual checks:

- Open `3D Path` for Flight 1 and Flight 2.
- Move the main time spinner or drag a plot marker; the solid past trajectory and drone glyph should move.
- Enter board-off mode while a 3D Path dialog is open; the dialog should hide.
- Return board-on; the dialog should restore only if it was previously requested.
- Load an option file with `# WayPoint`; waypoint dots should appear separately from the body trajectory.
- Confirm Map, Altitude, and 3D Path use the same mapped `Lat`/`Lon`/`Alt` source.

## Project Restore

```matlab
auto_test_runner('CaseList',[89:97 115 116 118 149:158 166:174], ...
    'LoadAvi','lazy', ...
    'CaptureMode','fail', ...
    'CaptureScale',1, ...
    'OnlineSafeMode',true)
```

Expected: project state restore does not break panel visibility, sync state, 3D Path desired visibility, or video control state.
