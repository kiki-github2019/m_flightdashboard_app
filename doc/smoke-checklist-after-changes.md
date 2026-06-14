# Smoke 체크리스트 — step1~5 변경 후 (MATLAB 환경 1회 실행)

step1(dialog cleanup)·step2(status 라벨)·step4(try-comma) 적용 후 핵심 4시나리오
+ 옵션 + tempdir 잔여 점검. 코드 변경 없음(점검 절차 문서).

## 사전
- 작업 폴더에 `FlightDataDashboard.m`, `flight_data1.dat`, `flight_data2.dat` (+ AVI는 sync 시).
- `app = FlightDataDashboard;` 로 기동, `app.DebugMode = true;`(진단 로그 활성).

## 1. Project restore
```matlab
auto_test_runner('CaseList', 115, 'CaptureMode','fail')   % layout_hsplit_grid
```
- 기대: PASS. EditDialog 경로면 status 라벨 '준비'→동작별 갱신(step2) 확인.
- 진단: `app.dumpErrorLog(20)` 에 `dialog:editDialog:build` 예외 없는지(step1 정상).

## 2. Board-off
```matlab
auto_test_runner('CaseList', [7 22 70], 'CaptureMode','fail')
```
- 기대: B/C/G-LAYOUT board-off 케이스 PASS(또는 알려진 stale 판정과 일치).
- 진단: 빠른 board 토글 후 재진입 가드(#4) 정상 — `boardToggle` 중복 진입 로그 없음.

## 3. Video sync
```matlab
auto_test_runner('CaseList', [149 150 31 32], 'LoadAvi','lazy', 'CaptureMode','fail')
```
- 기대: video control sync + dual-sync 독립성(J-PANEL-SYNC-31/32) PASS.
- 진단: F1 goToFrame 시 F2 frame/index 불변.

## 4. Flight play
```matlab
auto_test_runner('CaseList', [3263], 'CaptureMode','fail')   % H-FLIGHT-PLAY start-stop
```
- 기대: 타이머 start→stop 누수 없음. timer `ErrorFcn`(#1) 경유 로그만(예외 시).

## 옵션 점검
```matlab
auto_test_runner('CaptureMode','fail', 'OnlineSafeMode', true, 'LoadAvi','never')
```
- 기대: OnlineSafeMode 경고가 progress.md 의 `ONLINE_SAFE_WARN` 로 기록. FAIL 시
  `VALIDATION_ISSUE` 항목별 라인(A3) + case.md `## Validation Issues` 확인.

## tempdir 잔여 점검 (B3 fixture)
- 실행 후: `dir(fullfile(tempdir,'*_fdproj'))` 가 비어 있어야(runner onCleanup 이 정리).
- 잔여 시: 비정상 종료(Ctrl+C 외) 의심 → `i_tempProjectFileRegistry('cleanup','')` 수동 호출.

## EditDialog status 라벨(step2) 수동 확인
- EditDialog 열기 → 필드 편집(→'변경됨') → '적용'(→'적용됨') → 'project 저장'(→'저장됨').
- 저장 경로 강제 실패(권한 없는 경로) → '오류' 표시 확인.

## dialog build 예외(step1) 수동 확인(선택)
- 정상 환경에선 재현 어려움. build 단계에 임시 `error()` 주입 시 partial figure 가
  남지 않고(`findall(groot,'Type','figure')` 증가 없음) 예외가 전파되는지 확인 후 원복.

## 합격 기준
- 4시나리오 PASS(또는 문서화된 stale 판정 일치), dumpErrorLog 에 신규 build/timer 예외 없음,
  tempdir `*_fdproj` 잔여 0, status 라벨 5상태 정상 전이.
