# Layout 개선 진행 검토 (260606)

대상 HEAD: `07a44e7`
기준 제안서: `doc/layout_improvement_proposal_260605.md`
이전 baseline: `f43c5b1` (Claude Cowork L1 완료 시점)

---

## 1. 제안서 vs 구현 현황

### 1.1 제안 항목 8건 모두 구현 완료 (100%)

| 제안 ID | 항목 | 구현 commit | 상태 |
|---|---|---|---|
| **L1 C-1** | bodyGrid RowHeight 동적 변경 | 3e1afa9 (Claude) | ✅ |
| **L1 B-1** | 지도/고도 분리 | f43c5b1 (Claude) | ✅ |
| **L2 A-1** | 자세 폭 기반 reflow [3 1]/[2 2]/[1 3] | b3c43f2 (Chatgpt) | ✅ |
| **L2 A-3** | 자세 단독 모드 1×3 | b3c43f2 (Chatgpt) | ✅ |
| **L3 D**   | 레이아웃 picker 8 프리셋 | 18e2d39 (Chatgpt) | ✅ |
| **L3 B-2** | column splitter 드래그 | 180b0f2 (Chatgpt) | ✅ |
| **L3 B-3** | row splitter 드래그 | 180b0f2 (Chatgpt) | ✅ |
| **L4 A-2** | 게이지 라벨 강조/오버레이 | 8229b98 (Chatgpt) | ✅ |
| **L4 D-3** | 프리셋 저장/사용자 정의 | 4e05802 + 18e2d39 | ✅ |
| **E**      | PanelVisible 6키 확장 | 18e2d39 (Chatgpt) | ✅ |

### 1.2 제안 외 추가 구현

| 항목 | 위치 | 평가 |
|---|---|---|
| `setBoardOffDirect` / `setBodyRowSplitRatio` 헬퍼 | 9135~ | 프리셋 적용 시 토글 우회 직접 setter — 좋은 분리 |
| `saveCurrentLayoutPresetForTest` / `applySavedLayoutPresetForTest` testHook 라우팅 | 6353~ | 회귀 자동화 친화적 |
| `EDProjectLayoutPresetDD` Edit Dialog dropdown | 5730~ | Project 탭에 사용자 프리셋 노출 |
| `G-LAYOUT-01~10` 10 케이스 신규 | auto_test_runner.m 1597~ | 회귀 매트릭스 50→60 케이스 |
| `BodyRowSplitterVisible` state dump | 538~ | testState 에 splitter 상태 포함 |

### 1.3 파일 크기 변화

| 파일 | f43c5b1 직후 | 현재 (07a44e7) | 증가 |
|---|---|---|---|
| FlightDataDashboard.m | 9,691 | 11,422 | +1,731 (+18%) |
| auto_test_runner.m | 1,290 | 1,639 | +349 (+27%) |
| **합계** | 10,981 | 13,061 | +2,080 |

---

## 2. 제안 대비 미흡/개선 필요 사항

### 2.1 정책 불일치

| ID | 제안값 | 현재값 | 의견 |
|---|---|---|---|
| **N1** | `BoardOffSourceRatio = 0.7` | `0.9` | 0.9 는 source 90%/summary 10% — summary 표/plot 가독성 떨어짐. 사용자 캡처 확인 후 0.7~0.8 권장 |
| **N2** | preset `dual-3:1-top` 만 정의 | `top` 만 있음 | `dual-3:1-bot` 대칭 누락. 하단 보드를 크게 보고 싶은 사용자 case 미커버 |
| **N3** | preset `gauges-only` = 자세 1×3 가로 펼침 | 구현됨 | A-3 와 일관 — OK |
| **N4** | preset `data-focus` = info+dataView 만 | `(false, false, false, false, true, true)` | OK |

### 2.2 누락된 정책/UX

| ID | 항목 | 위험도 |
|---|---|---|
| **M1** | preset picker 가 헤더에 있는지? `LayoutPresetButtons` 속성은 보이나 헤더 build 시 8 아이콘 추가 코드 위치 확인 필요 | 중간 |
| **M2** | 사용자 프리셋 UI (Edit Dialog dropdown) 만으로 충분한가 — 헤더에서 1-click 적용/저장 quick-action 부재 | 낮음 |
| **M3** | `BoardOffSourceRatio` 사용자 노출 안 됨 (0.9 hardcoded). slider/spinner 로 노출 권장 | 낮음 |
| **M4** | splitter 드래그 중 marker 드래그 충돌 — G-LAYOUT-09 케이스로 회귀 검증은 하지만 실제 손상 시나리오 검증 미문서화 | **중간** |
| **M5** | `dual-3:1-bot`, `triple-row`, `quad` 등 추가 프리셋 — 제안서의 5×5 picker 아이콘 vs 실제 8 preset 매핑 불완전 | 낮음 |

