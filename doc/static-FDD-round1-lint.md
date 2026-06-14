# 정적 검사 라운드 1 — Python 린터 (FlightDataDashboard.m)

`python tools/lint_matlab.py FlightDataDashboard.m` (HEAD `f15b172`). **휴리스틱 린터**라
false-positive(FP)가 많음 — 아래에 FP 비율을 함께 표기.

## 집계 (총 367 findings)

| severity | 수 |
|---|---|
| MEDIUM | 58 |
| LOW | 309 |

| 카테고리 | 수 | 실질도 |
|---|---|---|
| bare `catch` | 241 | **대부분 FP** — 의도된 best-effort cleanup/guard |
| catch block no logging (MEDIUM) | 58 | **상당수 FP** — `disp`/fallback 대입/logCaught 내부 |
| loop var `i` shadow | 45 | 실질(스타일) — imaginary unit shadow |
| single-line try-comma | 16 | 실질(스타일) |
| magic-number density | 7 | 실질(주로 UI 빌더·테마) |

## FP 근거 (샘플)
- L259 `catch e` → `disp([... e.message])` 로 로깅하나 토큰 미일치 → FP.
- L2638/2647 → `logCaught` **내부**의 방어적 fallback 대입(`appValid=false` 등). 로깅 불요 → FP.
- bare catch 241건 다수는 `try delete(h); catch; end` 류 cleanup → 의도적.

## 실질 항목 (분류)

### Medium (검토 가치)
- **catch no logging 중 진성 후보**: 진짜 silent swallow인지 케이스별 확인 필요(58건 중 일부). 자동 분류 불가 — `disp`/fallback 제외 후 수동 선별 권장. 영향 낮음(대부분 cleanup 경로).

### Low (스타일·일관성)
- **loop var `i` (45건)**: imaginary unit shadow. 핵심 발췌 L297, 1213, 1393, 3983, 4251, 4337, 5361, 5476 외 37건. `k`/의미명으로 일괄 치환 가능(ATR에서 이미 수행한 패턴).
- **single-line try-comma (16건)**: L423, 663, 7015, 7027, 7048, 8740, 8860, 9083, 9097, 13733, 13795-6, 13863, 13866, 14141, 14153. 다수는 `try delete/stop; catch; end` 의도적 1줄 — 가독성 차이만.
- **magic-number density (7건, FP 가능)**: `getLightTheme`(279, 색상 리터럴 — 정상), `createLayout`(95), `createVideoControlDialog`(79), `initPlots`(86), `generateMockFlightData`(46), `buildEditTabPlot`(45), `plotSelectedVariable`(38). 대부분 UI 좌표/색상이라 상수화 가치 낮음(테마는 이미 토큰화). `plotSelectedVariable`만 일부 매직 넘버 정리 여지.

## 핵심 hit Top 30 (라인)
- loop-i: 297,1213,1393,3983,4251,4337,5361,5476,(+37)
- try-comma: 423,663,7015,7027,7048,8740,8860,9083,9097,13733,13795,13796,13863,13866,14141,14153
- magic#: 4440,6575,8142,8333,9591,11572,12128

## 결론
린터 신호 367건 중 **즉시 가치 있는 진성 이슈는 제한적**(loop-i 45 스타일 + try-comma 16 스타일 + 선별 필요한 catch 일부). 대량 bare-catch/no-logging은 FP. 우선순위 낮음 — 일괄 스타일 정리는 별도 라운드 권장.
