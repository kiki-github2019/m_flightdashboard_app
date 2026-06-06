## Python + Selenim UI 테스트 구현 제안

### MATLAB Online / Desktop App의 UI를 Python Selenium으로 자동화하는 프레임워크를 제공합니다.
#### 장점 (MATLAB auto_test_runner 대비)

MATLAB 메모리(OOM) 문제 완전 회피
브라우저 기반으로 안정적 (MATLAB Online도 지원)
병렬 실행, 스크린샷, 리포트, Video 녹화 가능
Plot Manager, Edit Dialog, Board Off 등 복잡한 UI 조작에 강력

#### MATLAB App에서 Selenium 사용 팁

MATLAB Desktop App:
MATLAB Web App Server 실행 후 URL로 접근
또는 MATLAB Online에서 브라우저 URL 사용

Selector 전략 (추천):
//button[contains(text(),'상단 보드 off')]
//span[contains(text(),'자세')]/parent::button
//div[contains(@class,'uitab')]

Plot Manager / Edit Dialog:
Dialog가 modeless이므로 WebDriverWait으로 visibility 확인


## 전략 1

**✅ Python + Selenium UI 테스트 프레임워크 전체 코드**

아래는 **단일 프로젝트**로 바로 사용할 수 있는 완전한 코드입니다.

### 1. 프로젝트 구조
```
flightdash_ui_test/
├── main.py
├── framework.py
├── test_cases.py
├── config.py
├── requirements.txt
└── screenshots/     (자동 생성)
```

---

### **requirements.txt**
```txt
selenium>=4.15.0
webdriver-manager
pillow
```

---

### **config.py**
```python
import os
from datetime import datetime

class Config:
    # MATLAB Online 또는 Desktop Web App URL (필요 시 수정)
    APP_URL = "https://matlab.mathworks.com"   # ← 실제 URL로 변경
    
    TIMEOUT = 15
    SCREENSHOT_DIR = "screenshots"
    REPORT_DIR = "reports"
    
    @staticmethod
    def get_screenshot_path(name):
        os.makedirs(Config.SCREENSHOT_DIR, exist_ok=True)
        timestamp = datetime.now().strftime("%H%M%S")
        return f"{Config.SCREENSHOT_DIR}/{name}_{timestamp}.png"
```

---

### **framework.py**
```python
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from webdriver_manager.chrome import ChromeDriverManager
import time
import os

class AppTestFramework:
    def __init__(self):
        options = webdriver.ChromeOptions()
        options.add_argument("--start-maximized")
        options.add_argument("--disable-gpu")
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        
        self.driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)
        self.wait = WebDriverWait(self.driver, 15)
        print("✅ Selenium Framework 초기화 완료")

    def open_app(self, url=None):
        if url is None:
            url = Config.APP_URL
        self.driver.get(url)
        time.sleep(4)  # App 로딩 대기
        print(f"📱 App opened: {url}")

    def click(self, selector, by=By.XPATH, timeout=10):
        try:
            elem = WebDriverWait(self.driver, timeout).until(
                EC.element_to_be_clickable((by, selector))
            )
            elem.click()
            time.sleep(0.6)
            return True
        except Exception as e:
            print(f"❌ Click 실패: {selector} - {e}")
            return False

    def send_keys(self, selector, text, by=By.XPATH):
        try:
            elem = self.wait.until(EC.visibility_of_element_located((by, selector)))
            elem.clear()
            elem.send_keys(text)
            time.sleep(0.5)
            return True
        except Exception as e:
            print(f"❌ Send keys 실패: {selector} - {e}")
            return False

    def capture(self, name="step"):
        path = Config.get_screenshot_path(name)
        try:
            self.driver.save_screenshot(path)
            print(f"📸 Captured: {path}")
            return path
        except Exception as e:
            print(f"❌ Capture 실패: {e}")
            return None

    def close(self):
        try:
            self.driver.quit()
            print("🛑 Browser closed")
        except:
            pass
```

---

