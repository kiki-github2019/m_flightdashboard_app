from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


class SessionLike(Protocol):
    def click_text(self, text: str, *, timeout_ms: int | None = None) -> None: ...
    def expect_text(self, text: str, *, timeout_ms: int | None = None) -> None: ...
    def fill_near_label(self, label: str, value: str) -> None: ...
    def press_key(self, key: str) -> None: ...
    def wait_stable(self, delay_ms: int = 700) -> None: ...


@dataclass(frozen=True)
class UiAction:
    name: str
    text: str | None = None
    expect: tuple[str, ...] = ()
    optional: bool = False

    def run(self, session: SessionLike) -> None:
        try:
            self._run_required(session)
        except Exception:
            if self.optional:
                return
            raise

    def _run_required(self, session: SessionLike) -> None:
        raise NotImplementedError


@dataclass(frozen=True)
class ClickText(UiAction):
    def _run_required(self, session: SessionLike) -> None:
        if not self.text:
            raise ValueError("ClickText requires text.")
        session.click_text(self.text)
        for text in self.expect:
            session.expect_text(text)


@dataclass(frozen=True)
class ExpectText(UiAction):
    def _run_required(self, session: SessionLike) -> None:
        if not self.text:
            raise ValueError("ExpectText requires text.")
        session.expect_text(self.text)


@dataclass(frozen=True)
class FillNearLabel(UiAction):
    value: str = ""

    def _run_required(self, session: SessionLike) -> None:
        if not self.text:
            raise ValueError("FillNearLabel requires label text.")
        session.fill_near_label(self.text, self.value)


@dataclass(frozen=True)
class PressKey(UiAction):
    key: str = "Escape"

    def _run_required(self, session: SessionLike) -> None:
        session.press_key(self.key)


@dataclass(frozen=True)
class Wait(UiAction):
    delay_ms: int = 700

    def _run_required(self, session: SessionLike) -> None:
        session.wait_stable(self.delay_ms)


@dataclass(frozen=True)
class UiCase:
    case_id: str
    group: str
    title: str
    objective: str
    actions: tuple[UiAction, ...] = field(default_factory=tuple)


CASES: tuple[UiCase, ...] = (
    UiCase(
        case_id="B01",
        group="BoardOff",
        title="Top board off/on summary smoke",
        objective="상단 보드 off 시 summary 표시 후 on 복귀 버튼이 보이는지 확인",
        actions=(
            ExpectText("baseline_header", "상단 보드 off"),
            ClickText("top_board_off", "상단 보드 off", expect=("상단 보드 on",)),
            ExpectText("top_summary", "Board Off Summary"),
            ClickText("top_board_on", "상단 보드 on", expect=("상단 보드 off",)),
        ),
    ),
    UiCase(
        case_id="B02",
        group="BoardOff",
        title="Bottom board off/on summary smoke",
        objective="하단 보드 off 시 summary 표시 후 on 복귀 버튼이 보이는지 확인",
        actions=(
            ExpectText("baseline_header", "하단 보드 off"),
            ClickText("bottom_board_off", "하단 보드 off", expect=("하단 보드 on",)),
            ExpectText("bottom_summary", "Board Off Summary"),
            ClickText("bottom_board_on", "하단 보드 on", expect=("하단 보드 off",)),
        ),
    ),
    UiCase(
        case_id="P01",
        group="PanelToggle",
        title="Main panel toggle smoke",
        objective="자세/지도/고도/비디오 토글 버튼이 클릭 가능한지 확인",
        actions=(
            ClickText("attitude_toggle", "자세"),
            ClickText("attitude_restore", "자세"),
            ClickText("map_toggle", "지도/고도"),
            ClickText("map_restore", "지도/고도"),
            ClickText("video_toggle", "비디오"),
            ClickText("video_restore", "비디오"),
        ),
    ),
    UiCase(
        case_id="E01",
        group="EditDialog",
        title="Plot Manager dialog smoke",
        objective="설정/편집 dialog와 Plot Manager 기본 항목이 보이는지 확인",
        actions=(
            ClickText("open_edit_dialog", "설정/편집", expect=("Project",)),
            ClickText("plot_manager_tab", "Plot Manager", expect=("Y 데이터 항목", "Plot height")),
            PressKey("close_dialog_escape", key="Escape", optional=True),
        ),
    ),
    UiCase(
        case_id="V01",
        group="Video",
        title="AVI control dialog smoke",
        objective="AVI 제어창이 열리고 frame navigator 문구가 보이는지 확인",
        actions=(
            ClickText("open_video_control", "제어창", expect=("AVI 제어",)),
            ExpectText("frame_navigator", "Frame Navigator", optional=True),
            ClickText("close_video_control", "제어창 닫기", optional=True),
        ),
    ),
)


def select_cases(case_ids: list[str] | None) -> tuple[UiCase, ...]:
    if not case_ids:
        return CASES
    wanted = {case_id.upper() for case_id in case_ids}
    return tuple(case for case in CASES if case.case_id.upper() in wanted)
