# FlightDataDashboard Python UI Tests

Python + Playwright 기반 브라우저 UI 회귀 테스트입니다.

현재 구현은 `FlightDataDashboard.m`을 수정하지 않고, 화면에 표시되는 버튼/탭/라벨 텍스트를 기준으로 조작합니다. 향후 안정적인 selector를 위해 MATLAB UI 컴포넌트에 `Tag` 또는 test id를 추가해야 하는 경우에는 별도 확인 후 진행해야 합니다.

## 목적

- MATLAB Online에서 `auto_test_runner.m` 반복 실행 중 발생하는 메모리 부담을 줄임
- Board off/on, panel toggle, Plot Manager, AVI control dialog 같은 실제 사용자 UI 흐름을 브라우저에서 검증
- 실패 시 Playwright screenshot/trace를 남겨 화면 기준으로 원인 분석

## 설치

```powershell
cd "D:\flightdashboard\1. 최초-MVC 전\python_gui_tests"
python -m pip install -r requirements.txt
python -m playwright install chromium
```

## MATLAB Online 준비

1. MATLAB Online에서 `FlightDataDashboard` 앱을 실행합니다.
2. 브라우저 주소창의 URL을 복사합니다.
3. 같은 로그인 세션을 재사용하려면 persistent profile을 사용합니다.

```powershell
$env:FLIGHTDASH_APP_URL="https://matlab.mathworks.com/..."
$env:FLIGHTDASH_PROFILE_DIR="D:\flightdashboard\1. 최초-MVC 전\python_gui_tests\.playwright-profile"
```

처음 실행 시 MATLAB 로그인이 필요하면 열린 Chromium 창에서 수동 로그인한 뒤 테스트를 다시 실행합니다.

## 실행

전체 smoke test:

```powershell
python run_ui_tests.py
```

특정 케이스만 실행:

```powershell
python run_ui_tests.py --case B01 --case E01
```

URL을 CLI로 직접 지정:

```powershell
python run_ui_tests.py --url "https://matlab.mathworks.com/..."
```

pytest 방식:

```powershell
pytest
```

## 캡처/Trace 옵션

기본값은 MATLAB Online 부담을 낮추기 위해 baseline과 실패 화면만 저장합니다.

```powershell
python run_ui_tests.py --capture-mode baseline --capture-scale 0.70
python run_ui_tests.py --capture-mode all --capture-scale 1
python run_ui_tests.py --capture-mode fail --trace retain-on-failure
```

지원 옵션:

| 옵션 | 값 |
|---|---|
| `--capture-mode` | `all`, `baseline`, `fail`, `none` |
| `--capture-scale` | `0.10` ~ `1.0` |
| `--trace` | `on`, `off`, `retain-on-failure` |
| `--profile-dir` | Playwright persistent profile 경로 |

결과는 `results/yyyyMMdd_HHmmss/` 아래에 저장됩니다.

## 현재 케이스

| Case | 범위 |
|---|---|
| `B01` | 상단 보드 off/on summary smoke |
| `B02` | 하단 보드 off/on summary smoke |
| `P01` | 자세/지도고도/비디오 panel toggle smoke |
| `E01` | 설정/편집 dialog와 Plot Manager 표시 |
| `V01` | AVI 제어창 표시 |

## 한계와 다음 단계

- 파일 선택 dialog 자동화는 현재 제외했습니다. `.fdproj` 자동 로드 또는 MATLAB 쪽 테스트 훅과 조합하는 방식이 더 안정적입니다.
- Plot 수, selected tab, video frame 번호 같은 정밀 상태 검증은 브라우저 화면만으로는 부족합니다.
- 다음 단계에서 Python 결과와 MATLAB `getTestState` JSON/MD 로그를 결합하면 화면 검증과 내부 상태 검증을 함께 수행할 수 있습니다.
- 안정적인 selector가 부족한 경우 `FlightDataDashboard.m`에 `Tag`를 추가하는 작업이 필요할 수 있으며, 이 경우 사용자 확인 후 진행합니다.