### **test_cases.py**
```python
test_cases = [
    {
        "id": "A01",
        "group": "Basic",
        "title": "기본 데이터 로드",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'비행경로 1 선택')]", "name": "load_f1"},
            {"type": "click", "selector": "//button[contains(text(),'비행경로 2 선택')]", "name": "load_f2"}
        ]
    },
    {
        "id": "B01",
        "group": "BoardOff",
        "title": "보드1 Off → On",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'상단 보드 off')]", "name": "board1_off"},
            {"type": "click", "selector": "//button[contains(text(),'상단 보드 on')]", "name": "board1_on"}
        ]
    },
    {
        "id": "F01",
        "group": "PlotManager",
        "title": "Plot Manager 열기",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'설정/편집')]", "name": "open_edit_dialog"}
        ]
    },
    {
        "id": "E04",
        "group": "VideoSync",
        "title": "비디오 동기 + 시간 변경",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'AVI 파일 열기')]", "name": "open_avi"}
        ]
    }
]
```

---

### **main.py** (실행 파일)
```python
from framework import AppTestFramework
from test_cases import test_cases
from config import Config
import time
import os

def run_all_tests():
    framework = AppTestFramework()
    
    try:
        framework.open_app(Config.APP_URL)
        
        for case in test_cases:
            print(f"\n🚀 [{case['id']}] {case['group']} - {case['title']}")
            success = True
            
            for action in case.get("actions", []):
                try:
                    if action["type"] == "click":
                        framework.click(action["selector"], name=action.get("name", "click"))
                    elif action["type"] == "keys":
                        framework.send_keys(action["selector"], action["text"])
                    
                    framework.capture(f"{case['id']}_{action.get('name', 'step')}")
                    time.sleep(1.2)
                except Exception as e:
                    print(f"   ❌ Action 실패: {action.get('name')} - {e}")
                    success = False
                    break
            
            status = "PASS" if success else "FAIL"
            print(f"   → {status}")
            
    except Exception as e:
        print(f"❌ 전체 테스트 실패: {e}")
    finally:
        framework.close()

if __name__ == "__main__":
    run_all_tests()
```

---

### 실행 방법

1. 폴더 생성 후 파일들 저장
2. 터미널에서:
   ```bash
   pip install -r requirements.txt
   python main.py
   ```

3. **중요**: `config.py`의 `APP_URL`을 실제 MATLAB App URL로 변경하세요.

---

** 확장할 기능 **
- Plot Manager 상세 조작 (트리 클릭, 입력 필드 편집)
- Board Off + Video Sync 복합 시나리오
- HTML 리포트 자동 생성



## 전략 2
**✅ Playwright 버전** (Selenium보다 현대적이고 안정적)

Playwright는 **2025~2026년 기준**으로 MATLAB Online / Web App 테스트에 가장 적합한 도구입니다.  
자동 대기, 안정적인 Selector, 스크린샷, 병렬 실행, Trace Viewer 등 강력한 기능을 제공합니다.

---

### 1. 프로젝트 구조

```
flightdash_playwright_test/
├── main.py
├── framework.py
├── test_cases.py
├── config.py
├── requirements.txt
├── screenshots/          # 자동 생성
└── test-results/         # Trace 및 리포트
```

---

### **requirements.txt**
```txt
playwright
pytest
pandas
```

설치:
```bash
pip install -r requirements.txt
playwright install chromium  # 최초 1회 실행
```

---

### **config.py**
```python
import os
from datetime import datetime

class Config:
    # MATLAB Online에서 앱을 연 후 주소창 URL을 여기에 붙여넣기
    APP_URL = "https://matlab.mathworks.com/..."   # ← 반드시 수정
    
    TIMEOUT = 20
    SCREENSHOT_DIR = "screenshots"
    TRACE_DIR = "test-results"
    
    @staticmethod
    def get_screenshot_path(name):
        os.makedirs(Config.SCREENSHOT_DIR, exist_ok=True)
        ts = datetime.now().strftime("%H%M%S")
        return f"{Config.SCREENSHOT_DIR}/{name}_{ts}.png"
```

---

