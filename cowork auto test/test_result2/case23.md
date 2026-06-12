# Case 23: C03 보드2 off + 보드1 지도 off → on

- **그룹**: C
- **검증 대상**: mid-off 영속성
- **기대 결과**: 보드1 지도 off 유지
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case23_step01.png) |
| 02 | 보드2 off | ![](case23_step02.png) |
| 03 | 보드1 지도/고도 off | ![](case23_step03.png) |
| 04 | 보드2 on | ![](case23_step04.png) |
