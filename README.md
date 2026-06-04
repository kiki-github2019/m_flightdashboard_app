# FlightDataDashboard

비행 데이터(.dat/.csv) 와 영상(.avi/.mp4) 을 시간축으로 동기 비교/분석하는 MATLAB uifigure 앱입니다.
두 개의 비행경로(Flight 1, Flight 2) 를 나란히 비교할 수 있고, 패널/플롯/탭/AVI 설정을 한 곳에서 편집하고
프로젝트 단위(`.fdproj`) 로 저장/불러오기/내보내기(export) 합니다.

## 요구사항

- **MATLAB R2020b 이상** (uifigure / uigridlayout / exportapp 사용)
- 선택: Parallel Computing Toolbox (비동기 영상 디코딩 시. 없어도 동기 디코드로 동작)
- 영상 파일은 MATLAB `VideoReader` 가 지원하는 코덱이어야 함

## 빠른 시작

```matlab
>> FlightDataDashboard
```

생성 후:

1. `비행경로 1 선택` 버튼 → `.dat`/`.csv` 데이터 파일 선택
2. `비디오 ▾` 패널 → `AVI 파일 열기` 로 영상 로드
3. `⚙ 설정/편집` 버튼 → Edit Dialog 에서 Sync/Plot/Options/Export 편집
4. Edit Dialog 의 Project 탭에서 `다른 이름으로...` → `.fdproj` 저장

## 주요 화면 구성

### 메인 대시보드 (상/하 보드)

| 영역 | 역할 |
|---|---|
| 상단 헤더 | 비행경로 선택, 해안선 정보, 보드 off/on, Debug, Sync, 최소/최대화, **⚙ 설정/편집** |
| 비행 자세 패널 | Pitch/Roll/Heading 시각화 |
| 지도/고도 패널 | 경로 + 빨간 삼각형(현재 위치), 고도 시계열 |
| 현재 비행 정보 | 컬럼별 현재 값 (`option*.dat` 의 `DisplayColumns` 기반) |
| H: 데이터 뷰 패널 | Tab 단위 plot. 별표(★) 드래그로 시간 이동 |
| I: AVI Video Player | 현재 frame 표시, 제어창에서 슬라이더/탐색 |

### 보드 off/on (디자인 §1.1)

- `상단 보드 off` / `하단 보드 off` 버튼으로 한쪽 보드를 숨기고 그 영역에 off-mode summary 표시
- summary 는 source 보드의 `현재 비행 정보` + `H: 데이터 뷰 패널` 을 복제 표시
- 두 보드를 동시에 off 할 수 없음 (mutual exclusion)
- off 중 source 보드의 자세/지도/비디오 토글은 보드 on 후에도 유지됨

### Edit Dialog (`⚙ 설정/편집`)

modeless uifigure 로 띄워지며 6개 탭으로 구성:

| 탭 | 기능 |
|---|---|
| **Project** | 현재 project 경로, 열기/저장/다른이름저장, 자동 저장 토글, 종료 전 저장 확인, 마지막 저장 시간 |
| **Files** | Flight 1/2 의 data/AVI/option 경로 확인 + 변경/다시 로드, Export everything 단축 버튼 |
| **Sync** | Flight↔Flight 비행시간 sync (offset preview 실시간), Flight 별 AVI sync (frame/time/Hz), 현재 화면값 가져오기 |
| **Options** | Flight 별 `option*.dat` 의 RequiredColumns(매핑) / DisplayColumns(표시 형식) 편집, 검증, 적용, 파일 저장, **Reset to default mapping** |
| **Plot Manager** | Tree (Flight > Tab > Plot) + 속성 패널 (이름/YColumn/X auto/X min/max/Y auto/Y min/max/높이/적용/복제/삭제), LinkXWithinTab 토글, Sync X→All Tabs, 캡처/재구성 |
| **Export** | parent 폴더 선택, 복사 대상 파일 목록 미리보기, 누락 파일 라벨, SHA256 검증 토글, Export 버튼, progress log |

## Project 파일 (`.fdproj`)

JSON 단일 파일. 저장 내용:

- Flight 1/2 의 `DataFile`, `AviFile`, `OptionFile` 경로 (export 시 자동 절대경로 변환)
- AVI sync 상태 (IsSynced, AnchorFrame, AnchorTime, VideoFps, DataFps, TotalFrames)
- Flight↔Flight sync 상태 (IsSynced, SyncT1, SyncT2)
- PlotConfig (Tab 별 Title/LinkXWithinTab, Plot 별 YColumn/XLim/YLim/Height/Order)
- UiState (WindowPosition, EditDialogPosition, ActiveTab)
- AuxFiles
- Version (현재 1)

### 자동 백업 / 복구

- ProjectDirty 상태에서 30초 간격으로 `<project>.fdproj.autosave.json` 스냅샷 자동 저장
- project 를 다시 열 때 autosave 가 원본보다 새로우면 복구 dialog 표시
- 정상 저장 시 autosave 파일 즉시 삭제

