from __future__ import annotations

import argparse
import sys
from pathlib import Path

from flightdash_ui.cases import select_cases
from flightdash_ui.config import TestConfig
from flightdash_ui.framework import FlightDashSession


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run FlightDataDashboard browser UI tests.")
    parser.add_argument("--url", default=None, help="MATLAB Online/Web App URL.")
    parser.add_argument("--case", action="append", dest="cases", help="Case id to run, e.g. B01.")
    parser.add_argument("--output", default=None, help="Output directory for reports.")
    parser.add_argument("--profile-dir", default=None, help="Persistent browser profile directory.")
    parser.add_argument("--headless", action="store_true", help="Run browser headless.")
    parser.add_argument(
        "--capture-mode",
        choices=["all", "baseline", "fail", "none"],
        default=None,
        help="Screenshot capture policy.",
    )
    parser.add_argument("--capture-scale", type=float, default=None, help="Screenshot downscale ratio.")
    parser.add_argument(
        "--trace",
        choices=["on", "off", "retain-on-failure"],
        default=None,
        help="Playwright trace policy.",
    )
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> TestConfig:
    output_dir = Path(args.output).expanduser() if args.output else None
    cfg = TestConfig.from_env(output_dir=output_dir)
    return TestConfig(
        app_url=args.url or cfg.app_url,
        output_dir=cfg.output_dir,
        user_data_dir=Path(args.profile_dir).expanduser() if args.profile_dir else cfg.user_data_dir,
        headless=args.headless or cfg.headless,
        timeout_ms=cfg.timeout_ms,
        initial_wait_ms=cfg.initial_wait_ms,
        viewport_width=cfg.viewport_width,
        viewport_height=cfg.viewport_height,
        capture_mode=args.capture_mode or cfg.capture_mode,
        capture_scale=args.capture_scale if args.capture_scale is not None else cfg.capture_scale,
        trace_mode=args.trace or cfg.trace_mode,
        record_video=cfg.record_video,
        slow_mo_ms=cfg.slow_mo_ms,
    )


def main() -> int:
    args = parse_args()
    cfg = build_config(args)
    cases = select_cases(args.cases)
    if not cases:
        print("No matching cases.")
        return 2

    results = []
    with FlightDashSession(cfg) as session:
        for case in cases:
            print(f"[{case.case_id}] {case.group} - {case.title}")
            result = session.run_case(case)
            results.append(result)
            print(f"  {result.status}")
        report = session.write_summary(results)
        print(f"Report: {report}")

    return 1 if any(result.status != "PASS" for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