### **framework.py** (Playwright Wrapper)
```python
from playwright.sync_api import sync_playwright, Page, expect
import time
import os
from config import Config

class AppTestFramework:
    def __init__(self):
        self.playwright = sync_playwright().start()
        self.browser = self.playwright.chromium.launch(headless=False, args=["--start-maximized"])
        self.context = self.browser.new_context()
        self.page: Page = self.context.new_page()
        self.page.set_default_timeout(Config.TIMEOUT * 1000)
        print("✅ Playwright Framework 초기화 완료")

    def open_app(self, url=None):
        if url is None:
            url = Config.APP_URL
        self.page.goto(url, wait_until="networkidle")
        self.page.wait_for_timeout(4000)
        print(f"📱 App opened: {url}")

    def click(self, selector: str, name="click"):
        try:
            self.page.locator(selector).click(timeout=10000)
            self.page.wait_for_timeout(800)
            print(f"✅ Click: {name}")
            return True
        except Exception as e:
            print(f"❌ Click 실패 [{name}]: {e}")
            return False

    def fill(self, selector: str, text: str, name="fill"):
        try:
            self.page.locator(selector).fill(text)
            print(f"✅ Fill: {name} = {text}")
            return True
        except Exception as e:
            print(f"❌ Fill 실패: {e}")
            return False

    def capture(self, name="step"):
        path = Config.get_screenshot_path(name)
        self.page.screenshot(path=path, full_page=False)
        print(f"📸 Screenshot saved: {path}")
        return path

    def close(self):
        try:
            self.context.close()
            self.browser.close()
            self.playwright.stop()
            print("🛑 Playwright closed")
        except:
            pass
```

---

### **test_cases.py**
```python
test_cases = [
    {
        "id": "A01",
        "group": "Basic",
        "title": "기본 데이터 로드",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'비행경로 1 선택')]", "name": "load_f1"},
            {"type": "click", "selector": "//button[contains(text(),'비행경로 2 선택')]", "name": "load_f2"}
        ]
    },
    {
        "id": "B01",
        "group": "BoardOff",
        "title": "보드1 Off → On",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'상단 보드 off')]", "name": "board1_off"},
            {"type": "click", "selector": "//button[contains(text(),'상단 보드 on')]", "name": "board1_on"}
        ]
    },
    {
        "id": "F01",
        "group": "PlotManager",
        "title": "Plot Manager 열기 및 기본 조작",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'설정/편집')]", "name": "open_edit"},
            {"type": "click", "selector": "//div[contains(@class,'uitab') and contains(text(),'Plot')]", "name": "plot_tab"}
        ]
    },
    {
        "id": "E01",
        "group": "Video",
        "title": "비디오 동기 테스트",
        "actions": [
            {"type": "click", "selector": "//button[contains(text(),'AVI 파일 열기')]", "name": "open_avi"}
        ]
    }
]
```

---

### **main.py** (실행 파일)
```python
from framework import AppTestFramework
from test_cases import test_cases
from config import Config
import time

def run_tests():
    framework = AppTestFramework()
    
    try:
        framework.open_app(Config.APP_URL)
        
        for case in test_cases:
            print(f"\n🚀 [{case['id']}] {case['group']} — {case['title']}")
            success = True
            
            for action in case.get("actions", []):
                try:
                    if action["type"] == "click":
                        framework.click(action["selector"], action.get("name", "click"))
                    # fill, select 등 필요 시 확장
                    
                    framework.capture(f"{case['id']}_{action.get('name','step')}")
                    time.sleep(1.0)
                except Exception as e:
                    print(f"   ❌ Action 실패: {action.get('name')} → {e}")
                    success = False
                    break
            
            status = "✅ PASS" if success else "❌ FAIL"
            print(f"   → {status}")
            
    except Exception as e:
        print(f"전체 테스트 중 오류: {e}")
    finally:
        framework.close()

if __name__ == "__main__":
    run_tests()
```

---

### 실행 방법

1. 위 파일들을 폴더에 저장
2. 터미널에서:
   ```bash
   pip install -r requirements.txt
   playwright install chromium
   python main.py
   ```

3. **가장 중요한 부분**: 
   - `config.py`의 `APP_URL`을 **MATLAB Online에서 앱을 연 상태**의 실제 URL로 바꾸세요.

---

**Playwright의 장점** (Selenium 대비)
- 자동 대기 (`auto-waiting`)가 훨씬 강력
- 더 안정적인 Locator (XPath, CSS, Text)
- Trace Viewer로 디버깅 용이 (`playwright show-trace test-results/trace.zip`)
- 스크린샷 품질이 좋음


## 전략 #3
**✅ Playwright Locator 전략**  
**FlightDataDashboard (MATLAB App Designer)용 실전 가이드**

MATLAB App Designer의 UI는 동적이고 클래스명이 불안정하기 때문에, **강력하고 유지보수하기 쉬운 Locator 전략**이 필수입니다.

### 1. Locator 우선순위 전략 (추천 순서)

