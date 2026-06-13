# 2026-06-14 회귀 실패 진단 보고서

대상: `auto_code_runner_260614_0222.zip` 결과. 사용 코드 = repo HEAD `9d03f94`
(업로드된 `auto_test_runner.m`/`FlightDataDashboard.m` 와 byte-identical 확인).
결과: **174건 중 PASS 138 / FAIL 36.**

## 카테고리별 원인 · 해결 상태

### ① 패치 적용 (16건)

| 클러스터 | 건수 | 원인 | 커밋 |
|---|---|---|---|
| J-PANEL-SYNC video control sync (149–158) | 10 | video sync 활성 상태 `goToFrame` 이 frame→time→index 로 데이터 currentIndex 동기 이동(앱 의도, `627d519`). expected 가 currentIndex 를 baseline(1)로 방치 → 오탐 | `3d2a083` (videoSynced 시 `exp.currentIndex=NaN`) |
| B/D video handle (19/42/44) | 3 | board-off 중 v5-A 가 video viewer 강제 숨김 → source 보드 video handle≠PanelVisible 오탐 | `f272038` (board-off 중 video handle 검사 skip) |
| I-PROJECT-RESTORE 115/116 | 2 | 복원이 저장된 UiState(preset=layout-hsplit / hidden info·dataView) 그대로 적용하나 expected 미반영 | `000b19a` → `c109d67`(헬퍼 통합) |
| I-PROJECT-RESTORE 118 | 1 | project 복원 후 altitude marker/xline `ButtonDownFcn`/`HitTest` 유실 — **실제 GUI 회귀** | `8360625` (FDD `ensureAltitudeMarkerCallbacks`) |

### ② stale 판정 · 패치 철회 (20건)

| 클러스터 | 건수 | 판정 근거 |
|---|---|---|
| B/C/D mid-off 영속 (panel-restore) | 15 | 최신 코드 board-on 복원은 `restoreBoardPanelState(fIdx/sourceIdx)` 로 **진입 시점 스냅샷 복원**(토글 유지 안 함) → 복원 후 attitude=ON 이어야 함. 그러나 ZIP 은 actual=0(토글 유지) → **ZIP 실패가 최신 복원 경로로 재현 불가 = stale**. 가설 패치(추적 토글 OFF 강제)는 오히려 최신 코드에서 깨뜨리는 over-patch |
| G-LAYOUT (20/21 off-branch + 26/27/28 restore) | 5 | 동일 board-off 패널 모델 영역. 가설 패치 번들에 포함 |

→ 가설 패치 `c2bafb8`(B1+B3) 전체 **revert** `7fd9e22`. v5-B 베이스라인 복원.
   외부 리뷰(R1-a)와 정적 분석이 일치: 해당 실패는 최신 코드에서 이미 통과하거나
   다른 양상일 것으로 추정. **런타임 재확인 필요.**

## 검증 권고 시나리오
`doc/regression-checklist.md` 참조. 요약:
1. `CaseList=[115 116 118 149:158]` — ①번 패치(goToFrame/video handle/project/marker) PASS 전환 확인.
2. board-off 클러스터(B/C/D + G-LAYOUT 20/21/26/27/28) — ②번 stale 판정 검증(이미 통과 예상).
3. 전체 회귀(`LoadAvi='lazy'`,`CaptureMode='fail'`).

## 적용 커밋 (main `8360625` 에 포함)
- `3d2a083` goToFrame currentIndex don't-care
- `f272038` board-off 중 video handle skip
- `c109d67` project fixture expected 헬퍼(115/116; `000b19a` 리팩터)
- `8360625` FDD altitude marker/xline 콜백 재부착(118)
- `7fd9e22` Revert board-off 패널 가설 패치(B1+B3, stale)
