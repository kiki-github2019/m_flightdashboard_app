# Case 20: B15 보드1 off + applyTimeChange

- **그룹**: B
- **검증 대상**: 드래그 결과 동기
- **기대 결과**: source 시간 + off-summary 추종
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case20_step01.png) |
| 02 | 보드1 off | ![](case20_step02.png) |
| 03 | applyTimeChange(2,50) | ![](case20_step03.png) |
| 04 | applyTimeChange(2,200) | ![](case20_step04.png) |