| 우선순위 | 전략 | 예시 | 추천 이유 |
|---------|------|------|----------|
| **1** | `text` + `contains` | `page.get_by_text("상단 보드 off")` | 가장 직관적이고 안정적 |
| **2** | `role` + `name` | `page.get_by_role("button", name="AVI 파일 열기")` | 접근성 최고, MATLAB UI에 잘 동작 |
| **3** | XPath (Text 기반) | `//button[contains(text(),'비행경로 1 선택')]` | 강력하지만 유지보수 어려움 |
| **4** | CSS + Attribute | `button:has-text("설정/편집")` | Playwright 전용 강력 문법 |
| **5** | Test ID (권장) | `data-testid="board-off-btn"` | 가장 안정적 (MATLAB 코드 수정 필요) |

---

### 2. FlightDataDashboard에 최적화된 Locator 전략

#### **기본 전략 (강력 추천)**

```python
# 1. Text 기반 (가장 추천)
framework.page.get_by_text("상단 보드 off", exact=False).click()
framework.page.get_by_text("설정/편집").click()

# 2. Role 기반
framework.page.get_by_role("button", name="비행경로 1 선택").click()
framework.page.get_by_role("tab", name="Plot").click()

# 3. Combined (가장 안정적)
framework.page.locator("button:has-text('AVI 파일 열기')").click()
```

#### **실전 Locator 예시** (FlightDataDashboard용)

```python
# Board Off / On
page.get_by_text("상단 보드 off").click()
page.get_by_text("상단 보드 on").click()

# Panel Toggle
page.get_by_text("자세 ▾").click()
page.get_by_text("지도/고도 ▾").click()
page.get_by_text("비디오 ▾").click()

# Plot Manager
page.get_by_text("설정/편집").click()                    # Edit Dialog 열기
page.get_by_text("Plot Manager").click()                # 또는 tab
page.locator("input[placeholder*='Plot Name']").fill("Altitude Test")

# Video Control
page.get_by_text("AVI 파일 열기").click()
page.get_by_text("동기").click()

# Spinner / Slider
page.locator("input[type='number']").fill("123.45")     # 시간 입력
```

---

### 3. 고급 Locator 전략

#### **Chain + Filter** (강력 추천)
```python
# 특정 Board 안의 버튼
page.locator("#flight1").get_by_text("자세 ▾").click()

# Plot Manager 내 특정 필드
page.locator("div[role='dialog']").get_by_text("YColumn").locator("..").locator("input").fill("Alt")
```

#### **XPath 전략** (필요할 때만)
```python
page.locator("//button[contains(@class, 'btn') and contains(text(),'보드1')]").click()
```

#### **Test ID 전략** (최고의 안정성)
MATLAB 코드에 아래처럼 추가하면 최고:

```matlab
% FlightDataDashboard.m
btn = uibutton(..., 'Text', '상단 보드 off', 'Tag', 'test-board1-off');
```

Python:
```python
page.get_by_test_id("test-board1-off").click()
```

---

### 4. Playwright Locator 베스트 프랙티스

1. **Text 우선** → `get_by_text()` 또는 `has-text`
2. **exact=False** 자주 사용 (MATLAB 버튼에 ▾, ▸ 기호 때문)
3. **Timeout 명시**:
   ```python
   page.get_by_text("비디오").click(timeout=15000)
   ```
4. **Waiting 전략**:
   ```python
   expect(page.get_by_text("동기 완료")).to_be_visible(timeout=10000)
   ```
5. **Locator 재사용**:
   ```python
   board1 = page.locator("div[title*='Flight Data 1']")
   board1.get_by_text("상단 보드 off").click()
   ```

---

### 5. 개선된 `framework.py` (Locator 전략 적용 버전)

```python
def click_by_text(self, text, exact=False, timeout=10000):
    try:
        self.page.get_by_text(text, exact=exact).click(timeout=timeout)
        self.page.wait_for_timeout(600)
        return True
    except:
        return self.click(f"//button[contains(text(),'{text}')]", name=text)

def click_by_role(self, role, name):
    self.page.get_by_role(role, name=name).click()
```

---

**실전 팁**:
- MATLAB Online에서 앱을 열고 **개발자 도구(F12) → Elements**에서 Selector를 미리 테스트하세요.
- `page.pause()`를 사용하면 브라우저가 멈추면서 Locator를 실시간으로 테스트할 수 있습니다.

---

## 전략 #4
**✅ Playwright Trace Viewer 활용법**  
**FlightDataDashboard 테스트 디버깅에 최적화된 가이드**

