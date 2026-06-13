# 정적 검토 — 기타 `.m` 파일 (2026-06-14)

오늘 집중 검토한 `FlightDataDashboard.m` / `auto_test_runner.m` 외의 추적된
`.m` 파일을 grep/regex 휴리스틱으로 점검한 보고서. **수정 없음, 보고만.**

## 대상 파일 (라인 수)

| 파일 | 라인 | 비고 |
|---|---|---|
| `FlightDataDashboard.m` | 14212 | 오늘 검토/패치 (제외) |
| `cowork auto test/FlightDataDashboard.m` | 12639 | **스냅샷 복제본** (현재 FDD와 1969줄 차이) |
| `auto_test_runner.m` | 3333 | 오늘 검토/패치 (제외) |
| `run_static_checks.m` | 497 | MATLAB-side 정적 검사 헬퍼 |
| `auto_test_runner_under_user.m` | 233 | 대화형(모달) 테스트 러너 |

## 우선순위 표

| 우선 | 파일:라인 | 항목 | 한 줄 권고 |
|---|---|---|---|
| **High** | `cowork auto test/FlightDataDashboard.m` (전체) | 추적된 **스냅샷 복제본** — 현재 FDD와 1969줄 diff. 편집 대상 혼동·repo bloat·stale 위험 | `.gitignore` 처리 또는 제거 검토(별 폴더가 자동 테스트 산출물이면 코드 복제본만 제외). 유지해야 하면 README에 "참조 스냅샷, 편집 금지" 명시 |
| Medium | `auto_test_runner_under_user.m:55,87,173` | `catch ME` 가 `fprintf` 콘솔 출력만, `app.logCaught` 미경유 → ring buffer 흔적 없음 | runner 가 `app` 보유 시 `try app.logCaught(ME,'under_user:...'); catch; end` 병행 (auto_test_runner R-M6 와 동일 패턴) |
| Low | `run_static_checks.m:404,416,438,457` | `for i =` (imaginary unit shadow) | `for k`/의미 있는 이름으로 변경 (auto_test_runner L1 과 동일) |
| Low | `run_static_checks.m:369` | bare `catch` (fopen UTF-8 실패 시 fallback) | 의도된 fallback — 주석 1줄 추가 권고(무해) |
| Low | `auto_test_runner_under_user.m:205` | bare `catch` (`i_safeDeleteApp` cleanup) | 의도된 best-effort cleanup — 유지 가능, 주석만 |
| Low | `run_static_checks.m` (전체) | MATLAB 전용 정적 검사기 — 본 작업 F)`tools/lint_matlab.py`(Python) 와 기능 중복 | 역할 분담 문서화(MATLAB 환경 vs CI/로컬 Python). 통합 여부는 추후 결정 |

## 파일별 요지

### `cowork auto test/FlightDataDashboard.m` (High)
`cowork auto test/` 폴더(자동 테스트 산출물 디렉터리)에 FDD 본체의 **복제본**이 커밋되어 있음. 현재 루트 `FlightDataDashboard.m`과 1969줄 차이 → 과거 시점 스냅샷으로 추정. 위험: (1) 두 파일 중 어느 것이 진본인지 혼동, (2) 잘못된 파일 편집, (3) repo 비대. 산출물 폴더라면 `.gitignore`에 `cowork auto test/*.m` 또는 해당 복제본만 제외 권고. **삭제는 사용자 판단** (자동 러너가 해당 경로를 참조하는지 먼저 확인 필요).

### `auto_test_runner_under_user.m` (Medium/Low)
구조 양호 — `for i`/try-comma/persistent 없음. `catch ME` 3곳이 콘솔 출력만 하고 ring buffer 미기록. 대화형 러너라 치명적이진 않으나, `auto_test_runner`와 일관성 위해 `app.logCaught` 병행 권고. `i_safeDeleteApp`의 bare catch는 의도된 cleanup.

### `run_static_checks.m` (Low)
MATLAB-side 정적 검사 스크립트. `for i =` 4곳(shadow), fopen fallback bare catch 1곳. 기능적으로 본 작업 F의 Python lint와 겹침 — 역할 분담만 정리하면 됨.

## 종합
- **즉시 조치 권고**: `cowork auto test/FlightDataDashboard.m` 복제본 처리(High).
- 나머지는 Low/Medium 스타일 일관성 — 일괄 정리는 별도 라운드.
