# FlightDataDashboard MATLAB GUI 구성 및 스타일 정적 분석

- 분석 대상 파일: `FlightDataDashboard(17).m`
- 분석 방식: MATLAB 실행 없이 소스 정적 분석
- 총 라인 수: 12,270 lines
- 핵심 판단: 이 파일은 classic `uicontrol(...)` 기반 GUI가 아니라 `uifigure`/`uigridlayout`/`uipanel`/`uibutton` 등 App Designer 계열 UI 컴포넌트를 직접 코드로 생성하는 구조입니다. 파일 내 `uicontrol(` 호출은 발견되지 않았습니다.

## 1. UI 객체 사용 현황

| 객체 타입 | 호출 수 | 용도 요약 |
|---|---:|---|
| `uifigure` | 4 | 메인 창, 비디오 플레이어 창, 설정/편집기 창, AVI 제어창 |
| `uigridlayout` | 49 | 전체 레이아웃, 헤더, 보드, 패널 내부 배치의 핵심 컨테이너 |
| `uipanel` | 29 | 보드/섹션/비디오/정보/플롯/스플리터/그룹 패널 |
| `uibutton` | 60 | 파일 선택, 패널 토글, 레이아웃 프리셋, 동기/저장/탭 조작 |
| `uilabel` | 75 | 상태 표시, 필드 제목, 현재시간, 안내 텍스트 |
| `uitable` | 5 | 현재 비행 정보, board-off 정보, 옵션/Export 테이블 |
| `uiaxes` | 6 | 지도, 고도, 자세 게이지, 비디오, 프레임 네비게이터/동적 plot |
| `uidropdown` | 7 | 레이아웃 프리셋, 비디오 해상도/캐시, 옵션 선택 |
| `uispinner` | 5 | 시간 입력, 동기 프레임/시간/FPS 입력 |
| `uitabgroup` | 4 | H plot 영역, board-off plot, 설정 편집기 탭 |
| `uitab` | 12 | plot tab 및 편집기 세부 탭 |
| `uieditfield` | 15 | 전역 sync 입력 및 설정 편집기 텍스트/숫자 입력 |
| `uitextarea` | 1 | Export progress log |
| `uicheckbox` | 6 | Project 옵션, plot/Export 옵션 |
| `uislider` | 1 | AVI frame navigator |
| `uicontextmenu` | 2 | 테이블 우클릭 plot 추가 메뉴 |
| `uimenu` | 2 | context menu 항목 |

## 2. 최상위 GUI 구조도

```text
app.UIFigure  [uifigure, main window]
└─ mainLayout [uigridlayout 2x1]
   ├─ Header bar [uipanel → glHeader uigridlayout 1x12]
   │  ├─ toolbar buttons: Flight1/Flight2 파일 선택, 해안선, 상단/하단 board off
   │  ├─ Layout preset picker [uipanel → preset buttons + dropdown]
   │  ├─ SyncInput [uieditfield]
   │  ├─ SyncBtn [uibutton]
   │  ├─ WindowMinBtn / WindowMaxBtn [uibutton]
   │  └─ 설정/편집 [uibutton → modeless edit dialog]
   └─ scrollBody [uipanel Scrollable on]
      └─ bodyGrid [uigridlayout 4x1]
         ├─ Flight Data 1 board [uipanel]
         ├─ BodyRowSplitter [uipanel, 4 px]
         ├─ Flight Data 2 board [uipanel]
         └─ board-off summary row [height 0 by default]
```

## 3. Flight board 내부 구조도

두 Flight board는 `for fIdx = 1:2` 루프에서 같은 구조로 생성됩니다.

```text
UI_temp(fIdx).panel  [uipanel Title='Flight Data 1/2']
└─ fGrid [uigridlayout 2x1, RowHeight={45,'1x'}]
   ├─ controlPanel [uipanel]
   │  └─ glCtrl [uigridlayout 1x11]
   │     ├─ 입력 시간 label + spinner
   │     ├─ 실시간 현재값 label
   │     ├─ fileNameLabel
   │     └─ panel toggle buttons: 자세/지도/고도/정보/plot/비디오
   └─ dataGrid [uigridlayout 1x8, Scrollable='on']
      ├─ Col1 panelAttitude [Pitch/Roll/Heading gauges]
      ├─ Col2/4/6 colSplitters [uipanel drag splitter]
      ├─ Col3 panelMapAlt
      │  ├─ panelMap [Map uiaxes]
      │  └─ panelAlt [Altitude uiaxes]
      ├─ Col5 panelInfo [uitable dataTable]
      ├─ Col7 panelDataView [uitabgroup plot tabs]
      └─ Col8 hiSplitter [legacy H↔I splitter; video는 별도 uifigure로 분리]
```

## 4. 비디오 및 편집 다이얼로그 구조

```text
Video Player - Flight Data N [uifigure, Visible off]
└─ viewerRoot [uigridlayout 1x1]
   └─ panelVideo [uipanel Title='Video Player']
      ├─ vBtnPnl: AVI 파일 열기, 크기 dropdown, 제어창 button, 동기 상태 label
      └─ vidContainer [uipanel, Scrollable on, black]
         └─ vidAxes [uiaxes, 720x512 pixel, black, axis off]

AVI 제어 - Flight Data N [uifigure]
├─ syncPnl: Frame/Time spinner + 동기 button
├─ Frame Navigator: label + slider + nav buttons + frame axes
└─ Hz/cache row: Video FPS/Data Hz spinner + cache dropdown

설정/프로젝트 편집기 [uifigure]
├─ status row: status/dirty/time labels
├─ tabs: Project, Files, Sync, Options, Plot Manager, Export
└─ bottom row: 적용, project 저장, 닫기
```

## 5. 중앙 Light Theme 정의

