# Option File Schema

`option1.dat` and `option2.dat` keep the existing `RequiredColumns` and `DisplayColumns` sections.

## WayPoint

Optional section. Each row is:

```text
# WayPoint
WP1 = 36.5001, 127.5002, 300.0, Takeoff
WP2 = 36.5100, 127.5300, 320.0, Turn
```

Format is `name = lat, lon, alt[, label]`.

Invalid rows are skipped and logged as `option:wayPoint:invalidRow`.

## BodyAttitude

Optional section for future drone attitude visualization.

```text
# BodyAttitude
bodyX = body_x_col
bodyY = body_y_col
bodyZ = body_z_col
```

If a configured column is missing from the loaded flight data, the value is ignored and the app continues without attitude rendering.
