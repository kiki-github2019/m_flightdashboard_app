# Case 61: G-LAYOUT-11 layout preset preserves PanelVisible

- **그룹**: G-LAYOUT
- **검증 대상**: arrangement only
- **기대 결과**: preset does not toggle panels
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case61_step01.png) |
| 02 | apply layout-vsplit | ![](case61_step02.png) |
| 03 | apply layout-compact | ![](case61_step03.png) |
| 04 | back to grid | ![](case61_step04.png) |