`getLightTheme()`에서 라이트 테마 색상과 폰트 기준값을 중앙 정의하고, 생성 후 `applyLightTheme(app.UIFigure)`로 후처리합니다.

| Theme key | 값 | 의미/비고 |
|---|---|---|
| `windowBg` | `[0.96 0.96 0.96]` | uifigure / dialog window |
| `surfaceBg` | `[1.00 1.00 1.00]` | panel surface (Editor-like) |
| `surfaceAltBg` | `[0.97 0.97 0.97]` | inactive button / striped row |
| `headerBg` | `[0.94 0.94 0.94]` | header / toolbar bar |
| `borderColor` | `[0.78 0.78 0.78]` |  |
| `gridLine` | `[0.85 0.85 0.85]` |  |
| `textPrimary` | `[0.10 0.10 0.10]` |  |
| `textSecondary` | `[0.35 0.35 0.35]` |  |
| `textMuted` | `[0.55 0.55 0.55]` |  |
| `accentBlue` | `[0.15 0.38 0.82]` |  |
| `accentBlueLite` | `[0.86 0.92 1.00]` |  |
| `accentBlueText` | `[0.05 0.15 0.32]` |  |
| `accentGreen` | `[0.06 0.65 0.50]` |  |
| `warningRed` | `[0.80 0.18 0.18]` |  |
| `successGreen` | `[0.06 0.45 0.22]` |  |
| `disabledBg` | `[0.90 0.90 0.90]` |  |
| `disabledFg` | `[0.45 0.45 0.45]` |  |
| `tableHeaderBg` | `[0.93 0.93 0.93]` |  |
| `tableRowBgA` | `[1.00 1.00 1.00]` |  |
| `tableRowBgB` | `[0.96 0.96 0.98]` |  |
| `axesBg` | `[1.00 1.00 1.00]` |  |
| `fontFamily` | `'Segoe UI'` |  |
| `fontFamilyMono` | `'Consolas'` |  |
| `fontSizeSmall` | `10` |  |
| `fontSizeBase` | `12` |  |
| `fontSizeLarge` | `14` |  |
| `btnActiveBg` | `t.accentBlue` | v4-L2: 활성 토글 = 파란색 accent (red 아님) |
| `btnActiveFg` | `t.textInverse` |  |
| `btnAccentBg` | `t.accentBlueLite` |  |
| `btnAccentFg` | `t.accentBlueText` |  |
| `btnNormalBg` | `t.surfaceAltBg` |  |
| `btnNormalFg` | `t.textPrimary` |  |
| `btnDisabledBg` | `t.disabledBg` |  |
| `btnDisabledFg` | `t.disabledFg` |  |
| `btnWarningBg` | `t.warningRed` | 명시적 경고/위험 액션 전용 |
| `btnWarningFg` | `t.textInverse` |  |

### Theme 후처리 규칙 요약

| 대상 | 후처리 기준 | 적용 스타일 |
|---|---|---|
| `uifigure` / dialog root | `Color` 또는 `BackgroundColor` 속성 존재 | `windowBg = [0.96 0.96 0.96]`
| `uipanel` | 어두운 배경이면 | `surfaceBg = [1 1 1]`로 보정
| `uigridlayout` | 어두운 배경이면 | `surfaceBg = [1 1 1]`로 보정
| `uibutton` | 어두운 배경/밝은 글자 조합 보정 | normal/active/accent/disabled 상태별 색상 적용
| `uilabel` | 밝은 배경 위 흰 글자 | `textPrimary = [0.10 0.10 0.10]`로 보정
| `uitable` | 채도 높은/어두운 배경 | 흰색 테이블 + dark text로 보정
| `uiaxes` | 어두운 축 배경, video 축 제외 | white axes + gray axis/grid 색상
| 입력류 | dropdown/edit/spinner/textarea/checkbox | 밝은 배경 + dark text 보정
| `uitab` | 어두운 배경/밝은 글자 | 밝은 배경 + dark text 보정
| `uipanel` title | light bg + title 존재 | `ForegroundColor = [0 0 0]`

## 6. 주요 객체별 스타일 요약

