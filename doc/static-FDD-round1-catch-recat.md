# R1 재분류 — catch 블록 (화이트리스트 적용)

라운드 1 린터의 catch 관련 findings(bare 257 / no-logging 58)를 **cleanup/IO/UI
화이트리스트**로 재분류. read-only(코드 변경 없음). 라인 번호는 현 작업트리
(step1/2/4 반영) 기준.

## 화이트리스트 휴리스틱
catch 주변(−7..+3줄)에 다음 토큰이 있으면 "의도된 best-effort"로 분류:
`delete( / stop( / fclose / cancel( / cleanup / clear / drawnow / uialert /
disp( / set( / .Visible / isvalid / return / = false|true|[] / fopen / movefile / rmdir`.

## no-logging catch (58) 재분류 결과
- **의도/저위험 (36)**: cleanup·정리·fallback 대입·UI 토글·IO 닫기 등. silent가 정상.
  예: `logCaught` 내부 fallback(appValid/suppressConsole), `try delete(h); catch; end` 류.
- **수동 점검 후보 (22)**: 화이트리스트 미일치 → 진성 silent swallow 여부 line별 확인 권장.
  라인: 633, 1177, 1188, 1410, 1454, 1476, 1535, 2064, 2692, 2745, 2748, 4658,
  9287, 9323, 10278, 10604, 11264, 12937, 13314, 13489, 13649, 14336.

## bare catch (257) 평가
- 대다수 `try <stmt>; catch; end`/cleanup 패턴 → **FP(의도적)**. step4에서 16건은
  다중라인화(가독성)했고 의미는 동일. 나머지는 정리/가드 경로로 silent가 설계 의도.
- 진성 후보는 위 no-logging 22건과 대체로 중복 — bare catch 단독으로는 추가 조치 불요.

## 권고
- 22개 수동 점검 후보를 line별 1회 검토해 "정리 의도"면 주석 1줄, "진성 누락"이면
  `logCaught` 추가. 영향 낮음(대부분 cleanup) → **다음 스프린트/모니터링**.
- 자동 분류 한계: 휴리스틱이라 22건에 FP 포함 가능. 최종 판정은 수동.
