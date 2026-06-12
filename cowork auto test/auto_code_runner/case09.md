# Case 09: B04 보드1 off + 보드2 비디오 off → on

- **그룹**: B
- **검증 대상**: mid-off 영속성
- **기대 결과**: 보드2 비디오 off 유지
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case09_step01.png) |
| 02 | 보드1 off | ![](case09_step02.png) |
| 03 | 보드2 비디오 off | ![](case09_step03.png) |
| 04 | 보드1 on | ![](case09_step04.png) |