| 객체/핸들 | 타입 | 라인 | 주요 스타일 속성 |
|---|---|---:|---|
| `app.UIFigure` | `uifigure` | 260 | Name='비행 데이터 리뷰 대시보드 (Dual)'<br>Color=[0.94 0.94 0.96]<br>Position=app.NormalWindowPosition |
| `fig` | `uifigure` | 5656 | Name='설정/프로젝트 편집기'<br>Position=pos |
| `app.EditDialogStatusLbl` | `uilabel` | 5671 | Text='준비'<br>FontSize=12); |
| `app.EDOptReqTable` | `uitable` | 5977 | 기본값/테마 후처리 |
| `app.EDOptDspTable` | `uitable` | 5983 | 기본값/테마 후처리 |
| `app.EDExpFileTable` | `uitable` | 6118 | 기본값/테마 후처리 |
| `dlg` | `uifigure` | 8443 | Name=sprintf('AVI 제어 - Flight Data %d'<br>Color=[0.94 0.94 0.96]<br>Position=[120<br>Visible='off' |
| `pnl` | `uipanel` | 10425 | Title=sprintf('Flight Data %d - Board Off Summary'<br>BackgroundColor=[0.98 0.98 0.98]<br>FontSize=14<br>FontWeight='bold'<br>Visible='off'); |
| `infoPanel` | `uipanel` | 10437 | Title='현재 비행 정보'<br>BackgroundColor='w'<br>FontSize=13<br>FontWeight='bold'<br>Scrollable='on'); |
| `tbl` | `uitable` | 10443 | BackgroundColor=tblBgColor<br>FontSize=11<br>FontName='Consolas');<br>ForegroundColor=themeT.textPrimary<br>FontWeight='bold'<br>ColumnWidth={'26x' |
| `plotPanel` | `uipanel` | 10452 | Title='plot 데이터'<br>BackgroundColor='w');<br>FontSize=13<br>FontWeight='bold' |
| `mainLayout` | `uigridlayout` | 10486 | 기본값/테마 후처리 |
| `scrollBody` | `uipanel` | 10495 | BackgroundColor=[0.94 0.94 0.96]);<br>BorderType='none'<br>Scrollable='on' |
| `bodyGrid` | `uigridlayout` | 10496 | 기본값/테마 후처리 |
| `app.BodyRowSplitter` | `uipanel` | 10502 | BackgroundColor=[0.55 0.55 0.58]<br>BorderType='none'); |
| `UI_temp(fIdx).panel` | `uipanel` | 10546 | Title=titleStrs{fIdx}<br>BackgroundColor=panelColors{fIdx});<br>FontSize=14<br>FontWeight='bold' |
| `controlPanel` | `uipanel` | 10555 | BackgroundColor='w'<br>BorderType='line'); |
| `glCtrl` | `uigridlayout` | 10557 | 기본값/테마 후처리 |
| `UI_temp(fIdx).spinner` | `uispinner` | 10563 | FontSize=13<br>Enable='off'<br>ValueDisplayFormat='%.3f' |
| `UI_temp(fIdx).currentTimeLabel` | `uilabel` | 10566 | Text='0.000 s'<br>FontSize=13<br>FontColor=[0.8 0.1 0.1]);<br>FontWeight='bold' |
| `UI_temp(fIdx).fileNameLabel` | `uilabel` | 10567 | Text='파일 없음'<br>FontSize=11<br>FontColor=[0.2 0.2 0.2]<br>FontWeight='bold'); |
| `UI_temp(fIdx).dataGrid` | `uigridlayout` | 10589 | 기본값/테마 후처리 |
| `UI_temp(fIdx).panelAttitude` | `uipanel` | 10606 | Title='비행 자세'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| `UI_temp(fIdx).panelMapAlt` | `uipanel` | 10620 | BackgroundColor=panelColors{fIdx});<br>BorderType='none' |
| `mapPnl` | `uipanel` | 10628 | Title='Map'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| `UI_temp(fIdx).mapAxes` | `uiaxes` | 10630 | 기본값/테마 후처리 |
| `altPnl` | `uipanel` | 10641 | Title='Altitude'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| `UI_temp(fIdx).altAxes` | `uiaxes` | 10645 | 기본값/테마 후처리 |
| `infoPanel` | `uipanel` | 10658 | Title='현재 비행 정보'<br>BackgroundColor='w'<br>FontSize=13<br>FontWeight='bold'<br>Scrollable='on'); |
| `UI_temp(fIdx).dataTable` | `uitable` | 10664 | BackgroundColor=tblBgColor<br>FontSize=11<br>FontName='Consolas');<br>ForegroundColor=themeT.textPrimary<br>FontWeight='bold'<br>ColumnWidth={'29x' |
| `hPnl` | `uipanel` | 10673 | Title='plot 데이터'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| `UI_temp(fIdx).hiSplitter` | `uipanel` | 10702 | BackgroundColor=[0.75 0.75 0.80]<br>BorderType='line'<br>BorderColor=[0.45 0.45 0.55] |
| `UI_temp(fIdx).vidViewerDialog` | `uifigure` | 10710 | Name=sprintf('Video Player - Flight Data %d'<br>Color=[0.94 0.94 0.96]<br>Position=[120<br>Visible='off' |
| `UI_temp(fIdx).panelVideo` | `uipanel` | 10723 | Title='Video Player'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| `vBtnPnl` | `uipanel` | 10733 | BackgroundColor='w');<br>BorderType='none' |
| `UI_temp(fIdx).vidResolutionDropdown` | `uidropdown` | 10740 | FontSize=11<br>Items={'320x240' |
| `UI_temp(fIdx).vidControlBtn` | `uibutton` | 10744 | Text='제어창'<br>FontSize=11 |
| `UI_temp(fIdx).vidSyncStatus` | `uilabel` | 10746 | Text='동기 미설정'<br>FontSize=11<br>FontColor=[0.5 0.5 0.5]<br>HorizontalAlignment='right'); |
| `UI_temp(fIdx).vidContainer` | `uipanel` | 10751 | BackgroundColor=[0 0 0]);<br>BorderType='none'<br>Scrollable='on' |
| `UI_temp(fIdx).vidAxes` | `uiaxes` | 10754 | Position=[0 0 720 512]); |
| `hHeaderPanel` | `uipanel` | 10953 | BackgroundColor=[0.94 0.94 0.94]<br>BorderType='line'); |
| `pnl` | `uipanel` | 10991 | Title='Layout'<br>BackgroundColor=[0.94 0.94 0.94]<br>FontSize=9<br>FontWeight='bold'); |

## 7. 직접 스타일 대입 목록

생성자 인자 외에 코드에서 `.BackgroundColor`, `.FontColor`, `.Color` 등으로 직접 변경하는 항목입니다.

