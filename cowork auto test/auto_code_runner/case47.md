# Case 47: E02 보드1 off + applyTimeChange

- **그룹**: E
- **검증 대상**: off-summary 동기
- **기대 결과**: marker 추종
- **관측 결과**: `PASS`

## 액션 시퀀스

| Step | 액션 | 캡처 |
|------|------|------|
| 01 | baseline (data loaded) | ![](case47_step01.png) |
| 02 | 보드1 off | ![](case47_step02.png) |
| 03 | applyTimeChange(2,30) | ![](case47_step03.png) |
| 04 | applyTimeChange(2,100) | ![](case47_step04.png) |
