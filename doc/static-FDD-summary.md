# 정적 검사 통합 요약 — FlightDataDashboard.m (HEAD `f15b172`)

read-only 4라운드 정적 검사. 코드 변경 없음. 휴리스틱·정적 분석 특성상 FP는
가능성·근거와 함께 표기.

## 라운드별 보고서
- [라운드 1 — Python 린터](static-FDD-round1-lint.md)
- [라운드 2 — properties/methods/callbacks cross-reference](static-FDD-round2-xref.md)
- [라운드 3 — lifecycle/timer/listener/figure](static-FDD-round3-lifecycle.md)
- [라운드 4 — 최근 변경 영향 분석](static-FDD-round4-impact.md)

## 라운드별 핵심
- **R1 (린터)**: 367 findings 중 진성은 제한적 — loop-var `i`(45, 스타일), try-comma(16, 스타일), magic#(7, 대부분 UI/테마 FP). bare-catch(241)/no-logging(58)은 대부분 FP(의도된 cleanup, `disp`/fallback).
- **R2 (xref)**: 정적 usage-count가 **동적 필드 접근**(`app.(sprintf('EDVSync%d..'))`, `app.(slotName)`)으로 신뢰 불가 → "미사용" 후보 대부분 FP. 진성: `EditDialogStatusLbl` 생성 후 미갱신(Low), L4595 listener 중복 가능성(Low/모니터링). 타이머 등록/해제 짝 양호.
- **R3 (lifecycle)**: 타이머 4종 콜백 + delete 재진입 모두 `IsDeleting` 가드 완비(직전 #1/#2/#3). 진성: dialog build 예외 시 partial figure 정리 부재(Medium/likelihood Low).
- **R4 (impact)**: `8847a66..f15b172` 변경은 시그니처 추가·additive 가드·내부 최적화 위주로 호출부 비파괴. 외부 회귀 표면 미발견.

## 통합 우선순위 표

| # | 항목 | 라운드 | Severity | FP 위험 |
|---|---|---|---|---|
| 1 | dialog build 예외 시 partial figure 미정리 (openEditDialog/createVideoControlDialog) | R3 | Medium (likelihood Low) | 낮음 |
| 2 | loop-var `i` shadow 45곳 | R1 | Low (스타일) | 낮음 |
| 3 | single-line try-comma 16곳 | R1 | Low (스타일) | 낮음 |
| 4 | `EditDialogStatusLbl` 생성 후 미갱신 | R2 | Low | 중(동적 갱신 가능성, 확인 결과 없음) |
| 5 | L4595 axis XLim listener 중복 누적 가능성 | R2/R3 | Low | 중(rebuild가 ax 재생성이면 무해) |
| 6 | `plotSelectedVariable` 등 magic-number 밀도 | R1 | Low | 높음(UI 좌표/색상 다수 FP) |
| 7 | catch no-logging 진성 선별분 | R1 | Low | 높음(다수 FP) |

## 적용 권고
- **즉시**: 없음 — 직전 라운드들로 lifecycle/타이머/async가 이미 견고화됨. 신규 critical/high 미발견.
- **다음 스프린트**: #1 dialog build 예외 정리(빌드 전체 try + 실패 시 `delete(fig)`), #2/#3 스타일 일괄 정리(loop-i/try-comma, ATR에서 검증된 패턴).
- **모니터링**: #5 listener 중복(rebuild 경로 1회 확인), #4 status 라벨, tempdir fixture 환경 의존(R4).
- **보류**: #6/#7 — FP 비율 높아 수동 선별 비용 대비 가치 낮음.

## 총평
HEAD `f15b172`의 FDD는 최근 라운드들(A1–C6, #1–#8)로 **자원 lifecycle·예외 로깅·타이머
teardown이 견고**하다. 정적 검사로 새로 드러난 **즉시 조치 critical/high는 없음**. 잔여는
스타일(loop-i/try-comma) + 1건의 Medium(dialog build 예외 정리, 발생 가능성 낮음) +
동적 접근으로 인한 정적-도구 한계(FP) 위주.
