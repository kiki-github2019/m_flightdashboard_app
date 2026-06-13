# `tools/lint_matlab.py` 사용법

MATLAB `.m` 소스용 **휴리스틱** 정적 린터. Python 3 표준 라이브러리만 사용
(외부 의존 없음). 정확한 파서가 아니라 프로젝트 컨벤션 점검용 — 오탐 가능.

## 실행
```sh
python tools/lint_matlab.py FlightDataDashboard.m auto_test_runner.m
```
출력 형식(찾은 항목당 한 줄):
```
path:line: severity: message
```
종료 코드 = HIGH/MEDIUM finding 수(최대 250). 0 이면 심각 항목 없음.

## 검출 규칙

| severity | 규칙 | 비고 |
|---|---|---|
| LOW | `for i =` (imaginary unit shadow) | `for k` 등으로 |
| LOW | 단일 라인 try-comma (`try ... catch ... end`) | 다중 라인 권장 |
| LOW | bare `catch` (예외 변수 없음) | 의도된 cleanup 일 수 있음 |
| MEDIUM | catch 블록에 로깅 없음 (logCaught/warning/error/rethrow/fprintf 부재) | **휴리스틱** — 들여쓰기 기반 블록 추정이라 오탐 존재 |
| LOW | 함수당 magic-number 밀도 임계 초과(>30, 0/1/2/3/100 제외) | 상수화 검토 |

## 한계 (휴리스틱)
- 주석 제거는 `%` 단순 처리(문자열 내 `%` 일부만 보정) — 드물게 오탐.
- catch-블록 경계는 들여쓰기 기반 추정 — 중첩 try/switch 에서 부정확할 수 있음.
- bare catch + 빈 본문(`catch / end`)도 "no logging"으로 잡힐 수 있음(의도된 패턴이면 무시).

## pre-commit hook (opt-in)
`tools/git-hooks/pre-commit` 는 staged `.m` 파일에 린터를 돌리는 **자문용**(commit
차단 안 함) 예제. 설치는 사용자 결정:
```sh
cp tools/git-hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```
차단형으로 바꾸려면 hook 끝의 `exit 0` 을 `exit "$rc"` 로 변경.

## MATLAB `run_static_checks.m` 와의 관계
`run_static_checks.m` 는 MATLAB 환경 전용(checkcode 등 활용). 본 Python 린터는
MATLAB 없이 CI/로컬에서 컨벤션을 빠르게 점검하는 보완재. 역할이 겹치므로 통합/정리는
추후 결정.