| 라인 | 객체 | 속성 | 값 |
|---:|---|---|---|
| 2665 | `app.UI(fIdx).vidSyncBtn` | `BackgroundColor` | `[0.58 0.0 0.83]` |
| 2669 | `app.UI(fIdx).vidSyncStatus` | `FontColor` | `[0.5 0.5 0.5]` |
| 2733 | `app.UI(fIdx).vidSyncBtn` | `BackgroundColor` | `[0.8 0.2 0.2]` |
| 2735 | `app.UI(fIdx).vidSyncStatus` | `FontColor` | `[0.06 0.65 0.50]` |
| 5756 | `app.EditDialogDirtyLbl` | `FontColor` | `[0.8 0.2 0.2]` |
| 5759 | `app.EditDialogDirtyLbl` | `FontColor` | `[0.4 0.4 0.4]` |
| 6350 | `app.EDExpMissingLbl` | `FontColor` | `[0.06 0.45 0.22]` |
| 6352 | `app.EDExpMissingLbl` | `FontColor` | `[0.75 0.20 0.20]` |
| 8320 | `app.UI(fIdx).vidContainer` | `BackgroundColor` | `[0 0 0]` |
| 8324 | `app.UI(fIdx).vidAxes` | `Color` | `[0 0 0]` |
| 8325 | `app.UI(fIdx).vidAxes` | `XColor` | `'none'` |
| 8326 | `app.UI(fIdx).vidAxes` | `YColor` | `'none'` |
| 9267 | `h` | `FontSize` | `fontSz` |
| 9280 | `h` | `FontSize` | `valueFontSz` |
| 9658 | `btn` | `BackgroundColor` | `t.btnActiveBg` |
| 9659 | `btn` | `FontColor` | `t.btnActiveFg` |
| 9661 | `btn` | `BackgroundColor` | `t.btnNormalBg` |
| 9662 | `btn` | `FontColor` | `t.btnNormalFg` |
| 10100 | `p` | `ForegroundColor` | `[0 0 0]` |
| 10161 | `root` | `Color` | `t.windowBg` |
| 10162 | `root` | `BackgroundColor` | `t.windowBg` |
| 10189 | `p` | `BackgroundColor` | `t.surfaceBg` |
| 10195 | `p` | `BorderColor` | `t.borderColor` |
| 10209 | `g` | `BackgroundColor` | `t.surfaceBg` |
| 10232 | `b` | `BackgroundColor` | `t.btnNormalBg` |
| 10241 | `b` | `FontColor` | `t.btnNormalFg` |
| 10267 | `lb` | `FontColor` | `t.textPrimary` |
| 10291 | `tb` | `BackgroundColor` | `t.tableRowBgA` |
| 10297 | `tb` | `ForegroundColor` | `t.textPrimary` |
| 10326 | `ax` | `Color` | `t.axesBg` |
| 10332 | `ax` | `XColor` | `t.textSecondary` |
| 10338 | `ax` | `YColor` | `t.textSecondary` |
| 10342 | `ax` | `GridColor` | `t.gridLine` |
| 10369 | `c` | `BackgroundColor` | `t.surfaceBg` |
| 10375 | `c` | `FontColor` | `t.textPrimary` |
| 10404 | `tb` | `BackgroundColor` | `t.surfaceBg` |
| 10410 | `tb` | `ForegroundColor` | `t.textPrimary` |
| 10756 | `UI_temp(fIdx).vidAxes` | `Color` | `[0 0 0]` |
| 10757 | `UI_temp(fIdx).vidAxes` | `XColor` | `'none'` |
| 10758 | `UI_temp(fIdx).vidAxes` | `YColor` | `'none'` |
| 10925 | `btn` | `FontSize` | `t.fontSizeSmall` |
| 10926 | `btn` | `FontWeight` | `'bold'` |
| 10933 | `btn` | `BackgroundColor` | `t.btnActiveBg` |
| 10934 | `btn` | `FontColor` | `t.btnActiveFg` |
| 10936 | `btn` | `BackgroundColor` | `t.btnAccentBg` |
| 10937 | `btn` | `FontColor` | `t.btnAccentFg` |
| 10939 | `btn` | `BackgroundColor` | `t.btnDisabledBg` |
| 10940 | `btn` | `FontColor` | `t.btnDisabledFg` |
| 10942 | `btn` | `BackgroundColor` | `t.btnNormalBg` |
| 10943 | `btn` | `FontColor` | `t.btnNormalFg` |
| 12048 | `app.UI(fIdx).vidSyncBtn` | `BackgroundColor` | `[0.8 0.2 0.2]` |
| 12054 | `app.UI(fIdx).vidSyncStatus` | `FontColor` | `[0.0 0.5 0.0]` |
| 12084 | `app.UI(fIdx).vidSyncStatus` | `FontColor` | `[0.0 0.5 0.0]` |
| 12087 | `app.UI(fIdx).vidSyncStatus` | `FontColor` | `[0.5 0.5 0.5]` |

## 8. 전체 생성자 스타일 인벤토리

아래 표는 생성자 인자에 스타일/배치 관련 속성이 들어간 UI 객체를 요약한 것입니다. 반복 생성되는 `Flight Data 1/2` 객체는 `fIdx` 루프 기준으로 2회 생성됩니다.

