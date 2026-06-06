# Dashboard 레이아웃/가독성 개선 제안서

작성일: 2026-06-05
대상 파일: `FlightDataDashboard.m`
배경 캡처: 123/124/125/126.png (사용자 보고), 127.png (MATLAB 레이아웃 picker 예시)

---

## 1. 현재 문제 진단

| ID | 캡처 | 증상 | 근본 원인 |
|---|---|---|---|
| P1 | 124.png 전체 | 모든 패널 동시 표시 시 게이지 원형의 라벨/숫자가 픽셀 부족으로 식별 불가 | 자세 패널 width 가 고정 비율, 게이지 axes 가 좁아져 폰트 자동 축소 |
| P2 | 123/126.png | 하단보드 off 인데 상단보드의 가로 공간이 노는 영역 다수. 지도가 정사각 → 시인성 낮음 | `reflowBoardColumns` 가 source 보드의 widths{4}='1x' 만 flex, 나머지는 고정 → 단일 패널만 표시되어도 다른 패널은 축소 안 됨 |
| P3 | 125.png | 자세만 켜져 있어도 게이지 3개가 세로 stack 그대로 → 가로 공간 낭비 | 자세 패널 내부가 [3 1] vertical 격자 고정. 컨테이너 폭에 따라 [1 3] horizontal 로 reflow 안 함 |
| P4 | 124.png 하단 | 하단보드 off 인데 상단보드의 데이터 뷰/현재 비행 정보가 세로로 너무 짧음 | board 의 row height 가 전체 figure 의 50% 고정. 보드 off 시 살아남은 보드가 100% 차지하도록 변경 안 됨 |
| P5 | 124.png | 지도 + 고도가 같은 패널에 묶여 있어 독립 토글 불가 | `togglePanel('map')` 이 둘을 한꺼번에 끔/켬. 분리 토글 필요 |
| P6 | 전반 | 사용자가 분할 비율을 마우스 드래그로 못 바꿈. 모든 비율은 코드 하드코딩 | uigridlayout 의 splitter 미사용. `RowHeight`/`ColumnWidth` 가 정적 |
| P7 | 전반 | 하단보드 off + 지도만 켜기 / 자세+비디오만 켜기 등 자주 쓰는 조합을 매번 토글로 만들어야 함 | 프리셋 레이아웃 picker 부재 |

---

## 2. 개선 제안

### A. 게이지 가독성 (P1, P3)

**A-1. 자세 패널 자동 reflow**
- `panelAttitude` 내부 격자를 컨테이너 폭에 따라 동적 전환:
  - 폭 < 220px: `[3 1]` (세로 3 게이지)
  - 폭 220~440px: `[2 2]` (Pitch+Roll 위, Heading 아래)
  - 폭 ≥ 440px: `[1 3]` (가로 3 게이지)
- 게이지 axes 의 `DataAspectRatio = [1 1 1]` 유지하되 폰트 사이즈를 셀 width 의 일정 비율로 자동 계산

**A-2. 게이지 라벨 강조**
- 현재: `'Pitch +0.928°'` 한 줄 라벨
- 개선: 라벨을 게이지 위쪽에 큰 폰트(`FontSize >= 16, Bold`), 값은 게이지 중앙에 오버레이 (uilabel + Color = white + BackgroundColor with alpha)
- 폭이 좁으면 게이지 outline 제거 → 단순 큰 숫자 표시 fallback

**A-3. 자세 단독 모드 (P3 직접 해결)**
- 다른 패널이 모두 꺼지고 자세만 남으면 게이지 3개를 가로 1×3 으로 펼치고 각 게이지가 셀 가득 채움 → 라벨 자동 확대

---

### B. 패널 toggle 확장 (P5, P6)

