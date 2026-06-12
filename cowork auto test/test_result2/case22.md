# Case 22: C02 보드2 off + 보드1 자세 off → on

- **그룹**: C
- **검증 대상**: mid-off 영속성
- **기대 결과**: 보드1 자세 off 유지
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case22_step01.png) |
| 02 | 보드2 off | ![](case22_step02.png) |
| 03 | 보드1 자세 off | ![](case22_step03.png) |
| 04 | 보드2 on | ![](case22_step04.png) |
