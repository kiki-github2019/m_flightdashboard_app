from __future__ import annotations

import os
from pathlib import Path

import pytest

from flightdash_ui.cases import CASES
from flightdash_ui.config import TestConfig
from flightdash_ui.framework import FlightDashSession


@pytest.mark.parametrize("case", CASES, ids=[case.case_id for case in CASES])
def test_dashboard_ui_case(case, tmp_path: Path) -> None:  # noqa: ANN001
    if not os.getenv("FLIGHTDASH_APP_URL"):
        pytest.skip("FLIGHTDASH_APP_URL is required for browser UI tests.")

    cfg = TestConfig.from_env(output_dir=tmp_path / "flightdash_ui")
    with FlightDashSession(cfg) as session:
        result = session.run_case(case)
        session.write_summary([result])

    assert result.status == "PASS", result.error
