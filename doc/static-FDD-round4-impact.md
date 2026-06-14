# 정적 검사 라운드 4 — 최근 변경 영향 분석

범위 `8847a66..f15b172` (e515464~f15b172, 18 커밋). FDD/ATR 단일 레포라 외부
호출자 없음 — 영향면은 두 파일 내부 + testHook 경계로 한정.

## 변경 함수 ↔ 영향 (caller→callee)

| 변경 | 종류 | caller | 회귀 표면 | 판정 |
|---|---|---|---|---|
| `findClosestIndexByTime(~→app)` (#6) | 시그니처(첫 인자명) | 메서드 dispatch `app.findClosest...` (sync/drag 경로) | app 암묵 전달 → 호출부 무변. 정상 경로에 `if app.DebugMode` 1회 추가(저비용) | SAFE |
| `i_validateState→[ok,msg,issues]` (A3) | 반환 추가 | i_runCase 2곳 (`[ok,msg,vissues]`) | `[ok,msg]`만 받는 코드 무영향(MATLAB 다중반환) | SAFE |
| 타이머 ErrorFcn/IsDeleting/early-stop (#1/#2/#3) | additive 가드 | delete/타이머 콜백 | 정상 경로 불변, teardown만 영향 | SAFE |
| `throttleHit` read 경로 (#4 perf) | 내부 최적화 | onVdub*/video update hot path | 반환·동작 동일(cell 복사만 제거) | SAFE |
| `i_createProjectFixture` tempdir (B3) | 경로/인자 | I-PROJECT-RESTORE 케이스 | outDir 인자 미사용(`%#ok<INUSD>`), 반환 projectPath 사용 무변. fixture 위치만 tempdir | SAFE (동작 동일) |
| `i_settleUi(n→n,settleS)` (#7) | 선택 인자 추가 | 다수 호출(인자 미전달) | 기본값 0.08 → 무변 | SAFE |
| `i_appendProgressMd` flush (#2 test) | additive | 모든 progress append | 중요 status 시 close(다음 append 재오픈) — 정상 경로 동일 | SAFE |
| `applyTimeChange` 주석 (C2) / FPS 주석 (#8) | 주석 | — | 무변 | SAFE |
| `VIDEO_DIALOG_FOLLOW_S` 상수 (#5) | 상수화 | VideoDialogFollowTimer | 값 동일(0.18) | SAFE |
| `toggleBoardVisibility` 재진입 가드 (#4) | additive 가드 | 보드 토글 버튼 콜백 | 정상 단일 토글 불변, 재진입만 차단 | SAFE |
| `logCaught` fallback (C6) | additive | 전역 catch | 성공 경로 불변, append 실패 시만 fallback | SAFE |
| `cacheGetFrame/Store` numel (A2) | 동등 변경 | 디코드 캐시 hot path | length→numel 동작 동일 | SAFE |
| async cleanup 이중망 (A1) | additive | delete | pool 무효/예외 경로만 추가 | SAFE |
| ATR J-PANEL-SYNC-31/32 (#2 test) | 신규 케이스 | i_buildCaseMatrix | 기존 케이스 무영향, 신규 2건 | SAFE |

## hot path 영향 요약
- per-frame/sync 경로 변경: `throttleHit`(복사 제거, 개선), `findClosestIndexByTime`(DebugMode 분기만), `cacheGet/Store`(numel 동등). → **순효과 중립~개선**, 회귀 위험 낮음.
- teardown/lifecycle: 모두 additive 가드 → 정상 경로 무변.

## 잠재 회귀 표면 (낮음, 모니터링)
1. `findClosestIndexByTime` DebugMode 시 `issorted` 호출 — 대용량 timeArray에서 DebugMode 한정 비용(정상 모드 무영향).
2. `i_createProjectFixture` tempdir 이동 — tempdir 쓰기 권한/공간 의존(CI 환경). registry cleanup 누락 시 temp 누적(onCleanup 등록되어 정상 종료 시 정리).
3. A3 `r.issues` 문자열 필드 — `results(idx)=r` dissimilar-struct 회피 위해 5템플릿 일관 추가됨(라운드 적용 시 확인 완료).

## 결론
범위 내 변경은 **시그니처 추가(다중반환/선택인자)·additive 가드·내부 최적화** 위주로
호출부 비파괴. 외부 회귀 표면 미발견. 잔여는 환경 의존(tempdir)·DebugMode 한정 비용 수준.
