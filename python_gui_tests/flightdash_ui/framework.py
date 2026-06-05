from __future__ import annotations

import json
import re
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from playwright.sync_api import Browser, BrowserContext, Locator, Page, Playwright, sync_playwright

from .config import TestConfig


@dataclass
class StepResult:
    label: str
    status: str
    detail: str = ""
    screenshot: Path | None = None


@dataclass
class CaseResult:
    case_id: str
    title: str
    status: str = "PASS"
    error: str = ""
    steps: list[StepResult] = field(default_factory=list)


class FlightDashSession:
    def __init__(self, config: TestConfig) -> None:
        self.config = config
        self.playwright: Playwright | None = None
        self.browser: Browser | None = None
        self.context: BrowserContext | None = None
        self.page: Page | None = None
        self.run_dir = self._make_run_dir(config.output_dir)
        self.screenshot_dir = self.run_dir / "screenshots"
        self.trace_dir = self.run_dir / "traces"
        self.video_dir = self.run_dir / "videos"
        self.progress_file = self.run_dir / "progress.md"
        self.had_failure = False
        self.screenshot_dir.mkdir(parents=True, exist_ok=True)
        self.trace_dir.mkdir(parents=True, exist_ok=True)
        self.video_dir.mkdir(parents=True, exist_ok=True)
        self._write_progress_header()

    def __enter__(self) -> "FlightDashSession":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:  # noqa: ANN001
        failed = exc is not None
        self.close(failed=failed)

    def start(self) -> None:
        if not self.config.app_url:
            raise RuntimeError(
                "FLIGHTDASH_APP_URL is empty. Set it to the MATLAB Online/Web App URL."
            )
        self.playwright = sync_playwright().start()
        viewport = {
            "width": self.config.viewport_width,
            "height": self.config.viewport_height,
        }
        common_kwargs = {
            "headless": self.config.headless,
            "slow_mo": self.config.slow_mo_ms,
            "args": ["--start-maximized"],
        }
        if self.config.user_data_dir:
            self.context = self.playwright.chromium.launch_persistent_context(
                user_data_dir=str(self.config.user_data_dir),
                viewport=viewport,
                record_video_dir=str(self.video_dir) if self.config.record_video else None,
                **common_kwargs,
            )
            self.page = self.context.pages[0] if self.context.pages else self.context.new_page()
        else:
            self.browser = self.playwright.chromium.launch(**common_kwargs)
            self.context = self.browser.new_context(
                viewport=viewport,
                record_video_dir=str(self.video_dir) if self.config.record_video else None,
            )
            self.page = self.context.new_page()

        self.page.set_default_timeout(self.config.timeout_ms)
        if self.config.trace_mode != "off":
            self.context.tracing.start(screenshots=True, snapshots=True, sources=True)
        self.page.goto(self.config.app_url, wait_until="domcontentloaded")
        self.page.wait_for_timeout(self.config.initial_wait_ms)
        self.append_progress("RUN", "OPENED", self.config.app_url)

    def close(self, failed: bool = False) -> None:
        trace_path: Path | None = None
        try:
            if self.context and self.config.trace_mode != "off":
                keep_trace = self.config.trace_mode == "on" or failed or self.had_failure
                if keep_trace:
                    trace_path = self.trace_dir / f"trace_{int(time.time())}.zip"
                    self.context.tracing.stop(path=str(trace_path))
                else:
                    self.context.tracing.stop()
        except Exception as exc:  # noqa: BLE001
            self.append_progress("RUN", "TRACE_WARN", str(exc))

        try:
            if self.context:
                self.context.close()
        finally:
            if self.browser:
                self.browser.close()
            if self.playwright:
                self.playwright.stop()
        if trace_path:
            self.append_progress("RUN", "TRACE_SAVED", str(trace_path))
        self._cleanup_empty_dirs()

    def run_case(self, case: "UiCase") -> CaseResult:
        result = CaseResult(case_id=case.case_id, title=case.title)
        # Best-effort cleanup BEFORE every case so leftovers from a previous
        # failure (open dialog, focused dropdown, etc.) do not pollute baseline.
        self._between_case_cleanup()
        self.append_progress(case.case_id, "START", case.title)
        try:
            shot = self.capture(case.case_id, "baseline", reason="baseline")
            result.steps.append(StepResult("baseline", "PASS", screenshot=shot))
            for idx, action in enumerate(case.actions, start=1):
                label = f"{idx:02d}_{action.name}"
                self.append_progress(case.case_id, "ACTION", label)
                action.run(self)
                shot = self.capture(case.case_id, label, reason="step")
                result.steps.append(StepResult(label, "PASS", screenshot=shot))
            self.append_progress(case.case_id, "PASS", case.title)
        except Exception as exc:  # noqa: BLE001
            self.had_failure = True
            result.status = "FAIL"
            result.error = f"{type(exc).__name__}: {exc}"
            fail_shot = self.capture(case.case_id, "failure", reason="fail")
            result.steps.append(StepResult("failure", "FAIL", result.error, fail_shot))
            self.append_progress(case.case_id, "FAIL", result.error)
        return result

    def _between_case_cleanup(self) -> None:
        """Send Escape twice + click body to dismiss any lingering modal/dropdown."""
        try:
            page = self._page()
            page.keyboard.press("Escape")
            page.wait_for_timeout(120)
            page.keyboard.press("Escape")
            page.wait_for_timeout(120)
            # Click an empty area to defocus any active widget without triggering anything.
            try:
                page.mouse.click(2, 2)
            except Exception:  # noqa: BLE001
                pass
        except Exception as exc:  # noqa: BLE001
            self.append_progress("RUN", "CLEANUP_WARN", str(exc))

    def click_text(self, text: str, *, timeout_ms: int | None = None) -> None:
        loc = self.find_text_locator(text)
        loc.click(timeout=timeout_ms or self.config.timeout_ms)
        self.wait_stable()

    def expect_text(self, text: str, *, timeout_ms: int | None = None) -> None:
        loc = self.find_text_locator(text)
        loc.first.wait_for(state="visible", timeout=timeout_ms or self.config.timeout_ms)

    def fill_near_label(self, label: str, value: str) -> None:
        page = self._page()
        label_loc = self.find_text_locator(label).first
        input_loc = label_loc.locator(
            "xpath=following::*[self::input or self::textarea][1]"
        )
        input_loc.fill(value)
        self.wait_stable()

    def press_key(self, key: str) -> None:
        self._page().keyboard.press(key)
        self.wait_stable()

    def find_text_locator(self, text: str) -> Locator:
        page = self._page()
        quoted = json.dumps(text)
        # Named tuples so the progress log can record WHICH strategy matched.
        # MATLAB Online renders uifigure to a canvas/iframe — role-based queries
        # are most likely to fail; text= fallback may succeed for non-canvas chrome.
        strategies: list[tuple[str, Locator]] = [
            ("role=button", page.get_by_role("button", name=re.compile(re.escape(text)))),
            ("role=tab",    page.get_by_role("tab",    name=re.compile(re.escape(text)))),
            ("role=link",   page.get_by_role("link",   name=re.compile(re.escape(text)))),
            ("get_by_text", page.get_by_text(text, exact=False)),
            ("css=button",  page.locator(f"button:has-text({quoted})")),
            ("css=[role]",  page.locator(f"[role=button]:has-text({quoted})")),
            ("text=",       page.locator(f"text={text}")),
        ]
        errors: list[str] = []
        for name, loc in strategies:
            try:
                if loc.count() > 0:
                    self.append_progress("LOC", "MATCH", f"{name} -> {text}")
                    return loc.first
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{name}: {exc}")
        details = "; ".join(errors[-3:])
        # Explicit hint about canvas rendering when EVERY strategy fails — most
        # common failure mode for MATLAB Online uifigure smoke tests.
        canvas_hint = (
            " HINT: MATLAB Online renders uifigure to canvas; DOM text queries "
            "may not see button labels. Consider adding Tag/data-testid in the "
            ".m file and switching locators to those tags."
        )
        raise RuntimeError(
            f"text locator not found: {text!r}. {details}{canvas_hint}"
        )

    def capture(self, case_id: str, name: str, *, reason: str) -> Path | None:
        if not self._should_capture(reason):
            return None
        path = self.screenshot_dir / f"{case_id}_{name}.png"
        self._page().screenshot(path=str(path), full_page=False)
        if self.config.capture_scale < 1:
            self._downscale_png(path, self.config.capture_scale)
        return path

    def wait_stable(self, delay_ms: int = 700) -> None:
        self._page().wait_for_timeout(delay_ms)

    def append_progress(self, case_id: str, status: str, detail: str = "") -> None:
        with self.progress_file.open("a", encoding="utf-8") as f:
            f.write(
                f"| {time.strftime('%Y-%m-%d %H:%M:%S')} | {case_id} | "
                f"`{status}` | {self._md(detail)} |\n"
            )

    def write_summary(self, results: Iterable[CaseResult]) -> Path:
        results = list(results)
        report = self.run_dir / "index.md"
        with report.open("w", encoding="utf-8") as f:
            f.write("# FlightDataDashboard Python UI Test Report\n\n")
            f.write(f"- URL: `{self.config.app_url}`\n")
            f.write(f"- CaptureMode: `{self.config.capture_mode}`\n")
            f.write(f"- CaptureScale: `{self.config.capture_scale}`\n")
            f.write(f"- Progress: [progress.md](progress.md)\n\n")
            f.write("| Case | Title | Status | Failure |\n")
            f.write("|---|---|---|---|\n")
            for result in results:
                f.write(
                    f"| {result.case_id} | {self._md(result.title)} | "
                    f"`{result.status}` | {self._md(result.error)} |\n"
                )
            for result in results:
                f.write(f"\n## {result.case_id}: {self._md(result.title)}\n\n")
                for step in result.steps:
                    link = "(not captured)"
                    if step.screenshot:
                        rel = step.screenshot.relative_to(self.run_dir).as_posix()
                        link = f"![]({rel})"
                    f.write(f"- `{step.status}` {self._md(step.label)}: {link}\n")
                if result.error:
                    f.write(f"\n```text\n{result.error}\n```\n")
        return report

    def _page(self) -> Page:
        if not self.page:
            raise RuntimeError("Playwright page is not started.")
        return self.page

    def _should_capture(self, reason: str) -> bool:
        mode = self.config.capture_mode
        if mode == "all":
            return True
        if mode == "baseline":
            return reason in {"baseline", "fail"}
        if mode == "fail":
            return reason == "fail"
        return False

    def _write_progress_header(self) -> None:
        with self.progress_file.open("w", encoding="utf-8") as f:
            f.write("# FlightDataDashboard Python UI Test Progress\n\n")
            f.write("| Time | Case | Status | Detail |\n")
            f.write("|---|---|---|---|\n")

    def _cleanup_empty_dirs(self) -> None:
        if not self.config.record_video:
            shutil.rmtree(self.video_dir, ignore_errors=True)
        try:
            if not any(self.trace_dir.iterdir()):
                self.trace_dir.rmdir()
        except OSError:
            pass

    @staticmethod
    def _make_run_dir(base: Path) -> Path:
        # Append millisecond suffix so two runs started within the same second
        # do not collide and overwrite each other's screenshots/reports.
        suffix = f"_{int(time.time() * 1000) % 1000:03d}"
        run_dir = base / (time.strftime("%Y%m%d_%H%M%S") + suffix)
        run_dir.mkdir(parents=True, exist_ok=True)
        return run_dir

    @staticmethod
    def _downscale_png(path: Path, scale: float) -> None:
        try:
            from PIL import Image

            with Image.open(path) as img:
                width, height = img.size
                size = (max(1, int(width * scale)), max(1, int(height * scale)))
                resized = img.resize(size, Image.Resampling.BILINEAR)
                resized.save(path)
        except Exception:
            return

    @staticmethod
    def _md(text: str) -> str:
        return str(text).replace("|", "\\|").replace("\n", "<br>") or "&nbsp;"