## Export (`Export everything to folder`)

`FlightDashboard_yyyy-MM-dd_HH-mm-ss` 폴더에 project 가 참조하는 모든 파일 복사 + project 경로 재작성.

- 동일 폴더 내 절대경로로 재작성 (다른 PC 에서도 그대로 사용)
- 누락 파일: `누락 제외 / 파일 다시 선택 / 중단` 선택
- 검증: 존재 여부 + 파일 크기 일치 + 옵션으로 SHA256
- 결과: `export_verification_report.md` 자동 생성
- 실패 시: `폴더 유지 / 폴더 삭제 / 재시도` 선택
- AVI 가 현재 앱에 열려 있으면 자동으로 release 후 복사 → 재오픈

## 영상 동기화 (AVI sync)

기준 frame + 기준 비행시간 + 영상 Hz + 데이터 Hz 로 매핑. 사용 예:

1. 영상에서 인식 가능한 시점의 frame 번호 확인
2. 그 frame 이 대응하는 비행데이터 time 입력
3. `동기 적용` → 마커/스피너/슬라이더/AVI 가 같은 기준으로 움직임
4. 메인 마커 드래그 시 cache 가 다음 인접 frame 을 prefetch (cache-only, 표시에 영향 없음)

`현재 화면값 가져오기` 버튼은 메인 UI 의 spinner/CurrentFrame/Hz 를 Sync 탭 입력으로 자동 복사.

## Options 파일 (`option1.dat`, `option2.dat`)

텍스트 형식. 두 영역:

```text
# RequiredColumns
Time: time
Roll: roll_deg
Pitch: pitch_deg
Heading: heading_deg
Alt: alt_m
Lat: lat_deg
Lon: lon_deg

# DisplayColumns
roll_deg, degree, %.6f, 1, 1.0
pitch_deg, degree, %.6f, 2, 1.0
...
```

- `RequiredColumns`: 7개 키(Time/Roll/Pitch/Heading/Alt/Lat/Lon) 의 데이터 컬럼 매핑
- `DisplayColumns`: header, unit, sprintf format, order, scale
- 편집기에서 `Reset to default mapping` 으로 첫 N개 데이터 컬럼 자동 매핑
- 저장 시 atomic write (`.bak` 백업 후 temp → movefile)
- scale 누적 곱셈 방지를 위해 `rawDataUnscaled` 를 단일 진실원으로 보관

## 자주 묻는 질문

**Q. 비디오를 열었는데 영상이 검정색입니다.**
A. AVI 코덱이 MATLAB `VideoReader` 미지원일 수 있습니다. `which VideoReader -all` 후 코덱 설치 또는 변환을 시도하세요.

**Q. project 를 다른 PC 로 옮기고 싶습니다.**
A. `Export everything to folder` → 생성된 폴더 전체를 복사. 폴더 내 `.fdproj` 가 모든 경로를 폴더 내부로 참조합니다.

**Q. 보드 off 상태에서 plot 을 추가했더니 X 축이 0~1초로 나옵니다.**
A. 해당 회귀는 v45d2d6f / c7e41a5 / 45d2d6f 에서 수정됨. 최신 commit (HEAD) 으로 업데이트 후 재시도하세요.

**Q. 빠른 슬라이더 드래그 시 마지막 frame 이 표시되지 않습니다.**
A. v266018b 의 pending video request drain 으로 수정됨. UseAsyncDecode=true 사용 시도 가능.

**Q. MATLAB Online 에서 50개 회귀 테스트를 돌릴 수 있나요?**
A. `auto_test_runner('Start',1,'End',5,'LoadAvi','lazy')` 처럼 배치를 작게 나누고 LoadAvi=lazy 권장. OOM 회피용 `LoadAvi='never'` 옵션도 있음.

## 디렉토리 구조 (대형 클래스 단일 파일)

```
FlightDataDashboard.m       메인 클래스 (~9,500 라인)
auto_test_runner.m          회귀 자동화 스크립트 (50 cases)
doc/
  merged_viewer_dialog_design.md  설계 문서 (디자인 §1~§10 + Decision Items)
  향후 작업 시트_*.md              향후 작업 우선순위 시트
.claude/settings.json       (개발자용 권한 allowlist)
```

향후 `+flightdash` 패키지 분할 예정 (디자인 §Q-01).

## 라이선스 / 기여

내부 R&D 코드. 외부 배포 전 검토 필요.

## 변경 이력

주요 마일스톤:
- Phase 1-6 (Project state, Options 리팩토링, Sync helpers, PlotConfig, Auto-load, Export)
- 안정화 P0/P1/P2 (prefetch cache-only, async stale guard, multi-instance, decode pending)
- 보드 off/on 기능 (디자인 §1.1)
- F-01~F-07 디자인 누락 항목 모두 구현
- Critical 1~3 / Major 1~6 안정화 패치

자세한 내역은 `git log --oneline` 참조.