### 2.3 회귀 검증 필요

| ID | 항목 |
|---|---|
| **V1** | G-LAYOUT-01~10 실제 통과 여부 확인 (auto_test_runner 실행 결과) |
| **V2** | preset 적용 → 수동 토글 → preset 재적용 시 일관성 |
| **V3** | row+column splitter 동시 드래그 시 race |
| **V4** | UserLayoutPresets 저장 후 project reload 시 dropdown 복원 |
| **V5** | 백워드 compat — 옛 .fdproj (mapOnly/altOnly 키 없음) 로드 시 legacy 'map' → 양쪽 켜기 마이그레이션 동작 |

### 2.4 잠재 회귀 위험

| ID | 항목 | 근거 |
|---|---|---|
| **R1** | 9,691 → 11,422 라인 (+18%). Q-01 (파일 분할) 우선순위 더 높아짐 | 단일 파일 한계 |
| **R2** | dataGrid 가 [1 6] → [1 8] 로 확장 (splitter 컬럼 추가). reflowBoardColumns 의 widths{N} 인덱스 변경 영향 추적 필요 | line 9835 |
| **R3** | `BoardOffSourceRatio = 0.9` 가 의도된 상향인지, 실수인지 확인 — 제안서는 0.7 명시 | 0.5~0.9 clamp 는 유지 |
| **R4** | preset 적용이 `markProjectDirtyAndScheduleRefresh` 를 호출하는지? dirty 처리 일관성 검증 | applyLayoutPreset 본문 확인 필요 |
| **R5** | `CurrentLayoutPreset = 'custom'` 으로 fallback 되는 조건이 합리적인지 (수동 토글 후 자동 'custom' 전환?) | 18e2d39 |

### 2.5 코드 품질

| ID | 항목 |
|---|---|
| **Q1** | 정적 분석 재실행 필요 — 새 코드 1,731 라인에 lint warning 신규 추가 가능성 |
| **Q2** | `splitter`, `preset`, `boardOff`, `layout` 관련 함수 30+ 개 추가 — 네이밍/책임 일관성 검토 |
| **Q3** | EditDialog 의 Layout 탭 신설 검토 (Project 탭 dropdown 만으로 부족 가능) |

---

## 3. 즉시 권장 후속 작업

### 3.1 즉시 (Cowork 측 코드 작업)

1. **N1**: `BoardOffSourceRatio` 0.9 → 0.7 조정 (사용자 캡처 검증 후 결정)
2. **N2**: `dual-3:1-bot` 프리셋 대칭 추가
3. **R2**: `dataGrid` ColumnWidth 인덱스 매핑표를 클래스 상단 주석에 명시
4. **Q1**: `checkcode FlightDataDashboard.m -id` 재실행 후 신규 warning 정리

### 3.2 사용자 측 검증 필요

1. **V1**: `auto_test_runner('Start',1,'End',60,'LoadAvi','lazy')` 1회 통과 확인
2. **V2~V5**: 수동 회귀 시나리오 5건
3. 124/125/126.png 재캡처 → preset 효과 정성 확인

### 3.3 중기 (별도 sprint)

1. **Q-01** 파일 분할 (`+flightdash` 패키지화) — 라인 11,422 부담 한계
2. **M2~M5** UX 추가 (사용자 프리셋 헤더 1-click, slider 노출, 추가 프리셋)
3. testHook 프로덕션 제거 (R-06) — T-01~T-15 통과 후

---

## 4. 결론

**제안서 100% 구현** 됨. Claude Cowork 가 L1 (C-1, B-1) 만 처리한 동안 Chatgpt Cowork 가 L2/L3/L4 전부 자동 추진하여 8 가지 핵심 개선 항목 완료.

**주요 차이/개선 필요점 5건** (N1, N2, R2, Q1, M4) 만 추가 처리하면 제안서 완료 처리 가능.

**다음 sprint 권장 순서**:
1. (즉시) N1 + N2 + Q1 — 작은 후속 fix
2. (검증) V1 — auto_test_runner 60 케이스 통과 확인
3. (중기) Q-01 파일 분할 — 11,422 라인 임계점 도달