| 라인 | 타입 | 핸들/변수 | 색상/폰트/배치 속성 |
|---:|---|---|---|
| 260 | `uifigure` | `app.UIFigure` | Name='비행 데이터 리뷰 대시보드 (Dual)'<br>Color=[0.94 0.94 0.96]<br>Position=app.NormalWindowPosition |
| 3810 | `uigridlayout` | `plotLayout` | Scrollable='on');<br>ColumnWidth={'1x'}<br>RowHeight={}<br>Padding=[5 5 5 5]<br>RowSpacing=5 |
| 4005 | `uipanel` | `p` | BackgroundColor='w');<br>BorderType='line' |
| 5656 | `uifigure` | `fig` | Name='설정/프로젝트 편집기'<br>Position=pos |
| 5671 | `uilabel` | `app.EditDialogStatusLbl` | Text='준비'<br>FontSize=12); |
| 5672 | `uilabel` | `app.EditDialogDirtyLbl` | Text='변경 없음'<br>FontSize=12<br>FontColor=[0.4 0.4 0.4]);<br>HorizontalAlignment='right' |
| 5674 | `uilabel` | `app.EditDialogTimeLbl` | Text=''<br>FontSize=11<br>FontColor=[0.4 0.4 0.4]);<br>HorizontalAlignment='right' |
| 5810 | `uilabel` | `(anonymous)` | Text='Project 파일:'<br>FontWeight='bold'); |
| 5811 | `uilabel` | `app.EDProjectPathLbl` | Text='(없음)'<br>FontColor=[0.3 0.3 0.7]); |
| 5818 | `uilabel` | `(anonymous)` | Text='저장:'<br>FontWeight='bold'); |
| 5819 | `uilabel` | `app.EDProjectStatusLbl` | Text='미저장'<br>FontColor=[0.4 0.4 0.4]); |
| 5826 | `uilabel` | `(anonymous)` | Text='자동 저장:'<br>FontWeight='bold'); |
| 5827 | `uicheckbox` | `app.EDProjectAutosaveCB` | Text=sprintf('%d초 간격 snapshot' |
| 5832 | `uilabel` | `(anonymous)` | Text='종료 확인:'<br>FontWeight='bold'); |
| 5833 | `uicheckbox` | `app.EDProjectConfirmCloseCB` | Text='종료 전 저장 확인' |
| 5838 | `uilabel` | `(anonymous)` | Text='마지막 저장:'<br>FontWeight='bold'); |
| 5839 | `uilabel` | `app.EDProjectLastSaveLbl` | Text='(없음)'<br>FontColor=[0.3 0.3 0.7]); |
| 5842 | `uilabel` | `(anonymous)` | Text='Layout preset:'<br>FontWeight='bold'); |
| 5843 | `uilabel` | `app.EDProjectLayoutLbl` | Text='0개 / custom'<br>FontColor=[0.3 0.3 0.7]); |
| 5849 | `uilabel` | `(anonymous)` | Text='저장된 preset:'<br>FontWeight='bold'); |
| 5850 | `uidropdown` | `app.EDProjectLayoutPresetDD` | Items={'(없음)'} |
| 5864 | `uilabel` | `head` | Text=sprintf('=== Flight %d ==='<br>FontWeight='bold'); |
| 5869 | `uilabel` | `(anonymous)` | Text=[pairs{k}{2} ':']<br>FontWeight='bold'); |
| 5870 | `uilabel` | `lbl` | Text='(없음)'<br>FontColor=[0.3 0.3 0.7]); |
| 5879 | `uibutton` | `(anonymous)` | Text='Export everything to folder'<br>BackgroundColor=[0.06 0.65 0.50]<br>FontColor='w'<br>FontWeight='bold' |
| 5891 | `uilabel` | `lbl` | Text='== Flight 1 ↔ Flight 2 비행시간 sync =='<br>FontWeight='bold'); |
| 5895 | `uieditfield` | `app.EDSyncF1Time` | 기본값/테마 후처리 |
| 5899 | `uieditfield` | `app.EDSyncF2Time` | 기본값/테마 후처리 |
| 5910 | `uilabel` | `app.EDSyncOffsetLbl` | Text='Offset (t2 - t1): 0.000 s'<br>FontColor=[0.3 0.3 0.7]<br>FontWeight='bold'); |
| 5915 | `uilabel` | `lbl` | Text=sprintf('== Flight %d AVI sync =='<br>FontWeight='bold'); |
| 5953 | `uilabel` | `(anonymous)` | Text='Flight:'<br>FontWeight='bold'); |
| 5954 | `uidropdown` | `app.EDOptFlightDD` | Items={'Flight 1' |
| 5977 | `uitable` | `app.EDOptReqTable` | 기본값/테마 후처리 |
| 5983 | `uitable` | `app.EDOptDspTable` | 기본값/테마 후처리 |
| 5992 | `uibutton` | `(anonymous)` | Text='적용 (즉시 반영)'<br>BackgroundColor=[0.15 0.38 0.82]<br>FontColor='w'<br>FontWeight='bold' |
| 6011 | `uilabel` | `(anonymous)` | Text='Flight:'<br>FontWeight='bold'); |
| 6012 | `uidropdown` | `app.EDPlotFlightDD` | Items={'Flight 1' |
| 6032 | `uipanel` | `propPanel` | Title='선택 항목 속성'<br>FontWeight='bold'<br>Scrollable='on'); |
| 6040 | `uieditfield` | `app.EDPlotNameEdit` | 기본값/테마 후처리 |
| 6043 | `uidropdown` | `app.EDPlotYColDD` | Items={'(선택)'} |
| 6045 | `uieditfield` | `app.EDPlotYLabelEdit` | 기본값/테마 후처리 |
| 6048 | `uicheckbox` | `app.EDPlotXAutoCB` | Text='XLimMode = auto' |
| 6051 | `uieditfield` | `app.EDPlotXMin` | 기본값/테마 후처리 |
| 6053 | `uieditfield` | `app.EDPlotXMax` | 기본값/테마 후처리 |
| 6055 | `uicheckbox` | `app.EDPlotYAutoCB` | Text='YLimMode = auto' |
| 6058 | `uieditfield` | `app.EDPlotYMin` | Enable='off'); |
| 6060 | `uieditfield` | `app.EDPlotYMax` | Enable='off'); |
| 6062 | `uieditfield` | `app.EDPlotHeight` | 기본값/테마 후처리 |
| 6066 | `uibutton` | `(anonymous)` | Text='적용'<br>BackgroundColor=[0.15 0.38 0.82]<br>FontColor='w'<br>FontWeight='bold' |
| 6077 | `uibutton` | `(anonymous)` | Text='삭제(plot)'<br>BackgroundColor=[0.75 0.20 0.20]<br>FontColor='w' |
| 6085 | `uilabel` | `(anonymous)` | Text='LinkXWithinTab:'<br>FontWeight='bold'); |
| 6086 | `uicheckbox` | `app.EDPlotLinkCB` | Text='선택된 tab의 X축 link' |
| 6098 | `uilabel` | `(anonymous)` | Text='Export parent 폴더:'<br>FontWeight='bold'); |
| 6099 | `uieditfield` | `app.EDExpParentEdit` | 기본값/테마 후처리 |
| 6103 | `uilabel` | `(anonymous)` | Text='생성될 폴더:'<br>FontWeight='bold'); |
| 6104 | `uilabel` | `app.EDExpPreviewLbl` | Text='(자동 생성)'<br>FontColor=[0.3 0.3 0.7]); |
| 6107 | `uilabel` | `(anonymous)` | Text='SHA256 검증:'<br>FontWeight='bold'); |
| 6108 | `uicheckbox` | `app.EDExpHashCB` | Text='느림. 기본 off' |
| 6113 | `uibutton` | `(anonymous)` | Text='Export everything to folder'<br>BackgroundColor=[0.06 0.65 0.50]<br>FontColor='w'<br>FontWeight='bold' |
| 6118 | `uitable` | `app.EDExpFileTable` | ColumnName={'Role' |
| 6124 | `uilabel` | `(anonymous)` | Text='누락/요약:'<br>FontWeight='bold'); |
| 6125 | `uilabel` | `app.EDExpMissingLbl` | Text='파일 0개'<br>FontColor=[0.3 0.3 0.7]); |
| 6128 | `uilabel` | `(anonymous)` | Text='Progress log:'<br>FontWeight='bold'); |
| 6129 | `uitextarea` | `app.EDExpLogArea` | 기본값/테마 후처리 |
| 8443 | `uifigure` | `dlg` | Name=sprintf('AVI 제어 - Flight Data %d'<br>Color=[0.94 0.94 0.96]<br>Position=[120<br>Visible='off' |
| 8452 | `uipanel` | `syncPnl` | Title='동기 설정'<br>BackgroundColor='w'<br>FontSize=ctrlSmallFont); |
| 8456 | `uilabel` | `(anonymous)` | Text='Frame:'<br>FontSize=ctrlFont<br>FontWeight='bold'); |
| 8457 | `uispinner` | `ctrl.vidSyncFrameInput` | Text='Time(s):'<br>FontSize=ctrlFont);<br>FontWeight='bold');<br>ValueDisplayFormat='%d' |
| 8459 | `uilabel` | `(anonymous)` | Text='Time(s):'<br>FontSize=ctrlFont<br>FontWeight='bold'); |
| 8460 | `uispinner` | `ctrl.vidSyncTimeInput` | Text='');<br>FontSize=ctrlFont);<br>ValueDisplayFormat='%.3f' |
| 8463 | `uibutton` | `ctrl.vidSyncBtn` | Text='동기'<br>BackgroundColor=[0.58 0.0 0.83]<br>FontSize=ctrlFont<br>FontColor='w'<br>FontWeight='bold' |
| 8468 | `uipanel` | `vdubGroupPnl` | Title='Frame Navigator'<br>BackgroundColor=[0.97 0.97 0.99]<br>FontSize=ctrlSmallFont<br>ForegroundColor=[0.1 0.2 0.5]);<br>FontWeight='bold'<br>BorderType='line' |
| 8476 | `uilabel` | `ctrl.vidVdubLabel` | Text='Frame 1 / 1  (00:00:00.000)'<br>FontSize=ctrlFont<br>FontName='Consolas'<br>FontColor=[0.1 0.2 0.5]<br>FontWeight='bold'<br>HorizontalAlignment='center'); |
| 8481 | `uislider` | `ctrl.vidVdubSlider` | 기본값/테마 후처리 |
| 8487 | `uipanel` | `navPnl` | BackgroundColor=[0.97 0.97 0.99]);<br>BorderType='none' |
| 8491 | `uibutton` | `(anonymous)` | Text='◄◄'<br>FontSize=ctrlFont<br>FontWeight='bold' |
| 8494 | `uibutton` | `(anonymous)` | Text='◄'<br>FontSize=ctrlFont<br>FontWeight='bold' |
| 8497 | `uibutton` | `(anonymous)` | Text='►'<br>FontSize=ctrlFont<br>FontWeight='bold' |
| 8500 | `uibutton` | `(anonymous)` | Text='►►'<br>FontSize=ctrlFont<br>FontWeight='bold' |
| 8504 | `uipanel` | `hzPnl` | BackgroundColor='w'<br>BorderType='line'); |
| 8508 | `uilabel` | `(anonymous)` | Text='Video FPS:'<br>FontSize=ctrlSmallFont<br>FontWeight='bold'); |
| 8509 | `uibutton` | `(anonymous)` | Text='◄'<br>FontSize=ctrlSmallFont |
| 8511 | `uispinner` | `ctrl.vidVideoFpsInput` | FontSize=ctrlSmallFont<br>ValueDisplayFormat='%d' |
| 8514 | `uibutton` | `(anonymous)` | Text='►'<br>FontSize=ctrlSmallFont |
| 8517 | `uilabel` | `(anonymous)` | Text='Data Hz:'<br>FontSize=ctrlSmallFont<br>FontWeight='bold'); |
| 8518 | `uibutton` | `(anonymous)` | Text='◄'<br>FontSize=ctrlSmallFont |
| 8520 | `uispinner` | `ctrl.vidDataFpsInput` | FontSize=ctrlSmallFont<br>ValueDisplayFormat='%d' |
| 8523 | `uibutton` | `(anonymous)` | Text='►'<br>FontSize=ctrlSmallFont |
| 8526 | `uilabel` | `(anonymous)` | Text='Cache:'<br>FontSize=ctrlSmallFont<br>FontWeight='bold'); |
| 8527 | `uidropdown` | `ctrl.vidCacheBudget` | FontSize=ctrlSmallFont<br>Items={'30 MB' |
| 9794 | `uigridlayout` | `plotLayout` | Scrollable='on');<br>ColumnWidth={'1x'}<br>RowHeight={}<br>Padding=[5 5 5 5]<br>RowSpacing=5 |
| 9811 | `uilabel` | `(anonymous)` | Text='표시할 plot 없음'<br>FontColor=[0.45 0.45 0.45]<br>FontWeight='bold');<br>HorizontalAlignment='center' |
| 9832 | `uipanel` | `p` | BackgroundColor='w');<br>BorderType='line' |
| 9913 | `uilabel` | `(anonymous)` | Text='표시할 plot 없음'<br>FontColor=[0.45 0.45 0.45]<br>FontWeight='bold');<br>HorizontalAlignment='center' |
| 10425 | `uipanel` | `pnl` | Title=sprintf('Flight Data %d - Board Off Summary'<br>BackgroundColor=[0.98 0.98 0.98]<br>FontSize=14<br>FontWeight='bold'<br>Visible='off'); |
| 10437 | `uipanel` | `infoPanel` | Title='현재 비행 정보'<br>BackgroundColor='w'<br>FontSize=13<br>FontWeight='bold'<br>Scrollable='on'); |
| 10443 | `uitable` | `tbl` | BackgroundColor=tblBgColor<br>FontSize=11<br>FontName='Consolas');<br>ForegroundColor=themeT.textPrimary<br>FontWeight='bold'<br>ColumnWidth={'26x'<br>RowStriping='off'<br>ColumnName={'항목' |
| 10452 | `uipanel` | `plotPanel` | Title='plot 데이터'<br>BackgroundColor='w');<br>FontSize=13<br>FontWeight='bold' |
| 10475 | `uilabel` | `(anonymous)` | Text='표시할 plot 없음'<br>FontColor=[0.45 0.45 0.45]<br>FontWeight='bold');<br>HorizontalAlignment='center' |
| 10486 | `uigridlayout` | `mainLayout` | 기본값/테마 후처리 |
| 10495 | `uipanel` | `scrollBody` | BackgroundColor=[0.94 0.94 0.96]);<br>BorderType='none'<br>Scrollable='on' |
| 10496 | `uigridlayout` | `bodyGrid` | 기본값/테마 후처리 |
| 10502 | `uipanel` | `app.BodyRowSplitter` | BackgroundColor=[0.55 0.55 0.58]<br>BorderType='none'); |
| 10546 | `uipanel` | `UI_temp(fIdx).panel` | Title=titleStrs{fIdx}<br>BackgroundColor=panelColors{fIdx});<br>FontSize=14<br>FontWeight='bold' |
| 10555 | `uipanel` | `controlPanel` | BackgroundColor='w'<br>BorderType='line'); |
| 10557 | `uigridlayout` | `glCtrl` | 기본값/테마 후처리 |
| 10562 | `uilabel` | `(anonymous)` | Text='입력 시간(s):'<br>FontSize=12);<br>FontWeight='bold' |
| 10563 | `uispinner` | `UI_temp(fIdx).spinner` | FontSize=13<br>Enable='off'<br>ValueDisplayFormat='%.3f' |
| 10565 | `uilabel` | `(anonymous)` | Text='실시간 현재값:'<br>FontSize=12);<br>FontWeight='bold' |
| 10566 | `uilabel` | `UI_temp(fIdx).currentTimeLabel` | Text='0.000 s'<br>FontSize=13<br>FontColor=[0.8 0.1 0.1]);<br>FontWeight='bold' |
| 10567 | `uilabel` | `UI_temp(fIdx).fileNameLabel` | Text='파일 없음'<br>FontSize=11<br>FontColor=[0.2 0.2 0.2]<br>FontWeight='bold'); |
| 10569 | `uibutton` | `UI_temp(fIdx).btnAtt` | Text='자세 ▸' |
| 10572 | `uibutton` | `UI_temp(fIdx).btnMap` | Text='지도 ▸' |
| 10574 | `uibutton` | `UI_temp(fIdx).btnAlt` | Text='고도 ▸' |
| 10576 | `uibutton` | `UI_temp(fIdx).btnInfo` | Text='정보 ▾' |
| 10578 | `uibutton` | `UI_temp(fIdx).btnDataView` | Text='plot ▾' |
| 10580 | `uibutton` | `UI_temp(fIdx).btnVid` | Text='비디오 ▸' |
| 10589 | `uigridlayout` | `UI_temp(fIdx).dataGrid` | 기본값/테마 후처리 |
| 10599 | `uipanel` | `sp` | BackgroundColor=[0.50 0.50 0.54]<br>BorderType='none'); |
| 10606 | `uipanel` | `UI_temp(fIdx).panelAttitude` | Title='비행 자세'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| 10620 | `uipanel` | `UI_temp(fIdx).panelMapAlt` | BackgroundColor=panelColors{fIdx});<br>BorderType='none' |
| 10628 | `uipanel` | `mapPnl` | Title='Map'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| 10630 | `uiaxes` | `UI_temp(fIdx).mapAxes` | 기본값/테마 후처리 |
| 10641 | `uipanel` | `altPnl` | Title='Altitude'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| 10645 | `uiaxes` | `UI_temp(fIdx).altAxes` | 기본값/테마 후처리 |
| 10658 | `uipanel` | `infoPanel` | Title='현재 비행 정보'<br>BackgroundColor='w'<br>FontSize=13<br>FontWeight='bold'<br>Scrollable='on'); |
| 10664 | `uitable` | `UI_temp(fIdx).dataTable` | BackgroundColor=tblBgColor<br>FontSize=11<br>FontName='Consolas');<br>ForegroundColor=themeT.textPrimary<br>FontWeight='bold'<br>ColumnWidth={'29x'<br>RowStriping='off'<br>ColumnName={'항목' |
| 10673 | `uipanel` | `hPnl` | Title='plot 데이터'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| 10680 | `uipanel` | `btnPnl` | BackgroundColor='w');<br>BorderType='none' |
| 10681 | `uibutton` | `(anonymous)` | Text='+ 빈 탭 추가'<br>Position=[5 5 90 22] |
| 10682 | `uibutton` | `(anonymous)` | Text='현재 탭 지우기'<br>Position=[100 5 100 22] |
| 10684 | `uitabgroup` | `UI_temp(fIdx).tabGroup` | 기본값/테마 후처리 |
| 10702 | `uipanel` | `UI_temp(fIdx).hiSplitter` | BackgroundColor=[0.75 0.75 0.80]<br>BorderType='line'<br>BorderColor=[0.45 0.45 0.55] |
| 10710 | `uifigure` | `UI_temp(fIdx).vidViewerDialog` | Name=sprintf('Video Player - Flight Data %d'<br>Color=[0.94 0.94 0.96]<br>Position=[120<br>Visible='off' |
| 10721 | `uigridlayout` | `viewerRoot` | ColumnWidth={'1x'});<br>RowHeight={'1x'}<br>Padding=[2 2 2 2] |
| 10723 | `uipanel` | `UI_temp(fIdx).panelVideo` | Title='Video Player'<br>BackgroundColor='w');<br>FontSize=12<br>FontWeight='bold' |
| 10733 | `uipanel` | `vBtnPnl` | BackgroundColor='w');<br>BorderType='none' |
| 10738 | `uibutton` | `(anonymous)` | Text='AVI 파일 열기'<br>FontSize=11 |
| 10739 | `uilabel` | `(anonymous)` | Text='크기:'<br>FontSize=11<br>FontWeight='bold'); |
| 10740 | `uidropdown` | `UI_temp(fIdx).vidResolutionDropdown` | FontSize=11<br>Items={'320x240' |
| 10744 | `uibutton` | `UI_temp(fIdx).vidControlBtn` | Text='제어창'<br>FontSize=11 |
| 10746 | `uilabel` | `UI_temp(fIdx).vidSyncStatus` | Text='동기 미설정'<br>FontSize=11<br>FontColor=[0.5 0.5 0.5]<br>HorizontalAlignment='right'); |
| 10751 | `uipanel` | `UI_temp(fIdx).vidContainer` | BackgroundColor=[0 0 0]);<br>BorderType='none'<br>Scrollable='on' |
| 10754 | `uiaxes` | `UI_temp(fIdx).vidAxes` | Position=[0 0 720 512]); |
| 10906 | `uibutton` | `btn` | Text=app.toolbarButtonText(iconText<br>FontSize=10<br>FontWeight='bold'); |
| 10953 | `uipanel` | `hHeaderPanel` | BackgroundColor=[0.94 0.94 0.94]<br>BorderType='line'); |
| 10969 | `uieditfield` | `app.SyncInput` | FontSize=13);<br>Enable='off' |
| 10991 | `uipanel` | `pnl` | Title='Layout'<br>BackgroundColor=[0.94 0.94 0.94]<br>FontSize=9<br>FontWeight='bold'); |
| 11002 | `uibutton` | `btn` | Text=icons{k}<br>FontSize=13<br>FontWeight='bold' |
| 11010 | `uidropdown` | `app.HeaderLayoutPresetDD` | FontSize=10<br>Items={'사용자 프리셋'} |
| 11066 | `uilabel` | `lbl` | Text=[titleStr ' +0.000']<br>FontSize=12<br>FontWeight='bold'<br>HorizontalAlignment='center'); |
| 11067 | `uipanel` | `axPnl` | BackgroundColor='w');<br>BorderType='none' |

