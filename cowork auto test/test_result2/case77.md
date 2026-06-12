# Case 77: G-LAYOUT-27 source-board mapOnly toggle during board-off

- **그룹**: G-LAYOUT
- **검증 대상**: panel toggle during board-off persists after board-on
- **기대 결과**: v-final P8
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case77_step01.png) |
| 02 | lower board off | ![](case77_step02.png) |
| 03 | source flight1 mapOnly toggle | ![](case77_step03.png) |
| 04 | lower board on | ![](case77_step04.png) |
