# 회귀 실행 체크리스트 (환경 가능 시 그대로 실행)

MATLAB 환경에서 `FlightDataDashboard.m`/`auto_test_runner.m` 와 같은 폴더,
`flight_data1.dat`/`flight_data2.dat` 존재 상태로 실행.

## 1단계 — R2/R3 패치 검증 (필수, 빠름)
```matlab
auto_test_runner('CaseList',[115 116 118 149:158], 'LoadAvi','lazy', 'CaptureMode','fail')
```
- 기대: 115/116/118 및 149~158 **PASS** 전환.
- 의미: goToFrame currentIndex(149~158), project preset/panel(115/116), altitude
  marker 콜백(118) 패치 효과 확인.
- 149~158 은 video sync 케이스 — `LoadAvi='lazy'` 로 requireAvi 충족 필요(AVI 파일 존재 확인).

## 2단계 — board-off 클러스터 stale 판정 검증
```matlab
auto_test_runner('CaseList',[7 8 9 10 11 16 19 22 23 24 25 26 31 34 38 39 42 44 70 71 76 77 78], 'LoadAvi','lazy', 'CaptureMode','fail')
```
- 기대: **이미 PASS** (revert `7fd9e22` 후 v5-B 베이스라인; 최신 복원 경로상 ZIP 실패 재현 불가).
- 만약 FAIL 잔존 시: 해당 케이스의 `expected vs actual` polarity 확인 →
  exp/actual 이 ZIP 과 같은 `exp=1/actual=0` 면 코드가 ZIP 시점과 동일(추가 조사),
  반대(`exp=0/actual=1`)면 복원-from-snapshot 동작 → expected 재모델 필요.

## 3단계 — 전체 회귀
```matlab
auto_test_runner('LoadAvi','lazy', 'CaptureMode','fail')
```
- 권장 옵션: `CaptureMode='fail'`(실패 진단만 캡처, 빠름), 필요 시 `'baseline'`.
- 예상 시간: 174건 × (setup+actions+settle). 로컬 기준 수~십 분(AVI lazy).
- OOM/hang 우려 환경: `OnlineSafeMode=true`, `LoadAvi='never'`(단 video 케이스 SKIP).

## 실패 시 보고 양식
```
case ID : (예) 116
expected: board 2 info PanelVisible expected=1
actual  : actual=0
의심 카테고리: I-PROJECT-RESTORE (fixture expected)
progress 로그: progress_NNN-NNN.md 의 해당 STEP 라인
caseNN.md Failure Detail 전문
```

## K-PATH3D — 3D Path Phase 1 수동 검증
```matlab
app = FlightDataDashboard;
```
- `3D 경로` 버튼으로 Flight 1/2 다이얼로그 open/close.
- 시간 spinner 또는 plot marker 이동 시 solid past trajectory 길이 변경 확인.
- board-off 진입 시 열린 3D Path 창이 숨겨지고 board-on 복귀 시 다시 표시되는지 확인.
- `# WayPoint` 섹션이 있는 option 파일 로드 시 waypoint 점 표시 확인.
- project 저장/로드 후 `3D 경로` 표시 상태가 복원되는지 확인.

## 부록 — 적용 패치 커밋 표

| 커밋 | 내용 | 영향 범위 |
|---|---|---|
| `3d2a083` | goToFrame: videoSynced 시 currentIndex don't-care | `auto_test_runner.m` `i_updateExpectedState` (J-PANEL-SYNC) |
| `f272038` | board-off 중 video handle 검사 skip | `auto_test_runner.m` `i_validateState` (B/D) |
| `c109d67` | project fixture expected 헬퍼 통합 | `auto_test_runner.m` `i_applyProjectFixtureExpected` (I-PROJECT-RESTORE 115/116) |
| `8360625` | altitude marker/xline 콜백 재부착 | `FlightDataDashboard.m` `ensureAltitudeMarkerCallbacks` + `updateDashboard` (case118, GUI) |
| `7fd9e22` | Revert board-off 패널 가설 패치(B1+B3) | `auto_test_runner.m` `i_updateExpectedState` 베이스라인 복원 (B/C/D, G-LAYOUT) |

`main` HEAD `8360625` 에 위 전부 반영(문서/스크립트 커밋은 `codex/avi-video-layout` 후속).