**B-1. 지도/고도 분리** (사용자 요청 #1)
- `togglePanel(fIdx, 'map')` → `togglePanel(fIdx, 'mapOnly')` + `togglePanel(fIdx, 'altOnly')` 2개로 분리
- 현재 합쳐진 panel `panelMapAlt` 내부는 이미 [2 1] 세로 격자. 각 sub-panel 의 `Visible` 토글로 처리
- 헤더 버튼: `[지도/고도 ▾]` → `[지도 ▾] [고도 ▾]` 2개
- 둘 다 끄면 panel 컬럼 폭 0
- 한쪽만 켜면 살아남은 sub-panel 이 full row 차지

**B-2. 컬럼 splitter (사용자 요청 #2)**
- `app.UI(fIdx).dataGrid.ColumnWidth` 사이에 4px draggable splitter 추가
- 구현: 컬럼 사이에 `width=4` uipanel + `WindowButtonMotionFcn` 으로 드래그 → 좌우 컬럼 폭 재계산
- 폭 = 0 인 (숨김) 컬럼 양쪽 splitter 는 비활성화
- 더블클릭 → 기본 비율 복귀

**B-3. 행 splitter (P4 직접 해결)**
- 상단/하단 보드 사이에 4px draggable splitter
- bodyGrid 의 `RowHeight = {h_top, 4, h_bot}` 형태로 변경
- 한쪽 보드 off 면 splitter 비활성화 + 살아남은 보드 100% 차지 (현재는 50% 고정인 듯)

---

### C. 보드 off 시 살아남은 보드 100% 활용 (P4)

**C-1. bodyGrid RowHeight 동적 갱신**
- `toggleBoardVisibility` 안에서:
  - 평상시: `bodyGrid.RowHeight = {'1x', 4, '1x'}`
  - 상단 off: `{0, 0, '1x', '1x'}` → 하단 + off-summary 가 가용 공간 분할
  - 하단 off: `{'1x', '1x', 0, 0}` → 상단 + off-summary 가 분할
- 핵심: 살아남은 보드가 실제로 figure 의 거의 전체 height 를 차지하도록

**C-2. off-summary 의 in-source 비율**
- 현재 off-summary 가 source 보드 옆에 같이 표시되어 source 보드 폭의 일부만 사용
- 변경: off-summary 를 source 보드 아래/위 row 로 배치 → 가로폭 전체 사용
- 또는 사용자 선택으로 layout 변경 가능 (D 와 연동)

---

### D. 레이아웃 프리셋 picker (사용자 요청 #3)

**D-1. 헤더에 picker 추가**

127.png 같은 5개 격자 아이콘 버튼:

```
[ □ ]  [ ▣ ]  [ ▥ ]  [ ▦ ]  [ ⊞ ]
single  half   stack  side    quad
```

각 버튼이 클릭되면 미리 정의된 `LayoutPreset` 적용. 토글 버튼 6개(자세/지도/고도/비디오 + 상단/하단) 의 조합을 일괄 변경.

**D-2. 프리셋 정의**

| 아이콘 | 이름 | 동작 |
|---|---|---|
| □ | `single-top` | 상단보드만 100%. 하단보드 off. 상단 모든 sub-panel on |
| □ | `single-bot` | 하단보드만 100%. 상단보드 off. 하단 모든 sub-panel on |
| ▣ | `dual-equal` | 상단/하단 50:50 (기본) |
| ▥ | `dual-3:1-top` | 상단 75% / 하단 25% |
| ▦ | `data-focus` | 양 보드 표시, 비디오 + 지도 off, 현재 비행 정보 + 데이터 뷰만 크게 |
| ⊞ | `gauges-only` | 자세만 on, 가로 1×3 배치 |
| ⊟ | `map-focus` | 지도만 on, 양 보드. 비행경로 비교 |
| ⊡ | `video-focus` | 비디오 + 데이터 뷰만 |

**D-3. 프리셋 저장/사용자 정의**
- `Edit Dialog` 의 Project 탭에 "현재 레이아웃을 프리셋으로 저장" 버튼
- 저장된 프리셋은 `.fdproj` 의 `UiState.LayoutPresets` 배열에 보관
- picker 에 사용자 정의 프리셋 5개 슬롯 추가 가능

---

### E. PanelVisible 모델 확장

현재 `app.UI(fIdx).PanelVisible` 구조:
```matlab
struct('attitude', true, 'map', true, 'video', true)
```

변경:
```matlab
struct('attitude', true, 'mapOnly', true, 'altOnly', true, 'video', true, ...
       'info', true, 'dataView', true)
```

- `mapOnly` + `altOnly` 분리 (B-1)
- `info`, `dataView` 도 toggle 가능하게 추가 (현재는 보드 off 모드에서만 hide 됨)
- `reflowBoardColumns` 가 이 6개 키를 모두 읽도록 확장
- `.fdproj` 의 PerFlight UiState 에 6개 키 모두 직렬화

---

## 3. 구현 우선순위

| Phase | 항목 | 효과 | 위험도 |
|---|---|---|---|
| **L1** | C-1 보드 off 시 살아남은 보드 100% 활용 | 즉각적 가독성 개선 | 낮음 (bodyGrid.RowHeight 변경만) |
| **L1** | B-1 지도/고도 분리 | 사용자 명시 요구 | 중간 (PanelVisible 키 추가 + 헤더 버튼 1개 추가) |
| **L2** | A-3 자세 단독 모드 1×3 reflow | P3 직접 해결 | 중간 (panelAttitude 내부 격자 동적 변경) |
| **L2** | A-1 자세 패널 폭 기반 reflow | 일반 가독성 | 중간 |
| **L3** | D 레이아웃 picker | UX 큰 개선 | 중간 (헤더 버튼 + 프리셋 로직) |
| **L3** | B-2/B-3 splitter 드래그 | 사용자 미세 조정 | 높음 (WindowButtonMotionFcn 충돌 위험, 마커 드래그와 race) |
| **L4** | A-2 게이지 라벨 강조 (오버레이) | 폭 좁은 케이스 시인성 | 낮음 |
| **L4** | D-3 프리셋 저장/사용자 정의 | 고급 사용자 편의 | 낮음 |

---

## 4. FlightDataDashboard.m 수정 사항 요약

| 영역 | 함수/속성 | 변경 내용 |
|---|---|---|
| properties | `PanelVisible` 초기화 | 키 6개로 확장 |
| `createLayout` | `bodyGrid.RowHeight` | `{'1x', 4, '1x'}` 로 splitter row 포함 (B-3 준비) |
| `buildHeaderBar` | 버튼 행 | `지도/고도` → `지도`, `고도` 2개로 분리 + 레이아웃 picker 8개 아이콘 추가 |
| `togglePanel` | 파라미터 | `'mapOnly'`, `'altOnly'`, `'info'`, `'dataView'` 케이스 추가 |
| `reflowBoardColumns` | widths 계산 | 6개 키 + splitter 위치 + 단독 모드 reflow |
| `toggleBoardVisibility` | bodyGrid 변경 | C-1 의 RowHeight 분기 추가 |
| 신규 | `applyLayoutPreset(name)` | 8개 프리셋 + 사용자 정의 적용 |
| 신규 | `panelAttitude` reflow | 폭 기반 [3 1]/[2 2]/[1 3] 자동 전환 (SizeChangedFcn 에서) |
| 신규 | `i_dragColumnSplitter` / `i_dragRowSplitter` | B-2/B-3 드래그 핸들러 |
| `.fdproj` | `UiState` | `PanelVisible(2)` per-flight + `LayoutPresets` 배열 + `RowHeights` |
| `collectCurrentProjectState` / `applyProjectState` | 직렬화/복원 | 확장된 UiState 처리 |

---

## 5. 예상 코드량 / 영향 범위

- 신규 코드: ~600-900 라인 (헬퍼 8개 + 프리셋 5-8개 + splitter 2종)
- 수정 코드: `reflowBoardColumns` / `togglePanel` / `createLayout` / `buildHeaderBar` 약 200 라인
- 회귀 위험: 중간 (보드 off / 패널 토글 기존 동작 모두 재검증 필요)
- 영향받는 50 회귀 케이스 (auto_test_runner): A/B/C/D/E 그룹 widths 검증 모두 갱신 필요

---

## 6. 즉시 착수 권장

1. **L1 (C-1 + B-1)** → 사용자 명시 요구 + 가장 큰 효과 / 가장 낮은 위험
2. L2 (A-3 + A-1) → P1/P3 직접 해결
3. L3 (D picker) → UX 정점, 위 둘 안정화 후

각 단계마다 `auto_test_runner.m` 의 새 케이스 (`G-LAYOUT-*`) 추가하여 회귀 방지.

---

## 7. 참고: 사용자 캡처 좌표 분석

- 123.png 하단보드 off + 모든 sub-panel on: 자세 폭 ≈ 110px, 게이지 라벨 폰트 ≈ 9pt → 가독 한계
- 124.png 양 보드 표시: 자세 폭 ≈ 100px → 가독 어려움
- 125.png 자세만 on: 자세 폭 ≈ 1400px 인데도 세로 3 stack 유지 → A-3 직접 적용 대상
- 126.png 지도+고도: 고도 폭 = 1400px, 높이 = 80px → A-1/A-3 의 가로폭 활용 방식이 지도/고도에도 필요

---

## 8. 결론

P1~P7 모두 **단일 원인** 으로 환원: **레이아웃이 정적 비율 + 셀 가려져도 내부 reflow 없음**. 해결 방향은 동적 reflow + 분리 토글 + 프리셋 picker 3축. L1 단계만 적용해도 사용자 보고 문제 60% 해결 예상.
