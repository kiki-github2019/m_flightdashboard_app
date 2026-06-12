# Case 48: E03 보드2 off + applyTimeChange

- **그룹**: E
- **검증 대상**: off-summary 동기
- **기대 결과**: marker 추종
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case48_step01.png) |
| 02 | 보드2 off | ![](case48_step02.png) |
| 03 | applyTimeChange(1,30) | ![](case48_step03.png) |
| 04 | applyTimeChange(1,100) | ![](case48_step04.png) |
