# 테스트 케이스 카탈로그 — `auto_test_runner`

카테고리별 케이스 그룹과 단언 내용. 총 케이스 수는 `i_buildCaseMatrix()` 기준
(2026-06-14: 174건). 상태 표기는 2026-06-14 ZIP 회귀(PASS 138 / FAIL 36) 기준.

## 카테고리 요약

| 그룹 | 대략 수 | 단언 내용 | 2026-06-14 상태 |
|---|---|---|---|
| **A** | 5 | 기본 로드·패널 토글 (board-off 없음). baseline 캡처, 패널 가시성 토글 정합 | 전부 PASS |
| **B** | 15 | 보드1 off + 보드2(source) 조작. mid-off 영속/복원, source hsplit | 일부 FAIL(stale 판정, 후술) |
| **C** | 15 | 보드2 off + 보드1(source) 조작. B 의 대칭 | 일부 FAIL(stale 판정) |
| **D** | 10 | 복합 전이(off→toggle→on 연쇄), 반대 보드 회귀 | 일부 FAIL(stale 판정) |
| **E** | 5 | video sync 관련(AVI 로드 필요 케이스 포함) | PASS |
| **G-EDIT** | 10 | EditDialog 탭 전환·apply·project save(비모달). G-EDIT-09 는 setProjectFilePath 선행 | PASS |
| **G-LAYOUT** | 28 | 레이아웃 프리셋(grid/vsplit/hsplit/compact/reset), board-off 행/열, source 패널 forced-visible | 5 FAIL(stale 판정) |
| **H-FLIGHT-PLAY** | ~19 | flight play 패널 토글, slider/frame/time 입력, start/stop 원자 사이클(타이머 검증) | PASS |
| **H-SYNC-SEARCH** | 9 | 동기시간 찾기(anchor→setFlightDataSync), context menu, edge-safety | PASS |
| **I-PROJECT-RESTORE** | ~21 | fixture 복원(21종): preset/panel/board-off/sync/safe-failure | 3 FAIL → 2 패치, 1 FDD 패치 |
| **J-PANEL-SYNC** | ~30 | EditDialog/video control 동기 — dialog 조작이 dashboard 상태 보존 | 10 FAIL(video sync) → 패치 |
| **K-PANEL-CAPTURE** | ~17 | 외부/control 패널 캡처 파일 존재·비어있지 않음 단언 | PASS |

## 2026-06-14 FAIL 36건 상태 (요약)

| 클러스터 | 건수 | 단언 | 상태 |
|---|---|---|---|
| J-PANEL-SYNC video control sync (149–158) | 10 | sync 상태 goToFrame 후 frame/data 정합 | **패치** `3d2a083` (currentIndex don't-care) |
| B/D video handle (19/42/44) | 3 | board-off 중 video handle 가시성 | **패치** `f272038` (board-off 중 video handle skip) |
| I-PROJECT-RESTORE 115/116 | 2 | hsplit preset / hidden panel 복원 | **패치** `c109d67` (fixture expected) |
| I-PROJECT-RESTORE 118 | 1 | altitude marker/xline 콜백 존재 | **패치(FDD)** `8360625` (콜백 재부착) |
| B/C/D mid-off 영속 (15) + G-LAYOUT (5) | 20 | 복원 후 패널 영속 / source forced-visible | **stale 판정·패치 철회** `7fd9e22` (revert) |

자세한 진단은 `doc/2026-06-14-failure-report.md` 참조.

## 케이스 ID ↔ 출력 번호
ZIP 결과의 `caseNN`(실행 순번)과 `i_buildCaseMatrix` 정의 순서가 1:1 대응.
`index_*.md`(chunk별)에서 `caseNN.md` 링크로 단언/캡처/실패 상세 확인.
