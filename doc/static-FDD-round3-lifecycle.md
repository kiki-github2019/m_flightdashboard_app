# 정적 검사 라운드 3 — lifecycle / timer / listener / figure 자원 관리

HEAD `f15b172`.

## 1. 타이머 콜백 teardown 가드 — 완비 (양호 확인)
직전 라운드(#1/#2/#3)로 4개 타이머 콜백 + delete 재진입이 모두 `IsDeleting` 가드 보유:
| 콜백 | 가드 위치 |
|---|---|
| `pollVideoDialogFollower` (VideoDialogFollow) | 첫 줄 `if app.IsDeleting, return; end` |
| `onFlightPlayTimer` (FlightPlay) | L8895 |
| `saveProjectAutosave` (Autosave) | L13536 (#1) |
| `applyPendingDialogChanges` (EditApply) | L13645 (#2) |
| `delete(app)` 재진입 | L306 |
+ `delete` 진입부 모든 타이머 early-stop(#3), 각 timer `ErrorFcn`(#1). → **teardown lifecycle 견고**. 신규 갭 미발견.

## 2. Dialog build 예외 시 partial figure 정리 부재 (Medium, likelihood Low)
- `openEditDialog`(L6204): `fig = uifigure(...)`(L6224) → `app.EditDialog = fig` 직후 콘텐츠를
  빌드. **빌드 단계 throw 시 partial fig 를 delete 하는 outer cleanup 부재** → 반쯤 빌드된
  EditDialog figure 가 잔존(app.EditDialog 에 저장). 다음 open 시 `isvalid` true →
  `figure(app.EditDialog)` 로 반쯤 빌드된 창을 전면화.
- `createVideoControlDialog`(L9591)도 유사 구조(부분 try/catch는 일부 단계만 감쌈).
- 근거/한계: 정적 레이아웃 빌드라 throw 가능성 낮음(likelihood Low). impact Medium(orphan figure/half-built dialog).
- 최소 완화(제안): 빌드 전체를 try로 감싸 실패 시 `delete(fig); app.EditDialog=[];` (read-only 보고, 수정 안 함).

## 3. Async / worker cleanup 일관성 (양호)
- `delete(app)`: per-fIdx `cancel(app.AsyncFutures{fIdx})`(L391) + A1 클라이언트
  `cleanupAsyncDecodeCache` fallback(pool 무효/예외). worker persistent VR 는 pool 수명 의존
  (앞 bug-hunting 라운드 #7로 모니터링 항목 정리됨).
- `onAsyncDecodeComplete`의 gen-mismatch 분기는 슬롯에 새 future 보유 → 정리 불요(앞 라운드 결론).

## 4. drawnow 재진입 (대부분 차단/저위험)
- FDD `drawnow` 23곳. 재진입 민감 핸들러는 `toggleBoardVisibility`가 주였고 **#4 InBoardToggle
  가드로 차단**. 나머지는 settle/limitrate 성격 → 재진입 위험 낮음.

## 5. Listener (라운드 2 연계)
- `altXLimListener`(L8402): 재등록 전 delete(L8377) — 올바른 짝.
- L4595 로컬 `L = addlistener(ax,...)`: source(ax) 수명 묶임 → 누수 아님. rebuild가 ax를
  재사용 시 중복 가능 → **모니터링**(rebuild가 ax delete→recreate면 무해).

## 결론
- teardown/타이머/async 자원 관리는 직전 라운드들로 견고화 완료.
- 잔여: **#2 dialog build 예외 partial-figure 정리(Medium/Low likelihood)**, **#5 L4595 listener 중복(Low/모니터링)**.
