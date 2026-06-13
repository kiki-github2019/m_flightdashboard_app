# 디버깅 가이드 — FlightDataDashboard

## 1. 에러 로깅: `logCaught` + ErrorLog ring buffer

- 모든 try/catch 는 `app.logCaught(ME, 'tag')` 로 통일. silent catch 라도 ring
  buffer(`ErrorLog`, 용량 `ErrorLogCapacity`=200)에 보관됨.
- 콘솔 출력은 `DebugMode` 일 때만(또는 silent 태그 생략). ring buffer 는 항상 유지.
- 사후 조사: `app.dumpErrorLog(n, filterTag)` — 최근 n개(태그 필터 옵션) 덤프.
- runner 측도 핵심 hook 실패를 `app.logCaught(ME,'runner:...')` 로 ring buffer 에 흔적(2026-06-14 M6).

**패턴**
```matlab
try
    ... 위험 동작 ...
catch ME
    app.logCaught(ME, 'subsystem:operation');
end
```
cleanup 콜백(onCleanup) 내부는 예외가 밖으로 새지 않게 자체 `try ... catch` 로 감쌈.

## 2. testHook 카탈로그 (테스트 전용 — production 의존 금지)

`varargout = app.testHook(methodName, varargin{:})`. 주요 그룹:

- **데이터/UI 부트스트랩**: `parseFlightData`, `setupDataUI`, `calculateBounds`,
  `initPlots`, `updateDashboard`
- **상태 스냅샷**: `getTestState`(read-only UI/model 스냅샷), `collectCurrentProjectState`
- **패널/보드**: `pushPanelToggleButton`, `pushBoardToggleButton`, `togglePanel`
- **project**: `setProjectFilePath`(테스트 setter; varargin 비면 clear, varargout{1}=이전값),
  `saveProjectFile`, `autoLoadProjectFromFile`, `editDialogOpenProjectFromPath`
- **video/sync**: `setVideoSync`, `goToFrame`, `setFlightDataSync`, `setPendingSyncAnchor`,
  `applyPendingSyncAnchor`, `computeSyncSearchRows(Raw)`
- **EditDialog**: `openEditDialog`, `closeEditDialog`, `applyPendingDialogChanges`,
  `editDialog*`
- **flight play**: `startFlightPlay`, `stopFlightPlay`, `isFlightPlayTimerAlive`
- **dialog/capture 보조**: `getOpenDialogHandlesForTest`, `getSelectedInfoValueForTest`,
  `getInfoTableMenuTexts`

테스트 hook 의 schema(필드명)를 바꾸면 `auto_test_runner` 와 동기화 필요
(예: `getTestState.ProjectFilePath` 필드는 `editDialogSaveProject` 가드가 의존).

## 3. capture dedup 작동 방식 (`auto_test_runner`)

- `i_captureFigure` 가 캡처 이미지의 signature(MD5, JVM 없으면 stride 샘플 통계)를
  계산해 직전 동일 키 signature 와 같으면 저장 skip(`status='duplicate'`).
- **target key**: `class|Tag|Name|handle식별자(nNumber 또는 h<double>)` 조합 +
  경로 tag(`|gf` getframe / `|ea` exportapp fallback) → 키 충돌·source 혼선 방지.
- skip 된 경로는 `i_captureDuplicateFile('add',...)` 로 persistent set + `duplicates.log`
  에 기록. `i_captureMarkdown` 이 set 조회로 `(duplicate skipped)` vs `(not captured)` 구분.
- persistent 상태는 runner 진입부 `i_captureDuplicateReset()` 로 초기화(중첩 실행 이월 방지).
- dedup 는 capture 비용(getframe/scale/signature)을 줄이지 않음 — 저장·리포트 노이즈만 절감.

## 4. board-off 동작 핵심 (회귀 민감)

- 진입: `captureBoardPanelState(fIdx)` + `captureBoardPanelState(sourceIdx)` 스냅샷 →
  off 보드 숨김, source 보드 hsplit(upper info+plot).
- 복원(board-on): `restoreBoardPanelState(fIdx)` + `restoreBoardPanelState(sourceIdx)`
  → **양 보드를 진입 시점 스냅샷으로 복원** + `ensureBoardCorePanelsVisible`(info/dataView 강제).
- 즉 source 의 during-off 토글은 복원 시 스냅샷 값으로 되돌아감(영속 아님). 테스트
  expected(v5-B)와의 정합은 런타임 검증 권고(2026-06-14 failure report 참조).

## 5. altitude marker/xline 콜백
`ensureAltitudeMarkerCallbacks(fIdx)` 가 `hAltMarker`/`timeLine` 의
`HitTest='on'`·`PickableParts='visible'`·`ButtonDownFcn`(비면 재설정) 복구.
`updateDashboard` 끝에서 best-effort 호출 → project 복원/동기 갱신 후 드래그 죽음 방지.
