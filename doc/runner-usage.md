# `auto_test_runner` 사용법

FlightDataDashboard 보드 off/on + 패널 토글 회귀 러너. MATLAB 명령창에서 실행.

## 옵션

| 옵션 | 기본값 | 의미 |
|---|---|---|
| `Start` | 1 | 시작 케이스 번호 |
| `End` | Inf | 종료 케이스 번호(양끝 포함) |
| `Order` | `'asc'` | `'asc'`\|`'desc'` 실행 순서 |
| `Skip` | `[]` | 스킵할 케이스 번호 벡터 |
| `CaseList` | `[]` | 명시적 실행 순서 벡터(지정 시 Start/End/Order 무시) |
| `LoadAvi` | `'lazy'` | `'lazy'`(requireAvi 케이스만)\|`'always'`\|`'never'` |
| `CaptureMode` | `'baseline'` | `'all'`\|`'baseline'`(baseline+fail)\|`'fail'`\|`'none'` |
| `CaptureScale` | `0.60` | PNG 축소 비율(0<v≤1) |
| `DeduplicateCaptures` | `true` | 연속 중복 PNG 저장 생략 |
| `OnlineSafeMode` | `false` | MATLAB Online OOM 회피(scale clamp + 경고) |
| `OutputDir` | `''` | 산출 디렉터리(미지정 시 자동 탐지) |

## 권장 조합

- **빠른 단일 케이스**: `auto_test_runner('CaseList',2,'CaptureMode','none','LoadAvi','never')`
- **특정 클러스터 검증**: `auto_test_runner('CaseList',[115 116 118 149:158])`
- **AVI 미로드 전체**: `auto_test_runner('LoadAvi','never')`
- **로컬 전체 회귀**: `auto_test_runner('LoadAvi','lazy','CaptureMode','fail')`
- **Online 안전**: `auto_test_runner('OnlineSafeMode',true,'CaptureMode','fail','LoadAvi','never')`

## 산출물 (OutputDir 하위)

- `index_NNN-NNN.md` — chunk(10건)별 결과 인덱스(상태/스텝/case 링크)
- `caseNN.md` — 케이스별 단언·액션 시퀀스·캡처·Failure Detail
- `caseNN_stepMM.png` — main figure 캡처 / `caseNN_stepMM_TAG.png` — 외부 dialog 캡처
- `progress_NNN-NNN.md` — 실시간 진행 로그(START/ACTION/CAPTURE/VALIDATION/FAIL 등; crash 대비 즉시 flush)
- `duplicates.log` — dedup 으로 저장 skip 된 PNG 경로(run 시작 시 timestamp 헤더로 truncate)
- `project_fixtures/` — I-PROJECT-RESTORE 가 생성하는 임시 `.fdproj`

## 출력 디렉터리 자동 탐지 순서
1. `<pwd>/cowork auto test`  2. `<pwd>/cowork_auto_test`  3. `<userpath>/cowork_auto_test`  4. `<pwd>/cowork_auto_test`(폴백)

## 모달 입력 케이스
`editDialogSaveProjectAs`/`OpenProject`/`AutoLoad` 등 파일 dialog 대기 액션은
`auto_test_runner` 가 차단(`AutoTest:UserInputActionBlocked`). 대화형은
`auto_test_runner_under_user` 사용.
