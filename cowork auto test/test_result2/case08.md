# Case 08: B03 보드1 off + 보드2 지도 off → on

- **그룹**: B
- **검증 대상**: mid-off 영속성
- **기대 결과**: 보드2 지도 off 유지
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case08_step01.png) |
| 02 | 보드1 off | ![](case08_step02.png) |
| 03 | 보드2 지도/고도 off | ![](case08_step03.png) |
| 04 | 보드1 on | ![](case08_step04.png) |
