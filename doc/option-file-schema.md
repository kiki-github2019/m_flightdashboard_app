# Option File Schema

`option1.dat` and `option2.dat` keep the existing `# RequiredColumns` and `# DisplayColumns` sections.

## RequiredColumns

`# RequiredColumns` maps semantic roles used by the dashboard to columns in the loaded flight data.

For 3D Path, these mappings define the body position:

```text
# RequiredColumns
Time: time_s
Roll: roll_deg
Pitch: pitch_deg
Heading: heading_deg
Alt: alt_m
Lat: lat_deg
Lon: lon_deg
```

- `Lat`, `Lon`, and `Alt` are the body position/altitude source.
- The 3D Path dialog, `Map` panel, and `Altitude` panel use the same mapped flight-data source.
- Changing these mappings changes the body trajectory source after the option file is applied.

## DisplayColumns

`# DisplayColumns` controls table display metadata and optional scaling.

```text
# DisplayColumns
lat_deg,degree,%.6f,6,1
lon_deg,degree,%.6f,7,1
alt_m,m,%.6f,13,1
```

Display columns do not choose the body trajectory source unless the same column is also mapped in `# RequiredColumns`.

## WayPoint

Optional reference/annotation section. It does not define body position.

```text
# WayPoint
WP1 = 36.5001, 127.5002, 300.0, Takeoff
WP2 = 36.5100, 127.5300, 320.0, Turn
```

Format is `name = lat, lon, alt[, label]`.

Invalid rows are skipped and logged as `option:wayPoint:invalidRow`.

## BodyAttitude

Optional section for overriding the attitude angle source used by the 3D drone glyph.

```text
# BodyAttitude
bodyX = roll_deg
bodyY = pitch_deg
bodyZ = heading_deg
```

- `bodyX`, `bodyY`, and `bodyZ` are interpreted as roll, pitch, and yaw/heading angle columns.
- Column names containing `rad` are treated as radians.
- Column names containing `deg`, or angle values larger than the radian range, are treated as degrees.
- Do not map body position columns (`lat`, `lon`, `alt`) or angular-rate columns (`gyro`, `rate`) here.
- If any configured column is missing, the app falls back to `Roll`, `Pitch`, and `Heading`; if those are unavailable, position still updates with identity rotation.
