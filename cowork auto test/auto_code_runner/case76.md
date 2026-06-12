# Case 76: G-LAYOUT-26 source-board attitude toggle during board-off

- **그룹**: G-LAYOUT
- **검증 대상**: panel toggle during board-off persists after board-on
- **기대 결과**: v-final P8
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case76_step01.png) |
| 02 | upper board off | ![](case76_step02.png) |
| 03 | source flight2 attitude toggle | ![](case76_step03.png) |
| 04 | upper board on | ![](case76_step04.png) |
