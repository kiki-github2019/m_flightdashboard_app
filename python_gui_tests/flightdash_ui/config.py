from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

CaptureMode = Literal["all", "baseline", "fail", "none"]
TraceMode = Literal["on", "off", "retain-on-failure"]


@dataclass(frozen=True)
class TestConfig:
    app_url: str
    output_dir: Path
    user_data_dir: Path | None
    headless: bool = False
    timeout_ms: int = 20_000
    initial_wait_ms: int = 8_000
    viewport_width: int = 1365
    viewport_height: int = 768
    capture_mode: CaptureMode = "baseline"
    capture_scale: float = 0.70
    trace_mode: TraceMode = "retain-on-failure"
    record_video: bool = False
    slow_mo_ms: int = 0

    @staticmethod
    def from_env(output_dir: Path | None = None) -> "TestConfig":
        url = os.getenv("FLIGHTDASH_APP_URL", "").strip()
        profile = os.getenv("FLIGHTDASH_PROFILE_DIR", "").strip()
        out = output_dir or Path(os.getenv("FLIGHTDASH_TEST_OUTPUT", "results")).expanduser()
        capture_mode = os.getenv("FLIGHTDASH_CAPTURE_MODE", "baseline").strip().lower()
        trace_mode = os.getenv("FLIGHTDASH_TRACE_MODE", "retain-on-failure").strip().lower()
        return TestConfig(
            app_url=url,
            output_dir=out,
            user_data_dir=Path(profile).expanduser() if profile else None,
            headless=_env_bool("FLIGHTDASH_HEADLESS", False),
            timeout_ms=_env_int("FLIGHTDASH_TIMEOUT_MS", 20_000),
            initial_wait_ms=_env_int("FLIGHTDASH_INITIAL_WAIT_MS", 8_000),
            viewport_width=_env_int("FLIGHTDASH_VIEWPORT_WIDTH", 1365),
            viewport_height=_env_int("FLIGHTDASH_VIEWPORT_HEIGHT", 768),
            capture_mode=_capture_mode(capture_mode),
            capture_scale=_capture_scale(os.getenv("FLIGHTDASH_CAPTURE_SCALE", "0.70")),
            trace_mode=_trace_mode(trace_mode),
            record_video=_env_bool("FLIGHTDASH_RECORD_VIDEO", False),
            slow_mo_ms=_env_int("FLIGHTDASH_SLOW_MO_MS", 0),
        )


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _capture_scale(raw: str) -> float:
    try:
        value = float(raw)
    except ValueError:
        value = 0.70
    return min(1.0, max(0.10, value))


def _capture_mode(value: str) -> CaptureMode:
    if value in {"all", "baseline", "fail", "none"}:
        return value  # type: ignore[return-value]
    return "baseline"


def _trace_mode(value: str) -> TraceMode:
    if value in {"on", "off", "retain-on-failure"}:
        return value  # type: ignore[return-value]
    return "retain-on-failure"