## 9. 스타일 관점의 핵심 관찰

1. **중앙 테마 정의는 존재하지만 완전 일관 적용은 아님.** `getLightTheme()`에 라이트 테마가 집중되어 있으나, 일부 생성자는 직접 RGB 색상과 폰트 크기를 지정합니다. 따라서 후속 유지보수 시 중앙 테마 상수로 흡수할 여지가 있습니다.
2. **폰트 종류는 테이블 중심으로 명시됩니다.** 전체 기본 폰트는 theme에서 `Segoe UI`, monospace는 `Consolas`로 정의되며, 데이터 테이블은 `FontName='Consolas'`가 명시되어 있습니다.
3. **폰트 크기 체계는 10/11/12/13/14가 혼재합니다.** theme 기준은 small=10, base=12, large=14이나, 컨트롤바/비디오/편집기에서 11·13이 직접 지정됩니다.
4. **어두운 배경은 비디오 영역에 집중됩니다.** `vidContainer`와 `vidAxes`는 `[0 0 0]`로 유지되고, theme 축 후처리에서 video 관련 축은 제외됩니다.
5. **스플리터는 uipanel로 구현됩니다.** row/column/H↔I splitter는 `uipanel` 배경색과 `ButtonDownFcn`으로 드래그 가능한 핸들처럼 사용됩니다.
6. **Board-off summary와 H plot 영역은 별도 tabgroup 구조를 공유합니다.** 기본 빈 탭과 `표시할 plot 없음` 라벨을 두고, 동적으로 plot panel/uiaxes를 추가하는 방식입니다.

## 10. 개선 권장사항

- `FontSize=11/13`, `[0.94 0.94 0.96]`, `[0.98 0.98 0.98]`, splitter 색상 등 직접 RGB/폰트값을 `getLightTheme()`의 semantic token으로 통합하는 것이 좋습니다.
- `applyLightTheme()`가 생성 직후 한 번 적용되므로, 동적으로 생성되는 plot panel/edit dialog/video control dialog에도 생성 직후 동일 테마 적용 여부를 체크해야 합니다.
- `uigridlayout`과 `uipanel`이 섞인 구조이므로, 구조도 문서를 유지하려면 `buildHeaderBar`, `createLayout`, `createVideoControlDialog`, `openEditDialog` 계열을 기준으로 UI 생성 책임을 더 분리하는 것이 좋습니다.
- classic `uicontrol` 기반이 아니므로, MATLAB App Designer 컴포넌트 속성명 기준으로 스타일 점검 체크리스트를 작성해야 합니다.
