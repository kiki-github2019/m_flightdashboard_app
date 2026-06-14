# 정적 검사 라운드 2 — properties·methods·callbacks cross-reference

HEAD `f15b172`. properties 163개(Constant/public/private 3블록). **중요 한계**: 본
앱은 동적 필드 접근(`app.(sprintf('EDVSync%dFrame',fIdx))`, `app.(slotName)`)을
다수 사용해 **정적 usage-count가 신뢰 불가**(아래 FP 다수). 모든 "의심"은 동적
접근 재확인 후 판정.

## 핵심 발견

### 1. 정적 카운트 FP — 동적 필드 접근 (검토 결과: 정상)
- **EDVSync1Frame..EDVSync2DFPS (8개, count=1처럼 보임)**: L199-206 선언, 실제로는
  `app.(sprintf('EDVSync%dFrame',fIdx))`로 **set(L6495+) + read(L7273+, .Value L7306+)**
  모두 존재 → **완전 사용, dead 아님**. 정적 grep blind spot.
- **LastSliderUpdate / LastVideoUpdate (count=2)**: `throttleHit('LastSliderUpdate',...)`
  문자열로 `app.(slotName)` 동적 접근 → 사용됨. FP.
- 결론: count-기반 "미사용" 후보는 동적 접근 확인 시 대부분 정상.

### 2. EditDialogStatusLbl — 생성 후 미갱신 (Low, 진성 가능)
- L185 선언, L6241 생성(`'Text','준비'`). 이후 `EditDialogStatusLbl.` 접근 **0건** →
  상태 라벨이 항상 '준비' 고정, 어떤 동작에도 갱신되지 않음. 동적 접근(`app.(...)`)도 없음.
- 영향: 기능적 무해(표시만), UX상 status 미반영. **Low / 선택**.

### 3. Listener 등록·해제 짝
- **L8402 `altXLimListener`**: UI struct에 저장 + **L8377에서 재등록 전 delete** → 올바른 짝. ✓
- **L4595 `L = addlistener(ax,'XLim','PostSet',...)`**: 로컬 변수에만 보관. `addlistener`는
  source(ax) 수명에 묶이므로 ax 삭제 시 자동 해제 → 누수 아님. 단 **동일 ax 핸들을
  재사용하며 재등록 시 중복 listener 누적** 가능(plot rebuild가 ax를 재생성하면 무해).
  **Low / 모니터링** — rebuild 경로가 ax delete→recreate인지 1회 확인 권장.

### 4. Timer 핸들 등록/해제 짝 (양호)
| timer | set | stop | delete | 가드 |
|---|---|---|---|---|
| FlightPlayTimer{} | 1 | 3 | 3 | IsDeleting(onFlightPlayTimer) + ErrorFcn(#1) + early-stop(#3) |
| EditApplyTimer | 1 | 8 | 1 | IsDeleting(#2) + ErrorFcn(#1) + early-stop(#3) |
| AutosaveTimer | 1 | 4 | 2 | IsDeleting(#1) + ErrorFcn(#1) + early-stop(#3) |
| VideoDialogFollowTimer | 1 | 3 | 1 | stopVideoDialogFollowTimer + ErrorFcn(#1) |
- 직전 라운드(#1/#2/#3)로 ErrorFcn·IsDeleting 가드·early-stop 적용 완료 → 짝 정합 양호.

## callback 시그니처
- timer `TimerFcn @(~,~)` / `ErrorFcn @(~,evt)`, listener `@(~,~)`, uicontrol `@(src,evt)`/`@(~,~)`
  패턴 일관. 명백한 시그니처 불일치 미발견(샘플 점검 기준).

## 결론
- 진성 이슈는 **#2(EditDialogStatusLbl 미갱신, Low)** 1건 + **#3(L4595 중복 listener 가능성, Low/모니터링)**.
- 대량 "미사용/저빈도" 후보는 동적 필드 접근으로 인한 FP. 정적 xref 단독으론 본 코드베이스에서 한계가 큼 → 동적 접근 패턴(`app.(sprintf(...))`) 인지한 도구/수동 확인 필요.