Playwright Trace Viewer는 **Selenium 대비 가장 강력한 디버깅 도구** 중 하나입니다. 테스트가 실패하거나 동작이 불안정할 때, **정확히 무엇이 문제인지** 시각적으로 분석할 수 있습니다.

---

### 1. Trace Viewer 활성화 방법

**Trace를 저장하면서 테스트 실행하기**

```bash
# 1. Trace 저장 옵션 추가해서 실행
python main.py

# 또는 pytest 사용 시
pytest --tracing=retain-on-failure
```

**framework.py**에 Trace 자동 저장 추가 (강력 추천):

```python
# framework.py __init__에 추가
self.context = self.browser.new_context(
    record_video_dir="videos",           # 비디오 녹화
    record_trace=True                    # Trace 자동 기록
)
```

또는 테스트 코드에서 직접:

```python
# main.py 또는 테스트 함수 내
context = framework.browser.new_context(record_trace=True)
page = context.new_page()
```

---

### 2. Trace Viewer 실행 방법

**가장 쉬운 방법 (추천)**

```bash
# 테스트 실행 후 생성된 trace.zip 파일 열기
playwright show-trace test-results/trace.zip
```

**또는 특정 trace 파일 지정**

```bash
playwright show-trace screenshots/trace_caseB01.zip
```

---

### 3. Trace Viewer 주요 기능 및 활용법

| 기능 | 설명 | FlightDataDashboard 활용 팁 |
|------|------|---------------------------|
| **Timeline** | 시간 순서대로 모든 액션 표시 | Board Off 토글 → Panel 숨김 → Summary rebuild 과정 확인 |
| **Action List** | 클릭, fill, wait 등의 상세 로그 | Locator가 실패한 정확한 시점과 이유 확인 |
| **Screenshots** | 각 액션마다 자동 캡처 | "상단 보드 off" 클릭 후 UI 상태 시각적 확인 |
| **Console** | 브라우저 콘솔 로그 | MATLAB 오류, JavaScript warning 확인 |
| **Network** | 네트워크 요청 | MATLAB Online 지연 원인 분석 |
| **Source** | 실행된 Playwright 코드 | Codegen 코드와 실제 실행 코드 비교 |

---

### 4. 실전 디버깅 워크플로우 (MATLAB App)

1. **Trace 저장 설정** 후 테스트 실행
2. 실패한 케이스의 `trace.zip` 파일 찾기
3. `playwright show-trace trace.zip` 실행
4. **Timeline 슬라이더**로 문제 구간 이동
5. **Before / After Screenshot** 비교
6. **Locator**가 제대로 잡혔는지 확인

**유용한 단축키**:
- `Space` → Play / Pause
- `← →` → 액션 이동
- `Ctrl + F` → Locator 검색

---

### 5. framework.py에 Trace 자동 저장 추가 (추천 코드)

```python
# framework.py
def __init__(self, trace_name=None):
    self.context = self.browser.new_context(
        record_trace=True,
        record_video_dir="videos"
    )
    self.page = self.context.new_page()
    
def save_trace(self, name="trace"):
    try:
        trace_path = f"test-results/{name}_{int(time.time())}.zip"
        self.context.tracing.stop(path=trace_path)
        print(f"📁 Trace saved: {trace_path}")
        return trace_path
    except:
        pass
```

**테스트 종료 시 호출**:
```python
framework.save_trace(f"case_{case['id']}")
```

---

### 6. Trace Viewer로 자주 보는 항목 (FlightDataDashboard)

- **Board Off** 테스트 → `refreshBoardOffSummaryPanel` 호출 후 layout 변화 확인
- **Plot Manager** → Edit Dialog가 제대로 열리는지, Tree 선택 후 Apply 동작 확인
- **Video Sync** → AVI 로드 후 Slider 이동 시 frame 업데이트 확인
- **Locator 실패** → 어떤 Selector가 실패했는지 정확히 파악

---

**실행 예시**

```bash
# 1. 테스트 실행 (Trace 저장)
python main.py

# 2. Trace 열기
playwright show-trace test-results/trace_1749123456.zip
```

---

**추가로 원하시면**:
- **Board Off 전용 Trace 분석 체크리스트**
- **자동 리포트 생성** (HTML + Trace 링크)
- **CI/CD (GitHub Actions)** 연동 예시


