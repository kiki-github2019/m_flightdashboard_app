# FlightDataDashboard.m 리팩터 후보 (2026-06-14)

함수별 라인 수 상위 식별 + 책임 분리 제안. **코드 변경 없음, 정적 제안만.**
라인 수는 `function` 경계 기반 추정치(±). FDD 전체 14,212줄.

## 상위 후보 (길이 추정)

| # | 함수 | ~라인 | 시작 | 위험도 | 분할 제안 |
|---|---|---|---|---|---|
| 1 | `createLayout` | 380 | 12045 | **High** | UI 트리 구축이 한 함수에 집중. 보드별/패널별 빌더로 추출: `buildBoardPanel(fIdx)`, `buildSidePanels(fIdx)`, `buildDataGrid(fIdx)`, `buildBodyGrid()`. 핸들 저장 구조(UI struct) 유지가 관건 |
| 2 | `testHook` | 225 | 483 | Medium | 거대 dispatch `switch`. 카테고리별 라우터로 분리: `i_hookPanel`, `i_hookProject`, `i_hookVideo`, `i_hookSync`, `i_hookCapture`. 단 테스트 전용이라 변경 시 runner 와 동기 필요 |
| 3 | `applyBoardHsplit` | 218 | 10685 | **High** | board-off hsplit 배치 핵심. column 매핑/reparent/splitter 가시성을 `computeHsplitColumns`, `reparentToHsplit`, `applyHsplitSplitters` 로 분리. **회귀 민감**(오늘 board-off 이슈 영역) |
| 4 | `collectTestBoardState` | 200 | 832 | Low | 테스트 스냅샷 수집. panel/plot/video/flightPlay 섹션별 `collect*` 헬퍼로 분리. 순수 read-only라 안전 |
| 5 | `exportEverythingToFolder` | 199 | 5197 | Medium | export 파이프라인. 파일종류별(`exportData`, `exportPlots`, `exportVideoFrames`, `exportProject`) 추출 + 진행률 콜백 분리 |
| 6 | `plotSelectedVariable` | 182 | 4373 | Medium | 변수 선택→플롯 추가 로직. validation/axis-setup/line-create/marker-attach 단계 분리 |
| 7 | `rebuildBoardOffPlots` | 165 | 11117 | **High** | board-off summary 플롯 재구성. signature 비교/clear/rebuild/marker-sync 분리. **회귀 민감** |
| 8 | `autoLoadProjectFromFile` | 146 | 5825 | Medium | project 복원. decode/migrate/applyState/refresh 단계 분리. 오늘 R2/R3 와 인접 — marker 콜백 재부착도 이 경로 후 호출됨 |
| 9 | `UIFigureCloseRequest` | 145 | 1393 | Low | 종료 cleanup. timer/dialog/figure/cache 정리를 `cleanup*` 헬퍼로 (이미 IsDeleting 가드 있음) |
| 10 | `createVideoControlDialog` | 130 | 9513 | Low | dialog 빌더. control row/nav button/frame axes 빌더로 분리 |

## 권고 우선순위

**먼저 손대면 안 되는(회귀 민감, High 위험) 영역**: `applyBoardHsplit`, `rebuildBoardOffPlots` — board-off 동작은 오늘 36 FAIL 중 다수가 걸린 곳이고 런타임 검증 없이 분할 시 회귀 위험 큼. **리팩터 전 회귀 스위트 통과 확인 필수.**

**안전하게 먼저 가능한 것(Low 위험, read-only/cleanup)**: `collectTestBoardState`, `UIFigureCloseRequest`, `createVideoControlDialog` — 순수 수집/정리/빌더라 동작 보존이 쉬움.

**중간(Medium)**: `testHook`(테스트 동기 필요), `exportEverythingToFolder`, `plotSelectedVariable`, `autoLoadProjectFromFile`.

## 공통 가이드
- 추출 메서드는 `methods (Access = private)` 블록 내 배치, `app.` 디스패치 유지(오늘 onCleanup helper 이동 사례 참조).
- 각 분할은 **단독 커밋 + 회귀 1회 실행**으로 검증. 한 번에 여러 함수 분할 금지.
- UI 핸들 struct(`app.UI(fIdx).*`) 의 필드 계약을 깨지 않도록 추출 함수가 동일 핸들에 기록.
