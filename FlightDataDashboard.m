classdef FlightDataDashboard < matlab.apps.AppBase
    % =========================================================================
    % 비행 데이터 리뷰 대시보드 - V3.22 (리팩토링: 모듈 분해 + 캐시 자료구조 개선)
    % 설명:
    %   [V3.22 변경사항]
    %   - #1 ErrorLog ring buffer (silent catch도 사후 조사 가능)
    %        + dumpErrorLog(n, filterTag) 헬퍼 메서드
    %   - #2 cacheGetFrame을 lastUse 카운터 기반 O(1) lookup으로 전환
    %        (cell 배열 reference shuffle 제거 → 큰 프레임 lookup 시 GC 압력 감소)
    %        cacheStoreFrame은 in-place 갱신 + lastUse 동기 관리
    %        evictByScore에 lastUse 인자 추가 → score = (hits * recency) / bytes
    %   - #3 loadAviFile을 6개 헬퍼로 분해:
    %        confirmVideoReplace / invalidateFrameCache / computeStartTimeFromFlightData
    %        cleanupVideoResources / openVideoReader / applyVideoLoadedUI
    %        computeTotalFrames / loadFirstFrame
    %   - #4 매직 넘버 상수화: ASYNC_WORKER_COUNT, WORKER_VR_CACHE_SLOTS,
    %        MAX_SEQ_READ_STEP, MAX_PENDING_ITERS
    %   - #5 UIGroup alias: 평면 UI struct를 attitude/map/video/plots/controls/data
    %        로 그룹화. 기존 평면 필드는 그대로 유지(100% 호환), 신규 코드는 그룹 사용
    %   - #6 Static wrapper: workerDecodeFrame / workerCleanupCache
    %        → 향후 +flightdash 패키지 마이그레이션 옵션 확보
    %   - #7 createLayout 분해: buildHeaderBar 추출 + 비행경로 루프 섹션 가이드 추가
    %
    %   [V3.21 #1-A] Generation counter (AsyncGen): 매 startAsyncDecode 호출 시
    %     증가, future에 myGen 캡처 → onAsyncDecodeComplete에서 비교하여 stale
    %     결과 폐기. 같은 frame이라도 generation mismatch면 무시 → race 차단.
    %   [V3.21 #3-A] 3계층 분리:
    %     Layer 1 requestFrame: 진입점 + 캐시 lookup + sync/async 전략 선택
    %     Layer 2 decodeFrameSync / startAsyncDecode: 디코딩 (전략 패턴)
    %     Layer 3 displayFrame: 표시 + 캐시 store (write-through 단일 출구)
    %     기존 updateVideoFrameByFrameNo는 requestFrame로 위임 (호환).
    %   [V3.21 #2-A] persistent VideoReader in worker:
    %     asyncDecodeFramePersistent 외부 함수에서 persistent 변수로 VR 재사용
    %     → 호출당 ~50ms→3ms로 단축. 파일 변경 시에만 VR 재생성.
    %   [V3.20 유지] 명시적 리소스 정리, 동기화 로그 prefix 표준화.
    %   [V3.19 유지] 비동기 디코딩, adaptive prefetch, 가중 LRU.
    %   [V3.18 유지] cache lookup clamp, Pending 완전 소진, hard limit 1.0.
    %   [V3.17 유지] InGoToFrame coalescing, IsDecoding 가드.
    % =========================================================================

    % ---------------------------------------------------------------------
    % 상수 (매직 넘버 제거)
    % ---------------------------------------------------------------------
    properties (Constant, Access = private)
        MAX_TABS          = 10
        MAX_PLOTS_PER_TAB = 12
        PLOT_ROW_HEIGHT   = 150     % H영역 내 각 플롯 패널 높이(px)
        MOCK_STEP_COUNT   = 200     % 모의 데이터 스텝 수
        VIDEO_THROTTLE_S  = 0.05    % 비디오 프레임 갱신 쓰로틀 간격(초)
        SLIDER_THROTTLE_S = 0.03    % [V3.15 항목 1] 슬라이더 갱신 최소 간격(초) - 33fps 상한
        MAX_CACHE_FRAMES  = 200     % [V3.14] 절대 상한 (DynamicCacheLimit는 이 값 이하로만 적용)
        MIN_CACHE_FRAMES  = 5       % [V3.14] 절대 하한
        REQ_KEYS          = {'Time', 'Roll', 'Pitch', 'Heading', 'Alt', 'Lat', 'Lon'}
        % [V3.22 #4] 매직 넘버 상수화
        ASYNC_WORKER_COUNT    = 2    % parallel pool worker 수 (process pool)
        WORKER_VR_CACHE_SLOTS = 4    % worker persistent VideoReader LRU 슬롯 수
        MAX_SEQ_READ_STEP     = 4    % 순차 readFrame 최대 step (이상이면 random seek)
        MAX_PENDING_ITERS     = 10   % goToFrame Pending 소진 루프 최대 반복
    end

    properties (Access = public)
        UIFigure
        UI
        UIGroup           % [V3.22 #5] UI를 attitude/map/video/plots/controls/data로 그룹화한 alias
        SyncInput
        SyncBtn

        Models
        SyncState
        VideoState
        VideoSyncState    % [V3.12] 비디오-비행데이터 동기화 정보 (배열 [1x2])
        WindowMinBtn
        WindowMaxBtn
        BoardToggleButtons

        CoastlineData
        FixedAreaBounds

        DebugMode         = false   % [V3.14 항목 6] true 시 zoom/pan off 등 로그 출력
        State             = 'IDLE'  % [V3.17 (8)] 'IDLE' | 'DRAGGING' | 'UPDATING' | 'DECODING'
        UseAsyncDecode    = false   % [V3.19 (1)] 비동기 디코딩 활성화 (Parallel Toolbox 필요)
    end

    properties (Access = private)
        LastVideoUpdate     = {uint64(0), uint64(0)}  % [PATCH] tic 핸들(채널별)
        IsUpdating          = [false, false] % 재귀 방지 플래그
        IsDraggingMarker    = false         % 마커 드래그 상태 플래그
        DraggedMarker       = []            % 현재 드래그 중인 그래픽 객체 핸들
        IsProgrammaticXLim  = [false, false] % [V3.11 A] 책장 넘기기 등 프로그래밍 XLim 변경 시 리스너 차단
        DraggedFIdx         = 0             % [V3.11 B] 드래그 중인 fIdx
        DraggedFromVideo    = false         % [V3.12] 비디오 Frame 마커에서 드래그 시작 여부
        VideoThrottleDyn    = 0.05          % [V3.12] (V3.13에서 미사용, 보존)
        LastDragTime        = {uint64(0), uint64(0)}  % [PATCH] 채널별 tic 핸들
        LastDisplayedFrame  = [0, 0]        % [PATCH] 실제로 화면에 표시된 frame (display path 만)
        LastDecodedFrame    = [0, 0]        % [Stabilization P1] 마지막 decode/read 결과 frame (seq readFrame 휴리스틱 전용)
        LastRequestedFrame  = [NaN, NaN]    % [Stabilization P1] 가장 최근에 요청된 frame (사용자 기준)
        PendingVideoFrame   = [NaN, NaN]    % [Stabilization P1] 디코딩 중 들어온 latest video frame request
        PendingVideoMode    = {'', ''}      % [Stabilization P1] 위 frame 요청의 source mode
        IsDeleting          = false         % [Stabilization P2] delete/close 재진입 가드
        HISplitterFIdx      = 0             % [PATCH UX-3] H/I 경계 드래그 중인 채널
        IsDraggingSplitter  = false         % [PATCH UX-3b] splitter 드래그 상태 플래그
        FrameCache          = {{}, {}}      % [V3.13 C-1] 비행경로별 프레임 캐시
        FrameCacheKeys      = {[], []}      % [V3.13 C-1] 비행경로별 캐시 키 순서 (LRU)
        DynamicCacheLimit   = [50, 50]      % [V3.14 항목 3] 비행경로별 동적 계산된 최대 캐시 프레임 수
        CacheBudgetMB       = 30            % [V3.14 항목 3] 비행경로당 캐시 메모리 예산(MB) - GUI에서 조정
        LastSliderUpdate    = {uint64(0), uint64(0)}  % [PATCH] tic 핸들(채널별)
        LastDragTableUpdate = [uint64(0), uint64(0)]  % [Perf] dataTable throttle (드래그 중)
        InGoToFrame         = [false, false] % [V3.16] goToFrame 재진입 차단 플래그
        PendingFrame        = [NaN, NaN]     % [V3.17 (1)(9)] 처리 중 들어온 최신 frame 요청
        PendingMode         = {'', ''}        % [V3.17 (1)(9)] 처리 중 들어온 최신 mode
        InCascade           = false          % [V3.17 (4)(11)] cascade 재귀 가드 (인스턴스 속성)
        IsDecoding          = [false, false] % [V3.17 (7)] 디코딩 진행 중 가드
        CacheBytesUsed      = [0, 0]         % [V3.17 (6)] 비행경로별 실제 사용 메모리(bytes)
        FrameCacheHits      = {[], []}        % [V3.19 (3)] 각 frame의 액세스 횟수 (가중 LRU)
        FrameCacheLastUse   = {[], []}        % [V3.22 #2] 각 frame의 마지막 사용 tic (uint64) - LRU 기준
        FrameCacheUseCounter = uint64(0)      % [V3.22 #2] 단조 증가 사용 카운터 (tic 대체)
        AsyncPool           = []              % [V3.19 (1)] parallel pool 핸들
        AsyncFutures        = {[], []}        % [V3.19 (1)] 진행 중 parfeval future
        AsyncTargetFrame    = [NaN, NaN]      % [V3.19 (1)] 비동기 디코딩 중인 frame No
        AsyncGen            = [0, 0]          % [V3.21 #1-A] generation counter (race 차단)
        VideoFilePath       = {'', ''}        % [V3.19 (1)] worker가 자체 VideoReader 생성용
        CurrentVideoFrame   = {[], []}        % 표시 해상도 변경 시 재렌더링할 원본 최신 프레임
        NormalWindowPosition = []             % 마지막 일반 창 위치(최대화 복원용)
        IsRestoringWindow   = false           % 복원 중 SizeChanged 저장 방지
        IsWindowManuallyMaximized = false     % WindowState 미지원 버전 fallback
        DragVelocity        = [0, 0]          % [V3.19 (2)] frames/sec (부호: 방향)
        DragVelocitySamples = {[], []}        % [V3.19 (2)] 최근 샘플 (이동평균용)
        % [V3.22 #1] silent catch도 사후 조사 가능하도록 ring buffer 보관
        % - stack은 cell-wrap으로 저장 (struct array 차원 불일치 회피)
        ErrorLog            = struct('time', {}, 'tag', {}, 'identifier', {}, 'message', {}, 'stack', {})
        ErrorLogCapacity    = 200             % [V3.22 #1] ring buffer 최대 크기

        % [Phase 1] Project state + edit dialog plumbing
        ProjectState         = []              % cached struct mirroring .fdproj
        ProjectFilePath      = ''              % absolute path of currently loaded project
        ProjectDirty         = false           % true when in-memory state diverges from saved file
        ProjectConfirmOnClose = true           % ask before closing with dirty project/options
        ProjectAutosaveEnabled = true          % enable .autosave snapshot timer
        ProjectLastSaveText  = ''              % last successful project save timestamp for Project tab
        OptionDrafts         = {[], []}        % per-flight option editor draft buffers (Phase 2 fills)
        PlotConfigState      = []              % captured PlotConfig (Phase 4 fills)
        EditDialog           = []              % handle to edit uifigure (modeless)
        EditApplyTimer       = []              % single-shot debounce timer (D2)
        EditApplyDelaySec    = 0.35            % timer StartDelay
        LastEditApplyTime    = NaT              % time of last applyPendingDialogChanges()
        AutosaveTimer        = []              % .fdproj.autosave snapshot timer (D2)
        AutosaveIntervalSec  = 30              % snapshot every N seconds while dirty
        ProjectFileVersion   = 1               % current .fdproj schema version
        BoardOffState        = [false, false]  % true when the corresponding flight board is replaced by summary view
        % [Q-03] BoardPanelVisibleSnapshot 제거 — restoreBoardPanelState 는
        % 현재 PanelVisible 만 사용하므로 스냅샷 불필요.

        % [Audit fix #1] Edit dialog UI handles (all default to [])
        EditDialogStatusLbl  = []
        EditDialogDirtyLbl   = []
        EditDialogTimeLbl    = []
        EDProjectPathLbl     = []
        EDProjectStatusLbl   = []
        EDProjectAutosaveCB  = []
        EDProjectConfirmCloseCB = []
        EDProjectLastSaveLbl = []
        EDFilesPathLbl       = struct()
        EDSyncF1Time         = []
        EDSyncF2Time         = []
        EDSyncOffsetLbl      = []   % [F-04] offset preview
        EDVSync1Frame        = []
        EDVSync1Time         = []
        EDVSync1VFPS         = []
        EDVSync1DFPS         = []
        EDVSync2Frame        = []
        EDVSync2Time         = []
        EDVSync2VFPS         = []
        EDVSync2DFPS         = []
        EDOptFlightDD        = []
        EDOptReqTable        = []
        EDOptDspTable        = []
        EDPlotFlightDD       = []
        EDPlotTree           = []
        EDPlotLinkCB         = []
        % [F-01] Plot Manager 속성 패널 핸들
        EDPlotNameEdit       = []
        EDPlotYColDD         = []
        EDPlotYLabelEdit     = []
        EDPlotXAutoCB        = []
        EDPlotXMin           = []
        EDPlotXMax           = []
        EDPlotYMin           = []
        EDPlotYMax           = []
        EDPlotYAutoCB        = []
        EDPlotHeight         = []
        EDExpParentEdit      = []
        EDExpPreviewLbl      = []
        EDExpHashCB          = []
        EDExpFileTable       = []
        EDExpMissingLbl      = []
        EDExpLogArea         = []
    end

    methods (Access = public)
        % ---------------------------------------------------------------------
        % 생성자 및 초기화
        % ---------------------------------------------------------------------
        function app = FlightDataDashboard()
            app.Models = [app.createEmptyModel(), app.createEmptyModel()];
            app.SyncState = struct('IsSynced', false, 'SyncT1', 0, 'SyncT2', 0);
            app.VideoState = struct('videoReader', {[], []}, 'videoStartTime', {0, 0}, 'vidImageHandle', {[], []});
            % [V3.12] VideoSyncState 초기화: 두 비행경로별 동기화 정보
            app.VideoSyncState = struct( ...
                'IsSynced',     {false, false}, ...     % 동기 설정 완료 여부
                'AnchorFrame',  {0, 0}, ...             % 동기 기준 프레임 번호
                'AnchorTime',   {0, 0}, ...             % 동기 기준 비행시간(초)
                'VideoFps',     {70, 70}, ...           % 영상 Hz (기본 70)
                'DataFps',      {50, 50}, ...           % 비행데이터 Hz (기본 50)
                'TotalFrames',  {0, 0}, ...             % 영상 총 프레임 수
                'CurrentFrame', {1, 1});                % 현재 프레임 위치
            app.CoastlineData = [];
            app.FixedAreaBounds = [];

            if isfile('option_flight_area.dat')
                try
                    areaData = readmatrix('option_flight_area.dat');
                    if size(areaData, 2) >= 2
                        app.FixedAreaBounds = struct('minLat', min(areaData(:,1)), 'maxLat', max(areaData(:,1)), ...
                                                     'minLon', min(areaData(:,2)), 'maxLon', max(areaData(:,2)));
                    end
                catch e
                    disp(['option_flight_area.dat 로드 실패: ', e.message]);
                end
            end

            % [Stabilization P1] Do NOT close other instances by name.
            % Multi-instance is supported; single-instance behaviour must be opt-in at the launcher level.
            % (was: close(findobj('Type', 'figure', 'Name', '비행 데이터 리뷰 대시보드 (Dual)')); )
            app.NormalWindowPosition = app.getInitialWindowPosition();
            app.UIFigure = uifigure('Name', '비행 데이터 리뷰 대시보드 (Dual)', ...
                                    'Units', 'pixels', ...
                                    'Position', app.NormalWindowPosition, ...
                                    'Color', [0.94 0.94 0.96], ...
                                    'CloseRequestFcn', @app.UIFigureCloseRequest);
            try
                if isprop(app.UIFigure, 'Resize')
                    app.UIFigure.Resize = 'on';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'constructor:resize');
            end
            try
                if isprop(app.UIFigure, 'AutoResizeChildren')
                    app.UIFigure.AutoResizeChildren = 'off';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'constructor:auto-resize-children');
            end

            app.createLayout();
            app.applyLightPanelTitleContrast(app.UIFigure);
            try
                app.UIFigure.SizeChangedFcn = @(~,~) app.onFigureSizeChanged();
            catch ME_silent
                app.logCaught(ME_silent, 'constructor:size-changed-fcn');
            end
            app.applyResponsiveLayout();

            for i = 1:2
                app.addPlotTab(i);
                app.VideoState(i).vidImageHandle = app.UI(i).vidImageHandle;
            end
        end

        function delete(app)
            % [V3.20 (5)] 명시적 리소스 정리: VideoReader, AsyncPool, futures
            % [Stabilization P2] re-entry guard so partial cleanup cannot run twice
            if app.IsDeleting, return; end
            app.IsDeleting = true;
            try
                for fIdx = 1:2
                    try
                        if ~isempty(app.UI) && numel(app.UI) >= fIdx && ...
                           isfield(app.UI(fIdx), 'vidControlDialog') && ...
                           ~isempty(app.UI(fIdx).vidControlDialog) && isvalid(app.UI(fIdx).vidControlDialog)
                            delete(app.UI(fIdx).vidControlDialog);
                        end
                    catch ME
                        app.logCaught(ME, 'delete:vid-control-dialog');
                    end
                    % VideoReader 정리
                    try
                        if ~isempty(app.VideoState(fIdx).videoReader) && ...
                           isvalid(app.VideoState(fIdx).videoReader)
                            delete(app.VideoState(fIdx).videoReader);
                        end
                    catch ME
                        app.logCaught(ME, 'delete:video-reader');
                    end
                    % 진행 중 비동기 future 취소
                    try
                        if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                            cancel(app.AsyncFutures{fIdx});
                        end
                    catch ME
                        % [Medium 2] 정확한 subsystem 태그 — cleanup 경로
                        app.logCaught(ME, 'delete:future-cancel');
                    end
                end
                % 캐시 비우기 (메모리 즉시 해제)
                app.FrameCache = {{}, {}};
                app.FrameCacheKeys = {[], []};
                app.FrameCacheHits = {[], []};
                app.FrameCacheLastUse = {[], []};   % [V3.22 #2] LRU 카운터 리셋
                app.FrameCacheUseCounter = uint64(0);
                app.CacheBytesUsed = [0, 0];
                app.AsyncGen = [0, 0];   % [V3.21 #1-A] generation reset
                app.LastDisplayedFrame = [0, 0];   % [PATCH] 조기반환 키 리셋
            catch ME
                app.logCaught(ME, 'delete:cache-reset');
            end

            % [PATCH / V3.22 #6] 워커 persistent VR 명시 해제 → 파일락 즉시 반환
            try
                if ~isempty(app.AsyncPool) && isvalid(app.AsyncPool)
                    parfevalOnAll(app.AsyncPool, @FlightDataDashboard.workerCleanupCache, 0);
                end
            catch ME
                app.logCaught(ME, 'delete:worker-cache-cleanup');
            end

            % [Phase 1 D2] stop debounce + autosave timers before tearing down UI
            try
                if ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer)
                    try
                        stop(app.EditApplyTimer);
                    catch
                    end
                    delete(app.EditApplyTimer);
                    app.EditApplyTimer = [];
                end
            catch ME
                app.logCaught(ME, 'delete:edit-apply-timer');
            end
            try
                if ~isempty(app.AutosaveTimer) && isvalid(app.AutosaveTimer)
                    try
                        stop(app.AutosaveTimer);
                    catch
                    end
                    delete(app.AutosaveTimer);
                    app.AutosaveTimer = [];
                end
            catch ME
                app.logCaught(ME, 'delete:autosave-timer');
            end
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    delete(app.EditDialog);
                    app.EditDialog = [];
                end
            catch ME
                app.logCaught(ME, 'delete:edit-dialog');
            end

            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    delete(app.UIFigure);
                end
            catch ME
                app.logCaught(ME, 'delete:uifigure');
            end
        end

        function model = createEmptyModel(~)
            % [Phase 1/Phase 2 D4] rawDataUnscaled keeps the unscaled source so option scale
            % changes never accumulate. File-path fields back the Project Files tab.
            model = struct('rawData', table(), 'rawDataUnscaled', table(), ...
                           'mappedCols', struct(), 'displayMeta', struct(), ...
                           'bounds', struct('minLat',0, 'maxLat',0, 'minLon',0, 'maxLon',0, 'isValid', false), ...
                           'altBounds', struct('minAlt',0, 'maxAlt',0), ...
                           'currentIndex', 1, 'selectedRow', 1, 'isMockData', false, ...
                           'dataFilePath', '', 'aviFilePath', '', 'optionFilePath', '');
        end

        function varargout = testHook(app, methodName, varargin)
            % [Testing] Public dispatch for private methods used by
            % auto_test_runner.m. Production code MUST NOT depend on this.
            varargout = {};
            switch methodName
                case 'parseFlightData',               app.parseFlightData(varargin{:});
                case 'setupDataUI',                   app.setupDataUI(varargin{:});
                case 'calculateBounds',               app.calculateBounds(varargin{:});
                case 'initPlots',                     app.initPlots(varargin{:});
                case 'updateDashboard',               app.updateDashboard(varargin{:});
                case 'pushPanelToggleButton'
                    fIdx = varargin{1}; pnlName = varargin{2};
                    switch lower(char(pnlName))
                        case 'attitude', btn = app.UI(fIdx).btnAtt;
                        case 'map',      btn = app.UI(fIdx).btnMap;
                        case 'video',    btn = app.UI(fIdx).btnVid;
                        otherwise
                            error('FlightDataDashboard:UnknownPanelToggle', ...
                                  'Unknown panel toggle: %s', char(pnlName));
                    end
                    cb = btn.ButtonPushedFcn;
                    cb(btn, []);
                case 'pushBoardToggleButton'
                    fIdx = varargin{1};
                    btn = app.BoardToggleButtons(fIdx);
                    cb = btn.ButtonPushedFcn;
                    cb(btn, []);
                case 'togglePanel',                   app.togglePanel(varargin{:});
                case 'toggleBoardVisibility',         app.toggleBoardVisibility(varargin{:});
                case 'boardOffAddPlotTab',            app.boardOffAddPlotTab(varargin{:});
                case 'boardOffClearCurrentTab',       app.boardOffClearCurrentTab(varargin{:});
                case 'boardOffPlotSelectedVariable',  app.boardOffPlotSelectedVariable(varargin{:});
                case 'applyTimeChange',               app.applyTimeChange(varargin{:});
                case 'setVideoSync',                  app.setVideoSync(varargin{:});
                case 'loadAviFileFromPath',           varargout{1} = app.loadAviFileFromPath(varargin{:});
                case 'plotSelectedVariable',          app.plotSelectedVariable(varargin{:});
                case 'addPlotTab',                    app.addPlotTab(varargin{:});
                case 'getTestState',                  varargout{1} = app.getTestState();
                case 'setSelectedRow'
                    fIdx = varargin{1}; row = varargin{2};
                    app.Models(fIdx).selectedRow = row;
                otherwise
                    error('FlightDataDashboard:UnknownTestHook', ...
                          'Unknown testHook method: %s', methodName);
            end
        end

        function state = getTestState(app)
            % [Testing] Read-only UI/model snapshot for auto_test_runner.m.
            state = struct();
            state.BoardOffState = logical(app.BoardOffState);
            state.boards = repmat(app.emptyTestBoardState(), 1, 2);
            for fIdx = 1:2
                state.boards(fIdx) = app.collectTestBoardState(fIdx);
            end
            state.toggleButtons = repmat(struct('Text', '', 'Enable', '', 'Visible', false), 1, 2);
            for k = 1:min(2, numel(app.BoardToggleButtons))
                try
                    btn = app.BoardToggleButtons(k);
                    if ~isempty(btn) && isvalid(btn)
                        state.toggleButtons(k).Text = char(btn.Text);
                        state.toggleButtons(k).Enable = char(btn.Enable);
                        state.toggleButtons(k).Visible = app.isUiVisible(btn);
                    end
                catch ME
                    app.logCaught(ME, 'test:get-toggle-button-state');
                end
            end
        end

        function s = emptyTestBoardState(~)
            panelVisible = struct('attitude', false, 'map', false, 'video', false);
            s = struct( ...
                'exists', false, ...
                'panelVisible', false, ...
                'PanelVisible', panelVisible, ...
                'sideHandleVisible', panelVisible, ...
                'dataLoaded', false, ...
                'aviLoaded', false, ...
                'currentIndex', NaN, ...
                'currentTime', NaN, ...
                'spinnerValue', NaN, ...
                'currentTimeLabel', '', ...
                'dataTableRows', 0, ...
                'selectedRow', NaN, ...
                'dataGridColumnWidth', {{}}, ...
                'infoColumnHidden', false, ...
                'plotColumnHidden', false, ...
                'splitterColumnHidden', false, ...
                'plotTabCount', 0, ...
                'selectedPlotTab', 0, ...
                'plotCounts', [], ...
                'totalPlotCount', 0, ...
                'selectedTabPlotCount', 0, ...
                'altMarkerInteractive', false, ...
                'altLineInteractive', false, ...
                'videoSync', struct('IsSynced', false, 'AnchorFrame', 0, 'AnchorTime', 0, ...
                                    'VideoFps', 0, 'DataFps', 0, 'TotalFrames', 0, 'CurrentFrame', 0), ...
                'boardOffPanelVisible', false, ...
                'boardOff', struct('tableRows', 0, 'buttonTexts', {{}}, 'tabCount', 0, ...
                                   'selectedTab', 0, 'plotCounts', [], 'totalPlotCount', 0, ...
                                   'markerCount', 0, 'interactiveMarkerCount', 0, ...
                                   'lineCount', 0, 'interactiveLineCount', 0, ...
                                   'firstMarkerX', NaN, 'firstLineX', NaN));
        end

        function s = collectTestBoardState(app, fIdx)
            s = app.emptyTestBoardState();
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                s.exists = true;
                s.panelVisible = app.isUiVisible(app.UI(fIdx).panel);

                if isfield(app.UI(fIdx), 'PanelVisible')
                    names = {'attitude', 'map', 'video'};
                    for iName = 1:numel(names)
                        nm = names{iName};
                        if isfield(app.UI(fIdx).PanelVisible, nm)
                            s.PanelVisible.(nm) = logical(app.UI(fIdx).PanelVisible.(nm));
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'panelAttitude')
                    s.sideHandleVisible.attitude = app.isUiVisible(app.UI(fIdx).panelAttitude);
                end
                if isfield(app.UI(fIdx), 'panelMapAlt')
                    s.sideHandleVisible.map = app.isUiVisible(app.UI(fIdx).panelMapAlt);
                end
                if isfield(app.UI(fIdx), 'panelVideo')
                    s.sideHandleVisible.video = app.isUiVisible(app.UI(fIdx).panelVideo);
                end

                s.dataLoaded = ~isempty(app.Models(fIdx).rawData);
                s.aviLoaded = ~isempty(app.VideoState(fIdx).videoReader);
                s.currentIndex = double(app.Models(fIdx).currentIndex);
                s.selectedRow = double(app.Models(fIdx).selectedRow);
                if s.dataLoaded && isfield(app.Models(fIdx).mappedCols, 'Time')
                    timeCol = app.Models(fIdx).mappedCols.Time;
                    idx = max(1, min(app.Models(fIdx).currentIndex, height(app.Models(fIdx).rawData)));
                    s.currentTime = double(app.Models(fIdx).rawData.(timeCol)(idx));
                end
                if isfield(app.UI(fIdx), 'spinner') && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                    s.spinnerValue = double(app.UI(fIdx).spinner.Value);
                end
                if isfield(app.UI(fIdx), 'currentTimeLabel') && ~isempty(app.UI(fIdx).currentTimeLabel) ...
                        && isvalid(app.UI(fIdx).currentTimeLabel)
                    s.currentTimeLabel = char(app.UI(fIdx).currentTimeLabel.Text);
                end
                if isfield(app.UI(fIdx), 'dataTable') && ~isempty(app.UI(fIdx).dataTable) && isvalid(app.UI(fIdx).dataTable)
                    s.dataTableRows = size(app.UI(fIdx).dataTable.Data, 1);
                end

                if isfield(app.UI(fIdx), 'dataGrid') && ~isempty(app.UI(fIdx).dataGrid) && isvalid(app.UI(fIdx).dataGrid)
                    widths = app.UI(fIdx).dataGrid.ColumnWidth;
                    s.dataGridColumnWidth = widths;
                    if numel(widths) >= 5
                        s.infoColumnHidden = app.isTestWidthZero(widths{3});
                        s.plotColumnHidden = app.isTestWidthZero(widths{4});
                        s.splitterColumnHidden = app.isTestWidthZero(widths{5});
                    end
                end

                if isfield(app.UI(fIdx), 'plotTabs')
                    s.plotTabCount = numel(app.UI(fIdx).plotTabs);
                    s.plotCounts = zeros(1, s.plotTabCount);
                    for tIdx = 1:s.plotTabCount
                        if tIdx <= numel(app.UI(fIdx).plotAxes) && ~isempty(app.UI(fIdx).plotAxes{tIdx})
                            s.plotCounts(tIdx) = numel(app.UI(fIdx).plotAxes{tIdx});
                        end
                    end
                    s.totalPlotCount = sum(s.plotCounts);
                    try
                        sel = find(app.UI(fIdx).plotTabs == app.UI(fIdx).tabGroup.SelectedTab, 1);
                        if ~isempty(sel)
                            s.selectedPlotTab = double(sel);
                            s.selectedTabPlotCount = s.plotCounts(sel);
                        end
                    catch ME_silent
                        app.logCaught(ME_silent, 'testState:selected-tab');
                    end
                end

                if isfield(app.UI(fIdx), 'hAltMarker')
                    s.altMarkerInteractive = app.isTestCallbackSet(app.UI(fIdx).hAltMarker, 'ButtonDownFcn');
                end
                if isfield(app.UI(fIdx), 'timeLine')
                    s.altLineInteractive = app.isTestCallbackSet(app.UI(fIdx).timeLine, 'ButtonDownFcn');
                end

                vss = app.VideoSyncState(fIdx);
                s.videoSync = struct('IsSynced', logical(vss.IsSynced), ...
                    'AnchorFrame', double(vss.AnchorFrame), 'AnchorTime', double(vss.AnchorTime), ...
                    'VideoFps', double(vss.VideoFps), 'DataFps', double(vss.DataFps), ...
                    'TotalFrames', double(vss.TotalFrames), 'CurrentFrame', double(vss.CurrentFrame));

                if isfield(app.UI(fIdx), 'boardOffPanel') && ~isempty(app.UI(fIdx).boardOffPanel) ...
                        && isvalid(app.UI(fIdx).boardOffPanel)
                    s.boardOffPanelVisible = app.isUiVisible(app.UI(fIdx).boardOffPanel);
                    allKids = findall(app.UI(fIdx).boardOffPanel);
                    for iKid = 1:numel(allKids)
                        h = allKids(iKid);
                        try
                            if isprop(h, 'Text') && isprop(h, 'ButtonPushedFcn')
                                txt = char(h.Text);
                                if ~isempty(txt)
                                    s.boardOff.buttonTexts{end + 1} = txt;
                                end
                            end
                        catch ME_silent
                            app.logCaught(ME_silent, 'testState:board-toggle-text');
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'boardOffTable') && ~isempty(app.UI(fIdx).boardOffTable) ...
                        && isvalid(app.UI(fIdx).boardOffTable)
                    s.boardOff.tableRows = size(app.UI(fIdx).boardOffTable.Data, 1);
                end
                if isfield(app.UI(fIdx), 'boardOffPlotTabs')
                    s.boardOff.tabCount = numel(app.UI(fIdx).boardOffPlotTabs);
                    s.boardOff.plotCounts = zeros(1, s.boardOff.tabCount);
                    for tIdx = 1:s.boardOff.tabCount
                        if tIdx <= numel(app.UI(fIdx).boardOffPlotAxes) && ~isempty(app.UI(fIdx).boardOffPlotAxes{tIdx})
                            s.boardOff.plotCounts(tIdx) = numel(app.UI(fIdx).boardOffPlotAxes{tIdx});
                        end
                        if tIdx <= numel(app.UI(fIdx).boardOffTimeMarkers) && ~isempty(app.UI(fIdx).boardOffTimeMarkers{tIdx})
                            s.boardOff.markerCount = s.boardOff.markerCount + numel(app.UI(fIdx).boardOffTimeMarkers{tIdx});
                            for pIdx = 1:numel(app.UI(fIdx).boardOffTimeMarkers{tIdx})
                                h = app.UI(fIdx).boardOffTimeMarkers{tIdx}{pIdx};
                                if app.isTestCallbackSet(h, 'ButtonDownFcn')
                                    s.boardOff.interactiveMarkerCount = s.boardOff.interactiveMarkerCount + 1;
                                end
                                if isnan(s.boardOff.firstMarkerX) && ~isempty(h) && isvalid(h)
                                    xData = h.XData;
                                    if ~isempty(xData)
                                        s.boardOff.firstMarkerX = double(xData(1));
                                    end
                                end
                            end
                        end
                        if tIdx <= numel(app.UI(fIdx).boardOffTimeLines) && ~isempty(app.UI(fIdx).boardOffTimeLines{tIdx})
                            s.boardOff.lineCount = s.boardOff.lineCount + numel(app.UI(fIdx).boardOffTimeLines{tIdx});
                            for pIdx = 1:numel(app.UI(fIdx).boardOffTimeLines{tIdx})
                                h = app.UI(fIdx).boardOffTimeLines{tIdx}{pIdx};
                                if app.isTestCallbackSet(h, 'ButtonDownFcn')
                                    s.boardOff.interactiveLineCount = s.boardOff.interactiveLineCount + 1;
                                end
                                if isnan(s.boardOff.firstLineX) && ~isempty(h) && isvalid(h)
                                    s.boardOff.firstLineX = double(h.Value);
                                end
                            end
                        end
                    end
                    s.boardOff.totalPlotCount = sum(s.boardOff.plotCounts);
                    try
                        sel = find(app.UI(fIdx).boardOffPlotTabs == app.UI(fIdx).boardOffTabGroup.SelectedTab, 1);
                        if ~isempty(sel), s.boardOff.selectedTab = double(sel); end
                    catch ME_silent
                        app.logCaught(ME_silent, 'testState:boardoff-selected-tab');
                    end
                end
            catch ME
                app.logCaught(ME, 'testState');
            end
        end

        function tf = isTestCallbackSet(~, h, propName)
            tf = false;
            try
                if isempty(h) || ~isvalid(h) || ~isprop(h, propName), return; end
                cb = h.(propName);
                if isempty(cb), return; end
                if isprop(h, 'HitTest') && strcmpi(char(h.HitTest), 'off'), return; end
                if isprop(h, 'PickableParts') && strcmpi(char(h.PickableParts), 'none'), return; end
                tf = true;
            catch
                tf = false;
            end
        end

        function tf = isTestWidthZero(~, widthSpec)
            tf = false;
            try
                if isnumeric(widthSpec)
                    tf = widthSpec <= 0;
                elseif isstring(widthSpec) || ischar(widthSpec)
                    tf = strcmp(strtrim(char(widthSpec)), '0');
                end
            catch
                tf = false;
            end
        end
    end

    % =========================================================================
    % 시간 변경 단일 진입점 (동기화/업데이트/재귀방지를 한 곳에서 처리)
    % =========================================================================
    methods (Access = private)
        function applyTimeChange(app, fIdx, index)
            if app.IsUpdating(fIdx), return; end
            if isempty(app.Models(fIdx).rawData), return; end

            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(index);
            app.Models(fIdx).currentIndex = index;

            % --- 해당 경로 뷰 갱신 ---
            app.IsUpdating(fIdx) = true;
            try
                app.updateDashboard(fIdx, index);
                if abs(app.UI(fIdx).spinner.Value - currTime) > eps
                    app.UI(fIdx).spinner.Value = currTime;
                end
            catch e
                warning('applyTimeChange 오류: %s', e.message);
            end
            app.IsUpdating(fIdx) = false;

            % --- 동기화: 경로 1 변경 시 경로 2도 연동 ---
            if app.SyncState.IsSynced && fIdx == 1 && ~isempty(app.Models(2).rawData)
                targetT2 = app.SyncState.SyncT2 + (currTime - app.SyncState.SyncT1);

                timeCol2 = app.Models(2).mappedCols.Time;
                idx2 = app.findClosestIndexByTime(app.Models(2).rawData.(timeCol2), targetT2);

                if ~isequal(app.Models(2).currentIndex, idx2)
                    app.applyTimeChange(2, idx2);
                end
            end
        end
    end

    % =========================================================================
    % Callback-accessible methods: 파일 로드 및 메인 로직
    % =========================================================================
    methods (Access = public)
        function handleFlightFile(app, fIdx)
            try
                [filename, pathname] = uigetfile( ...
                    {'*.csv;*.dat;*.txt', 'Flight data files (*.csv, *.dat, *.txt)'; ...
                     '*.*', 'All files (*.*)'}, ...
                    sprintf('비행경로 %d 파일 선택', fIdx));
            catch e
                app.logCaught(e, 'flight-file-dialog');
                try
                    uialert(app.UIFigure, sprintf('파일 선택창을 열 수 없습니다:\n%s', e.message), '파일 선택 오류');
                catch
                    errordlg(['파일 선택창을 열 수 없습니다: ', e.message], '파일 선택 오류');
                end
                return;
            end
            if isequal(filename, 0), return; end

            % [V3.12] 기존 비디오 동기 설정이 있으면 사용자 확인 후 해제
            if app.VideoSyncState(fIdx).IsSynced
                sel = uiconfirm(app.UIFigure, ...
                    '새 비행데이터를 로드하면 기존 비디오-비행데이터 동기 설정이 해제됩니다. 계속하시겠습니까?', ...
                    '동기 해제 확인', ...
                    'Options', {'계속', '취소'}, 'DefaultOption', 1, 'CancelOption', 2);
                if strcmp(sel, '취소'), return; end
                app.resetVideoSync(fIdx);
            end

            d = uiprogressdlg(app.UIFigure, 'Title', '데이터 로딩 중', ...
                'Message', sprintf('비행경로 %d 데이터를 파싱하고 있습니다...', fIdx), ...
                'Indeterminate', 'on');
            % [Major 6] uiprogressdlg cleanup 을 autoLoadProjectFromFile 과 동일한 패턴으로
            % onCleanup + safeClose 로 일관화 → 어떤 분기에서 return/throw 해도 dialog 잔류 없음.
            cleanupDlg = onCleanup(@() app.safeClose(d));
            try
                fullpath = fullfile(pathname, filename);
                app.parseFlightData(fIdx, fullpath);

                timeCol = app.Models(fIdx).mappedCols.Time;
                if ~issorted(app.Models(fIdx).rawData.(timeCol), 'strictascend')
                    errordlg('시간 데이터가 순차적으로 증가하지 않거나 중복되었습니다.', '데이터 오류');
                    return;
                end

                if ~isempty(app.VideoState(fIdx).videoReader)
                    app.VideoState(fIdx).videoStartTime = app.Models(fIdx).rawData.(timeCol)(1);
                end

                % [V3.12] 비행데이터 Hz 자동 계산 후 입력란 갱신
                try
                    times = app.Models(fIdx).rawData.(timeCol);
                    if length(times) > 1
                        dt = mean(diff(times(1:min(100, end))));
                        if dt > 0
                            estFps = round(1 / dt);
                            if estFps >= 1 && estFps <= 1000
                                app.VideoSyncState(fIdx).DataFps = estFps;
                                if isfield(app.UI(fIdx), 'vidDataFpsInput') && ~isempty(app.UI(fIdx).vidDataFpsInput) && isvalid(app.UI(fIdx).vidDataFpsInput)
                                    app.UI(fIdx).vidDataFpsInput.Value = estFps;
                                end
                            end
                        end
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'handleFlightFile:restore-ui-snapshot');
                end
                app.setupDataUI(fIdx);

                % [수정 2] 비행 데이터 파싱 후, 이미 영상이 열려있다면 Video FPS 강제 재계산
                if app.VideoSyncState(fIdx).TotalFrames > 0
                    times = app.Models(fIdx).rawData.(timeCol);
                    maxTime = max(times);
                    if maxTime > 0
                        newFps = app.VideoSyncState(fIdx).TotalFrames / maxTime;
                        app.VideoSyncState(fIdx).VideoFps = newFps; % 소수점 정밀도 저장

                        if isfield(app.UI(fIdx), 'vidVideoFpsInput') && ~isempty(app.UI(fIdx).vidVideoFpsInput) && any(isvalid(app.UI(fIdx).vidVideoFpsInput))
                            app.UI(fIdx).vidVideoFpsInput.Value = round(newFps);
                        end
                        % 재계산된 FPS를 바탕으로 슬라이더 위의 총 시간 텍스트 즉시 갱신
                        app.updateVdubFrameLabel(fIdx, app.VideoSyncState(fIdx).CurrentFrame);
                    end
                end

                app.UI(fIdx).fileNameLabel.Text = filename;
                % [Major 6] dialog cleanup 은 onCleanup 가 담당 — 명시 close 제거
            catch e
                % [V3.20 (3)] 상세 에러 로그
                if app.DebugMode
                    fprintf('[Flight] parse failed: %s\n  %s\n  stack: %s\n', ...
                        filename, e.message, e.identifier);
                end
                errordlg(['오류 발생: ', e.message], '오류');
            end
        end

        function handleCoastFile(app)
            [filename, pathname] = uigetfile('*.csv', '해안선 정보 파일 선택');
            if isequal(filename, 0), return; end
            try
                fullpath = fullfile(pathname, filename);
                rawData = readmatrix(fullpath);
                app.CoastlineData = rawData(~any(isnan(rawData(:, 1:2)), 2), 1:2);

                hasRealData = (~isempty(app.Models(1).rawData) && ~app.Models(1).isMockData) || ...
                              (~isempty(app.Models(2).rawData) && ~app.Models(2).isMockData);

                for i = 1:2
                    if ~hasRealData && (isempty(app.Models(i).rawData) || app.Models(i).isMockData)
                        app.Models(i).rawData = table();
                        app.calculateBounds(i);
                        app.generateMockFlightData(i);
                    else
                        app.calculateBounds(i);
                        app.initPlots(i);
                        app.updateDashboard(i, app.Models(i).currentIndex);
                    end
                end
            catch e
                errordlg(['오류 발생: ', e.message], '오류');
            end
        end

        function handleSpinnerChange(app, fIdx, newTime)
            if isempty(app.Models(fIdx).rawData), return; end
            if app.IsUpdating(fIdx), return; end

            timeCol = app.Models(fIdx).mappedCols.Time;
            idx = app.findClosestIndexByTime(app.Models(fIdx).rawData.(timeCol), newTime);

            if isequal(app.Models(fIdx).currentIndex, idx), return; end

            app.applyTimeChange(fIdx, idx);
        end

        function handleTableSelection(app, fIdx, event)
            if ~isempty(event.Indices)
                app.Models(fIdx).selectedRow = event.Indices(1, 1);
            end
        end

        function UIFigureCloseRequest(app, ~, ~)
            % [Stabilization P2] do not run the close path twice
            if app.IsDeleting, return; end

            % [P3] Abort close immediately when apply/save paths fail
            % (or when the user cancels).
            try
                pendingTimer = ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer) ...
                               && strcmpi(app.EditApplyTimer.Running, 'on');
                if (app.ProjectDirty || pendingTimer) && app.ProjectConfirmOnClose
                    try
                        sel = uiconfirm(app.UIFigure, ...
                            ['저장되지 않은 편집 사항이 있습니다.', newline, ...
                             'project / option 파일을 저장하고 닫을까요?'], ...
                            '저장되지 않은 변경사항', ...
                            'Options', {'적용 후 저장하고 닫기', '버리고 닫기', '취소'}, ...
                            'DefaultOption', 1, 'CancelOption', 3);
                    catch
                        sel = '적용 후 저장하고 닫기';
                    end
                    switch sel
                        case '취소'
                            return;
                        case '적용 후 저장하고 닫기'
                            if pendingTimer
                                try
                                    stop(app.EditApplyTimer);
                                catch
                                end
                                try
                                    app.applyPendingDialogChanges();
                                catch ME
                                    app.logCaught(ME, 'close-apply');
                                    try
                                        cont = uiconfirm(app.UIFigure, ...
                                            sprintf('대기 중 편집 적용 실패:\n%s\n계속 닫을까요?', ME.message), ...
                                            'Apply 실패', ...
                                            'Options', {'그래도 닫기', '취소'}, ...
                                            'DefaultOption', 2, 'CancelOption', 2);
                                    catch
                                        cont = '';
                                    end
                                    if ~strcmp(cont, '그래도 닫기'), return; end
                                end
                            end
                            % --- Project save (must succeed or user aborts) ---
                            if isempty(app.ProjectFilePath)
                                [fn, pn] = uiputfile({'*.fdproj', 'Project file'}, '저장할 project 파일');
                                if isequal(fn, 0)
                                    return;     % user cancelled save destination
                                end
                                app.ProjectFilePath = fullfile(pn, fn);
                            end
                            okSave = false;
                            try
                                okSave = app.saveProjectFile(app.ProjectFilePath);
                            catch ME
                                app.logCaught(ME, 'close-save-project');
                            end
                            if ~okSave
                                try
                                    uialert(app.UIFigure, 'project 저장 실패. 창을 닫지 않습니다.', 'Project');
                                catch
                                end
                                return;
                            end
                            try
                                app.clearProjectAutosave();
                            catch
                            end
                            % --- Option drafts (warn on failure, ask whether to proceed) ---
                            optionFailures = {};
                            for fIdx = 1:2
                                draft = app.OptionDrafts{fIdx};
                                if isempty(draft) || ~isfield(draft, 'sourcePath') ...
                                        || isempty(draft.sourcePath)
                                    continue;
                                end
                                try
                                    okOpt = app.writeOptionFileAtomic(draft.sourcePath, draft);
                                catch ME
                                    app.logCaught(ME, 'close-save-option');
                                    okOpt = false;
                                end
                                if ~okOpt
                                    optionFailures{end+1} = draft.sourcePath; %#ok<AGROW>
                                end
                            end
                            if ~isempty(optionFailures)
                                try
                                    cont = uiconfirm(app.UIFigure, ...
                                        sprintf(['다음 option 파일 저장 실패:\n%s\n', ...
                                                 '그래도 창을 닫을까요?'], strjoin(optionFailures, newline)), ...
                                        'Option 저장 실패', ...
                                        'Options', {'그래도 닫기', '취소'}, ...
                                        'DefaultOption', 2, 'CancelOption', 2);
                                catch
                                    cont = '';
                                end
                                if ~strcmp(cont, '그래도 닫기'), return; end
                            end
                        case '버리고 닫기'
                            % Discard path: stop the autosave timer cleanly, do not write.
                            if pendingTimer
                                try
                                    stop(app.EditApplyTimer);
                                catch
                                end
                            end
                    end
                elseif pendingTimer
                    try
                        stop(app.EditApplyTimer);
                    catch
                    end
                    try
                        app.applyPendingDialogChanges();
                    catch ME
                        app.logCaught(ME, 'close-apply-no-confirm');
                    end
                end
            catch ME
                app.logCaught(ME, 'close-request');
            end

            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'close-request:clear-window-callbacks');
            end
            delete(app);
        end

        function togglePanel(app, fIdx, pnlName)
            % 패널 표시/숨김 토글 (픽셀 고정 기반 리사이징)
            state = app.UI(fIdx).PanelVisible.(pnlName);
            newState = ~state;
            app.UI(fIdx).PanelVisible.(pnlName) = newState;

            widths = app.UI(fIdx).dataGrid.ColumnWidth;

            if strcmp(pnlName, 'attitude')
                app.UI(fIdx).panelAttitude.Visible = newState;
                if newState
                    panelWidths = app.getResponsivePanelWidths();
                    widths{1} = panelWidths(1);
                    app.UI(fIdx).btnAtt.Text = '자세 ▾';
                else
                    widths{1} = 0;
                    app.UI(fIdx).btnAtt.Text = '자세 ▸';
                end
            elseif strcmp(pnlName, 'map')
                app.UI(fIdx).panelMapAlt.Visible = newState;
                if newState
                    panelWidths = app.getResponsivePanelWidths();
                    widths{2} = panelWidths(2);
                    app.UI(fIdx).btnMap.Text = '지도/고도 ▾';
                else
                    widths{2} = 0;
                    app.UI(fIdx).btnMap.Text = '지도/고도 ▸';
                end
            elseif strcmp(pnlName, 'video')
                app.UI(fIdx).panelVideo.Visible = newState;
                if newState
                    % [V3.12 2.1] 영상 로드되어 있으면 영상 비율 기반 너비 사용
                    targetWidth = app.getVideoPanelTargetWidth();
                    widths{6} = targetWidth; % 5를 6으로 수정
                    app.UI(fIdx).btnVid.Text = '비디오 ▾';
                else
                    widths{6} = 0;           % 5를 6으로 수정
                    app.UI(fIdx).btnVid.Text = '비디오 ▸';
                end
            end
            app.UI(fIdx).dataGrid.ColumnWidth = widths;
            app.reflowBoardColumns(fIdx);
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end

        % ---------------------------------------------------------------------
        % 비디오 및 동기화
        % ---------------------------------------------------------------------
        function toggleSync(app)
            if app.SyncState.IsSynced
                app.SyncState.IsSynced = false;
                app.SyncBtn.Text = '비행시간 동기';
                app.SyncBtn.BackgroundColor = [0.58 0.0 0.83];
                app.SyncInput.Enable = 'on';
                if ~isempty(app.Models(2).rawData)
                    app.UI(2).spinner.Enable = 'on';
                end
                return;
            end

            inputStr = app.SyncInput.Value;
            tokens = regexp(inputStr, '^\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)\s*$', 'tokens');
            if isempty(tokens)
                errordlg('입력 형식이 올바르지 않습니다. 예: "23.4, 34.4"', '형식 오류');
                return;
            end
            if isempty(app.Models(1).rawData) || isempty(app.Models(2).rawData)
                errordlg('두 경로 데이터가 모두 로드되어야 합니다.', '데이터 부족');
                return;
            end

            t1 = str2double(tokens{1}{1});
            t2 = str2double(tokens{1}{2});
            app.SyncState.SyncT1 = t1;
            app.SyncState.SyncT2 = t2;
            app.SyncState.IsSynced = true;

            app.SyncBtn.Text = '비행시간 동기 해제';
            app.SyncBtn.BackgroundColor = [0.8 0.2 0.2];
            app.SyncInput.Enable = 'off';
            app.UI(2).spinner.Enable = 'off';

            timeCol1 = app.Models(1).mappedCols.Time;
            idx1 = app.findClosestIndexByTime(app.Models(1).rawData.(timeCol1), t1);
            app.applyTimeChange(1, idx1);

            % [V3.20 (2)] 동기화 디버그 로그 (SyncState - 두 비행데이터 시간축 매핑)
            if app.DebugMode
                fprintf('[FlightSync] enabled: T1=%.3fs ↔ T2=%.3fs (offset=%.3fs)\n', ...
                    t1, t2, t2 - t1);
            end
        end

        % [V3.22 #3] loadAviFile 분해 - 오케스트레이터 + 6단계 헬퍼
        % 단계: 1) 사용자 확인 → 2) 캐시 무효화 → 3) 기존 자원 정리
        %       4) VR 생성 → 5) TotalFrames + UI 동기화 → 6) 첫 프레임 로드
        % 각 단계는 실패 시 명확한 종료 조건을 가지며 책임이 한정됨
        function loadAviFile(app, fIdx)
            % [User entry] file picker wrapper. For programmatic loads
            % (project auto-load, file replacement, export reopen) call
            % loadAviFileFromPath(fIdx, fullPath, opts) directly.
            [fname, pname] = uigetfile({'*.avi;*.mp4;*.mkv', 'Video Files (*.avi, *.mp4)'}, sprintf('비디오 선택 %d', fIdx));
            if isequal(fname, 0), return; end
            fullPath = fullfile(pname, fname);
            app.loadAviFileFromPath(fIdx, fullPath, struct('promptOnSync', true));
        end

        function ok = loadAviFileFromPath(app, fIdx, fullPath, opts)
            % [Audit fix #3 + #4] Path-based AVI load with no file picker.
            % opts.promptOnSync (default false): ask before clearing existing video sync.
            % opts.preserveSync (default false): keep VideoSyncState across the reload.
            %                                    Use for project auto-load and export reopen
            %                                    so restored sync values are not wiped.
            ok = false;
            if nargin < 4 || isempty(opts), opts = struct(); end
            if ~isfield(opts, 'promptOnSync'), opts.promptOnSync = false; end
            if ~isfield(opts, 'preserveSync'), opts.preserveSync = false; end
            if isempty(fullPath) || ~isfile(fullPath)
                try
                    uialert(app.UIFigure, sprintf('AVI 파일을 찾을 수 없습니다:\n%s', fullPath), 'Video');
                catch
                end
                return;
            end

            % [P1] snapshot sync state before any reset/invalidate so we can restore it.
            syncSnapshot = app.VideoSyncState(fIdx);

            % [High #2] same-path detection — preserveSync reopen 시 AsyncGen 미증가.
            samePath = false;
            try
                if numel(app.VideoFilePath) >= fIdx
                    prevAbs = app.normalizeAbsPath(app.VideoFilePath{fIdx});
                    samePath = ~isempty(prevAbs) && strcmpi(prevAbs, app.normalizeAbsPath(fullPath));
                end
            catch
            end

            if opts.preserveSync
                % Do NOT prompt and do NOT reset; we will restore the snapshot post-load.
            elseif opts.promptOnSync
                if ~app.confirmVideoReplace(fIdx), return; end
            elseif app.VideoSyncState(fIdx).IsSynced
                % Programmatic load: silently reset video sync without prompting.
                app.resetVideoSync(fIdx);
            end

            % [High #2] preserveSync + 동일 경로 재오픈인 경우 AsyncGen 유지.
            app.invalidateFrameCache(fIdx, ~(opts.preserveSync && samePath));

            % [High #4] AVI 경로가 실제로 바뀐 경우 워커 persistent VR 캐시 해제.
            % 같은 path 재오픈은 슬롯 재사용이 효율적이므로 건너뜀.
            % 비정상 종료 시 잔존 file lock 도 다음 로드 직전에 비움.
            if ~samePath
                try
                    if ~isempty(app.AsyncPool) && isvalid(app.AsyncPool)
                        parfevalOnAll(app.AsyncPool, @FlightDataDashboard.workerCleanupCache, 0);
                    end
                catch ME, app.logCaught(ME, 'loadAvi:worker-cache-cleanup'); end
            end
            startTime = app.computeStartTimeFromFlightData(fIdx);
            app.cleanupVideoResources(fIdx);

            [~, fname, fext] = fileparts(fullPath);
            vr = app.openVideoReader(fIdx, fullPath, [fname fext]);
            if isempty(vr), return; end

            % Keep both path mirrors in lockstep (#3 invariant).
            absPath = app.normalizeAbsPath(fullPath);
            app.VideoFilePath{fIdx}        = absPath;
            app.Models(fIdx).aviFilePath   = absPath;

            app.VideoState(fIdx).videoStartTime          = startTime;
            app.VideoState(fIdx).videoReader.CurrentTime = 0;
            app.LastVideoUpdate{fIdx}                    = uint64(0);

            app.applyVideoLoadedUI(fIdx, vr);
            app.loadFirstFrame(fIdx);

            % [P1] restore the snapshot so AVI sync survives project auto-load / export reopen.
            % applyVideoLoadedUI sets TotalFrames from the freshly opened reader; keep that one
            % and only restore the user-defined fields plus IsSynced state.
            if opts.preserveSync && syncSnapshot.IsSynced
                newTotal = app.VideoSyncState(fIdx).TotalFrames;
                app.VideoSyncState(fIdx).IsSynced    = true;
                app.VideoSyncState(fIdx).AnchorFrame = syncSnapshot.AnchorFrame;
                app.VideoSyncState(fIdx).AnchorTime  = syncSnapshot.AnchorTime;
                app.VideoSyncState(fIdx).VideoFps    = syncSnapshot.VideoFps;
                app.VideoSyncState(fIdx).DataFps     = syncSnapshot.DataFps;
                if newTotal <= 0, app.VideoSyncState(fIdx).TotalFrames = syncSnapshot.TotalFrames; end
                try
                    app.refreshSyncUi(fIdx);
                catch ME
                    app.logCaught(ME, 'loadAvi:refresh-sync-ui');
                end
            end
            % [Q-07] Keep Export file table current after path-based AVI changes.
            try
                app.refreshExportTab();
            catch ME
                app.logCaught(ME, 'export-refresh-avi');
            end
            ok = true;
        end

        % --------- loadAviFile 헬퍼들 (V3.22 #3) ---------

        % [V3.22 #3-1] 기존 동기 설정이 있을 때 사용자 확인 다이얼로그
        function ok = confirmVideoReplace(app, fIdx)
            ok = true;
            if app.VideoSyncState(fIdx).IsSynced
                sel = uiconfirm(app.UIFigure, ...
                    '새 영상을 로드하면 기존 비디오-비행데이터 동기 설정이 해제됩니다. 계속하시겠습니까?', ...
                    '동기 해제 확인', ...
                    'Options', {'계속', '취소'}, 'DefaultOption', 1, 'CancelOption', 2);
                if strcmp(sel, '취소'), ok = false; return; end
                app.resetVideoSync(fIdx);
            end
        end

        % [V3.22 #3-2] 프레임 캐시 비우기 (LastUse/Hits 포함)
        function invalidateFrameCache(app, fIdx, bumpAsyncGen)
            % [High #2] bumpAsyncGen 기본 true. preserveSync 재오픈처럼 동일 AVI 를
            % 다시 여는 흐름에서는 호출자가 false 를 전달해 stale-rejection 과잉 발동을 피한다.
            if nargin < 3, bumpAsyncGen = true; end
            app.FrameCache{fIdx}        = {};
            app.FrameCacheKeys{fIdx}    = [];
            app.FrameCacheHits{fIdx}    = [];
            app.FrameCacheLastUse{fIdx} = [];
            app.CacheBytesUsed(fIdx)    = 0;
            app.LastDisplayedFrame(fIdx) = 0;
            % [Stabilization P1] reset decode + pending state on AVI replace
            app.LastDecodedFrame(fIdx)   = 0;
            app.LastRequestedFrame(fIdx) = NaN;
            app.PendingVideoFrame(fIdx)  = NaN;
            app.PendingVideoMode{fIdx}   = '';
            % invalidate any in-flight async result (optional)
            if bumpAsyncGen
                app.AsyncGen(fIdx)           = app.AsyncGen(fIdx) + 1;
                app.AsyncTargetFrame(fIdx)   = NaN;
            end
        end

        % [V3.22 #3-3] 비행데이터 첫 시간 추출 (시작 오프셋용)
        function startTime = computeStartTimeFromFlightData(app, fIdx)
            startTime = 0;
            if ~isempty(app.Models(fIdx).rawData) && isfield(app.Models(fIdx).mappedCols, 'Time')
                timeCol = app.Models(fIdx).mappedCols.Time;
                if ~isempty(timeCol) && ismember(timeCol, app.Models(fIdx).rawData.Properties.VariableNames)
                    startTime = app.Models(fIdx).rawData.(timeCol)(1);
                end
            end
        end

        % [V3.22 #3-4] 기존 VideoReader / 비동기 future 명시적 정리
        function cleanupVideoResources(app, fIdx)
            try
                if ~isempty(app.VideoState(fIdx).videoReader) && ...
                   isvalid(app.VideoState(fIdx).videoReader)
                    delete(app.VideoState(fIdx).videoReader);
                end
            catch ME
                app.logCaught(ME, 'video-cleanup:reader');
            end
            try
                if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                    cancel(app.AsyncFutures{fIdx});
                    app.AsyncFutures{fIdx} = [];
                end
            catch ME
                app.logCaught(ME, 'video-cleanup:future-cancel');
            end
        end

        % [V3.22 #3-5] VideoReader 생성 (실패 시 errordlg + [] 반환)
        function vr = openVideoReader(app, fIdx, fullPath, fname)
            try
                vr = VideoReader(fullPath);
                app.VideoState(fIdx).videoReader = vr;
                % Always store canonical absolute path so picker/path callers agree.
                try
                    app.VideoFilePath{fIdx} = app.normalizeAbsPath(fullPath);
                catch
                    app.VideoFilePath{fIdx} = fullPath;
                end
                if app.DebugMode
                    fprintf('[Video] loaded: %s (fIdx=%d)\n', fname, fIdx);
                end
            catch e
                if app.DebugMode
                    fprintf('[Video] load failed: %s\n  %s\n', fullPath, e.message);
                end
                app.logCaught(e, 'Video:open');
                errordlg(['영상 로드 실패: ', e.message], '오류');
                vr = [];
            end
        end

        % [V3.22 #3-6] TotalFrames 산정 + 관련 UI 위젯/스피너/슬라이더 동기화
        function applyVideoLoadedUI(app, fIdx, vr)
            % [Major 2] core state (TotalFrames / VideoFps / CurrentFrame / cache size)
            % MUST succeed before any UI sub-step runs. Otherwise UI would show values
            % from stale VideoSyncState (e.g. wrong slider range or label).
            actualFps = 15;
            coreOk = false;
            try
                totalFrames = app.computeTotalFrames(fIdx, vr);
                totalFrames = max(1, totalFrames);
                app.VideoSyncState(fIdx).TotalFrames = totalFrames;
                hasData = ~isempty(app.Models(fIdx).rawData) && isfield(app.Models(fIdx).mappedCols, 'Time');
                if hasData
                    timeCol = app.Models(fIdx).mappedCols.Time;
                    times = app.Models(fIdx).rawData.(timeCol);
                    maxTime = max(times);
                    if maxTime > 0
                        actualFps = totalFrames / maxTime; % 정확한 소수점 FPS 계산
                    else
                        actualFps = 15;
                    end
                else
                    % 비행 데이터가 아직 없으면 기본 15 FPS
                    actualFps = 15;
                    try
                        if isprop(vr, 'FrameRate') && ~isempty(vr.FrameRate) && vr.FrameRate > 0
                            actualFps = vr.FrameRate;
                        end
                    catch ME
                        app.logCaught(ME, 'applyVideoLoadedUI:fps-prop');
                    end
                end
                app.VideoSyncState(fIdx).VideoFps = actualFps;
                app.VideoSyncState(fIdx).CurrentFrame = 1;
                app.adjustCacheSize(fIdx);
                coreOk = true;
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:core');
            end

            if ~coreOk
                % [Major 2] core failed → skip UI updates that depend on TotalFrames/VideoFps.
                % [Medium #5] Ensure TotalFrames is at least 1 so downstream goToFrame /
                % slider math cannot produce NaN / 0-division.
                try
                    if app.VideoSyncState(fIdx).TotalFrames < 1
                        app.VideoSyncState(fIdx).TotalFrames = 1;
                    end
                catch ME, app.logCaught(ME, 'applyVideoLoadedUI:totalFrames-fallback'); end
                % Surface the failure visibly so user knows video is not usable.
                try
                    uialert(app.UIFigure, ...
                        sprintf('Flight %d 영상 메타데이터 로드 실패. 슬라이더/라벨 갱신을 건너뜁니다.', fIdx), ...
                        'Video') %#ok<NOSEM>
                catch
                end
                return;
            end

            try
                if isfield(app.UI(fIdx), 'vidVideoFpsInput') && ~isempty(app.UI(fIdx).vidVideoFpsInput) ...
                        && isvalid(app.UI(fIdx).vidVideoFpsInput)
                    app.UI(fIdx).vidVideoFpsInput.Value = round(actualFps);
                end
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:fps-ui');
            end

            try
                if isfield(app.UI(fIdx), 'vidSyncFrameInput') && ~isempty(app.UI(fIdx).vidSyncFrameInput) ...
                        && isvalid(app.UI(fIdx).vidSyncFrameInput)
                    maxF = max(1, app.VideoSyncState(fIdx).TotalFrames);
                    app.UI(fIdx).vidSyncFrameInput.Limits = [1 maxF];
                    if app.UI(fIdx).vidSyncFrameInput.Value > maxF
                        app.UI(fIdx).vidSyncFrameInput.Value = 1;
                    end
                end
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:frame-input');
            end

            try
                app.updateVdubSliderRange(fIdx);
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:slider');
            end

            try
                app.updateVdubFrameLabel(fIdx, 1);
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:label');
            end

            try
                app.adjustVideoPanelWidth(fIdx);
            catch ME
                app.logCaught(ME, 'applyVideoLoadedUI:panel-size');
            end
        end

        % [V3.22 #3-7] TotalFrames 계산 (NumFrames 우선, 폴백: Duration*FrameRate)
        function totalFrames = computeTotalFrames(app, fIdx, vr)
            totalFrames = 0;
            try
                if isprop(vr, 'NumFrames') && ~isempty(vr.NumFrames) && vr.NumFrames > 0
                    totalFrames = double(vr.NumFrames);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'computeTotalFrames:NumFrames');
                totalFrames = 0;
            end
            if totalFrames < 1 && vr.FrameRate > 0
                totalFrames = floor(vr.Duration * vr.FrameRate);
            end

            % VFR/MP4 의심 시 경고
            try
                if vr.FrameRate > 0
                    estFrames = floor(vr.Duration * vr.FrameRate);
                    if totalFrames > 0 && abs(totalFrames - estFrames) / max(totalFrames,1) > 0.1
                        if app.DebugMode
                            fprintf('[Video] fIdx=%d TotalFrames mismatch: NumFrames=%d, est=%d (VFR/MP4 의심)\n', ...
                                fIdx, totalFrames, estFrames);
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'Video:vfrCheck');
            end
        end

        % [V3.22 #3-8] 첫 프레임을 정확히 디코딩하여 표시 + 캐시 저장
        function loadFirstFrame(app, fIdx)
            firstFrame = [];
            try
                firstFrame = read(app.VideoState(fIdx).videoReader, 1);
            catch
                try
                    app.VideoState(fIdx).videoReader.CurrentTime = 0;
                    if hasFrame(app.VideoState(fIdx).videoReader)
                        firstFrame = readFrame(app.VideoState(fIdx).videoReader);
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'loadFirstFrame:fallback');
                end
            end

            if ~isempty(firstFrame)
                app.setVideoImageFrame(fIdx, firstFrame);
                app.cacheStoreFrame(fIdx, 1, firstFrame);
            end
        end

        % [V3.12 2.1] 영상 가로:세로 비율에 따라 비디오 패널 너비 동적 조정
        function adjustVideoPanelWidth(app, fIdx)
            try
                targetWidth = app.getVideoPanelTargetWidth();

                if app.UI(fIdx).PanelVisible.video
                    widths = app.UI(fIdx).dataGrid.ColumnWidth;
                    widths{6} = targetWidth;  % 5를 6으로 수정
                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                end
                app.setVideoDisplaySize(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'adjustVideoPanelWidth');
            end
        end

        % [V3.14 항목 3] 동적 캐시 크기 계산: 해상도 + 사용자 예산 기반
        function adjustCacheSize(app, fIdx)
            try
                vr = app.VideoState(fIdx).videoReader;
                if isempty(vr) || ~isvalid(vr)
                    app.DynamicCacheLimit(fIdx) = app.MAX_CACHE_FRAMES;
                    return;
                end

                % 한 프레임당 메모리 사용량 (RGB uint8 기준)
                bytesPerFrame = vr.Width * vr.Height * 3;
                if bytesPerFrame <= 0
                    app.DynamicCacheLimit(fIdx) = app.MAX_CACHE_FRAMES;
                    return;
                end

                % 사용자 예산 기반 최대 프레임 수 계산
                budgetBytes = app.CacheBudgetMB * 1024 * 1024;
                maxFrames = floor(budgetBytes / bytesPerFrame);

                % 절대 상한/하한 적용
                maxFrames = max(app.MIN_CACHE_FRAMES, min(maxFrames, app.MAX_CACHE_FRAMES));
                app.DynamicCacheLimit(fIdx) = maxFrames;

                if app.DebugMode
                    fprintf('[Cache] fIdx=%d, %dx%d, budget=%dMB, limit=%d frames\n', ...
                        fIdx, vr.Width, vr.Height, app.CacheBudgetMB, maxFrames);
                end

                % 현재 캐시가 한도 초과 시 가중 evict (V3.22 #2)
                if length(app.FrameCacheKeys{fIdx}) > maxFrames
                    keys    = app.FrameCacheKeys{fIdx};
                    cache   = app.FrameCache{fIdx};
                    hits    = app.FrameCacheHits{fIdx};
                    lastUse = app.FrameCacheLastUse{fIdx};
                    nKeys = length(keys);
                    if length(hits) ~= nKeys, hits = ones(1, nKeys); end
                    if length(lastUse) ~= nKeys, lastUse = zeros(1, nKeys); end
                    [keys, cache, hits, lastUse] = app.evictByScore(fIdx, keys, cache, hits, lastUse, maxFrames, false);
                    app.FrameCacheKeys{fIdx}    = keys;
                    app.FrameCache{fIdx}        = cache;
                    app.FrameCacheHits{fIdx}    = hits;
                    app.FrameCacheLastUse{fIdx} = lastUse;
                end
            catch ME_silent
                app.logCaught(ME_silent, 'adjustCacheSize');
                app.DynamicCacheLimit(fIdx) = 50;
            end
        end

        % [V3.14 항목 3] 사용자가 GUI에서 캐시 예산 변경 시 호출
        % [V3.15 항목 3-1] isVideoReady 가드로 영상 미로드 경로의 불필요 호출 차단
        function setCacheBudget(app, budgetMB)
            try
                if budgetMB <= 0, return; end
                app.CacheBudgetMB = budgetMB;
                % 두 비행경로 중 영상이 로드된 경로만 캐시 한도 재계산
                for fIdx = 1:2
                    if app.isVideoReady(fIdx)   % [V3.15 항목 3-1] 가드
                        app.adjustCacheSize(fIdx);
                    end
                end
                if app.DebugMode
                    fprintf('[Cache] Budget changed to %d MB\n', budgetMB);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'setCacheBudget');
            end
        end

        % [V3.15 항목 5-3] DebugMode GUI 체크박스 콜백
        function toggleDebugMode(app, val)
            try
                app.DebugMode = logical(val);
                fprintf('[Debug] DebugMode = %s\n', mat2str(app.DebugMode));
            catch ME_silent
                app.logCaught(ME_silent, 'toggleDebugMode');
            end
        end

        % [V3.14 항목 5] VideoReader 유효성 검사 헬퍼 (일관성 있는 가드)
        % [Medium #6] TotalFrames > 0 도 함께 확인 — applyVideoLoadedUI core 실패 시
        % vr 은 valid 지만 TotalFrames=0 인 half-loaded 상태가 가능하므로 false 반환.
        function tf = isVideoReady(app, fIdx)
            tf = false;
            try
                if fIdx < 1 || fIdx > 2, return; end
                vr = app.VideoState(fIdx).videoReader;
                h = app.VideoState(fIdx).vidImageHandle;
                tf = ~isempty(vr) && isvalid(vr) && ~isempty(h) && isvalid(h) ...
                     && app.VideoSyncState(fIdx).TotalFrames > 0;
            catch ME_silent
                app.logCaught(ME_silent, 'isVideoReady');
                tf = false;
            end
        end

        % [V3.14 VirtualDub UI] Frame 슬라이더 범위 갱신 (영상 로드 시)
        function updateVdubSliderRange(app, fIdx)
            try
                if isfield(app.UI(fIdx), 'vidVdubSlider') && ~isempty(app.UI(fIdx).vidVdubSlider) ...
                        && isvalid(app.UI(fIdx).vidVdubSlider)
                    maxF = max(2, app.VideoSyncState(fIdx).TotalFrames);
                    sld = app.UI(fIdx).vidVdubSlider;
                    sld.Limits = [1, maxF];
                    sld.Value = 1;
                    ticks = round(linspace(1, maxF, 5));
                    sld.MajorTicks = ticks;
                    sld.MajorTickLabels = arrayfun(@num2str, ticks, 'UniformOutput', false); % 지수 표기 방지
                    sld.MinorTicks = [];
                end
            catch ME_silent
                app.logCaught(ME_silent, 'updateVdubSliderRange');
            end
        end

        % [V3.14 VirtualDub UI] Frame N / Total (HH:MM:SS.mmm) 라벨 갱신
        % [V3.15 항목 5-1] milliseconds 정확도 개선 (floor + 0.5) + 캐리오버
        function updateVdubFrameLabel(app, fIdx, frameNo)
            try
                if ~isfield(app.UI(fIdx), 'vidVdubLabel') || isempty(app.UI(fIdx).vidVdubLabel) ...
                        || ~isvalid(app.UI(fIdx).vidVdubLabel)
                    return;
                end
                total = app.VideoSyncState(fIdx).TotalFrames;
                fps = app.VideoSyncState(fIdx).VideoFps;
                if fps <= 0, fps = 70; end

                tSec = (frameNo - 1) / fps;
                hh = floor(tSec / 3600);
                mm = floor(mod(tSec, 3600) / 60);
                ss = floor(mod(tSec, 60));

                % [V3.15 항목 5-1] floor + 0.5 방식으로 부동소수점 오차 보정
                ms = floor(mod(tSec, 1) * 1000 + 0.5);
                % 반올림으로 1000이 되면 초 단위로 캐리오버
                if ms >= 1000
                    ms = 0; ss = ss + 1;
                    if ss >= 60, ss = 0; mm = mm + 1; end
                    if mm >= 60, mm = 0; hh = hh + 1; end
                end

                app.UI(fIdx).vidVdubLabel.Text = sprintf('Frame %d / %d  (%02d:%02d:%02d.%03d)', ...
                    frameNo, total, hh, mm, ss, ms);
            catch ME_silent
                app.logCaught(ME_silent, 'updateVdubFrameLabel');
            end
        end

        % [V3.15 항목 2 / V3.16 / V3.17 (1)(9)] goToFrame() - 단일 공식 진입점
        % - V3.16: InGoToFrame 재진입 가드 + onCleanup
        % - V3.17 (1)(9): coalescing - 처리 중 새 요청은 PendingFrame에 저장 후
        %                 현재 처리 완료 시 자동 흡수 (최신 frame 누락 방지)
        % - V3.17 (8): State = 'UPDATING' 표시
        function goToFrame(app, fIdx, frameNo, mode)
            if nargin < 4, mode = 'final'; end

            % [V3.17 (1)(9)] 처리 중이면 최신 요청을 Pending에 저장 후 종료
            % 현재 처리 완료 직전 coalescing 루프에서 자동 처리됨
            if app.InGoToFrame(fIdx)
                app.PendingFrame(fIdx) = frameNo;
                app.PendingMode{fIdx}  = mode;
                return;
            end

            app.InGoToFrame(fIdx) = true;
            app.State = 'UPDATING';
            cleanupObj = onCleanup(@() app.clearGoToFrameFlag(fIdx));

            % 핵심 처리 루프 (coalescing 지원)
            app.processFrameInternal(fIdx, frameNo, mode);

            % [V3.17 (1)(9) / V3.18 (3) / V3.22 #4] Pending 완전 소진 루프
            % - break 대신 continue로 누적된 모든 Pending 처리
            % - MAX_PENDING_ITERS 안전망으로 무한 루프 방지
            maxIter = app.MAX_PENDING_ITERS;
            iter = 0;
            while ~isnan(app.PendingFrame(fIdx)) && iter < maxIter
                pf = app.PendingFrame(fIdx);
                pm = app.PendingMode{fIdx};
                app.PendingFrame(fIdx) = NaN;
                app.PendingMode{fIdx}  = '';
                iter = iter + 1;
                % 같은 frame이라도 break 대신 continue → 다음 Pending 누적분 처리
                if pf == app.VideoSyncState(fIdx).CurrentFrame
                    continue;
                end
                app.processFrameInternal(fIdx, pf, pm);
            end
            if iter >= maxIter && app.DebugMode
                fprintf('[goToFrame] Pending loop hit max iterations (fIdx=%d)\n', fIdx);
            end

            % [V3.17 (5)] goToFrame 종료 시 단일 drawnow (drag/final 모두)
            drawnow limitrate;
        end

        % [V3.17 (1)(9)] goToFrame의 핵심 처리 로직 (재진입 가드 우회 - coalescing 전용)
        function processFrameInternal(app, fIdx, frameNo, mode)
            if isempty(mode), mode = 'final'; end

            % 1. 범위 검증 + clamp
            totalF = app.VideoSyncState(fIdx).TotalFrames;
            if totalF < 1, return; end
            frameNo = round(frameNo);
            frameNo = max(1, min(frameNo, totalF));

            % 2. 변경 없으면 종료
            if app.VideoSyncState(fIdx).CurrentFrame == frameNo, return; end
            app.VideoSyncState(fIdx).CurrentFrame = frameNo;

            % 3. 모든 표시 요소 일괄 동기화
            app.syncFrameMarkersAndLabel(fIdx, frameNo);

            % 4. 영상 갱신 (mode에 따라 source 선택)
            if strcmp(mode, 'drag')
                app.updateVideoFrameByFrameNo(fIdx, frameNo, 'drag');
            else
                app.updateVideoFrameByFrameNo(fIdx, frameNo, 'sync');
            end

            % 5. 동기 모드일 때 비행데이터 측도 갱신
            if app.VideoSyncState(fIdx).IsSynced && ~isempty(app.Models(fIdx).rawData)
                try
                    targetTime = app.frameToTime(fIdx, frameNo);
                    timeCol = app.Models(fIdx).mappedCols.Time;
                    times = app.Models(fIdx).rawData.(timeCol);
                    targetTime = max(times(1), min(targetTime, times(end)));
                    idx = app.findClosestIndexByTime(times, targetTime);

                    if ~isequal(app.Models(fIdx).currentIndex, idx)
                        app.DraggedFromVideo = true;
                        try
                            if strcmp(mode, 'drag')
                                app.updateMarkersOnly(fIdx, idx);
                            else
                                app.IsUpdating(fIdx) = true;
                                app.updateDashboard(fIdx, idx);
                                if isfield(app.UI(fIdx), 'spinner') && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                                    currDataTime = app.Models(fIdx).rawData.(timeCol)(idx);
                                    if abs(app.UI(fIdx).spinner.Value - currDataTime) > eps
                                        app.UI(fIdx).spinner.Value = currDataTime;
                                    end
                                end
                                app.IsUpdating(fIdx) = false;
                            end
                        catch e
                            app.IsUpdating(fIdx) = false;
                            if app.DebugMode
                                fprintf('[goToFrame] error: %s\n', e.message);
                            end
                        end
                        app.DraggedFromVideo = false;
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'processFrameInternal:data-sync');
                end
            end
            app.refreshBoardOffSummaryPanel(fIdx);
        end

        % [V3.15 항목 1] 슬라이더 드래그 중 콜백 (ValueChangingFcn)
        % - throttle 0.03s(33fps) 적용으로 디코딩 큐 적체 방지
        % - 'drag' 모드로 goToFrame 호출 → 경량 갱신만 수행
        function onVdubSliderChanging(app, fIdx, evtValue)
            % 슬라이더 throttle: 너무 자주 호출되면 무시
            if app.throttleHit('LastSliderUpdate', fIdx, app.SLIDER_THROTTLE_S), return; end

            % [V3.19 (2)] 드래그 속도 측정 (adaptive prefetch용)
            app.updateDragVelocity(fIdx, round(evtValue));

            app.goToFrame(fIdx, evtValue, 'drag');
        end

        % [V3.15 항목 1] 슬라이더 드래그 종료 시 콜백 (ValueChangedFcn)
        % - 'final' 모드로 goToFrame 호출 → 전체 패널 1회 동기화 보장
        % - [V3.16] 같은 frame이라도 drag 모드 종료 직후일 수 있으므로 updateDashboard 강제
        function onVdubSliderChanged(app, fIdx, src)
            try
                target = round(src.Value);
                if app.VideoSyncState(fIdx).CurrentFrame == target
                    % drag 모드는 updateMarkersOnly만 호출 → 테이블/게이지 stale 가능
                    % final 모드 1회 강제 호출로 전체 동기화 보장
                    if app.VideoSyncState(fIdx).IsSynced && ~isempty(app.Models(fIdx).rawData)
                        app.IsUpdating(fIdx) = true;
                        try
                            app.updateDashboard(fIdx, app.Models(fIdx).currentIndex);
                        catch
                        end
                        app.IsUpdating(fIdx) = false;
                    end
                    return;
                end
                app.goToFrame(fIdx, src.Value, 'final');
                % [V3.19 (2)] 슬라이더 드래그 종료 시 adaptive prefetch
                app.prefetchAdjacentFrames(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'onVdubSliderChanged');
            end
        end

        % [V3.16 / V3.17 (8)] goToFrame 재진입 플래그 해제 (onCleanup 콜백)
        function clearGoToFrameFlag(app, fIdx)
            app.InGoToFrame(fIdx) = false;
            if ~any(app.InGoToFrame), app.State = 'IDLE'; end
        end

        % [V3.17 (7)] 디코딩 진행 중 플래그 해제 (onCleanup 콜백)
        function clearDecodingFlag(app, fIdx)
            app.IsDecoding(fIdx) = false;
            % [Stabilization P1] Drain the latest queued user request, if any.
            try
                app.drainPendingVideoRequest(fIdx);
            catch ME
                app.logCaught(ME, 'video-pending-drain');
            end
        end

        % [V3.17 (2)] 캐시 존재 여부만 확인 (LRU 갱신 안 함)
        % [V3.18 (1)] lookup clamp 일관성
        function tf = hasCachedFrame(app, fIdx, frameNo)
            try
                totalF = app.VideoSyncState(fIdx).TotalFrames;
                if totalF >= 1
                    frameNo = max(1, min(round(frameNo), totalF));
                end
                tf = ~isempty(find(app.FrameCacheKeys{fIdx} == frameNo, 1));
            catch
                tf = false;
            end
        end

        % [V3.19 (2)] 드래그 속도 추적 (지수 이동평균)
        function updateDragVelocity(app, fIdx, newFrame)
            try
                if app.LastDragTime{fIdx} == 0, app.LastDragTime{fIdx} = tic; end
                nowT = toc(app.LastDragTime{fIdx});   % [PATCH] 채널별 상대초
                samples = app.DragVelocitySamples{fIdx};

                if isempty(samples)
                    samples = struct('time', nowT, 'frame', newFrame);
                else
                    last = samples(end);
                    dt = nowT - last.time;
                    if dt > 0.001
                        instantV = (newFrame - last.frame) / dt;
                        % 지수 이동평균 (alpha=0.3)
                        app.DragVelocity(fIdx) = 0.7 * app.DragVelocity(fIdx) + 0.3 * instantV;
                    end
                    samples(end+1) = struct('time', nowT, 'frame', newFrame);
                    if length(samples) > 5, samples(1) = []; end
                end
                app.DragVelocitySamples{fIdx} = samples;
            catch ME
                app.logCaught(ME, 'updateDragVelocity');
            end
        end

        % [PATCH] tic/toc 기반 throttle 헬퍼 - 만료 시 false 반환 + 핸들 갱신
        function hit = throttleHit(app, slotName, fIdx, limitS)
            slot = app.(slotName);
            t0 = slot{fIdx};
            if t0 ~= 0 && toc(t0) < limitS
                hit = true; return;
            end
            slot{fIdx} = tic;
            app.(slotName) = slot;
            hit = false;
        end

        % [PATCH] DebugMode 게이팅 catch 로깅 헬퍼 (핫패스 안전)
        function logCaught(app, ME, tag)
            % [V3.22 #1] silent/non-silent 모두 ring buffer에 보관
            % - DebugMode일 때만 콘솔 출력 (silent 태그는 콘솔 출력 생략)
            % - ring buffer는 항상 유지 → app.dumpErrorLog()로 사후 조사
            % [Medium] delete 진행 중에는 콘솔만 억제하고, ring buffer 태그는 보존한다.
            suppressConsole = false;
            try
                if ~isempty(app) && isvalid(app) && app.IsDeleting
                    suppressConsole = true;
                end
            catch
                suppressConsole = true;
            end
            try
                % stack은 길이가 다른 struct array일 수 있어 cell로 wrap → 차원 불일치 회피
                stackCell = {[]};
                try
                    stackCell = {ME.stack};
                catch
                end
                entry = struct( ...
                    'time',       datetime('now'), ...
                    'tag',        char(tag), ...
                    'identifier', char(ME.identifier), ...
                    'message',    char(ME.message), ...
                    'stack',      stackCell);
                if isempty(app.ErrorLog)
                    app.ErrorLog = entry;
                else
                    app.ErrorLog(end+1) = entry;
                    if numel(app.ErrorLog) > app.ErrorLogCapacity
                        app.ErrorLog = app.ErrorLog(end-app.ErrorLogCapacity+1:end);
                    end
                end
            catch
                % ring buffer 자체가 실패해도 절대 throw 안 함
            end

            if suppressConsole || ~app.DebugMode, return; end
            % silent 태그는 buffer만 남기고 콘솔에는 안 찍음 (기존 동작 유지)
            if strcmpi(tag, 'silent'), return; end
            fprintf('[%s] %s: %s\n', tag, ME.identifier, ME.message);
        end

        % [V3.22 #1] 사후 조사용: 누적된 에러 로그 콘솔 출력
        % 사용 예: app.dumpErrorLog()         → 전체 출력
        %         app.dumpErrorLog(20)        → 최근 20건
        %         app.dumpErrorLog(20, 'Async') → 최근 20건 중 'Async' 포함 태그만
        function dumpErrorLog(app, n, filterTag)
            if isempty(app.ErrorLog)
                fprintf('[ErrorLog] (empty)\n'); return;
            end
            log = app.ErrorLog;
            if nargin >= 3 && ~isempty(filterTag)
                keep = arrayfun(@(e) contains(e.tag, filterTag, 'IgnoreCase', true), log);
                log = log(keep);
            end
            if nargin >= 2 && ~isempty(n) && n > 0 && numel(log) > n
                log = log(end-n+1:end);
            end
            fprintf('[ErrorLog] %d entries:\n', numel(log));
            for k = 1:numel(log)
                try
                    tstr = char(datetime(log(k).time, 'Format', 'HH:mm:ss.SSS'));
                catch
                    try
                        tstr = char(string(log(k).time));
                    catch
                        tstr = '';
                    end
                end
                fprintf('  [%s] [%s] %s: %s\n', tstr, ...
                    log(k).tag, log(k).identifier, log(k).message);
            end
        end

        % [V3.19 (1) / V3.20 (5-2)] 비동기 디코딩 시작
        % - thread pool 우선 (직렬화 비용 0), 미지원 시 process pool 폴백
        % - 둘 다 실패하면 UseAsyncDecode=false로 자동 폴백 (재시도 안 함)
        % [PATCH Async 1.1] thread pool 사용 금지 - persistent VR이 워커 간 공유되어
        %                   race condition 발생. process pool은 워커별 독립 메모리.
        % [Static fix] Async path intentionally does NOT set IsDecoding.
        % IsDecoding/PendingVideoFrame are sync-decode coalescing state.
        % AsyncFutures/AsyncTargetFrame/AsyncGen are async in-flight state:
        % every new async request cancels/invalidates the previous future, and
        % completion displays only when generation + target + CurrentFrame match.
        function ok = startAsyncDecode(app, fIdx, frameNo)
            ok = false;
            try
                % parallel pool 준비 (없으면 지연 생성)
                if isempty(app.AsyncPool) || ~isvalid(app.AsyncPool)
                    poolOk = false;
                    % [PATCH] 기존 pool 재사용 가능하면 사용 (단, threads는 거부)
                    try
                        existing = gcp('nocreate');
                        if ~isempty(existing) && isvalid(existing)
                            poolType = class(existing);
                            if contains(poolType, 'Thread', 'IgnoreCase', true)
                                if app.DebugMode
                                    fprintf('[Async] existing thread pool rejected (race risk)\n');
                                end
                            else
                                app.AsyncPool = existing;
                                poolOk = true;
                            end
                        end
                    catch ME
                        app.logCaught(ME, 'Async:gcp');
                    end

                    % process pool 신규 생성
                    if ~poolOk
                        try
                            app.AsyncPool = parpool('local', app.ASYNC_WORKER_COUNT);
                            poolOk = true;
                            if app.DebugMode
                                fprintf('[Async] process pool ready (%d workers)\n', app.ASYNC_WORKER_COUNT);
                            end
                        catch e2
                            if app.DebugMode
                                fprintf('[Async] process pool failed: %s\n', e2.message);
                            end
                        end
                    end

                    % 실패: 영구 비활성화
                    if ~poolOk
                        app.UseAsyncDecode = false;
                        if app.DebugMode
                            fprintf('[Async] disabled - falling back to sync decode\n');
                        end
                        return;
                    end
                end

                % [V3.21 #1-A] generation counter 증가 - 신규 요청 발행
                app.AsyncGen(fIdx) = app.AsyncGen(fIdx) + 1;
                myGen = app.AsyncGen(fIdx);

                % 이전 future 취소 (구식 결과 폐기)
                try
                    if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                        cancel(app.AsyncFutures{fIdx});
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'async-start:cancel-previous');
                end
                app.AsyncTargetFrame(fIdx) = frameNo;
                fps = app.VideoSyncState(fIdx).VideoFps;
                filePath = app.VideoFilePath{fIdx};

                % [V3.21 #2-A / V3.22 #4 / V3.22 #6] persistent VR worker 함수 사용
                % static wrapper를 통해 향후 +flightdash 패키지 마이그레이션 가능
                fut = parfeval(app.AsyncPool, @FlightDataDashboard.workerDecodeFrame, 1, ...
                    filePath, frameNo, fps, app.WORKER_VR_CACHE_SLOTS);
                app.AsyncFutures{fIdx} = fut;

                % [Critical 3] afterEach displays a successful frame; afterAll runs
                % regardless of success/failure/cancel so AsyncFutures/AsyncTargetFrame
                % cannot leak when the worker errors or the cancel races completion.
                afterEach(fut, @(img) app.onAsyncDecodeComplete(fIdx, frameNo, myGen, img), 1, ...
                    'PassFuture', false);
                afterAll(fut, @(f) app.onAsyncDecodeFinally(fIdx, frameNo, myGen, f), 0, ...
                    'PassFuture', true);
                ok = true;
            catch e
                app.AsyncTargetFrame(fIdx) = NaN;
                app.AsyncFutures{fIdx} = [];
                app.UseAsyncDecode = false;
                app.logCaught(e, 'async-start');
                if app.DebugMode
                    fprintf('[Async] startAsyncDecode error: %s\n', e.message);
                end
            end
        end

        % [V3.19 (1) / V3.21 #1-A / V3.21 #3-A] 비동기 디코딩 완료 콜백 (main thread)
        % - generation 비교로 stale 결과 차단
        % - displayFrame 단일 출구 통과 (write-through)
        function onAsyncDecodeComplete(app, fIdx, frameNo, gen, img)
            % [Stabilization P0] Strong stale-frame rejection.
            % Display ONLY if every condition still holds at completion time.
            try
                if isempty(img), app.clearAsyncDecodeState(fIdx, gen); return; end

                % 1) app + figure still valid
                if isempty(app) || ~isvalid(app) ...
                        || isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                    app.clearAsyncDecodeState(fIdx, gen);
                    return;
                end
                % 2) generation must match the live generation
                if gen ~= app.AsyncGen(fIdx)
                    if app.DebugMode
                        fprintf('[Async] stale: gen mismatch (%d vs %d)\n', gen, app.AsyncGen(fIdx));
                    end
                    return;  % [Major 1] newer request exists; do NOT clear newer state
                end
                % 3) the frame we were asked to decode must still be the live async target
                if isnan(app.AsyncTargetFrame(fIdx)) || frameNo ~= app.AsyncTargetFrame(fIdx)
                    if app.DebugMode
                        fprintf('[Async] stale: target moved (frame=%d, target=%g)\n', ...
                            frameNo, app.AsyncTargetFrame(fIdx));
                    end
                    % [Major 1] same gen + obsolete target → clear so future doesn't leak
                    app.clearAsyncDecodeState(fIdx, gen);
                    return;
                end
                % 4) and must still be the currently selected frame in the video state
                if frameNo ~= app.VideoSyncState(fIdx).CurrentFrame
                    if app.DebugMode
                        fprintf('[Async] stale: CurrentFrame moved (frame=%d, cur=%d)\n', ...
                            frameNo, app.VideoSyncState(fIdx).CurrentFrame);
                    end
                    % [Major 1] CurrentFrame moved on same gen → clear
                    app.clearAsyncDecodeState(fIdx, gen);
                    return;
                end
                % 5) video still ready
                if ~app.isVideoReady(fIdx)
                    % [Major 1] video gone before display → clear
                    app.clearAsyncDecodeState(fIdx, gen);
                    return;
                end

                app.displayFrame(fIdx, frameNo, img, false);
                app.clearAsyncDecodeState(fIdx, gen);
                % [Stabilization P1] consume any newer request that arrived during async work
                try
                    app.drainPendingVideoRequest(fIdx);
                catch ME
                    app.logCaught(ME, 'async-drain');
                end
            catch ME_silent
                app.logCaught(ME_silent, 'async-complete');
            end
        end

        function clearAsyncDecodeState(app, fIdx, gen)
            try
                if nargin < 3 || gen == app.AsyncGen(fIdx)
                    app.AsyncTargetFrame(fIdx) = NaN;
                    app.AsyncFutures{fIdx} = [];
                end
            catch ME
                app.logCaught(ME, 'async-clear');
            end
        end

        function onAsyncDecodeFinally(app, fIdx, frameNo, gen, fut) %#ok<INUSL>
            % [Critical 3] Terminal-state cleanup for async decode futures.
            % Fires on Finished / Failed / Cancelled regardless of whether
            % afterEach delivered an image. Logs worker errors and guarantees
            % AsyncTargetFrame / AsyncFutures cannot leak to the next request.
            % [High #1] Detach AsyncFutures{fIdx} immediately when this is still
            % the live future for that gen — prevents a late-arriving afterAll
            % from racing a newer startAsyncDecode that already overwrote the slot.
            try
                if fIdx >= 1 && fIdx <= numel(app.AsyncFutures) ...
                        && ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx}) ...
                        && app.AsyncFutures{fIdx} == fut ...
                        && gen == app.AsyncGen(fIdx)
                    app.AsyncFutures{fIdx} = [];
                end
            catch ME, app.logCaught(ME, 'async-finally:detach'); end
            try
                if isempty(fut) || ~isvalid(fut), return; end
                state = '';
                try
                    state = char(fut.State);
                catch
                end
                hadError = false;
                try
                    if ~isempty(fut.Error)
                        app.logCaught(fut.Error, 'async-future-error');
                        hadError = true;
                    end
                catch ME
                    app.logCaught(ME, 'async-future-inspect');
                end
                if app.DebugMode && (hadError || ~strcmpi(state, 'finished'))
                    fprintf('[Async] finally fIdx=%d gen=%d frame=%d state=%s hadError=%d\n', ...
                        fIdx, gen, frameNo, state, hadError);
                end
                % Always clear when this future's generation is still the live one.
                app.clearAsyncDecodeState(fIdx, gen);
                % If this future ended without delivering a usable frame, drain pending
                % so a queued user request can proceed.
                if hadError || ~strcmpi(state, 'finished')
                    try
                        app.drainPendingVideoRequest(fIdx);
                    catch ME
                        app.logCaught(ME, 'async-finally:drain-pending');
                    end
                end
            catch ME
                app.logCaught(ME, 'async-finally');
            end
        end

        % [V3.18 (4) / V3.19 (2)] adaptive prefetch: 드래그 속도/방향 기반 prefetch 범위
        function prefetchAdjacentFrames(app, fIdx)
            try
                if ~app.isVideoReady(fIdx), return; end
                cur = app.VideoSyncState(fIdx).CurrentFrame;
                total = app.VideoSyncState(fIdx).TotalFrames;

                v = app.DragVelocity(fIdx);   % frames/sec (부호 = 방향)
                speed = abs(v);

                % [V3.19 (2)] 속도 기반 prefetch 범위
                if speed < 30
                    offsets = [-3:-1, 1:3];        % 느림: 균등 양방향
                elseif speed < 100
                    if v > 0
                        offsets = [-2, -1, 1:7];   % 정방향 우세
                    else
                        offsets = [-7:-1, 1, 2];   % 역방향 우세
                    end
                else
                    if v > 0
                        offsets = 1:12;            % 빠름: 진행방향만 깊게
                    else
                        offsets = -12:-1;
                    end
                end

                if app.DebugMode
                    fprintf('[Prefetch] fIdx=%d, v=%.1f f/s, %d offsets\n', fIdx, v, length(offsets));
                end

                % 다음 드래그용 reset
                app.DragVelocity(fIdx) = 0;
                app.DragVelocitySamples{fIdx} = [];

                for offset = offsets
                    target = cur + offset;
                    if target < 1 || target > total, continue; end
                    if app.hasCachedFrame(fIdx, target), continue; end
                    % [Stabilization P0] cache-only path; never touches displayed frame state
                    app.prefetchFrameToCacheOnly(fIdx, target);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'prefetchAdjacentFrames');
            end
        end

        % [Stabilization P0] Decode-and-cache a single frame WITHOUT touching display state.
        % Guarantees:
        %  - clamps frameNo to [1, TotalFrames]
        %  - skips when video not ready
        %  - skips when frame already cached
        %  - never calls setVideoImageFrame / displayFrame
        %  - never updates LastDisplayedFrame / VideoSyncState.CurrentFrame / slider / label
        function prefetchFrameToCacheOnly(app, fIdx, frameNo)
            try
                if ~app.isVideoReady(fIdx), return; end
                total = app.VideoSyncState(fIdx).TotalFrames;
                if total < 1, return; end
                clamped = max(1, min(round(frameNo), total));
                if app.hasCachedFrame(fIdx, clamped), return; end

                vr = app.VideoState(fIdx).videoReader;
                img = [];
                try
                    img = read(vr, clamped);
                catch
                    try
                        fps = app.VideoSyncState(fIdx).VideoFps;
                        if fps <= 0, fps = 70; end
                        relTime = max(0, (clamped - 1) / fps);
                        if relTime >= vr.Duration
                            relTime = max(0, vr.Duration - 0.05);
                        end
                        vr.CurrentTime = relTime;
                        if hasFrame(vr), img = readFrame(vr); end
                    catch ME
                        app.logCaught(ME, 'prefetch:fallback');
                    end
                end
                if isempty(img), return; end
                % Only mutates cache state; explicitly DOES NOT update LastDisplayedFrame.
                app.cacheStoreFrame(fIdx, clamped, img);
                % LastDecodedFrame is OK to update so seq-read heuristic can still benefit.
                app.LastDecodedFrame(fIdx) = clamped;
            catch ME_silent
                app.logCaught(ME_silent, 'prefetchFrameToCacheOnly');
            end
        end

        % [V3.14 VirtualDub UI] ◄◄ ◄ ► ►► 네비게이션 버튼 콜백
        % [V3.15 항목 2] goToFrame 단일 진입점 사용
        function onVdubNav(app, fIdx, action)
            try
                if ~app.isVideoReady(fIdx), return; end
                cur = app.VideoSyncState(fIdx).CurrentFrame;
                total = app.VideoSyncState(fIdx).TotalFrames;
                if total < 1, return; end

                switch action
                    % [수정 2] 10 프레임씩 뒤로/앞으로 이동하도록 변경
                    case 'first',  newFrame = max(1, cur - 10);
                    case 'prev',   newFrame = max(1, cur - 1);
                    case 'next',   newFrame = min(total, cur + 1);
                    case 'last',   newFrame = min(total, cur + 10);
                    otherwise,     newFrame = cur;
                end

                if newFrame == cur, return; end
                app.goToFrame(fIdx, newFrame, 'final');
            catch ME_silent
                app.logCaught(ME_silent, 'onVdubNav');
            end
        end

        % [V3.14 VirtualDub UI] Frame 마커/슬라이더/라벨 일괄 동기화 헬퍼
        function syncFrameMarkersAndLabel(app, fIdx, frameNo)
            try
                % [수정] 사용하지 않는 옛날 마커 갱신 코드는 완전히 삭제하여 에러 원천 차단

                % 1. 슬라이더 위치 갱신
                if isfield(app.UI(fIdx), 'vidVdubSlider') && ~isempty(app.UI(fIdx).vidVdubSlider) ...
                        && isvalid(app.UI(fIdx).vidVdubSlider)
                    if abs(app.UI(fIdx).vidVdubSlider.Value - frameNo) > 0.5
                        app.UI(fIdx).vidVdubSlider.Value = frameNo;
                    end
                end

                % 2. 라벨 텍스트 갱신 (에러 없이 안전하게 도달)
                app.updateVdubFrameLabel(fIdx, frameNo);

            catch ME_silent
                app.logCaught(ME_silent, 'video-marker-label');
            end
        end

        % [V3.12] 비디오 동기 상태 초기화
        function resetVideoSync(app, fIdx)
            app.VideoSyncState(fIdx).IsSynced = false;
            app.VideoSyncState(fIdx).AnchorFrame = 0;
            app.VideoSyncState(fIdx).AnchorTime = 0;
            try
                if isfield(app.UI(fIdx), 'vidSyncBtn') && ~isempty(app.UI(fIdx).vidSyncBtn) && isvalid(app.UI(fIdx).vidSyncBtn)
                    app.UI(fIdx).vidSyncBtn.Text = '동기';
                    app.UI(fIdx).vidSyncBtn.BackgroundColor = [0.58 0.0 0.83];
                end
                if isfield(app.UI(fIdx), 'vidSyncStatus') && ~isempty(app.UI(fIdx).vidSyncStatus) && isvalid(app.UI(fIdx).vidSyncStatus)
                    app.UI(fIdx).vidSyncStatus.Text = '동기 미설정';
                    app.UI(fIdx).vidSyncStatus.FontColor = [0.5 0.5 0.5];
                end
            catch ME_silent
                app.logCaught(ME_silent, 'resetVideoSync:update-ui');
            end
        end

        % [V3.12 2.2.3] 동기 버튼 콜백 - 입력값 검증 및 동기 설정
        function applyVideoSync(app, fIdx)
            % 동기 해제 모드
            if app.VideoSyncState(fIdx).IsSynced
                app.resetVideoSync(fIdx);
                return;
            end

            % 1. 영상/데이터 로드 검증
            if isempty(app.VideoState(fIdx).videoReader)
                errordlg('먼저 AVI 파일을 로드하세요.', '동기 오류'); return;
            end
            if isempty(app.Models(fIdx).rawData)
                errordlg('먼저 비행데이터(CSV)를 로드하세요.', '동기 오류'); return;
            end

            % 2. 입력값 추출
            frameNo = app.UI(fIdx).vidSyncFrameInput.Value;
            timeVal = app.UI(fIdx).vidSyncTimeInput.Value;

            % 3. 범위 검증
            totalFrames = app.VideoSyncState(fIdx).TotalFrames;
            timeCol = app.Models(fIdx).mappedCols.Time;
            times = app.Models(fIdx).rawData.(timeCol);

            if frameNo < 1 || frameNo > totalFrames
                errordlg(sprintf('Frame No는 1 ~ %d 범위여야 합니다.', totalFrames), '범위 오류'); return;
            end
            if timeVal < times(1) || timeVal > times(end)
                errordlg(sprintf('Time(s)는 %.3f ~ %.3f 범위여야 합니다.', times(1), times(end)), '범위 오류'); return;
            end

            % 4. Hz 값 갱신
            vfpsUI = app.UI(fIdx).vidVideoFpsInput.Value;
            dfps = app.UI(fIdx).vidDataFpsInput.Value;
            if vfpsUI < 1 || dfps < 1
                errordlg('Hz 값은 1 이상이어야 합니다.', '입력 오류'); return;
            end

            % [수정 3] 소수점 정밀도 유실 방지 로직
            % 내부의 정확한 소수점 FPS를 반올림한 값과 현재 UI 스피너의 값이 같다면,
            % 사용자가 스피너를 수동 조작하지 않은 것으로 간주하여 정확한 내부 소수점 FPS를 유지함.
            if round(app.VideoSyncState(fIdx).VideoFps) == vfpsUI
                % do nothing (소수점 정밀도 유지)
            else
                app.VideoSyncState(fIdx).VideoFps = vfpsUI; % 사용자가 스피너를 바꾼 경우에만 갱신
            end

            app.VideoSyncState(fIdx).DataFps = dfps;

            % 5. 동기 정보 저장
            app.VideoSyncState(fIdx).IsSynced = true;
            app.VideoSyncState(fIdx).AnchorFrame = frameNo;
            app.VideoSyncState(fIdx).AnchorTime = timeVal;

            % 6. UI 피드백
            app.UI(fIdx).vidSyncBtn.Text = '동기 해제';
            app.UI(fIdx).vidSyncBtn.BackgroundColor = [0.8 0.2 0.2];
            app.UI(fIdx).vidSyncStatus.Text = sprintf('동기 완료 (F%d ↔ %.3fs)', frameNo, timeVal);
            app.UI(fIdx).vidSyncStatus.FontColor = [0.06 0.65 0.50];

            % [V3.14 항목 4 / V3.17 (6) / V3.19 (3) / V3.22 #2] 동기 재설정 시 캐시 무효화
            app.FrameCache{fIdx} = {};
            app.FrameCacheKeys{fIdx} = [];
            app.FrameCacheHits{fIdx} = [];
            app.FrameCacheLastUse{fIdx} = [];
            app.CacheBytesUsed(fIdx) = 0;
            app.LastDisplayedFrame(fIdx) = 0;   % [PATCH] 조기반환 키 리셋
            if app.DebugMode
                fprintf('[VideoSync] fIdx=%d, anchor F%d ↔ %.3fs, vfps=%d, dfps=%d, cache cleared\n', ...
                    fIdx, frameNo, timeVal, vfpsUI, dfps);
            end
        end

        % [V3.12 2.2.3.1] Hz 입력 ± 화살표 버튼 콜백 (1Hz 단위)
        function adjustHzValue(app, fIdx, target, delta)
            try
                if strcmp(target, 'video')
                    fld = app.UI(fIdx).vidVideoFpsInput;
                else
                    fld = app.UI(fIdx).vidDataFpsInput;
                end
                newVal = fld.Value + delta;
                if newVal < 1, newVal = 1; end
                if newVal > 1000, newVal = 1000; end
                fld.Value = newVal;

                % 즉시 VideoSyncState에도 반영 (동기 설정 전이라도)
                if strcmp(target, 'video')
                    app.VideoSyncState(fIdx).VideoFps = newVal;
                else
                    app.VideoSyncState(fIdx).DataFps = newVal;
                end
            catch ME_silent
                app.logCaught(ME_silent, 'adjustHzValue');
            end
        end

        % [V3.12 2.2.3.1] Hz 직접 입력 시 콜백 (스피너 ValueChangedFcn)
        function onHzInputChanged(app, fIdx, target, newVal)
            try
                if newVal < 1, newVal = 1; end
                if newVal > 1000, newVal = 1000; end
                if strcmp(target, 'video')
                    app.VideoSyncState(fIdx).VideoFps = newVal;
                else
                    app.VideoSyncState(fIdx).DataFps = newVal;
                end
            catch ME_silent
                app.logCaught(ME_silent, 'onHzInputChanged');
            end
        end

        % [V3.12 2.2.3] Frame No → Time 매핑 (앵커 기반 선형)
        function timeVal = frameToTime(app, fIdx, frameNo)
            s = app.VideoSyncState(fIdx);
            if s.VideoFps <= 0
                timeVal = s.AnchorTime; return;
            end
            timeVal = s.AnchorTime + (frameNo - s.AnchorFrame) / s.VideoFps;
        end

        % [V3.12 2.2.3] Time → Frame No 매핑
        function frameNo = timeToFrame(app, fIdx, timeVal)
            s = app.VideoSyncState(fIdx);
            frameNo = round(s.AnchorFrame + (timeVal - s.AnchorTime) * s.VideoFps);
            frameNo = max(1, min(frameNo, s.TotalFrames));
        end

        % [V3.13 C-1] 프레임 캐시 조회 (LRU)
        % [V3.18 (1)] lookup도 clamp 적용 - store 키와 일관성 보장
        function img = cacheGetFrame(app, fIdx, frameNo)
            % [V3.22 #2] LRU 갱신을 lastUse 카운터로만 처리
            % 기존: cell 배열에서 삭제 후 끝에 재삽입 → 큰 프레임 reference shuffle
            % 변경: lastUse 배열만 업데이트 → cache cell 자체는 그대로 유지
            img = [];
            try
                % [V3.18 (1)] 안전망: 호출처가 clamp 누락해도 보호
                totalF = app.VideoSyncState(fIdx).TotalFrames;
                if totalF >= 1
                    frameNo = max(1, min(round(frameNo), totalF));
                end
                keys = app.FrameCacheKeys{fIdx};
                if isempty(keys), return; end
                foundIdx = find(keys == frameNo, 1);
                if isempty(foundIdx), return; end

                cache = app.FrameCache{fIdx};
                img = cache{foundIdx};

                % [V3.22 #2] 사용 카운터 단조 증가 + lastUse 갱신
                app.FrameCacheUseCounter = app.FrameCacheUseCounter + 1;
                lastUse = app.FrameCacheLastUse{fIdx};
                % 길이 동기화 (방어적)
                if length(lastUse) < length(keys)
                    lastUse(end+1:length(keys)) = 0;
                end
                lastUse(foundIdx) = app.FrameCacheUseCounter;
                app.FrameCacheLastUse{fIdx} = lastUse;

                % [V3.19 (3)] 히트 카운터 갱신 (가중 LRU score용)
                hits = app.FrameCacheHits{fIdx};
                if length(hits) < length(keys)
                    hits(end+1:length(keys)) = 1;
                end
                hits(foundIdx) = hits(foundIdx) + 1;
                app.FrameCacheHits{fIdx} = hits;
            catch ME_silent
                app.logCaught(ME_silent, 'cacheGet');
                img = [];
            end
        end

        % [V3.13 C-1 / V3.14 / V3.17 (6) / V3.19 (3) / V3.22 #2] 프레임 캐시 저장
        % - 가중 LRU: score = (hits * lastUseRecency) / bytes
        %   → 자주 + 최근에 액세스된 작은 frame 보호, 오래되고 큰 frame 우선 evict
        function cacheStoreFrame(app, fIdx, frameNo, img)
            try
                keys    = app.FrameCacheKeys{fIdx};
                cache   = app.FrameCache{fIdx};
                hits    = app.FrameCacheHits{fIdx};
                lastUse = app.FrameCacheLastUse{fIdx};

                % [PATCH] 길이 동기화 - 양방향 보정
                nKeys = length(keys);
                if length(hits) < nKeys, hits(end+1:nKeys) = 1;
                elseif length(hits) > nKeys, hits = hits(1:nKeys); end
                if length(lastUse) < nKeys, lastUse(end+1:nKeys) = 0;
                elseif length(lastUse) > nKeys, lastUse = lastUse(1:nKeys); end

                % 사용 카운터 단조 증가
                app.FrameCacheUseCounter = app.FrameCacheUseCounter + 1;
                useNow = app.FrameCacheUseCounter;

                % 이미 있으면 in-place 갱신 (cell 재배치 없음)
                foundIdx = find(keys == frameNo, 1);
                if ~isempty(foundIdx)
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) - numel(cache{foundIdx});
                    cache{foundIdx}    = img;
                    lastUse(foundIdx)  = useNow;
                    % hits는 그대로 누적 (덮어쓰기로 hit 카운트 리셋하지 않음)
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) + numel(img);
                else
                    % 신규 추가 (끝에 append)
                    keys(end+1)    = frameNo;
                    cache{end+1}   = img;
                    hits(end+1)    = 1;
                    lastUse(end+1) = useNow;
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) + numel(img);
                end

                % frame 수 한도 초과 시 가중 evict
                limit = app.DynamicCacheLimit(fIdx);
                if limit < app.MIN_CACHE_FRAMES, limit = app.MIN_CACHE_FRAMES; end
                if limit > app.MAX_CACHE_FRAMES, limit = app.MAX_CACHE_FRAMES; end

                [keys, cache, hits, lastUse] = app.evictByScore(fIdx, keys, cache, hits, lastUse, limit, false);

                % [V3.18 (5)] 절대 메모리 hard limit
                hardLimitBytes = app.CacheBudgetMB * 1024 * 1024;
                [keys, cache, hits, lastUse] = app.evictByScore(fIdx, keys, cache, hits, lastUse, hardLimitBytes, true);

                app.FrameCacheKeys{fIdx}    = keys;
                app.FrameCache{fIdx}        = cache;
                app.FrameCacheHits{fIdx}    = hits;
                app.FrameCacheLastUse{fIdx} = lastUse;
            catch e
                if app.DebugMode
                    fprintf('[Cache] cacheStoreFrame failed: %s\n', e.message);
                end
                app.logCaught(e, 'cacheStore');
            end
        end

        % [V3.22 #2] 가중 LRU evict 통합 헬퍼 (frame수 한도 / bytes 한도 공용)
        % - byBytes=false: limit는 frame 개수
        % - byBytes=true : limit는 누적 바이트
        % - score = (hits * recency) / bytes
        %   recency: lastUse가 클수록(최근일수록) 보호. 가장 오래된 항목은 useCounter 차이로 차등화
        function [keys, cache, hits, lastUse] = evictByScore(app, fIdx, keys, cache, hits, lastUse, limit, byBytes)
            while length(keys) > 1
                if byBytes
                    if app.CacheBytesUsed(fIdx) <= limit, break; end
                else
                    if length(keys) <= limit, break; end
                end
                bytesArr = cellfun(@numel, cache);
                % recency 정규화: 최신 항목 기준 상대값 (0~1)
                useNow = double(app.FrameCacheUseCounter);
                if useNow <= 0, useNow = 1; end
                recency = double(lastUse) ./ useNow;
                recency = max(recency, 0.01);   % 0 보호
                scores = (double(hits) .* recency) ./ max(double(bytesArr), 1);

                % 최신(가장 마지막에 추가된) 항목은 보호하지 않고 score로만 평가하되,
                % 안전을 위해 length(keys)-1까지에서만 victim 선택
                [~, evictIdx] = min(scores(1:end-1));
                app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) - bytesArr(evictIdx);
                keys(evictIdx)    = [];
                cache(evictIdx)   = [];
                hits(evictIdx)    = [];
                lastUse(evictIdx) = [];
            end
        end

        % =====================================================================
        % [V3.21 #3-A] 3계층 분리 구조 - 책임 명확화
        %
        %   Layer 1: requestFrame  - 진입점 + 캐시 lookup + 전략 선택
        %   Layer 2: decodeFrameSync - 동기 디코딩 (read or 폴백)
        %            startAsyncDecode - 비동기 디코딩 (별도 메서드, 기존)
        %   Layer 3: displayFrame  - 표시 + 캐시 store (단일 출구)
        %
        % 기존 updateVideoFrameByFrameNo는 호환을 위해 requestFrame로 위임.
        % =====================================================================

        % [V3.21 #3-A Layer 1] Frame 요청 진입점
        % source: 'drag' / 'autoplay' / 'sync' / 'force'
        function requestFrame(app, fIdx, frameNo, source)
            if nargin < 4, source = 'force'; end

            % 유효성 검사
            if ~app.isVideoReady(fIdx), return; end

            % autoplay throttle 분기
            if strcmp(source, 'autoplay')
                if app.throttleHit('LastVideoUpdate', fIdx, app.VIDEO_THROTTLE_S), return; end
            end

            % clamp (lookup/store 키 일관성)
            totalF = app.VideoSyncState(fIdx).TotalFrames;
            clampedFrame = max(1, min(round(frameNo), max(1, totalF)));

            % [Stabilization P1] Track the latest user-requested frame.
            app.LastRequestedFrame(fIdx) = clampedFrame;

            % 동일 프레임 조기 반환 - 실제 표시된 frame 기준
            if app.LastDisplayedFrame(fIdx) == clampedFrame, return; end

            % Layer 1: 캐시 lookup
            cached = app.cacheGetFrame(fIdx, clampedFrame);
            if ~isempty(cached)
                app.displayFrame(fIdx, clampedFrame, cached, true);  % cacheHit=true
                return;
            end

            % [Stabilization P1] 디코딩 진행 중이면 latest pending 만 보관 후 return.
            % 디코드 완료 시 clearDecodingFlag/onAsyncDecodeComplete 가 drainPendingVideoRequest 를 호출.
            if app.IsDecoding(fIdx)
                app.PendingVideoFrame(fIdx) = clampedFrame;
                app.PendingVideoMode{fIdx}  = source;
                return;
            end

            % [Stabilization P0] 'final' 진입은 진행 중 async 결과를 무효화한다
            if strcmp(source, 'final')
                app.AsyncGen(fIdx) = app.AsyncGen(fIdx) + 1;
                app.AsyncTargetFrame(fIdx) = NaN;
            end

            % 전략 선택: async vs sync
            if app.UseAsyncDecode && strcmp(source, 'drag')
                if app.startAsyncDecode(fIdx, clampedFrame)
                    return;
                end
                % Async unavailable/failure: continue through sync path once.
            end

            % Layer 2: 동기 디코딩
            app.IsDecoding(fIdx) = true;
            cleanup2 = onCleanup(@() app.clearDecodingFlag(fIdx));

            img = app.decodeFrameSync(fIdx, clampedFrame);
            if ~isempty(img)
                app.displayFrame(fIdx, clampedFrame, img, false);  % cacheHit=false
            end
        end

        % [Stabilization P1] Process the latest pending video request (if any).
        % Called once after a decode completes. Only the newest request matters.
        function drainPendingVideoRequest(app, fIdx)
            try
                if isnan(app.PendingVideoFrame(fIdx)), return; end
                target = app.PendingVideoFrame(fIdx);
                mode   = app.PendingVideoMode{fIdx};
                app.PendingVideoFrame(fIdx) = NaN;
                app.PendingVideoMode{fIdx}  = '';
                % Skip stale intermediate if the newest user request differs and is also pending.
                if app.LastDisplayedFrame(fIdx) == target, return; end
                app.requestFrame(fIdx, target, mode);
            catch ME
                app.logCaught(ME, 'drainPendingVideoRequest');
            end
        end

        % [V3.21 #3-A Layer 2] 동기 디코딩 (read or 폴백)
        function img = decodeFrameSync(app, fIdx, clampedFrame)
            img = [];
            vr = app.VideoState(fIdx).videoReader;

            % [PATCH Async 1.2 / V3.22 #4] 작은 step 휴리스틱 - 직전 표시 프레임 근처면 readFrame 순차
            % MP4 역방향 seek는 매우 비싸므로 전진 방향 작은 step만 readFrame 사용
            try
                % [Stabilization P1] seq-read heuristic uses last DECODED frame (read position
                % of the VideoReader), not last DISPLAYED frame.
                lastF = app.LastDecodedFrame(fIdx);
                step = clampedFrame - lastF;
                if lastF > 0 && step >= 1 && step <= app.MAX_SEQ_READ_STEP
                    for k = 1:step
                        if hasFrame(vr), img = readFrame(vr); else, img = []; break; end
                    end
                    if ~isempty(img)
                        app.LastDecodedFrame(fIdx) = clampedFrame;
                        return;
                    end
                end
            catch ME
                app.logCaught(ME, 'decodeSync:seq');
            end

            try
                img = read(vr, clampedFrame);
            catch
                % 폴백: CurrentTime + readFrame
                try
                    fps = app.VideoSyncState(fIdx).VideoFps;
                    if fps <= 0, fps = 70; end
                    relTime = (clampedFrame - 1) / fps;
                    if relTime < 0, relTime = 0; end
                    if relTime >= vr.Duration
                        relTime = max(0, vr.Duration - 0.05);
                    end
                    vr.CurrentTime = relTime;
                    if hasFrame(vr)
                        img = readFrame(vr);
                    end
                catch ME
                    app.logCaught(ME, 'decodeSync:fallback');
                    img = [];
                end
            end
            % [Stabilization P1] Track read position for seq heuristic.
            if ~isempty(img), app.LastDecodedFrame(fIdx) = clampedFrame; end
        end

        % [V3.21 #3-A Layer 3] 단일 표시 출구 - 모든 디코딩 결과는 여기 통과
        function displayFrame(app, fIdx, frameNo, img, isCacheHit)
            try
                if ~app.isVideoReady(fIdx) || isempty(img), return; end
                app.setVideoImageFrame(fIdx, img);
                app.LastDisplayedFrame(fIdx) = frameNo;   % [PATCH] 조기반환 키

                % 캐시 store (히트 아닐 때만 - cache-first write-through)
                if ~isCacheHit
                    app.cacheStoreFrame(fIdx, frameNo, img);
                end
            catch ME
                app.logCaught(ME, 'displayFrame');
            end
        end

        % [V3.13 / V3.14 / V3.21 호환] 기존 updateVideoFrameByFrameNo는
        % requestFrame로 위임 (외부 호출처 호환 유지)
        function updateVideoFrameByFrameNo(app, fIdx, frameNo, source)
            if nargin < 4, source = 'force'; end
            app.requestFrame(fIdx, frameNo, source);
        end

        function updateVideoFrame(app, fIdx, currentTime, force)
            if nargin < 4, force = false; end

            try
                if isempty(app.VideoState(fIdx).videoReader) || isempty(app.VideoState(fIdx).vidImageHandle) || ~isvalid(app.VideoState(fIdx).vidImageHandle)
                    return;
                end
            catch
                return;
            end

            if ~force
                if app.throttleHit('LastVideoUpdate', fIdx, app.VIDEO_THROTTLE_S), return; end
            end

            try
                relTime = currentTime - app.VideoState(fIdx).videoStartTime;
                if isnan(relTime) || ~isfinite(relTime), return; end
                if relTime < 0, relTime = 0; end
                if relTime >= app.VideoState(fIdx).videoReader.Duration
                    relTime = max(0, app.VideoState(fIdx).videoReader.Duration - 0.1);
                end

                app.VideoState(fIdx).videoReader.CurrentTime = relTime;
                if hasFrame(app.VideoState(fIdx).videoReader)
                    frame = readFrame(app.VideoState(fIdx).videoReader);
                    app.setVideoImageFrame(fIdx, frame);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'displayFrameLegacy');
            end
        end

        % ---------------------------------------------------------------------
        % 마커 클릭 & 드래그 이벤트 전용 핸들러 (스턱 방어 강화)
        % ---------------------------------------------------------------------
        function startPlotMarkerDrag(app, fIdx, ~, src, event)
            % 마우스 왼쪽 버튼 클릭 시에만 실행 (우클릭 등 제외)
            if event.Button ~= 1, return; end
            if isempty(app.Models(fIdx).rawData), return; end
            if app.SyncState.IsSynced && fIdx == 2, return; end

            % 드래그 상태 활성화 및 객체 HitTest 끄기
            app.IsDraggingMarker = true;
            app.DraggedMarker = src;
            app.DraggedFIdx = fIdx;   % [V3.11 B] 드래그 종료 시 전체 동기화용
            app.DraggedFromVideo = false;   % [V3.12] 비행데이터 측에서 시작
            app.VideoThrottleDyn = 0.05;    % [V3.12] 동적 throttle 초기값 20fps
            app.LastDragTime{fIdx} = tic;
            app.State = 'DRAGGING';   % [V3.17 (8)]
            src.HitTest = 'off';

            % 드래그 중 Axes의 기본 조작(Pan/Zoom) 끄기 (마우스 뗌 씹힘 방지)
            try
                ax = src.Parent;
                if isvalid(ax) && isprop(ax, 'Interactions')
                    app.DraggedMarker.UserData = ax.Interactions; % 기존 설정 백업
                    ax.Interactions = []; % 드래그 중 내장 Pan 비활성화
                end
            catch ME
                app.logCaught(ME, 'startPlotMarkerDrag:disable-interactions');
            end

            % [V3.11 B] 드래그 중 XLim 리스너 일시 중단
            app.setXLimListenersEnabled(fIdx, false);

            % [V3.11 C] 드래그 중 xline을 불투명(Alpha=1)으로 전환 → 렌더링 가속
            try
                for tIdx = 1:length(app.UI(fIdx).timeLines)
                    tlArr = app.UI(fIdx).timeLines{tIdx};
                    for k = 1:length(tlArr)
                        if ~isempty(tlArr{k}) && isvalid(tlArr{k})
                            tlArr{k}.Alpha = 1.0;
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'timeLine') && ~isempty(app.UI(fIdx).timeLine) && isvalid(app.UI(fIdx).timeLine)
                    app.UI(fIdx).timeLine.Alpha = 1.0;
                end
            catch ME
                app.logCaught(ME, 'startPlotMarkerDrag:xline-alpha');
            end

            app.UIFigure.WindowButtonMotionFcn = @(~,~) app.plotMarkerDragMotion(fIdx);
            app.UIFigure.WindowButtonUpFcn = @(~,~) app.stopPlotMarkerDrag();
        end

        % [V3.12 2.2.2] 비디오 Frame 마커 드래그 시작 핸들러
        function startVideoFrameDrag(app, fIdx, src, event)
            if event.Button ~= 1, return; end
            if isempty(app.VideoState(fIdx).videoReader), return; end

            app.IsDraggingMarker = true;
            app.DraggedMarker = src;
            app.DraggedFIdx = fIdx;
            app.DraggedFromVideo = true;   % ⭐ 비디오 측에서 드래그 시작
            app.VideoThrottleDyn = 0.05;
            app.LastDragTime{fIdx} = tic;
            app.State = 'DRAGGING';   % [V3.17 (8)]
            src.HitTest = 'off';

            try
                ax = src.Parent;
                if isvalid(ax) && isprop(ax, 'Interactions')
                    app.DraggedMarker.UserData = ax.Interactions;
                    ax.Interactions = [];
                end
            catch ME
                app.logCaught(ME, 'startVideoFrameDrag:disable-interactions');
            end

            % XLim 리스너 중단 (비행데이터와 동일 정책)
            app.setXLimListenersEnabled(fIdx, false);

            app.UIFigure.WindowButtonMotionFcn = @(~,~) app.videoFrameDragMotion(fIdx);
            app.UIFigure.WindowButtonUpFcn = @(~,~) app.stopPlotMarkerDrag();
        end

        function plotMarkerDragMotion(app, fIdx)
            if ~app.IsDraggingMarker, return; end
            try
                if isempty(app.DraggedMarker) || ~isvalid(app.DraggedMarker), return; end

                ax = app.DraggedMarker.Parent;
                if isempty(ax) || ~isvalid(ax), return; end

                pt = ax.CurrentPoint;
                if isempty(pt) || any(isnan(pt(:))) || any(~isfinite(pt(:)))
                    return;
                end

                % [V3.13] V3.12 동적 throttle 호출 제거 - source 기반 절충 throttle 사용

                % [V3.11 C] 드래그 중에는 경량 경로로만 업데이트
                targetTime = pt(1,1);
                timeCol = app.Models(fIdx).mappedCols.Time;
                times = app.Models(fIdx).rawData.(timeCol);
                if isempty(times), return; end

                targetTime = max(min(targetTime, times(end)), times(1));
                idx = app.findClosestIndexByTime(times, targetTime);

                if isequal(app.Models(fIdx).currentIndex, idx), return; end
                app.updateMarkersOnly(fIdx, idx);
            catch ME_silent
                app.logCaught(ME_silent, 'plotMarkerDragMotion');
            end
        end

        % [V3.12 2.2.2] 비디오 Frame 마커 드래그 모션 핸들러
        % [V3.12 2.2.2] 비디오 Frame 마커 별표 드래그 모션 핸들러
        % [V3.15 항목 2] goToFrame 단일 진입점 사용으로 리팩토링
        function videoFrameDragMotion(app, fIdx)
            if ~app.IsDraggingMarker, return; end
            try
                if isempty(app.DraggedMarker) || ~isvalid(app.DraggedMarker), return; end

                ax = app.DraggedMarker.Parent;
                if isempty(ax) || ~isvalid(ax), return; end

                pt = ax.CurrentPoint;
                if isempty(pt) || any(isnan(pt(:))) || any(~isfinite(pt(:)))
                    return;
                end

                targetFrame = round(pt(1,1));
                totalFrames = app.VideoSyncState(fIdx).TotalFrames;
                if totalFrames < 1, return; end

                % [V3.19 (2)] 드래그 속도 측정 (adaptive prefetch용)
                app.updateDragVelocity(fIdx, targetFrame);

                % [V3.15 항목 2] 단일 진입점 통과 - 'drag' 모드로 경량 갱신
                app.goToFrame(fIdx, targetFrame, 'drag');
                drawnow limitrate;
            catch ME_silent
                app.logCaught(ME_silent, 'videoFrameDragMotion');
            end
        end

        % [V3.12 영상 동적 throttle 계산]
        % - 드래그 이동이 빠르면 throttle 간격을 늘려 영상 갱신 빈도를 줄임 (5fps까지)
        % - 느리면 간격을 줄여 영상이 부드럽게 따라오게 함 (20fps까지)
        function computeDynamicVideoThrottle(app)
            try
                fIdx = app.DraggedFIdx;
                if fIdx < 1 || fIdx > 2, return; end
                if app.LastDragTime{fIdx} == 0, app.LastDragTime{fIdx} = tic; return; end
                dt = toc(app.LastDragTime{fIdx});
                app.LastDragTime{fIdx} = tic;

                if dt <= 0, return; end

                % 이동 빈도가 60fps에 가까울수록(dt 작을수록) 영상은 적게 갱신
                % dt=0.016(60fps) → throttle 0.20 (5fps)
                % dt=0.05 (20fps) → throttle 0.10 (10fps)
                % dt=0.1+(10fps 이하) → throttle 0.05 (20fps)
                if dt < 0.025
                    target = 0.20;
                elseif dt < 0.06
                    target = 0.10;
                else
                    target = 0.05;
                end

                % 부드러운 전이 (지수 가중 이동평균)
                app.VideoThrottleDyn = 0.7 * app.VideoThrottleDyn + 0.3 * target;
            catch ME_silent
                app.logCaught(ME_silent, 'computeDynamicVideoThrottle');
            end
        end

        % [PATCH UX-3] H↔I 패널 경계 splitter 드래그 핸들러
        function startHISplitterDrag(app, fIdx)
            try
                app.HISplitterFIdx = fIdx;
                app.IsDraggingSplitter = true;
                app.UIFigure.WindowButtonMotionFcn = @(~,~) app.hiSplitterMotion();
                app.UIFigure.WindowButtonUpFcn    = @(~,~) app.stopHISplitterDrag();
                if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'left-right'; end
            catch ME
                app.logCaught(ME, 'HISplitter:start');
            end
        end

        function hiSplitterMotion(app)
            if ~app.IsDraggingSplitter, return; end
            try
                fIdx = app.HISplitterFIdx;
                if fIdx < 1 || fIdx > 2, return; end
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg) || numel(dg.ColumnWidth) < 6, return; end
                figPos  = app.UIFigure.CurrentPoint;
                gridPos = getpixelposition(dg, true);
                gridW   = gridPos(3);
                mouseX_in_grid = figPos(1) - gridPos(1);
                newVideoW = gridW - mouseX_in_grid;
                cw = dg.ColumnWidth;
                % H패널('1x')과 비디오 패널의 최소 폭을 현재 창 크기에 맞춰 보장
                fixedSum = 0;
                for colIdx = [1 2 3 5]
                    if isnumeric(cw{colIdx})
                        fixedSum = fixedSum + cw{colIdx};
                    end
                end
                spacing = dg.ColumnSpacing * max(0, numel(cw) - 1);
                minPlotW = app.getMinPlotPanelWidth();
                minVideoW = app.getMinVideoPanelWidth();
                maxVideoW = max(minVideoW, gridW - fixedSum - spacing - minPlotW);
                newVideoW = round(max(minVideoW, min(maxVideoW, newVideoW)));
                if isequal(cw{6}, newVideoW), return; end
                cw{6} = newVideoW;
                dg.ColumnWidth = cw;
            catch ME
                app.logCaught(ME, 'HISplitter:motion');
            end
        end

        function stopHISplitterDrag(app)
            try
                app.UIFigure.WindowButtonMotionFcn = '';
                app.UIFigure.WindowButtonUpFcn    = '';
                if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'arrow'; end
                app.IsDraggingSplitter = false;
                app.HISplitterFIdx = 0;
                drawnow limitrate;
            catch ME
                app.logCaught(ME, 'HISplitter:stop');
            end
        end

        function stopPlotMarkerDrag(app)
            % 콜백 및 드래그 상태 완벽 초기화
            wasDraggingFIdx = app.DraggedFIdx;
            app.IsDraggingMarker = false;
            app.State = 'IDLE';   % [V3.17 (8)] 드래그 종료 시 IDLE 복원

            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                end
            catch ME
                app.logCaught(ME, 'stopPlotMarkerDrag:clear-window-callbacks');
            end

            try
                if ~isempty(app.DraggedMarker) && isvalid(app.DraggedMarker)
                    app.DraggedMarker.HitTest = 'on';
                    % 기존 Axes 상호작용(Pan/Zoom) 복원
                    ax = app.DraggedMarker.Parent;
                    if isvalid(ax) && isprop(ax, 'Interactions') && ~isempty(app.DraggedMarker.UserData)
                        ax.Interactions = app.DraggedMarker.UserData;
                    end
                end
            catch ME
                app.logCaught(ME, 'stopPlotMarkerDrag:restore-hit-test');
            end

            app.DraggedMarker = [];
            app.DraggedFIdx = 0;
            app.DraggedFromVideo = false;   % [V3.12] 비디오 드래그 플래그 리셋
            app.VideoThrottleDyn = 0.05;    % [V3.12] throttle 기본값 복원

            % [V3.11 C] xline Alpha를 0.5로 복원
            for fIdx = 1:2
                try
                    for tIdx = 1:length(app.UI(fIdx).timeLines)
                        tlArr = app.UI(fIdx).timeLines{tIdx};
                        for k = 1:length(tlArr)
                            if ~isempty(tlArr{k}) && isvalid(tlArr{k})
                                tlArr{k}.Alpha = 0.5;
                            end
                        end
                    end
                    if isfield(app.UI(fIdx), 'timeLine') && ~isempty(app.UI(fIdx).timeLine) && isvalid(app.UI(fIdx).timeLine)
                        app.UI(fIdx).timeLine.Alpha = 0.5;
                    end
                catch ME
                    app.logCaught(ME, 'stopPlotMarkerDrag:restore-xline-alpha');
                end
            end

            % [V3.11 B] XLim 리스너 복원 (드래그 시작 시 중단했던 리스너 복구)
            if wasDraggingFIdx >= 1 && wasDraggingFIdx <= 2
                app.setXLimListenersEnabled(wasDraggingFIdx, true);
            end

            % [V3.11 C] 드래그 종료 시 전체 대시보드 1회 동기화
            % (드래그 중 경량 경로로만 갱신했던 테이블/게이지/맵/비디오 최종 반영)
            for fIdx = 1:2
                if ~isempty(app.Models(fIdx).rawData)
                    idx = app.Models(fIdx).currentIndex;
                    % [Major 4] IsUpdating 복원을 onCleanup 로 고정 (예외 경로에서도 복원 보장)
                    prevUpdating = app.IsUpdating(fIdx);
                    app.IsUpdating(fIdx) = true;
                    cleanupUpdating = onCleanup(@() i_restoreIsUpdating(app, fIdx, prevUpdating));
                    try
                        app.updateDashboard(fIdx, idx);
                    catch e
                        warning('stopPlotMarkerDrag 전체 동기화 오류: %s', e.message);
                    end
                    clear cleanupUpdating  % 명시적 cleanup (다음 iteration 의 prevUpdating 캡처 안전화)
                    % [V3.18 (4)] 드래그 종료 후 인접 frame 워밍업 (idle CPU 활용)
                    app.prefetchAdjacentFrames(fIdx);
                end
            end
        end

        % ---------------------------------------------------------------------
        % [V3.11 B] XLim 리스너 일괄 제어 (드래그 중 중단/복원)
        % ---------------------------------------------------------------------
        function setXLimListenersEnabled(app, fIdx, enabled)
            % H 패널 내 모든 탭의 XLim 리스너 제어
            try
                for tIdx = 1:length(app.UI(fIdx).xLimListeners)
                    listeners = app.UI(fIdx).xLimListeners{tIdx};
                    for k = 1:length(listeners)
                        L = listeners{k};
                        if ~isempty(L) && isvalid(L)
                            L.Enabled = enabled;
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'setXLimListenersEnabled:plot');
            end

            % Altitude 패널 XLim 리스너 제어
            try
                if isfield(app.UI(fIdx), 'altXLimListener')
                    L = app.UI(fIdx).altXLimListener;
                    if ~isempty(L) && isvalid(L)
                        L.Enabled = enabled;
                    end
                end
            catch ME
                app.logCaught(ME, 'setXLimListenersEnabled:altitude');
            end
        end

        % ---------------------------------------------------------------------
        % [V3.11 C / V3.12 확장] 경량 업데이트 경로 (드래그 중 전용)
        % - V3.11: 마커/xline + 현재시간 라벨 + H 패널 책장 넘기기
        % - V3.12 1.1: Map 비행경로 + 빨간 삼각형 실시간 갱신 추가
        % - V3.12 2.2.3: 비디오 동기 설정 시 Frame 마커 갱신 + 영상 프레임 갱신
        % - 현재 비행 정보/자세 숫자는 드래그 중에도 즉시 갱신
        % ---------------------------------------------------------------------
        function updateNumericPanelsOnly(app, fIdx, idx)
            try
                if isempty(app.Models(fIdx).rawData), return; end

                % [Perf] dataTable.Data = cell{N x 2} rewrite is the single most
                % expensive per-frame op on MATLAB Online (uitable network round-trip).
                % While dragging, throttle to ~6 fps (0.16 s); final value applies on stop.
                allowTable = true;
                if app.IsDraggingMarker
                    last = app.LastDragTableUpdate(fIdx);
                    if last ~= uint64(0) && toc(last) < 0.16
                        allowTable = false;
                    else
                        app.LastDragTableUpdate(fIdx) = tic;
                    end
                else
                    app.LastDragTableUpdate(fIdx) = uint64(0);
                end

                if allowTable && isfield(app.UI(fIdx), 'dataTable') ...
                        && ~isempty(app.UI(fIdx).dataTable) && isvalid(app.UI(fIdx).dataTable)
                    metaList = app.Models(fIdx).displayMeta;
                    dataCell = cell(length(metaList), 2);
                    for i = 1:length(metaList)
                        m = metaList(i);
                        val = app.Models(fIdx).rawData.(m.header)(idx);
                        dataCell{i, 1} = sprintf('%s (%s)', m.header, m.unit);
                        dataCell{i, 2} = sprintf(m.format, val);
                    end
                    app.UI(fIdx).dataTable.Data = dataCell;
                end

                pitch = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Pitch)(idx);
                roll  = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Roll)(idx);
                hdg   = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Heading)(idx);

                if isfield(app.UI(fIdx), 'pitchLabel') && ~isempty(app.UI(fIdx).pitchLabel) && isvalid(app.UI(fIdx).pitchLabel)
                    app.UI(fIdx).pitchLabel.Text = sprintf('Pitch %+.3f°', pitch);
                end
                if isfield(app.UI(fIdx), 'rollLabel') && ~isempty(app.UI(fIdx).rollLabel) && isvalid(app.UI(fIdx).rollLabel)
                    app.UI(fIdx).rollLabel.Text = sprintf('Roll %+.3f°', roll);
                end
                if isfield(app.UI(fIdx), 'hdgLabel') && ~isempty(app.UI(fIdx).hdgLabel) && isvalid(app.UI(fIdx).hdgLabel)
                    app.UI(fIdx).hdgLabel.Text = sprintf('Heading %+.3f°', hdg);
                end

                if isfield(app.UI(fIdx), 'hgPitch') && ~isempty(app.UI(fIdx).hgPitch) && isvalid(app.UI(fIdx).hgPitch)
                    set(app.UI(fIdx).hgPitch, 'Matrix', makehgtform('zrotate', -pitch * pi / 180));
                end
                if isfield(app.UI(fIdx), 'hgRoll') && ~isempty(app.UI(fIdx).hgRoll) && isvalid(app.UI(fIdx).hgRoll)
                    set(app.UI(fIdx).hgRoll, 'Matrix', makehgtform('zrotate', -roll * pi / 180));
                end
                if isfield(app.UI(fIdx), 'hgHdg') && ~isempty(app.UI(fIdx).hgHdg) && isvalid(app.UI(fIdx).hgHdg)
                    set(app.UI(fIdx).hgHdg, 'Matrix', makehgtform('zrotate', -hdg * pi / 180));
                end
                app.refreshBoardOffSummaryPanel(fIdx);
            catch ME
                app.logCaught(ME, 'numericPanels');
            end
        end

        function updateMarkersOnly(app, fIdx, idx)
            % [V3.17 (4)(11)] persistent inCascade → InCascade 인스턴스 속성으로 이동
            % [V3.17 (5)] drawnow를 외부(goToFrame)에서 처리하므로 자체 호출은 가드
            isOuter = ~app.InCascade;

            app.Models(fIdx).currentIndex = idx;
            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(idx);

            try
                altCol = app.Models(fIdx).mappedCols.Alt;
                alts = app.Models(fIdx).rawData.(altCol);

                % Altitude 패널 마커 + xline 갱신
                if isfield(app.UI(fIdx), 'hAltMarker') && ~isempty(app.UI(fIdx).hAltMarker) && isvalid(app.UI(fIdx).hAltMarker)
                    set(app.UI(fIdx).hAltMarker, 'XData', currTime, 'YData', alts(idx));
                end
                if isfield(app.UI(fIdx), 'timeLine') && ~isempty(app.UI(fIdx).timeLine) && isvalid(app.UI(fIdx).timeLine)
                    app.UI(fIdx).timeLine.Value = currTime;
                end

                % 현재시간 라벨 (매우 가벼움)
                if isfield(app.UI(fIdx), 'currentTimeLabel') && ~isempty(app.UI(fIdx).currentTimeLabel) && isvalid(app.UI(fIdx).currentTimeLabel)
                    app.UI(fIdx).currentTimeLabel.Text = sprintf('%.3f s', currTime);
                end

                % 스피너 갱신 (가벼움)
                if isfield(app.UI(fIdx), 'spinner') && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                    if abs(app.UI(fIdx).spinner.Value - currTime) > eps
                        app.UI(fIdx).spinner.Value = currTime;
                    end
                end
                app.updateNumericPanelsOnly(fIdx, idx);
            catch ME
                app.logCaught(ME, 'clearCurrentTab:delete-children');
            end

            % [V3.12 1.1] Map 비행경로 + 빨간 삼각형 실시간 갱신 (가벼움)
            try
                pathLon = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lon);
                pathLat = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lat);
                currLon = pathLon(1:idx);
                currLat = pathLat(1:idx);
                validIdx = (currLon ~= 0) | (currLat ~= 0);

                if isfield(app.UI(fIdx), 'hMapPath') && ~isempty(app.UI(fIdx).hMapPath) && isvalid(app.UI(fIdx).hMapPath)
                    set(app.UI(fIdx).hMapPath, 'XData', currLon(validIdx), 'YData', currLat(validIdx));
                end

                hdg = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Heading)(idx);
                lastValid = find(validIdx, 1, 'last');
                if ~isempty(lastValid) && isfield(app.UI(fIdx), 'hgMapPlane') && ~isempty(app.UI(fIdx).hgMapPlane) && isvalid(app.UI(fIdx).hgMapPlane)
                    T_map = makehgtform('translate', [currLon(lastValid), currLat(lastValid), 0]) * makehgtform('zrotate', -hdg * pi / 180);
                    set(app.UI(fIdx).hgMapPlane, 'Matrix', T_map);
                end
            catch ME
                app.logCaught(ME, 'updateNumericPanelsOnly:map');
            end

            % H 패널 책장 넘기기 + 마커 갱신 (개선안 A의 IsProgrammaticXLim 가드 작동)
            try
                app.updatePlotTimeLines(fIdx, idx, currTime);
            catch ME
                app.logCaught(ME, 'hpanel-update');
            end

            % [V3.12 2.2.3] 비디오 동기 설정 시 Frame 마커 + 영상 프레임 갱신
            % (단, 비디오 측에서 시작된 드래그가 아닐 때만 - 무한 루프 방지)
            % [PATCH UX-1] Sync 명시 활성화 + 비디오 ready 동시 충족 시에만 갱신
            if app.VideoSyncState(fIdx).IsSynced && ~app.DraggedFromVideo ...
                    && app.isVideoReady(fIdx) && app.VideoSyncState(fIdx).AnchorFrame > 0
                try
                    targetFrame = app.timeToFrame(fIdx, currTime);
                    app.VideoSyncState(fIdx).CurrentFrame = targetFrame;

                    % [V3.14] Frame 마커 + xline + 슬라이더 + 라벨 일괄 동기화
                    app.syncFrameMarkersAndLabel(fIdx, targetFrame);

                    % [V3.13 절충] 비행데이터 드래그 시 영상 갱신은 throttle 유지
                    app.updateVideoFrameByFrameNo(fIdx, targetFrame, 'autoplay');
                catch ME
                    app.logCaught(ME, 'clearAllTabs:delete-tab');
                end
            end

            % 동기화 모드: 경로 1 드래그 시 경로 2도 경량 업데이트
            if app.SyncState.IsSynced && fIdx == 1 && ~isempty(app.Models(2).rawData)
                targetT2 = app.SyncState.SyncT2 + (currTime - app.SyncState.SyncT1);
                timeCol2 = app.Models(2).mappedCols.Time;
                idx2 = app.findClosestIndexByTime(app.Models(2).rawData.(timeCol2), targetT2);
                if ~isequal(app.Models(2).currentIndex, idx2)
                    % [V3.17 (4)(11)] InCascade 인스턴스 속성으로 cascade 가드
                    % [Major 3] onCleanup 만으로 복원 — 수동 복원 제거 (중복 호출 방지/의도 명확화)
                    prevCascade = app.InCascade;
                    app.InCascade = true;
                    cleanupCascade = onCleanup(@() app.restoreInCascade(prevCascade));
                    app.updateMarkersOnly(2, idx2);
                end
            end

            % [V3.17 (5)] cascade 외부 + goToFrame 미경유 시에만 drawnow
            % goToFrame은 자체 종료 시 drawnow 호출하므로 중복 방지
            if isOuter && ~any(app.InGoToFrame)
                drawnow limitrate;
            end
        end

        function restoreInCascade(app, prevValue)
            try
                app.InCascade = logical(prevValue);
            catch ME
                app.logCaught(ME, 'cascade-restore');
            end
        end

        function updateTimeFromScrub(app, fIdx, targetTime)
            timeCol = app.Models(fIdx).mappedCols.Time;
            times = app.Models(fIdx).rawData.(timeCol);
            if isempty(times), return; end

            targetTime = max(min(targetTime, times(end)), times(1));
            idx = app.findClosestIndexByTime(times, targetTime);

            app.applyTimeChange(fIdx, idx);
        end

        function idx = findClosestIndexByTime(~, timeArray, targetTime)
            if isempty(timeArray), idx = 1; return; end
            if isnan(targetTime), idx = 1; return; end

            left = 1; right = length(timeArray);
            while left <= right
                mid = floor((left + right) / 2);
                if timeArray(mid) == targetTime, idx = mid; return; end
                if timeArray(mid) < targetTime, left = mid + 1; else, right = mid - 1; end
            end
            if left > length(timeArray), idx = length(timeArray); return; end
            if right < 1, idx = 1; return; end
            if abs(timeArray(left) - targetTime) < abs(timeArray(right) - targetTime)
                idx = left;
            else
                idx = right;
            end
        end

        function updateTabTimeLines(app, fIdx)
            if isempty(app.Models(fIdx).rawData), return; end
            currIdx = app.Models(fIdx).currentIndex;
            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(currIdx);
            try
                app.updatePlotTimeLines(fIdx, currIdx, currTime);
            catch ME
                app.logCaught(ME, 'hpanel-tab-timeline');
            end
            app.refreshBoardOffSummaryPanel(fIdx);
        end

        function updatePlotTimeLines(app, fIdx, currIdx, currTime)
            currTab = app.UI(fIdx).tabGroup.SelectedTab;
            if isempty(currTab), return; end

            tabIdx = find(app.UI(fIdx).plotTabs == currTab, 1);
            if isempty(tabIdx), return; end

            % [기능 유지] H 패널 자동 화면 넘김 (Auto-Page Panning)
            % 확대된 상태에서 마커가 화면 밖을 벗어나면 기존 확대 폭을 유지한 채 X축 이동
            % [V3.11 A] XLim 변경 시 handlePlotXLimChange 리스너 무한 재귀 차단
            if ~isempty(app.UI(fIdx).plotAxes{tabIdx})
                firstAx = app.UI(fIdx).plotAxes{tabIdx}{1};
                try
                    if isvalid(firstAx)
                        xlims = firstAx.XLim;
                        xMin = xlims(1);
                        xMax = xlims(2);
                        xWidth = xMax - xMin;

                        if currTime > xMax
                            newMin = xMax;
                            newMax = xMax + xWidth;
                            while currTime > newMax
                                newMin = newMax;
                                newMax = newMax + xWidth;
                            end
                            prevProgrammatic = app.IsProgrammaticXLim(fIdx);
                            app.IsProgrammaticXLim(fIdx) = true;   % 리스너 가드 ON
                            cleanupXLim = onCleanup(@() app.restoreProgrammaticXLim(fIdx, prevProgrammatic));
                            firstAx.XLim = [newMin, newMax];
                            app.IsProgrammaticXLim(fIdx) = prevProgrammatic;
                        elseif currTime < xMin
                            newMax = xMin;
                            newMin = xMin - xWidth;
                            while currTime < newMin
                                newMax = newMin;
                                newMin = newMin - xWidth;
                            end
                            prevProgrammatic = app.IsProgrammaticXLim(fIdx);
                            app.IsProgrammaticXLim(fIdx) = true;   % 리스너 가드 ON
                            cleanupXLim = onCleanup(@() app.restoreProgrammaticXLim(fIdx, prevProgrammatic));
                            firstAx.XLim = [newMin, newMax];
                            app.IsProgrammaticXLim(fIdx) = prevProgrammatic;
                        end
                    end
                catch ME
                    app.logCaught(ME, 'hpanel-xlim');
                end
            end

            tlArr = app.UI(fIdx).timeLines{tabIdx};
            mkArr = app.UI(fIdx).timeMarkers{tabIdx};
            dataArr = app.UI(fIdx).plotData{tabIdx};

            for i = 1:length(tlArr)
                try
                    if ~isempty(tlArr{i}) && isvalid(tlArr{i})
                        set(tlArr{i}, 'Value', currTime);
                    end
                    if ~isempty(mkArr{i}) && isvalid(mkArr{i})
                        yData = dataArr{i};
                        set(mkArr{i}, 'XData', currTime, 'YData', yData(currIdx));
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'hpanel-marker');
                end
            end
        end

        function restoreProgrammaticXLim(app, fIdx, prevValue)
            try
                app.IsProgrammaticXLim(fIdx) = prevValue;
            catch ME
                app.logCaught(ME, 'hpanel-xlim-restore');
            end
        end

        % ---------------------------------------------------------------------
        % H 영역 탭 및 다중 플롯 관리
        % ---------------------------------------------------------------------
        function addPlotTab(app, fIdx)
            nTabs = length(app.UI(fIdx).plotTabs);
            if nTabs >= app.MAX_TABS
                errordlg(sprintf('최대 %d개의 탭만 생성할 수 있습니다.', app.MAX_TABS), '알림');
                return;
            end

            newTab = uitab(app.UI(fIdx).tabGroup, 'Title', sprintf('Tab %d', nTabs+1));
            app.UI(fIdx).plotTabs(end+1) = newTab;

            plotLayout = uigridlayout(newTab, 'ColumnWidth', {'1x'}, 'RowHeight', {}, ...
                                      'Padding', [5 5 5 5], 'RowSpacing', 5, 'Scrollable', 'on');

            app.UI(fIdx).plotLayouts{end+1} = plotLayout;

            tabIdx = nTabs + 1;
            app.UI(fIdx).plotAxes{tabIdx} = {};
            app.UI(fIdx).timeLines{tabIdx} = {};
            app.UI(fIdx).timeMarkers{tabIdx} = {};
            app.UI(fIdx).plotData{tabIdx} = {};
            app.UI(fIdx).xLimListeners{tabIdx} = {};

            app.UI(fIdx).tabGroup.SelectedTab = newTab;
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end

        function clearCurrentTab(app, fIdx)
            currTab = app.UI(fIdx).tabGroup.SelectedTab;
            if isempty(currTab), return; end
            tabIdx = find(app.UI(fIdx).plotTabs == currTab, 1);
            if isempty(tabIdx), return; end

            app.deleteListeners(app.UI(fIdx).xLimListeners{tabIdx});
            app.deleteGraphicsHandles(app.UI(fIdx).timeLines{tabIdx});
            app.deleteGraphicsHandles(app.UI(fIdx).timeMarkers{tabIdx});
            app.deleteGraphicsHandles(app.UI(fIdx).plotAxes{tabIdx});

            targetLayout = app.UI(fIdx).plotLayouts{tabIdx};
            try
                if ~isempty(targetLayout) && isvalid(targetLayout)
                    delete(targetLayout.Children);
                    targetLayout.RowHeight = {};
                end
            catch ME
                app.logCaught(ME, 'clearCurrentTab:delete-layout-children');
            end

            app.UI(fIdx).plotAxes{tabIdx} = {};
            app.UI(fIdx).timeLines{tabIdx} = {};
            app.UI(fIdx).timeMarkers{tabIdx} = {};
            app.UI(fIdx).plotData{tabIdx} = {};
            app.UI(fIdx).xLimListeners{tabIdx} = {};
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end

        function clearAllTabs(app, fIdx)
            for i = 1:length(app.UI(fIdx).plotTabs)
                if i <= length(app.UI(fIdx).xLimListeners)
                    app.deleteListeners(app.UI(fIdx).xLimListeners{i});
                end
                try
                    if ~isempty(app.UI(fIdx).plotTabs(i)) && isvalid(app.UI(fIdx).plotTabs(i))
                        delete(app.UI(fIdx).plotTabs(i));
                    end
                catch ME
                    app.logCaught(ME, 'clearAllTabs:delete-tab');
                end
            end
            app.UI(fIdx).plotTabs = [];
            app.UI(fIdx).plotLayouts = {};
            app.UI(fIdx).plotAxes = cell(1, app.MAX_TABS);
            app.UI(fIdx).timeLines = cell(1, app.MAX_TABS);
            app.UI(fIdx).timeMarkers = cell(1, app.MAX_TABS);
            app.UI(fIdx).plotData = cell(1, app.MAX_TABS);
            app.UI(fIdx).xLimListeners = cell(1, app.MAX_TABS);

            app.addPlotTab(fIdx);
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end

        function deleteGraphicsHandles(app, handleCell)
            if isempty(handleCell), return; end
            for k = 1:length(handleCell)
                h = handleCell{k};
                try
                    if ~isempty(h) && isvalid(h)
                        delete(h);
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'deleteGraphicsHandles');
                end
            end
        end

        function deleteListeners(app, listenerCell)
            if isempty(listenerCell), return; end
            for k = 1:length(listenerCell)
                L = listenerCell{k};
                try
                    if ~isempty(L) && isvalid(L)
                        delete(L);
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'deleteListeners');
                end
            end
        end

        function handlePlotXLimChange(app, fIdx, ax)
            % [V3.11 A] 프로그래밍적 XLim 변경(책장 넘기기 등)인 경우 리스너 무시
            %           → 사용자가 드래그한 마커 위치가 중앙으로 강제 점프되는 현상 차단
            if app.IsProgrammaticXLim(fIdx), return; end

            % =======================================================
            % [V3.8 보강] 툴바의 Zoom/Pan 모드를 프로그래밍적으로 강제 Off
            % - 혹시 외부 API나 다른 경로를 통해 zoom/pan 모드가 켜졌을 경우
            %   WindowButtonUp 이벤트 가로채기로 인한 마커 스턱 현상 원천 차단
            % =======================================================
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    zoom(app.UIFigure, 'off');
                    pan(app.UIFigure, 'off');
                    if app.DebugMode
                        fprintf('[XLim] zoom/pan off forced (fIdx=%d)\n', fIdx);
                    end
                end
            catch ME
                app.logCaught(ME, 'handlePlotXLimChange:force-interaction-off');
            end

            % [버그 완벽 수정] 줌/팬 등에 의해 X축 범위가 변경되었을 때
            % 혹시 남아있을지 모르는 드래그 상태를 안전하게 강제 초기화
            if app.IsDraggingMarker
                app.stopPlotMarkerDrag();
            end

            % [줌 동기화 핵심] 확대/이동 발생 시 중앙 시간 획득 후 대시보드 동기화
            if app.IsUpdating(fIdx), return; end
            try
                if isempty(ax) || ~isvalid(ax), return; end
            catch
                return;
            end

            xlims = ax.XLim;
            centerTime = mean(xlims);

            timeCol = app.Models(fIdx).mappedCols.Time;
            times = app.Models(fIdx).rawData.(timeCol);
            idx = app.findClosestIndexByTime(times, centerTime);

            % Y축 자동 스케일: 확대 시 마커가 Y축 밖으로 벗어나 사라지는 것을 완벽 방지
            ax.YLimMode = 'auto';

            if isequal(app.Models(fIdx).currentIndex, idx), return; end
            app.applyTimeChange(fIdx, idx);
        end

        function plotSelectedVariable(app, fIdx)
            selRow = app.Models(fIdx).selectedRow;
            if isempty(selRow) || selRow < 1, return; end
            if isempty(app.Models(fIdx).rawData), return; end

            currTab = app.UI(fIdx).tabGroup.SelectedTab;
            if isempty(currTab)
                app.addPlotTab(fIdx);
                currTab = app.UI(fIdx).tabGroup.SelectedTab;
            end

            tabIdx = find(app.UI(fIdx).plotTabs == currTab, 1);
            if isempty(tabIdx)
                errordlg('현재 탭이 유효하지 않습니다. "+ 빈 탭 추가"를 먼저 눌러주세요.', '탭 오류');
                return;
            end

            numPlots = length(app.UI(fIdx).plotAxes{tabIdx});
            if numPlots >= app.MAX_PLOTS_PER_TAB
                errordlg(sprintf('한 탭에는 최대 %d개의 플롯만 추가할 수 있습니다.', app.MAX_PLOTS_PER_TAB), '알림');
                return;
            end

            if selRow > length(app.Models(fIdx).displayMeta)
                errordlg('선택된 행이 유효하지 않습니다.', '선택 오류');
                return;
            end

            meta = app.Models(fIdx).displayMeta(selRow);
            yCol = meta.header;
            yLabelStr = sprintf('%s (%s)', meta.header, meta.unit);
            timeCol = app.Models(fIdx).mappedCols.Time;

            if ~ismember(yCol, app.Models(fIdx).rawData.Properties.VariableNames)
                errordlg(sprintf('컬럼 "%s"을(를) 찾을 수 없습니다.', yCol), '데이터 오류');
                return;
            end

            tData = app.Models(fIdx).rawData.(timeCol);
            yData = app.Models(fIdx).rawData.(yCol);

            targetLayout = app.UI(fIdx).plotLayouts{tabIdx};
            targetLayout.RowHeight{end+1} = app.PLOT_ROW_HEIGHT;
            newRowIdx = numel(targetLayout.RowHeight);

            p = uipanel(targetLayout, 'BorderType', 'line', 'BackgroundColor', 'w');
            p.Layout.Row = newRowIdx;
            p.Layout.Column = 1;

            axGrid = uigridlayout(p, 'ColumnWidth', {'1x'}, 'RowHeight', {'1x'}, 'Padding', [5 5 5 5]);
            ax = uiaxes(axGrid);
            ax.Layout.Row = 1;
            ax.Layout.Column = 1;

            % [V3.10] H 패널 Tab 플롯 전용 커스텀 툴바 (Restore/ZoomIn/ZoomOut/Pan)
            %         Map/Altitude/비디오/게이지 axes는 툴바 숨김 유지
            %         휠 줌/드래그 팬 기본 상호작용도 함께 허용
            %         스턱 방어는 handlePlotXLimChange의 zoom/pan off 로직이 담당
            ax.Interactions = [panInteraction, zoomInteraction];
            tb = axtoolbar(ax, {'restoreview', 'zoomin', 'zoomout', 'pan'});
            tb.Visible = 'on';

            grid(ax, 'on'); set(ax, 'XMinorGrid', 'on', 'YMinorGrid', 'on');
            % [R-08] Tag the primary data line so overlay lines never win lookup.
            plot(ax, tData, yData, 'LineWidth', 1.5, 'Color', [0.15 0.38 0.82], ...
                'Tag', 'fdd:dataLine');
            % [Bug #1 fix v2] Force XLim to data span immediately so the off-mode summary
            % mirror cannot inherit a pre-commit default [0 1] / [0 0.x] when reading
            % srcAx.XLim during refreshBoardOffSummaryPanel.
            if numel(tData) >= 2 && tData(end) > tData(1)
                ax.XLim = [tData(1) tData(end)];
            end
            xlabel(ax, 'Time(s)', 'FontWeight', 'bold', 'FontSize', 9);
            ylabel(ax, yLabelStr, 'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');

            hold(ax, 'on');
            currIdx = app.Models(fIdx).currentIndex;
            currTime = tData(currIdx);
            currY = yData(currIdx);

            % [개선안 3] 라인 두께(3.0) 및 반투명(0.5), 마커 크기(14) 대폭 확대
            tl = xline(ax, currTime, 'r', 'LineWidth', 3.0, 'Alpha', 0.5, 'HitTest', 'on');
            mk = plot(ax, currTime, currY, 'p', 'MarkerFaceColor', [0.98 0.75 0.14], ...
                      'MarkerEdgeColor', [0.71 0.33 0.04], 'MarkerSize', 14, 'HitTest', 'on');

            tl.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, tabIdx, src, event);
            mk.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, tabIdx, src, event);

            app.UI(fIdx).plotAxes{tabIdx}{end+1} = ax;
            app.UI(fIdx).timeLines{tabIdx}{end+1} = tl;
            app.UI(fIdx).timeMarkers{tabIdx}{end+1} = mk;
            app.UI(fIdx).plotData{tabIdx}{end+1} = yData;

            L = addlistener(ax, 'XLim', 'PostSet', @(~,~) app.handlePlotXLimChange(fIdx, ax));
            app.UI(fIdx).xLimListeners{tabIdx}{end+1} = L;

            allAxes = [app.UI(fIdx).plotAxes{tabIdx}{:}];
            % [Phase 4 D3] honour LinkXWithinTab flag (defaults true) instead of forcing link.
            if numel(allAxes) > 1 && app.getLinkXWithinTab(fIdx, tabIdx)
                linkaxes(allAxes, 'x');
            end

            % [Phase 4] capture the freshly added plot into PlotConfigState for project save.
            try
                app.recordPlotInConfig(fIdx, tabIdx, struct( ...
                    'YColumn', yCol, 'YLabel', yLabelStr, ...
                    'XLim', ax.XLim, 'XLimMode', char(ax.XLimMode), ...
                    'YLimMode', char(ax.YLimMode), ...
                    'YLim', ax.YLim, 'Height', app.PLOT_ROW_HEIGHT));
            catch
            end

            drawnow;
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end
    end

    % =========================================================================
    % [Phase 4] PlotConfig capture/apply + LinkXWithinTab gating (D3)
    % =========================================================================
    methods (Access = private)
        function spec = emptyPlotSpec(app)
            spec = struct('YColumn', '', 'YLabel', '', 'XLim', [0 1], ...
                'XLimMode', 'manual', 'YLimMode', 'auto', 'YLim', [0 1], ...
                'Height', app.PLOT_ROW_HEIGHT, 'Order', 1);
        end

        function plots = normalizePlotSpecArray(app, plots)
            defaults = app.emptyPlotSpec();
            if isempty(plots)
                plots = defaults([]);
                return;
            end
            fields = fieldnames(defaults);
            for iField = 1:numel(fields)
                f = fields{iField};
                if ~isfield(plots, f)
                    for p = 1:numel(plots)
                        plots(p).(f) = defaults.(f);
                    end
                end
            end
            for p = 1:numel(plots)
                hVal = NaN;
                try
                    if isnumeric(plots(p).Height) && ~isempty(plots(p).Height)
                        hVal = double(plots(p).Height(1));
                    elseif ischar(plots(p).Height) || isstring(plots(p).Height)
                        hVal = str2double(char(plots(p).Height));
                    end
                catch
                    hVal = NaN;
                end
                if ~isfinite(hVal) || hVal <= 0
                    hVal = app.PLOT_ROW_HEIGHT;
                end
                plots(p).Height = max(60, min(600, hVal));
                if isempty(plots(p).XLimMode)
                    plots(p).XLimMode = 'manual';
                end
                if isempty(plots(p).YLimMode)
                    plots(p).YLimMode = 'auto';
                end
                % [Review Medium #4] Order 는 항상 array index 로 재기록 — duplicate/
                % delete 후 stale Order 가 sort/persist 시 충돌 일으키지 않도록.
                plots(p).Order = p;
            end
        end

        function spec = normalizePlotSpec(app, spec)
            specs = app.normalizePlotSpecArray(spec);
            if isempty(specs)
                spec = app.emptyPlotSpec();
            else
                spec = specs(1);
            end
        end

        % [R-09] Trailing empty tabs are dropped.
        % [R-09] A non-trailing empty tab is preserved because the UI tab still exists.
        % [R-09] Default-title middle empty tabs are logged only in DebugMode.
        function tabs = compactPlotTabsSpec(app, tabs)
            if isempty(tabs), return; end
            lastKeep = 0;
            for t = 1:numel(tabs)
                if isfield(tabs(t), 'Plots') && ~isempty(tabs(t).Plots)
                    lastKeep = t;
                end
            end
            if lastKeep > 1 && app.DebugMode
                for t = 1:(lastKeep - 1)
                    isEmptyMiddle = ~isfield(tabs(t), 'Plots') || isempty(tabs(t).Plots);
                    titleStr = '';
                    if isfield(tabs(t), 'Title') && ~isempty(tabs(t).Title)
                        titleStr = char(tabs(t).Title);
                    end
                    if isEmptyMiddle && strcmp(titleStr, sprintf('Tab %d', t))
                        fprintf('[R-09] compactPlotTabsSpec preserved middle empty default tab: %s\n', titleStr);
                    end
                end
            end
            if lastKeep == 0
                tabs = tabs(1);
                if isfield(tabs, 'Plots')
                    tabs.Plots = tabs.Plots([]);
                end
            else
                tabs = tabs(1:lastKeep);
            end
        end

        function h = getConfiguredPlotHeight(app, fIdx, tabIdx, plotIdx, fallback)
            h = fallback;
            try
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                tabs = cfg.Flights(fIdx).PlotTabs;
                if numel(tabs) >= tabIdx && isfield(tabs(tabIdx), 'Plots') ...
                        && numel(tabs(tabIdx).Plots) >= plotIdx ...
                        && isfield(tabs(tabIdx).Plots(plotIdx), 'Height')
                    rawVal = tabs(tabIdx).Plots(plotIdx).Height;
                    if isnumeric(rawVal)
                        val = double(rawVal(1));
                    else
                        val = str2double(char(rawVal));
                    end
                    if isfinite(val) && val > 0
                        h = max(60, min(600, val));
                    end
                end
            catch ME
                app.logCaught(ME, 'getConfiguredPlotHeight');
            end
        end

        function h = getLivePlotHeight(app, fIdx, tabIdx, plotIdx, fallback)
            h = fallback;
            try
                if tabIdx <= numel(app.UI(fIdx).plotLayouts)
                    layout = app.UI(fIdx).plotLayouts{tabIdx};
                    if ~isempty(layout) && isvalid(layout)
                        rows = layout.RowHeight;
                        if numel(rows) >= plotIdx && isnumeric(rows{plotIdx}) ...
                                && isfinite(double(rows{plotIdx}))
                            h = max(60, min(600, double(rows{plotIdx})));
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'getLivePlotHeight');
            end
        end

        function cfg = ensurePlotConfigShape(app, cfg)
            if isempty(cfg) || ~isstruct(cfg) || ~isfield(cfg, 'Flights')
                empty = struct('PlotTabs', []);
                cfg = struct('Flights', [empty, empty]);
            end
            for fIdx = 1:2
                if numel(cfg.Flights) < fIdx
                    cfg.Flights(fIdx).PlotTabs = [];
                end
                if ~isfield(cfg.Flights(fIdx), 'PlotTabs')
                    cfg.Flights(fIdx).PlotTabs = [];
                end
                if ~isempty(cfg.Flights(fIdx).PlotTabs)
                    for t = 1:numel(cfg.Flights(fIdx).PlotTabs)
                        if ~isfield(cfg.Flights(fIdx).PlotTabs(t), 'Title') ...
                                || isempty(cfg.Flights(fIdx).PlotTabs(t).Title)
                            cfg.Flights(fIdx).PlotTabs(t).Title = sprintf('Tab %d', t);
                        end
                        if ~isfield(cfg.Flights(fIdx).PlotTabs(t), 'LinkXWithinTab') ...
                                || isempty(cfg.Flights(fIdx).PlotTabs(t).LinkXWithinTab)
                            cfg.Flights(fIdx).PlotTabs(t).LinkXWithinTab = true;
                        end
                        if ~isfield(cfg.Flights(fIdx).PlotTabs(t), 'Plots')
                            cfg.Flights(fIdx).PlotTabs(t).Plots = [];
                        end
                        cfg.Flights(fIdx).PlotTabs(t).Plots = ...
                            app.normalizePlotSpecArray(cfg.Flights(fIdx).PlotTabs(t).Plots);
                    end
                end
            end
            app.PlotConfigState = cfg;
        end

        function tf = getLinkXWithinTab(app, fIdx, tabIdx)
            tf = true;   % default
            try
                cfg = app.PlotConfigState;
                if isstruct(cfg) && isfield(cfg, 'Flights') ...
                        && numel(cfg.Flights) >= fIdx ...
                        && isfield(cfg.Flights(fIdx), 'PlotTabs') ...
                        && numel(cfg.Flights(fIdx).PlotTabs) >= tabIdx ...
                        && isfield(cfg.Flights(fIdx).PlotTabs(tabIdx), 'LinkXWithinTab')
                    tf = logical(cfg.Flights(fIdx).PlotTabs(tabIdx).LinkXWithinTab);
                end
            catch ME
                app.logCaught(ME, 'getLinkXWithinTab');
            end
        end

        function setLinkXWithinTab(app, fIdx, tabIdx, enabled)
            % [D3] central toggle. Updates PlotConfigState and live axes link state.
            cfg = app.ensurePlotConfigShape(app.PlotConfigState);
            try
                if numel(cfg.Flights(fIdx).PlotTabs) < tabIdx
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots = [];
                end
                cfg.Flights(fIdx).PlotTabs(tabIdx).LinkXWithinTab = logical(enabled);
                app.PlotConfigState = cfg;
            catch ME
                app.logCaught(ME, 'setLinkXWithinTab:state');
            end
            try
                axesCell = app.UI(fIdx).plotAxes{tabIdx};
                if iscell(axesCell), allAxes = [axesCell{:}]; else, allAxes = axesCell; end
                if numel(allAxes) > 1
                    if enabled, linkaxes(allAxes, 'x'); else, linkaxes(allAxes, 'off'); end
                end
            catch ME
                app.logCaught(ME, 'setLinkXWithinTab:live-link');
            end
        end

        function disableLinkXOnIndividualEdit(app, fIdx, tabIdx)
            % [D3] Called when a single-plot X range is edited; auto-off + leaves a Link off marker.
            app.setLinkXWithinTab(fIdx, tabIdx, false);
            try
                if isfield(app.UI(fIdx), 'plotTabs') && numel(app.UI(fIdx).plotTabs) >= tabIdx ...
                        && isvalid(app.UI(fIdx).plotTabs(tabIdx))
                    baseTitle = char(app.UI(fIdx).plotTabs(tabIdx).Title);
                    if ~contains(baseTitle, '[Link off]')
                        app.UI(fIdx).plotTabs(tabIdx).Title = [baseTitle ' [Link off]'];
                    end
                end
            catch ME
                app.logCaught(ME, 'disableLinkXOnIndividualEdit');
            end
            app.markProjectDirtyAndScheduleRefresh('linkx-off');
        end

        function recordPlotInConfig(app, fIdx, tabIdx, entry)
            cfg = app.ensurePlotConfigShape(app.PlotConfigState);
            try
                entry = app.normalizePlotSpec(entry);
                if numel(cfg.Flights(fIdx).PlotTabs) < tabIdx
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Title          = sprintf('Tab %d', tabIdx);
                    cfg.Flights(fIdx).PlotTabs(tabIdx).LinkXWithinTab = true;
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots          = [];
                end
                plots = app.normalizePlotSpecArray(cfg.Flights(fIdx).PlotTabs(tabIdx).Plots);
                if isempty(plots)
                    plots = entry;
                else
                    plots(end+1) = entry;
                end
                cfg.Flights(fIdx).PlotTabs(tabIdx).Plots = plots;
                app.PlotConfigState = cfg;
            catch ME
                app.logCaught(ME, 'recordPlotInConfig');
            end
        end

        function cfg = capturePlotConfigFromUi(app)
            % [P4] Capture live UI state WITHOUT destroying identity fields
            % (YColumn in particular). We match live axes to existing PlotConfigState
            % entries by (flight, tab, order) and only update display fields
            % (XLim, YLim, YLimMode, Height, Order, LinkXWithinTab, YLabel).
            cfg = app.ensurePlotConfigShape(app.PlotConfigState);
            for fIdx = 1:2
                try
                    if ~isfield(app.UI(fIdx), 'plotAxes') || isempty(app.UI(fIdx).plotAxes)
                        continue;
                    end
                    % Pull existing per-flight tabs so we can preserve identity fields.
                    if numel(cfg.Flights) >= fIdx && isfield(cfg.Flights(fIdx), 'PlotTabs')
                        existingTabs = cfg.Flights(fIdx).PlotTabs;
                    else
                        existingTabs = [];
                    end
                    numTabs = numel(app.UI(fIdx).plotTabs);
                    newTabs = struct('Title', {}, 'LinkXWithinTab', {}, 'Plots', {});
                    for tabIdx = 1:numTabs
                        if isempty(app.UI(fIdx).plotTabs(tabIdx)) || ~isvalid(app.UI(fIdx).plotTabs(tabIdx))
                            continue;
                        end
                        axesCell = app.UI(fIdx).plotAxes{tabIdx};
                        plots = struct('YColumn', {}, 'YLabel', {}, 'XLim', {}, ...
                                       'XLimMode', {}, 'YLimMode', {}, 'YLim', {}, ...
                                       'Height', {}, 'Order', {});
                        % Existing per-tab plot list for identity lookup.
                        existingPlots = [];
                        if ~isempty(existingTabs) && numel(existingTabs) >= tabIdx ...
                                && isfield(existingTabs(tabIdx), 'Plots')
                            existingPlots = app.normalizePlotSpecArray(existingTabs(tabIdx).Plots);
                        end
                        if iscell(axesCell)
                            for p = 1:numel(axesCell)
                                ax = axesCell{p};
                                if isempty(ax) || ~isvalid(ax), continue; end
                                ylabStr = '';
                                try
                                    ylabStr = char(ax.YLabel.String);
                                catch
                                end
                                % [P4] preserve YColumn if a corresponding existing entry has one.
                                yColumn = '';
                                if ~isempty(existingPlots) && numel(existingPlots) >= p ...
                                        && isfield(existingPlots(p), 'YColumn') ...
                                        && ~isempty(existingPlots(p).YColumn)
                                    yColumn = char(existingPlots(p).YColumn);
                                end
                                if isempty(yColumn)
                                    try
                                        metaHeaders = {app.Models(fIdx).displayMeta.header};
                                        for hIdx = 1:numel(metaHeaders)
                                            hdr = char(metaHeaders{hIdx});
                                            if strcmp(ylabStr, hdr) || startsWith(ylabStr, [hdr ' ('])
                                                yColumn = hdr;
                                                break;
                                            end
                                        end
                                    catch ME
                                        app.logCaught(ME, 'capturePlotConfigFromUi:y-column');
                                    end
                                end
                                % Inherit Height from existing entry when possible.
                                heightVal = app.PLOT_ROW_HEIGHT;
                                heightVal = app.getConfiguredPlotHeight(fIdx, tabIdx, p, heightVal);
                                heightVal = app.getLivePlotHeight(fIdx, tabIdx, p, heightVal);
                                xMode = 'manual';
                                try
                                    xMode = char(ax.XLimMode);
                                catch
                                end
                                plots(end+1) = struct('YColumn', yColumn, 'YLabel', ylabStr, ...
                                    'XLim', ax.XLim, 'XLimMode', xMode, ...
                                    'YLimMode', char(ax.YLimMode), 'YLim', ax.YLim, ...
                                    'Height', heightVal, ...
                                    'Order', p); %#ok<AGROW>
                            end
                        end
                        titleStr = sprintf('Tab %d', tabIdx);
                        try
                            titleStr = char(app.UI(fIdx).plotTabs(tabIdx).Title);
                        catch
                        end
                        link = app.getLinkXWithinTab(fIdx, tabIdx);
                        newTabs(tabIdx) = struct( ...
                            'Title', titleStr, 'LinkXWithinTab', link, 'Plots', plots);
                    end
                    newTabs = app.compactPlotTabsSpec(newTabs);
                    cfg.Flights(fIdx).PlotTabs = newTabs;
                catch ME
                    app.logCaught(ME, 'capturePlotConfigFromUi:flight');
                end
            end
            app.PlotConfigState = cfg;
        end

        function applyPlotAxisConfig(app, fIdx, tabIdx, plotIdx, axisCfg)
            % Apply XLim/YLim/YLimMode to a specific plot. If the X-range is changed individually,
            % auto-off the tab link (D3) so the edit actually takes effect.
            try
                axesCell = app.UI(fIdx).plotAxes{tabIdx};
                if ~iscell(axesCell) || numel(axesCell) < plotIdx, return; end
                ax = axesCell{plotIdx};
                if isempty(ax) || ~isvalid(ax), return; end
                manualX = ~isfield(axisCfg, 'XLimMode') || strcmpi(char(axisCfg.XLimMode), 'manual');
                xChanged = manualX && isfield(axisCfg, 'XLim') && ~isequal(ax.XLim, axisCfg.XLim);
                yLimSpecified = isfield(axisCfg, 'YLim') && numel(axisCfg.YLim) == 2 ...
                                && all(isfinite(axisCfg.YLim)) && axisCfg.YLim(2) > axisCfg.YLim(1);
                yChanged = yLimSpecified && ~isequal(ax.YLim, axisCfg.YLim);
                if xChanged && app.getLinkXWithinTab(fIdx, tabIdx)
                    app.disableLinkXOnIndividualEdit(fIdx, tabIdx);
                end
                oldFlag = app.IsProgrammaticXLim(fIdx);
                app.IsProgrammaticXLim(fIdx) = true;
                cleanupFlag = onCleanup(@() app.restoreProgrammaticXLim(fIdx, oldFlag));
                if isfield(axisCfg, 'XLimMode') && strcmpi(char(axisCfg.XLimMode), 'auto')
                    ax.XLimMode = 'auto';
                elseif isfield(axisCfg, 'XLim') && numel(axisCfg.XLim) == 2 ...
                        && all(isfinite(axisCfg.XLim)) && axisCfg.XLim(2) > axisCfg.XLim(1)
                    ax.XLim = axisCfg.XLim;
                    ax.XLimMode = 'manual';
                end
                if isfield(axisCfg, 'YLimMode'), ax.YLimMode = axisCfg.YLimMode; end
                if yLimSpecified
                    ax.YLim = axisCfg.YLim;
                end
                % [Review High #1] Always mark project dirty + schedule refresh when axes
                % actually changed via Plot Manager so debounce + autosave + off-summary
                % mirror see the latest XLim/YLim.
                if xChanged || yChanged
                    app.markProjectDirtyAndScheduleRefresh('plot-axis-edit');
                end
                % [R-11] onCleanup fires at function exit; do not clear manually.
            catch ME
                app.logCaught(ME, 'applyPlotAxisConfig');
            end
        end

        function applyPlotYLabelInPlace(app, fIdx, tabIdx, plotIdx, yLabelText)
            try
                if tabIdx > numel(app.UI(fIdx).plotAxes) || ~iscell(app.UI(fIdx).plotAxes{tabIdx}) ...
                        || plotIdx > numel(app.UI(fIdx).plotAxes{tabIdx})
                    return;
                end
                ax = app.UI(fIdx).plotAxes{tabIdx}{plotIdx};
                if isempty(ax) || ~isvalid(ax), return; end
                ylabel(ax, yLabelText, 'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');
            catch ME
                app.logCaught(ME, 'applyPlotYLabelInPlace');
            end
        end

        function applyPlotHeightInPlace(app, fIdx, tabIdx, plotIdx, heightValue)
            try
                if tabIdx > numel(app.UI(fIdx).plotLayouts), return; end
                layout = app.UI(fIdx).plotLayouts{tabIdx};
                if isempty(layout) || ~isvalid(layout), return; end
                rowHeight = layout.RowHeight;
                if numel(rowHeight) < plotIdx, return; end
                heightValue = max(60, min(600, double(heightValue)));
                rowHeight{plotIdx} = heightValue;
                layout.RowHeight = rowHeight;
            catch ME
                app.logCaught(ME, 'applyPlotHeightInPlace');
            end
        end

        function ok = replacePlotYColumnInPlace(app, fIdx, tabIdx, plotIdx, yCol)
            % Replace one Plot Manager plot's Y source without rebuilding the tab.
            % Rebuilding from PlotConfig can drop plots when config and live UI are out of sync.
            ok = false;
            try
                if isempty(app.Models(fIdx).rawData) || ~ismember(yCol, app.Models(fIdx).rawData.Properties.VariableNames)
                    return;
                end
                if tabIdx > numel(app.UI(fIdx).plotAxes) || ~iscell(app.UI(fIdx).plotAxes{tabIdx}) ...
                        || plotIdx > numel(app.UI(fIdx).plotAxes{tabIdx})
                    return;
                end
                ax = app.UI(fIdx).plotAxes{tabIdx}{plotIdx};
                if isempty(ax) || ~isvalid(ax), return; end
                oldXLim = ax.XLim;
                oldXLimMode = 'manual';
                try
                    oldXLimMode = char(ax.XLimMode);
                catch
                end

                timeCol = app.Models(fIdx).mappedCols.Time;
                tData = app.Models(fIdx).rawData.(timeCol);
                yData = app.Models(fIdx).rawData.(yCol);
                n = min(numel(tData), numel(yData));
                if n < 1, return; end
                tData = tData(1:n);
                yData = yData(1:n);

                metaIdx = find(strcmp({app.Models(fIdx).displayMeta.header}, yCol), 1);
                if ~isempty(metaIdx)
                    meta = app.Models(fIdx).displayMeta(metaIdx);
                    yLabelStr = sprintf('%s (%s)', meta.header, meta.unit);
                else
                    yLabelStr = yCol;
                end

                mainLine = app.findMainPlotLine(ax);
                if isempty(mainLine) || ~isvalid(mainLine), return; end
                mainLine.XData = tData;
                mainLine.YData = yData;
                ylabel(ax, yLabelStr, 'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');

                if tabIdx <= numel(app.UI(fIdx).plotData) && numel(app.UI(fIdx).plotData{tabIdx}) >= plotIdx
                    app.UI(fIdx).plotData{tabIdx}{plotIdx} = yData;
                end

                currIdx = max(1, min(app.Models(fIdx).currentIndex, n));
                currTime = tData(currIdx);
                if tabIdx <= numel(app.UI(fIdx).timeLines) && numel(app.UI(fIdx).timeLines{tabIdx}) >= plotIdx
                    tl = app.UI(fIdx).timeLines{tabIdx}{plotIdx};
                    if ~isempty(tl) && isvalid(tl)
                        tl.Value = currTime;
                    end
                end
                if tabIdx <= numel(app.UI(fIdx).timeMarkers) && numel(app.UI(fIdx).timeMarkers{tabIdx}) >= plotIdx
                    mk = app.UI(fIdx).timeMarkers{tabIdx}{plotIdx};
                    if ~isempty(mk) && isvalid(mk)
                        mk.XData = currTime;
                        mk.YData = yData(currIdx);
                    end
                end

                if strcmpi(oldXLimMode, 'auto')
                    ax.XLimMode = 'auto';
                elseif numel(oldXLim) == 2 && all(isfinite(oldXLim)) && oldXLim(2) > oldXLim(1)
                    ax.XLim = oldXLim;
                elseif numel(tData) >= 2 && tData(end) > tData(1)
                    ax.XLim = [tData(1), tData(end)];
                end

                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) >= tabIdx ...
                        && isfield(cfg.Flights(fIdx).PlotTabs(tabIdx), 'Plots') ...
                        && numel(cfg.Flights(fIdx).PlotTabs(tabIdx).Plots) >= plotIdx
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).YColumn = yCol;
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).YLabel = yLabelStr;
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).XLim = ax.XLim;
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).XLimMode = char(ax.XLimMode);
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).YLimMode = char(ax.YLimMode);
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots(plotIdx).YLim = ax.YLim;
                    app.PlotConfigState = cfg;
                end

                try
                    app.updatePlotTimeLines(fIdx, currIdx, currTime);
                catch ME
                    app.logCaught(ME, 'hpanel-plot-y-replace');
                end
                app.refreshBoardOffSummaryPanel(fIdx, true);
                ok = true;
            catch ME
                app.logCaught(ME, 'plot-y-replace');
            end
        end

        function lineObj = findMainPlotLine(app, ax)
            lineObj = [];
            try
                % [R-08] Prefer the tagged primary data line; keep legacy heuristic as fallback.
                tagged = findobj(ax, 'Type', 'Line', 'Tag', 'fdd:dataLine');
                if ~isempty(tagged)
                    lineObj = tagged(1);
                    return;
                end
                lines = findall(ax, 'Type', 'Line');
                bestN = 0;
                for k = 1:numel(lines)
                    h = lines(k);
                    try
                        if isempty(h) || ~isvalid(h), continue; end
                        if isprop(h, 'Marker') && ~strcmpi(char(h.Marker), 'none'), continue; end
                        n = numel(h.XData);
                        if n > bestN
                            bestN = n;
                            lineObj = h;
                        end
                    catch ME_silent
                        app.logCaught(ME_silent, 'findMainPlotLine:tagged-line');
                    end
                end
            catch ME
                app.logCaught(ME, 'findMainPlotLine:fallback');
            end
        end

        function yData = getPlotYData(app, fIdx, tabIdx, plotIdx)
            % [R-12] plotData mirrors the tagged data line's YData and must stay in sync.
            yData = [];
            try
                if tabIdx <= numel(app.UI(fIdx).plotData) ...
                        && numel(app.UI(fIdx).plotData{tabIdx}) >= plotIdx ...
                        && ~isempty(app.UI(fIdx).plotData{tabIdx}{plotIdx})
                    yData = app.UI(fIdx).plotData{tabIdx}{plotIdx};
                    return;
                end
                if tabIdx <= numel(app.UI(fIdx).plotAxes) ...
                        && numel(app.UI(fIdx).plotAxes{tabIdx}) >= plotIdx
                    ax = app.UI(fIdx).plotAxes{tabIdx}{plotIdx};
                    if ~isempty(ax) && isvalid(ax)
                        lineObj = app.findMainPlotLine(ax);
                        if ~isempty(lineObj) && isvalid(lineObj)
                            yData = lineObj.YData;
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'getPlotYData');
            end
        end

        function syncSelectedPlotXLimToAll(app, fIdx, tabIdx, plotIdx)
            % Apply this plot's X range to every plot in every tab of every flight.
            try
                axesCell = app.UI(fIdx).plotAxes{tabIdx};
                if ~iscell(axesCell) || numel(axesCell) < plotIdx, return; end
                srcAx = axesCell{plotIdx};
                if isempty(srcAx) || ~isvalid(srcAx), return; end
                xlim = srcAx.XLim;
            catch ME
                app.logCaught(ME, 'syncSelectedPlotXLimToAll:source'); return
            end
            for f = 1:2
                try
                    if ~isfield(app.UI(f), 'plotAxes'), continue; end
                    for t = 1:numel(app.UI(f).plotAxes)
                        axc = app.UI(f).plotAxes{t};
                        if ~iscell(axc), continue; end
                        for p = 1:numel(axc)
                            ax = axc{p};
                            if ~isempty(ax) && isvalid(ax), ax.XLim = xlim; end
                        end
                    end
                catch ME
                    app.logCaught(ME, 'syncSelectedPlotXLimToAll:target');
                end
            end
            app.markProjectDirtyAndScheduleRefresh('xlim-sync-all');
        end

        function applyTabXLimToTab(app, fIdx, srcTabIdx, dstFIdx, dstTabIdx)
            try
                srcAxesCell = app.UI(fIdx).plotAxes{srcTabIdx};
                if ~iscell(srcAxesCell) || isempty(srcAxesCell), return; end
                srcAx = srcAxesCell{1};
                if isempty(srcAx) || ~isvalid(srcAx), return; end
                xlim = srcAx.XLim;
                dstCell = app.UI(dstFIdx).plotAxes{dstTabIdx};
                if iscell(dstCell)
                    for p = 1:numel(dstCell)
                        ax = dstCell{p};
                        if ~isempty(ax) && isvalid(ax), ax.XLim = xlim; end
                    end
                end
            catch ME
                app.logCaught(ME, 'applyTabXLimToTab');
            end
            app.markProjectDirtyAndScheduleRefresh('xlim-tab');
        end

        function applyTabXLimToAllTabs(app, fIdx, srcTabIdx)
            try
                srcAxesCell = app.UI(fIdx).plotAxes{srcTabIdx};
                if ~iscell(srcAxesCell) || isempty(srcAxesCell), return; end
                srcAx = srcAxesCell{1};
                if isempty(srcAx) || ~isvalid(srcAx), return; end
                xlim = srcAx.XLim;
            catch ME
                app.logCaught(ME, 'applyTabXLimToAllTabs:source'); return
            end
            for f = 1:2
                try
                    if ~isfield(app.UI(f), 'plotAxes'), continue; end
                    for t = 1:numel(app.UI(f).plotAxes)
                        axc = app.UI(f).plotAxes{t};
                        if ~iscell(axc), continue; end
                        for p = 1:numel(axc)
                            ax = axc{p};
                            if ~isempty(ax) && isvalid(ax), ax.XLim = xlim; end
                        end
                    end
                catch ME
                    app.logCaught(ME, 'applyTabXLimToAllTabs:target');
                end
            end
            app.markProjectDirtyAndScheduleRefresh('xlim-all-tabs');
        end

        % =================================================================
        % [Phase 6] Export everything to folder (D1 AVI lock + D6 verify)
        % =================================================================
        function ok = exportEverythingToFolder(app, parentFolder, opts)
            % Copy every file recorded in current project state to a timestamped folder
            % and rewrite the copied project's path fields to point inside it.
            ok = false;
            if nargin < 3 || isempty(opts), opts = struct(); end
            if ~isfield(opts, 'verifyHash'), opts.verifyHash = false; end
            if nargin < 2 || isempty(parentFolder)
                parentFolder = uigetdir(pwd, 'Export 대상 parent 폴더 선택');
                if isequal(parentFolder, 0), return; end
            end
            if ~isfolder(parentFolder)
                try
                    uialert(app.UIFigure, 'parent 폴더가 존재하지 않습니다.', 'Export');
                catch
                end
                return;
            end

            folderName = char(datetime('now', 'Format', 'yyyy-MM-dd_HH-mm-ss'));
            target = fullfile(parentFolder, ['FlightDashboard_' folderName]);
            if isfolder(target)
                target = [target '_' char(java.util.UUID.randomUUID.toString.substring(0,4))];
            end
            mkdir(target);

            % [P4] capture live plot UI state so exported project carries current XLim/YLim.
            try
                app.capturePlotConfigFromUi();
            catch ME_pc
                app.logCaught(ME_pc, 'exportEverythingToFolder:refresh-project-cache');
            end
            st = app.collectCurrentProjectState();
            [fileList, missingList] = app.buildExportFileList(st);

            % [Audit fix #5] Force the user to decide on missing files instead of silent-omit.
            if ~isempty(missingList)
                names = arrayfun(@(e) sprintf('  - %s: %s', e.role, e.src), missingList, 'UniformOutput', false);
                msg = sprintf(['project에 기록된 다음 파일을 찾을 수 없습니다:\n%s\n\n', ...
                               '어떻게 처리할까요?'], strjoin(names, newline));
                sel = '';
                try
                    sel = uiconfirm(app.UIFigure, msg, '누락 파일', ...
                        'Options', {'누락 제외하고 진행', '파일 다시 선택', '중단'}, ...
                        'DefaultOption', 1, 'CancelOption', 3);
                catch
                end
                switch sel
                    case '파일 다시 선택'
                        for k = 1:numel(missingList)
                            if missingList(k).fIdx > 0
                                kind = strsplit(missingList(k).role, '.');
                                app.requestFileChange(missingList(k).fIdx, kind{end});
                            end
                        end
                        % Recurse once with the freshly chosen files.
                        app.exportEverythingToFolder(parentFolder, opts);
                        return;
                    case '중단'
                        try
                            uialert(app.UIFigure, 'export 가 취소되었습니다.', 'Export');
                        catch
                        end
                        return;
                    case '누락 제외하고 진행'
                        % proceed with current fileList; verification will explicitly fail on missing.
                    otherwise
                        return;
                end
            end

            if isempty(fileList)
                try
                    uialert(app.UIFigure, '복사할 파일이 없습니다.', 'Export');
                catch
                end
                return;
            end

            d = uiprogressdlg(app.UIFigure, 'Title', 'Export', ...
                'Message', '대상 파일 수집 중', 'Cancelable', 'on');
            cleanupDlg = onCleanup(@() app.safeClose(d));

            % [D1] release AVI VideoReader handles before copying when source path is currently open.
            releasedFlights = app.releaseOpenAvisForExport(fileList);
            cleanupReopen = onCleanup(@() app.reopenReleasedAvis(releasedFlights));

            copyMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
            failures = {};
            n = numel(fileList);
            for i = 1:n
                if d.CancelRequested
                    failures{end+1} = 'cancelled by user'; %#ok<AGROW>
                    break;
                end
                entry = fileList(i);
                d.Value   = (i - 1) / max(1, n);
                d.Message = sprintf('복사 중 (%d/%d): %s', i, n, entry.role);
                % [D1] self-overwrite guard
                srcAbs = app.normalizeAbsPath(entry.src);
                if startsWith(srcAbs, app.normalizeAbsPath(target))
                    failures{end+1} = sprintf('자기 자신 덮어쓰기 차단: %s', srcAbs); %#ok<AGROW>
                    continue;
                end
                [~, base, ext] = fileparts(entry.src);
                dstName = [entry.prefix base ext];
                dstPath = fullfile(target, dstName);
                % basename collision resolution
                k = 1;
                while isfile(dstPath)
                    dstName = sprintf('%s%s_%d%s', entry.prefix, base, k, ext);
                    dstPath = fullfile(target, dstName);
                    k = k + 1;
                end
                try
                    copyfile(entry.src, dstPath, 'f');
                    copyMap(srcAbs) = dstPath;
                catch ME
                    failures{end+1} = sprintf('%s: %s', entry.src, ME.message); %#ok<AGROW>
                    app.logCaught(ME, 'export-copy');
                end
            end

            d.Value   = 0.92;
            d.Message = 'project 파일 경로 재작성 중';
            stRewritten = app.rewriteProjectPathsForExport(st, copyMap);
            projDstName = 'project.fdproj';
            if ~isempty(app.ProjectFilePath)
                [~, b, ~] = fileparts(app.ProjectFilePath);
                if ~isempty(b), projDstName = [b '.fdproj']; end
            end
            projDst = fullfile(target, projDstName);
            fid = -1;
            try
                txt = jsonencode(stRewritten, 'PrettyPrint', true);
                fid = fopen(projDst, 'w');
                if fid < 0, error('FlightDataDashboard:ExportWrite', 'project 파일 쓰기 실패'); end
                fwrite(fid, txt, 'char');
                fclose(fid);
                fid = -1;
            catch ME
                if fid > 0
                    try
                        fclose(fid);
                    catch ME_close
                        app.logCaught(ME_close, 'export-project-close');
                    end
                end
                failures{end+1} = sprintf('project write: %s', ME.message);
            end

            d.Value   = 0.96;
            d.Message = '검증 중';
            verifyReport = app.verifyExportedProject(projDst, copyMap, opts.verifyHash);
            try
                app.writeExportVerificationReport(target, verifyReport, failures, opts.verifyHash);
            catch ME
                app.logCaught(ME, 'export-report');
            end

            ok = isempty(failures) && verifyReport.allPresent && verifyReport.allSizeMatch ...
                 && verifyReport.allWithinFolder ...
                 && (~opts.verifyHash || verifyReport.allHashMatch);

            d.Value   = 1.0;
            d.Message = '완료';

            if ~ok
                msg = sprintf('Export에서 문제가 발생했습니다.\n실패: %d개\n검증: 존재=%d/%d, 크기=%d/%d', ...
                    numel(failures), verifyReport.presentCount, verifyReport.totalCount, ...
                    verifyReport.sizeMatchCount, verifyReport.totalCount);
                sel = '';
                try
                    sel = uiconfirm(app.UIFigure, msg, 'Export 실패', ...
                        'Options', {'폴더 유지', '폴더 삭제', '재시도'}, ...
                        'DefaultOption', 1, 'CancelOption', 1);
                catch
                end
                switch sel
                    case '폴더 삭제'
                        try
                            rmdir(target, 's')
                        catch
                        end
                    case '재시도'
                        try
                            rmdir(target, 's')
                        catch
                        end
                        app.exportEverythingToFolder(parentFolder, opts);
                end
            end
        end

        function [list, missing] = buildExportFileList(app, st)
            % [Audit fix #5] Build list from EVERY recorded path. Missing files are returned
            % in the `missing` struct array so callers can surface skip/reselect/abort instead
            % of silently dropping entries.
            list    = struct('role', {}, 'src', {}, 'prefix', {});
            missing = struct('role', {}, 'src', {}, 'prefix', {}, 'fIdx', {});
            if isempty(st), return; end
            seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            addEntry = @(role, src, prefix) struct('role', role, 'src', src, 'prefix', prefix);
            addMissing = @(role, src, prefix, fIdx) struct('role', role, 'src', src, ...
                'prefix', prefix, 'fIdx', fIdx);
            if isfield(st, 'Flights')
                for i = 1:numel(st.Flights)
                    flightPrefix = sprintf('flight%d_', i);
                    fields = {{'DataFile','data'}, {'AviFile','avi'}, {'OptionFile','option'}};
                    for k = 1:numel(fields)
                        f = fields{k}{1}; tag = fields{k}{2};
                        if ~isfield(st.Flights(i), f) || isempty(st.Flights(i).(f))
                            continue;
                        end
                        p = app.normalizeAbsPath(st.Flights(i).(f));
                        if isfile(p)
                            if ~isKey(seen, p)
                                seen(p) = true;
                                list(end+1) = addEntry(sprintf('flight%d.%s', i, tag), p, flightPrefix); %#ok<AGROW>
                            end
                        else
                            missing(end+1) = addMissing(sprintf('flight%d.%s', i, tag), p, flightPrefix, i); %#ok<AGROW>
                        end
                    end
                end
            end
            if isfield(st, 'AuxFiles') && iscell(st.AuxFiles)
                for i = 1:numel(st.AuxFiles)
                    if isempty(st.AuxFiles{i}), continue; end
                    p = app.normalizeAbsPath(st.AuxFiles{i});
                    if isfile(p)
                        if ~isKey(seen, p)
                            seen(p) = true;
                            list(end+1) = addEntry(sprintf('aux%d', i), p, 'aux_'); %#ok<AGROW>
                        end
                    else
                        missing(end+1) = addMissing(sprintf('aux%d', i), p, 'aux_', 0); %#ok<AGROW>
                    end
                end
            end
        end

        function previewPath = getExportProjectPreviewPath(app)
            previewPath = 'project.fdproj';
            try
                if ~isempty(app.ProjectFilePath)
                    [~, b, ~] = fileparts(app.ProjectFilePath);
                    if ~isempty(b)
                        previewPath = [b '.fdproj'];
                    end
                end
            catch ME
                app.logCaught(ME, 'getExportProjectPreviewPath');
            end
        end

        function flights = releaseOpenAvisForExport(app, fileList)
            % [D1] If a file in the export list matches a flight's currently open AVI, release VR.
            flights = [];
            try
                for fIdx = 1:2
                    aviPath = app.normalizeAbsPath(app.Models(fIdx).aviFilePath);
                    if isempty(aviPath), continue; end
                    for i = 1:numel(fileList)
                        if strcmpi(app.normalizeAbsPath(fileList(i).src), aviPath)
                            if ~isempty(app.VideoState(fIdx).videoReader) ...
                                    && isvalid(app.VideoState(fIdx).videoReader)
                                try
                                    delete(app.VideoState(fIdx).videoReader);
                                catch
                                end
                            end
                            app.VideoState(fIdx).videoReader = [];
                            flights(end+1) = fIdx; %#ok<AGROW>
                            break;
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'releaseOpenAvisForExport');
            end
        end

        function reopenReleasedAvis(app, flights)
            % [P2] preserveSync=true so export reopen does not disturb dashboard sync state.
            for k = 1:numel(flights)
                fIdx = flights(k);
                p = app.Models(fIdx).aviFilePath;
                if isempty(p) && numel(app.VideoFilePath) >= fIdx
                    p = app.VideoFilePath{fIdx};
                end
                if isempty(p) || ~isfile(p), continue; end
                try
                    app.loadAviFileFromPath(fIdx, p, ...
                        struct('promptOnSync', false, 'preserveSync', true));
                catch ME
                    app.logCaught(ME, 'reopenReleasedAvis');
                end
            end
        end

        function st = rewriteProjectPathsForExport(app, st, copyMap)
            if isempty(st), return; end
            remap = @(p) app.remapPath(p, copyMap);
            if isfield(st, 'Flights')
                for i = 1:numel(st.Flights)
                    st.Flights(i).DataFile   = remap(st.Flights(i).DataFile);
                    st.Flights(i).AviFile    = remap(st.Flights(i).AviFile);
                    st.Flights(i).OptionFile = remap(st.Flights(i).OptionFile);
                end
            end
            if isfield(st, 'AuxFiles') && iscell(st.AuxFiles)
                for i = 1:numel(st.AuxFiles)
                    st.AuxFiles{i} = remap(st.AuxFiles{i});
                end
            end
        end

        function out = remapPath(app, p, copyMap)
            out = char(p);
            if isempty(out), return; end
            key = app.normalizeAbsPath(p);
            if isKey(copyMap, key)
                out = copyMap(key);
            end
        end

        function report = verifyExportedProject(app, projDst, copyMap, verifyHash)
            % [D6 + Audit fix #5] verify project file readable, ALL referenced paths exist
            % inside the export folder, sizes match, and (optionally) SHA256 matches.
            % Also asserts every Flight/Aux path field in the rewritten project lives under
            % the export folder (no stale absolute path leaked through).
            report = struct('allPresent', false, 'allSizeMatch', false, 'allHashMatch', true, ...
                            'allWithinFolder', true, ...
                            'presentCount', 0, 'sizeMatchCount', 0, 'hashMatchCount', 0, ...
                            'totalCount', 0, 'errors', {{}});
            try
                if ~isfile(projDst)
                    report.errors{end+1} = sprintf('project 파일 없음: %s', projDst); return;
                end
                exportRoot = app.normalizeAbsPath(fileparts(projDst));
                txt = fileread(projDst);
                st  = jsondecode(txt);

                % [Audit fix #5] Confirm every project path field lives inside exportRoot.
                projPaths = app.collectProjectPathFields(st);
                for i = 1:numel(projPaths)
                    p = projPaths{i};
                    if isempty(p), continue; end
                    pAbs = app.normalizeAbsPath(p);
                    if ~startsWith(pAbs, exportRoot)
                        report.allWithinFolder = false;
                        report.errors{end+1} = sprintf('project가 외부 경로를 참조함: %s', pAbs);
                    end
                end

                pairs = app.collectPathPairs(st, copyMap);
                report.totalCount = numel(pairs);
                if report.totalCount == 0
                    report.allPresent   = true;
                    report.allSizeMatch = true;
                    return;
                end
                presentOK = true; sizeOK = true; hashOK = true;
                for i = 1:numel(pairs)
                    src = pairs(i).src; dst = pairs(i).dst;
                    if isfile(dst)
                        report.presentCount = report.presentCount + 1;
                        sd = dir(src); dd = dir(dst);
                        if ~isempty(sd) && ~isempty(dd) && sd(1).bytes == dd(1).bytes
                            report.sizeMatchCount = report.sizeMatchCount + 1;
                        else
                            sizeOK = false;
                            report.errors{end+1} = sprintf('size mismatch: %s', dst);
                        end
                        if verifyHash
                            try
                                hSrc = app.sha256File(src);
                                hDst = app.sha256File(dst);
                                if strcmp(hSrc, hDst)
                                    report.hashMatchCount = report.hashMatchCount + 1;
                                else
                                    hashOK = false;
                                    report.errors{end+1} = sprintf('hash mismatch: %s', dst);
                                end
                            catch ME
                                app.logCaught(ME, 'export-hash'); hashOK = false;
                            end
                        end
                    else
                        presentOK = false;
                        report.errors{end+1} = sprintf('missing: %s', dst);
                    end
                end
                report.allPresent   = presentOK;
                report.allSizeMatch = sizeOK;
                report.allHashMatch = hashOK;
            catch ME
                app.logCaught(ME, 'export-verify');
                report.errors{end+1} = ME.message;
            end
        end

        function writeExportVerificationReport(~, targetFolder, report, failures, verifyHash)
            if nargin < 5, verifyHash = false; end
            reportPath = fullfile(targetFolder, 'export_verification_report.md');
            fid = fopen(reportPath, 'w');
            if fid < 0
                error('FlightDataDashboard:ExportReportWrite', 'cannot write %s', reportPath);
            end
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid, '# Export Verification Report\n\n');
            fprintf(fid, '- Generated: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
            fprintf(fid, '- SHA256: %s\n', mat2str(logical(verifyHash)));
            fprintf(fid, '- Present: %d / %d\n', report.presentCount, report.totalCount);
            fprintf(fid, '- Size match: %d / %d\n', report.sizeMatchCount, report.totalCount);
            fprintf(fid, '- Hash match: %d / %d\n', report.hashMatchCount, report.totalCount);
            fprintf(fid, '- All within folder: %s\n\n', mat2str(logical(report.allWithinFolder)));
            if isempty(failures)
                fprintf(fid, '## Copy Failures\n\nNone\n\n');
            else
                fprintf(fid, '## Copy Failures\n\n');
                for i = 1:numel(failures)
                    fprintf(fid, '- %s\n', failures{i});
                end
                fprintf(fid, '\n');
            end
            if isempty(report.errors)
                fprintf(fid, '## Verification Errors\n\nNone\n');
            else
                fprintf(fid, '## Verification Errors\n\n');
                for i = 1:numel(report.errors)
                    fprintf(fid, '- %s\n', report.errors{i});
                end
            end
        end

        function pairs = collectPathPairs(~, ~, copyMap)
            pairs = struct('src', {}, 'dst', {});
            keys = copyMap.keys;
            for i = 1:numel(keys)
                pairs(end+1) = struct('src', keys{i}, 'dst', copyMap(keys{i})); %#ok<AGROW>
            end
        end

        function out = collectProjectPathFields(~, st)
            % Flat list of every path string in a project-state struct.
            out = {};
            if isempty(st), return; end
            if isfield(st, 'Flights')
                for i = 1:numel(st.Flights)
                    f = st.Flights(i);
                    fields = {'DataFile', 'AviFile', 'OptionFile'};
                    for k = 1:numel(fields)
                        if isfield(f, fields{k}) && ~isempty(f.(fields{k}))
                            out{end+1} = char(f.(fields{k})); %#ok<AGROW>
                        end
                    end
                end
            end
            if isfield(st, 'AuxFiles') && iscell(st.AuxFiles)
                for i = 1:numel(st.AuxFiles)
                    if ~isempty(st.AuxFiles{i})
                        out{end+1} = char(st.AuxFiles{i}); %#ok<AGROW>
                    end
                end
            end
        end

        function h = sha256File(~, p)
            % Streaming SHA256 via java.security.MessageDigest (no Toolbox dependency).
            md  = java.security.MessageDigest.getInstance('SHA-256');
            fid = fopen(p, 'r');
            if fid < 0, error('FlightDataDashboard:HashOpen', 'cannot open %s', p); end
            cleanup = onCleanup(@() fclose(fid));
            while true
                buf = fread(fid, 1024*1024, '*uint8');
                if isempty(buf), break; end
                md.update(buf);
            end
            digest = typecast(md.digest(), 'uint8');
            h = lower(reshape(dec2hex(digest, 2).', 1, []));
        end

        function safeClose(~, d)
            try
                if ~isempty(d) && isvalid(d)
                    close(d);
                end
            catch
            end
        end

        function info = validateMappedColsAgainstData(app, fIdx)
            % [D5] return struct with missing required keys vs current rawData/Unscaled headers.
            info = struct('brokenMappings', {{}}, 'reasons', {{}});
            try
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0
                    src = app.Models(fIdx).rawData;
                end
                if isempty(src) || width(src) == 0
                    info.reasons{end+1} = 'no data loaded'; return;
                end
                headers = src.Properties.VariableNames;
                mc = app.Models(fIdx).mappedCols;
                reqKeys = app.REQ_KEYS;
                for i = 1:numel(reqKeys)
                    if ~isfield(mc, reqKeys{i}) || isempty(mc.(reqKeys{i})) ...
                            || ~ismember(mc.(reqKeys{i}), headers)
                        info.brokenMappings{end+1} = reqKeys{i};
                    end
                end
            catch ME
                app.logCaught(ME, 'validateMappedColsAgainstData');
            end
        end

        function info = validatePlotConfigAgainstData(app, fIdx)
            % [D5] return list of plot YColumn entries that no longer exist in the data table.
            info = struct('brokenPlots', {{}});
            try
                cfg = app.PlotConfigState;
                if isempty(cfg) || ~isfield(cfg, 'Flights') || numel(cfg.Flights) < fIdx
                    return;
                end
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0, src = app.Models(fIdx).rawData; end
                if isempty(src) || width(src) == 0, return; end
                headers = src.Properties.VariableNames;
                tabs = cfg.Flights(fIdx).PlotTabs;
                for t = 1:numel(tabs)
                    if ~isfield(tabs(t), 'Plots'), continue; end
                    for p = 1:numel(tabs(t).Plots)
                        y = tabs(t).Plots(p).YColumn;
                        if ~isempty(y) && ~ismember(y, headers)
                            info.brokenPlots{end+1} = sprintf('Tab%d/Plot%d:%s', t, p, y);
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'validatePlotConfigAgainstData');
            end
        end

        function requestFileChange(app, fIdx, kind)
            % [Phase 5] Files-tab entry. kind = 'data' | 'avi' | 'option'.
            switch lower(kind)
                case 'data'
                    [fn, pn] = uigetfile({'*.csv;*.dat;*.txt', 'Flight data'}, ...
                        sprintf('Flight %d 비행데이터 선택', fIdx));
                    if isequal(fn, 0), return; end
                    fullpath = fullfile(pn, fn);
                    try
                        app.parseFlightData(fIdx, fullpath);
                        app.afterFileReplaceValidation(fIdx, 'data');
                    catch ME
                        app.logCaught(ME, 'file-change-data');
                        try
                            uialert(app.UIFigure, sprintf('비행데이터 로드 실패:\n%s', ME.message), 'Files');
                        catch
                        end
                    end
                case 'avi'
                    [fn, pn] = uigetfile({'*.avi;*.mp4;*.mov', 'Video'}, ...
                        sprintf('Flight %d AVI 선택', fIdx));
                    if isequal(fn, 0), return; end
                    fullpath = fullfile(pn, fn);
                    try
                        % [Fix #3] path-based loader keeps VideoFilePath{}/aviFilePath in sync.
                        app.loadAviFileFromPath(fIdx, fullpath, struct('promptOnSync', true));
                    catch ME
                        app.logCaught(ME, 'file-change-avi');
                    end
                case 'option'
                    [fn, pn] = uigetfile({'*.dat;*.txt', 'Option file'}, ...
                        sprintf('Flight %d option 선택', fIdx));
                    if isequal(fn, 0), return; end
                    fullpath = fullfile(pn, fn);
                    app.Models(fIdx).optionFilePath = app.normalizeAbsPath(fullpath);
                    src = app.Models(fIdx).rawDataUnscaled;
                    if isempty(src) || width(src) == 0
                        try
                            uialert(app.UIFigure, '비행데이터를 먼저 로드하세요.', 'Files');
                        catch
                        end
                        return;
                    end
                    draft = app.parseOptionFileToDraft(fullpath, src.Properties.VariableNames);
                    app.applyOptionDraftToModel(fIdx, draft, false);
                    app.afterFileReplaceValidation(fIdx, 'option');
                otherwise
                    return;
            end
            % [Q-07] Reflect changed data/AVI/option paths in the Export tab immediately.
            try
                app.refreshExportTab();
            catch ME
                app.logCaught(ME, 'export-refresh-path');
            end
            app.markProjectDirtyAndScheduleRefresh('file-change');
        end

        function afterFileReplaceValidation(app, fIdx, kind)
            % [D5] surface broken mappings/plots after a file replace. Apply stays blocked
            % at the dialog level until user resolves them (dialog UI lives in Phase 6+).
            m = app.validateMappedColsAgainstData(fIdx);
            p = app.validatePlotConfigAgainstData(fIdx);
            if ~isempty(m.brokenMappings) || ~isempty(p.brokenPlots)
                msg = sprintf(['Flight %d %s 교체 후 호환성 경고:\n', ...
                               '  Broken mappings: %s\n', ...
                               '  Broken plots: %s\n', ...
                               'dialog에서 해소할 때까지 Apply가 차단됩니다.'], ...
                    fIdx, kind, strjoin(m.brokenMappings, ', '), strjoin(p.brokenPlots, ', '));
                try
                    uialert(app.UIFigure, msg, 'D5: 호환성 검증');
                catch
                end
                app.ProjectDirty = true;
            end
        end

        function autoLoadProjectFromFile(app, filePath)
            % [Phase 5] 12-step uiprogressdlg auto-load matching design §5.
            % [Critical 1] Track load integrity. Only clear ProjectDirty when every
            %              referenced file loaded cleanly (no missing/reselect/validation issue).
            % [Critical 2] Refresh local Models(fIdx) snapshot BEFORE each load step
            %              so warnMissingFile->requestFileChange takes effect on the
            %              subsequent step within the same flight.
            if nargin < 2 || isempty(filePath) || ~isfile(filePath)
                try
                    uialert(app.UIFigure, 'project 파일을 찾을 수 없습니다.', 'Project');
                catch
                end
                return;
            end
            loadCompletedCleanly   = true;   % [Critical 1] flag
            try
                d = uiprogressdlg(app.UIFigure, 'Title', 'Project 자동 로드', ...
                    'Message', 'project 파일 읽는 중', 'Cancelable', 'on');
                cleanupDlg = onCleanup(@() app.safeClose(d));
                advance = @(val, msg) app.setProgress(d, val, msg);

                advance(0.02, 'project 파일 읽는 중');
                st = app.loadProjectFile(filePath);
                if isempty(st), return; end

                advance(0.08, '파일 경로 검증 중');
                app.applyProjectState(st, struct('skipFiles', true));
                if ~isempty(d) && d.CancelRequested
                    app.ProjectDirty = true; return;
                end

                stepBase = [0.10 0.18 0.30; 0.42 0.50 0.62]; % rows: flights, cols: option/data/avi
                for fIdx = 1:2
                    if ~isempty(d) && d.CancelRequested
                        app.ProjectDirty = true; return;
                    end

                    % [Critical 2] Always re-read Models(fIdx) before each sub-step.
                    m = app.Models(fIdx);
                    advance(stepBase(fIdx, 1), sprintf('Flight %d option 파일 읽는 중', fIdx));
                    if ~isempty(m.optionFilePath) && ~isfile(m.optionFilePath)
                        status = app.warnMissingFile(fIdx, 'option', m.optionFilePath);
                        if ~strcmp(status, 'ok'), loadCompletedCleanly = false; end
                    end

                    m = app.Models(fIdx);  % [Critical 2] refresh after possible reselect
                    advance(stepBase(fIdx, 2), sprintf('Flight %d 비행데이터 로드 중', fIdx));
                    if ~isempty(m.dataFilePath) && isfile(m.dataFilePath)
                        try
                            app.parseFlightData(fIdx, m.dataFilePath);
                        catch ME
                            app.logCaught(ME, 'auto-load-data');
                            loadCompletedCleanly = false;
                        end
                    elseif ~isempty(m.dataFilePath)
                        status = app.warnMissingFile(fIdx, 'data', m.dataFilePath);
                        if ~strcmp(status, 'ok'), loadCompletedCleanly = false; end
                    end

                    m = app.Models(fIdx);  % [Critical 2] refresh again before AVI step
                    advance(stepBase(fIdx, 3), sprintf('Flight %d AVI 메타데이터 로드 중', fIdx));
                    if ~isempty(m.aviFilePath) && isfile(m.aviFilePath)
                        try
                            % [P1] preserveSync=true so restored AVI sync survives auto-load.
                            app.loadAviFileFromPath(fIdx, m.aviFilePath, ...
                                struct('promptOnSync', false, 'preserveSync', true));
                        catch ME
                            app.logCaught(ME, 'auto-load-avi');
                            loadCompletedCleanly = false;
                        end
                    elseif ~isempty(m.aviFilePath)
                        status = app.warnMissingFile(fIdx, 'avi', m.aviFilePath);
                        if ~strcmp(status, 'ok'), loadCompletedCleanly = false; end
                    end
                end

                if ~isempty(d) && d.CancelRequested
                    app.ProjectDirty = true; return;
                end
                advance(0.78, '비행데이터 동기화 상태 복원 중');
                if app.SyncState.IsSynced
                    app.setFlightDataSync(app.SyncState.SyncT1, app.SyncState.SyncT2, true);
                end
                for fIdx = 1:2
                    vss = app.VideoSyncState(fIdx);
                    if vss.IsSynced && ~isempty(app.VideoState(fIdx).videoReader)
                        app.setVideoSync(fIdx, vss.AnchorFrame, vss.AnchorTime, vss.VideoFps, vss.DataFps, true);
                    end
                end

                advance(0.86, 'plot tab 복원 중');
                if ~isempty(app.PlotConfigState)
                    for fIdx = 1:2
                        try
                            app.rebuildPlotsFromConfig(fIdx, app.PlotConfigState);
                        catch ME
                            app.logCaught(ME, 'auto-load-plots');
                        end
                    end
                end

                advance(0.94, '화면 갱신 중');
                for fIdx = 1:2
                    try
                        if ~isempty(app.Models(fIdx).rawData) && height(app.Models(fIdx).rawData) > 0
                            app.setupDataUI(fIdx);
                            app.afterFileReplaceValidation(fIdx, 'project-load');
                        end
                    catch ME
                        app.logCaught(ME, 'autoLoadProjectFromFile');
                    end
                end

                advance(1.00, '완료');
                % [Critical 1] Only clear dirty when nothing went sideways.
                if loadCompletedCleanly
                    app.ProjectDirty = false;
                else
                    app.ProjectDirty = true;
                end
            catch ME
                app.logCaught(ME, 'auto-load');
                app.ProjectDirty = true;   % [Critical 1] keep dirty on exception
                try
                    uialert(app.UIFigure, sprintf('project 자동 로드 실패:\n%s', ME.message), 'Project');
                catch
                end
            end
        end

        function setProgress(~, d, val, msg)
            try
                if isempty(d) || ~isvalid(d), return; end
                d.Value   = max(0, min(1, val));
                d.Message = msg;
            catch
            end
        end

        function status = warnMissingFile(app, fIdx, kind, p)
            % [Critical 1] Returns a status string so autoLoadProjectFromFile can
            % decide whether to clear ProjectDirty at the end:
            %   'skip'    — user skipped the missing file (load remains incomplete)
            %   'changed' — user reselected (Models updated; caller must refresh local m)
            %   (throws 'FlightDataDashboard:AutoLoadAborted' on cancel/abort)
            % Returns 'ok' only when nothing was missing (caller still gates on isfile).
            status = 'skip';
            try
                sel = uiconfirm(app.UIFigure, ...
                    sprintf('Flight %d %s 파일을 찾을 수 없습니다:\n%s', fIdx, kind, p), ...
                    '누락 파일', 'Options', {'건너뛰기', '파일 다시 선택', '중단'}, ...
                    'DefaultOption', 1, 'CancelOption', 3);
                switch sel
                    case '파일 다시 선택'
                        app.requestFileChange(fIdx, kind);
                        status = 'changed';
                    case '중단'
                        error('FlightDataDashboard:AutoLoadAborted', '사용자가 자동 로드를 중단했습니다.');
                    otherwise
                        status = 'skip';
                end
                app.ProjectDirty = true;   % stays dirty until resolved
            catch ME
                if ~strcmp(ME.identifier, 'FlightDataDashboard:AutoLoadAborted')
                    app.logCaught(ME, 'missing-file');
                else
                    rethrow(ME);
                end
            end
        end

        function rebuildPlotsFromConfig(app, fIdx, cfg)
            % [Audit fix #7] Restore tabs to match saved config exactly.
            % - clearAllTabs auto-creates one default tab; consume that as the first
            %   restored tab and only add (numel(tabs)-1) extras to avoid drift.
            % - Reset PlotConfigState for this flight before replaying so that
            %   recordPlotInConfig (called from plotSelectedVariable) does not
            %   duplicate existing entries.
            % - Apply saved XLim/YLim/YLimMode/Height after each plot is created.
            if isempty(cfg) || ~isstruct(cfg) || ~isfield(cfg, 'Flights') ...
                    || numel(cfg.Flights) < fIdx
                return;
            end
            tabs = app.compactPlotTabsSpec(cfg.Flights(fIdx).PlotTabs);
            if isempty(tabs), return; end

            try
                app.clearAllTabs(fIdx);
            catch
            end

            % After clearAllTabs there is exactly one fresh tab.
            existingTabCount = numel(app.UI(fIdx).plotTabs);
            for t = (existingTabCount + 1):numel(tabs)
                try
                    app.addPlotTab(fIdx);
                catch
                end
            end

            % Clear the in-memory PlotConfig for this flight; recordPlotInConfig will refill it.
            cfgOut = app.ensurePlotConfigShape(app.PlotConfigState);
            cfgOut.Flights(fIdx).PlotTabs = [];
            app.PlotConfigState = cfgOut;

            for t = 1:numel(tabs)
                tabSpec = tabs(t);
                if isfield(tabSpec, 'Title') && ~isempty(tabSpec.Title) ...
                        && numel(app.UI(fIdx).plotTabs) >= t ...
                        && isvalid(app.UI(fIdx).plotTabs(t))
                    try
                        app.UI(fIdx).plotTabs(t).Title = char(tabSpec.Title);
                    catch
                    end
                end
                if isfield(tabSpec, 'Plots') && ~isempty(tabSpec.Plots)
                    plotsSpec = app.normalizePlotSpecArray(tabSpec.Plots);
                    for p = 1:numel(plotsSpec)
                        spec = plotsSpec(p);
                        yCol = '';
                        if isfield(spec, 'YColumn'), yCol = char(spec.YColumn); end
                        if isempty(yCol), continue; end
                        idx = find(strcmp({app.Models(fIdx).displayMeta.header}, yCol), 1);
                        if isempty(idx), continue; end
                        % Force the plotSelectedVariable target row + active tab.
                        app.Models(fIdx).selectedRow = idx;
                        try
                            if numel(app.UI(fIdx).plotTabs) >= t && isvalid(app.UI(fIdx).plotTabs(t))
                                app.UI(fIdx).tabGroup.SelectedTab = app.UI(fIdx).plotTabs(t);
                            end
                        catch
                        end
                        try
                            app.plotSelectedVariable(fIdx);
                        catch
                        end
                        % Apply axis spec to the freshly added plot.
                        try
                            axesCell = app.UI(fIdx).plotAxes{t};
                            if iscell(axesCell) && ~isempty(axesCell)
                                ax = axesCell{end};
                                if isvalid(ax)
                                    if isfield(spec, 'XLimMode') && strcmpi(char(spec.XLimMode), 'auto')
                                        ax.XLimMode = 'auto';
                                    elseif isfield(spec, 'XLim') && ~isempty(spec.XLim) ...
                                            && numel(spec.XLim) == 2
                                        ax.XLim = spec.XLim;
                                        ax.XLimMode = 'manual';
                                    end
                                    if isfield(spec, 'YLimMode') && ~isempty(spec.YLimMode)
                                        ax.YLimMode = char(spec.YLimMode);
                                    end
                                    if isfield(spec, 'YLim') && ~isempty(spec.YLim) ...
                                            && numel(spec.YLim) == 2, ax.YLim = spec.YLim; end
                                    if isfield(spec, 'YLabel') && ~isempty(spec.YLabel)
                                        ylabel(ax, char(spec.YLabel), 'FontWeight', 'bold', ...
                                            'FontSize', 10, 'Interpreter', 'none');
                                    end
                                    if isfield(spec, 'Height') && ~isempty(spec.Height)
                                        app.applyPlotHeightInPlace(fIdx, t, numel(axesCell), spec.Height);
                                    end
                                    cfgLive = app.ensurePlotConfigShape(app.PlotConfigState);
                                    livePlotIdx = numel(axesCell);
                                    if numel(cfgLive.Flights(fIdx).PlotTabs) >= t ...
                                            && numel(cfgLive.Flights(fIdx).PlotTabs(t).Plots) >= livePlotIdx
                                        if isfield(spec, 'YLabel') && ~isempty(spec.YLabel)
                                            cfgLive.Flights(fIdx).PlotTabs(t).Plots(livePlotIdx).YLabel = char(spec.YLabel);
                                        end
                                        if isfield(spec, 'Height') && ~isempty(spec.Height)
                                            cfgLive.Flights(fIdx).PlotTabs(t).Plots(livePlotIdx).Height = spec.Height;
                                        end
                                        cfgLive.Flights(fIdx).PlotTabs(t).Plots(livePlotIdx).XLim = ax.XLim;
                                        cfgLive.Flights(fIdx).PlotTabs(t).Plots(livePlotIdx).XLimMode = char(ax.XLimMode);
                                        cfgLive.Flights(fIdx).PlotTabs(t).Plots(livePlotIdx).Order = livePlotIdx;
                                        app.PlotConfigState = cfgLive;
                                    end
                                end
                            end
                        catch ME
                            app.logCaught(ME, 'rebuildPlotsFromConfig');
                        end
                    end
                end
                if isfield(tabSpec, 'LinkXWithinTab')
                    app.setLinkXWithinTab(fIdx, t, logical(tabSpec.LinkXWithinTab));
                end
            end
        end
    end

    % =========================================================================
    % [Audit fix #1/#2/#8] Modeless Settings/Edit dialog
    % Tabs: Project / Files / Sync / Options / Plot Manager / Export
    % =========================================================================
    methods (Access = public)
        function openEditDialog(app)
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    figure(app.EditDialog);
                    return;
                end
            catch
            end

            pos = [120, 120, 980, 660];
            try
                if ~isempty(app.ProjectState) && isfield(app.ProjectState, 'UiState') ...
                        && isfield(app.ProjectState.UiState, 'EditDialogPosition') ...
                        && numel(app.ProjectState.UiState.EditDialogPosition) == 4
                    pos = app.ProjectState.UiState.EditDialogPosition;
                end
            catch
            end

            fig = uifigure('Name', '설정/프로젝트 편집기', ...
                           'Position', pos, 'Resize', 'on', ...
                           'CloseRequestFcn', @(~,~) app.closeEditDialog());
            app.EditDialog = fig;

            outer = uigridlayout(fig, [3 1]);
            outer.RowHeight    = {28, '1x', 28};
            outer.ColumnWidth  = {'1x'};
            outer.Padding      = [6 6 6 6];
            outer.RowSpacing   = 4;

            % Top status bar
            statusGrid = uigridlayout(outer, [1 3]);
            statusGrid.RowHeight = {'fit'};
            statusGrid.ColumnWidth = {'1x', 200, 160};
            app.EditDialogStatusLbl = uilabel(statusGrid, 'Text', '준비', 'FontSize', 12);
            app.EditDialogDirtyLbl  = uilabel(statusGrid, 'Text', '변경 없음', ...
                'FontSize', 12, 'HorizontalAlignment', 'right', 'FontColor', [0.4 0.4 0.4]);
            app.EditDialogTimeLbl   = uilabel(statusGrid, 'Text', '', ...
                'FontSize', 11, 'HorizontalAlignment', 'right', 'FontColor', [0.4 0.4 0.4]);

            tabs = uitabgroup(outer);
            tabProject = uitab(tabs, 'Title', 'Project');
            tabFiles   = uitab(tabs, 'Title', 'Files');
            tabSync    = uitab(tabs, 'Title', 'Sync');
            tabOpts    = uitab(tabs, 'Title', 'Options');
            tabPlot    = uitab(tabs, 'Title', 'Plot Manager');
            tabExport  = uitab(tabs, 'Title', 'Export');

            app.buildEditTabProject(tabProject);
            app.buildEditTabFiles(tabFiles);
            app.buildEditTabSync(tabSync);
            app.buildEditTabOptions(tabOpts);
            app.buildEditTabPlot(tabPlot);
            app.buildEditTabExport(tabExport);
            app.applyLightPanelTitleContrast(fig);

            % Bottom button row
            bottom = uigridlayout(outer, [1 4]);
            bottom.RowHeight = {'fit'};
            bottom.ColumnWidth = {'1x', 120, 120, 100};
            uilabel(bottom, 'Text', '');
            uibutton(bottom, 'Text', '적용 (즉시 반영)', ...
                'ButtonPushedFcn', @(~,~) app.applyPendingDialogChanges());
            uibutton(bottom, 'Text', 'project 저장', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveProject());
            uibutton(bottom, 'Text', '닫기', ...
                'ButtonPushedFcn', @(~,~) app.closeEditDialog());

            app.refreshEditDialog();
        end

        function closeEditDialog(app)
            % [Review High #2] Before tearing down, force-apply any pending debounce
            % AND capture live PlotConfig so unsynced edits are not lost.
            try
                if ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer) ...
                        && strcmpi(app.EditApplyTimer.Running, 'on')
                    try
                        stop(app.EditApplyTimer);
                    catch
                    end
                    try
                        app.applyPendingDialogChanges();
                    catch ME
                        app.logCaught(ME, 'editClose:pendingApply');
                    end
                end
                try
                    app.capturePlotConfigFromUi();
                catch ME
                    app.logCaught(ME, 'editClose:plotCapture');
                end
            catch ME, app.logCaught(ME, 'closeEditDialog:clear-pending-timer'); end
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    % Capture position into project ui state before closing.
                    try
                        if isempty(app.ProjectState), app.ProjectState = app.createDefaultProjectState(); end
                        app.ProjectState.UiState.EditDialogPosition = app.EditDialog.Position;
                    catch
                    end
                    delete(app.EditDialog);
                end
            catch ME
                app.logCaught(ME, 'closeEditDialog:delete-dialog');
            end
            app.EditDialog = [];
        end

        function refreshEditDialog(app)
            % Refresh status, paths, sync values, option drafts, plot tree if dialog open.
            % [Review Medium #5] 모든 ED* 핸들 접근 전 ~isempty + isvalid 가드.
            try
                if isempty(app.EditDialog) || ~isvalid(app.EditDialog), return; end
                if ~isempty(app.EditDialogDirtyLbl) && isvalid(app.EditDialogDirtyLbl)
                    if app.ProjectDirty
                        app.EditDialogDirtyLbl.Text = '변경됨 ●';
                        app.EditDialogDirtyLbl.FontColor = [0.8 0.2 0.2];
                    else
                        app.EditDialogDirtyLbl.Text = '변경 없음';
                        app.EditDialogDirtyLbl.FontColor = [0.4 0.4 0.4];
                    end
                end
                if ~isempty(app.EditDialogTimeLbl) && isvalid(app.EditDialogTimeLbl) ...
                        && ~isnat(app.LastEditApplyTime)
                    app.EditDialogTimeLbl.Text = sprintf('마지막 적용 %s', ...
                        char(datetime(app.LastEditApplyTime, 'Format', 'HH:mm:ss')));
                end
                % Refresh per-tab content if the handles still exist.
                % [Medium #5] 각 sub-refresh 호출도 독립 try/catch 로 cascading failure 차단.
                try
                    app.refreshProjectTab();
                catch ME
                    app.logCaught(ME, 'refreshProjectTab');
                end
                try
                    app.refreshFilesTab();
                catch ME
                    app.logCaught(ME, 'refreshFilesTab');
                end
                try
                    app.refreshSyncTab();
                catch ME
                    app.logCaught(ME, 'refreshSyncTab');
                end
                try
                    app.refreshOptionsTab();
                catch ME
                    app.logCaught(ME, 'refreshOptionsTab');
                end
                try
                    app.refreshPlotTab();
                catch ME
                    app.logCaught(ME, 'refreshPlotTab');
                end
                try
                    app.refreshExportTab();
                catch ME
                    app.logCaught(ME, 'refreshExportTab');
                end
            catch ME
                app.logCaught(ME, 'refreshEditDialog');
            end
        end

        function buildEditTabProject(app, parent)
            gl = uigridlayout(parent, [7 4]);
            gl.RowHeight = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
            gl.ColumnWidth = {120, '1x', 100, 100};
            gl.RowSpacing = 6; gl.Padding = [10 10 10 10];

            uilabel(gl, 'Text', 'Project 파일:', 'FontWeight', 'bold');
            app.EDProjectPathLbl = uilabel(gl, 'Text', '(없음)', 'FontColor', [0.3 0.3 0.7]);
            app.EDProjectPathLbl.Layout.Column = 2;
            uibutton(gl, 'Text', '열기...', ...
                'ButtonPushedFcn', @(~,~) app.editDialogOpenProject());
            uibutton(gl, 'Text', '다른 이름으로...', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveProjectAs());

            uilabel(gl, 'Text', '저장:', 'FontWeight', 'bold');
            app.EDProjectStatusLbl = uilabel(gl, 'Text', '미저장', 'FontColor', [0.4 0.4 0.4]);
            app.EDProjectStatusLbl.Layout.Column = 2;
            uibutton(gl, 'Text', '저장', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveProject());
            uibutton(gl, 'Text', '자동 로드', ...
                'ButtonPushedFcn', @(~,~) app.editDialogAutoLoad());

            uilabel(gl, 'Text', '자동 저장:', 'FontWeight', 'bold');
            app.EDProjectAutosaveCB = uicheckbox(gl, 'Text', sprintf('%d초 간격 snapshot', app.AutosaveIntervalSec), ...
                'Value', app.ProjectAutosaveEnabled, ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleAutosave(src.Value));
            app.EDProjectAutosaveCB.Layout.Column = [2 4];

            uilabel(gl, 'Text', '종료 확인:', 'FontWeight', 'bold');
            app.EDProjectConfirmCloseCB = uicheckbox(gl, 'Text', '종료 전 저장 확인', ...
                'Value', app.ProjectConfirmOnClose, ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleCloseConfirm(src.Value));
            app.EDProjectConfirmCloseCB.Layout.Column = [2 4];

            uilabel(gl, 'Text', '마지막 저장:', 'FontWeight', 'bold');
            app.EDProjectLastSaveLbl = uilabel(gl, 'Text', '(없음)', 'FontColor', [0.3 0.3 0.7]);
            app.EDProjectLastSaveLbl.Layout.Column = [2 4];
        end

        function buildEditTabFiles(app, parent)
            gl = uigridlayout(parent, [10 4]);
            gl.RowHeight = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
            gl.ColumnWidth = {120, '1x', 100, 100};
            gl.RowSpacing = 6; gl.Padding = [10 10 10 10];

            app.EDFilesPathLbl = struct();
            for fIdx = 1:2
                head = uilabel(gl, 'Text', sprintf('=== Flight %d ===', fIdx), 'FontWeight', 'bold');
                head.Layout.Column = [1 4];
                pairs = {{'data', '비행데이터'}, {'avi', 'AVI'}, {'option', 'Option'}};
                for k = 1:numel(pairs)
                    kind = pairs{k}{1};
                    uilabel(gl, 'Text', [pairs{k}{2} ':'], 'FontWeight', 'bold');
                    lbl = uilabel(gl, 'Text', '(없음)', 'FontColor', [0.3 0.3 0.7]);
                    lbl.Layout.Column = 2;
                    app.EDFilesPathLbl.(sprintf('f%d_%s', fIdx, kind)) = lbl;
                    uibutton(gl, 'Text', '변경...', ...
                        'ButtonPushedFcn', @(~,~) app.requestFileChangeAndRefresh(fIdx, kind));
                    uibutton(gl, 'Text', '다시 로드', ...
                        'ButtonPushedFcn', @(~,~) app.editDialogReloadFile(fIdx, kind));
                end
            end
            uibutton(gl, 'Text', 'Export everything to folder', ...
                'BackgroundColor', [0.06 0.65 0.50], 'FontColor', 'w', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogExport());
        end

        function buildEditTabSync(app, parent)
            % [F-03/F-04] Adds "현재 화면값 가져오기" buttons + offset preview label.
            gl = uigridlayout(parent, [16 5]);
            gl.RowHeight = repmat({'fit'}, 1, 16);
            gl.ColumnWidth = {130, 100, 100, 100, 100};
            gl.RowSpacing = 5; gl.Padding = [10 10 10 10];

            lbl = uilabel(gl, 'Text', '== Flight 1 ↔ Flight 2 비행시간 sync ==', 'FontWeight', 'bold');
            lbl.Layout.Column = [1 5];
            lbl = uilabel(gl, 'Text', 'Flight 1 기준 시간(s):');
            lbl.Tooltip = lbl.Text;
            app.EDSyncF1Time = uieditfield(gl, 'numeric', 'Value', 0, ...
                'ValueChangedFcn', @(~,~) app.refreshSyncOffsetLabel());
            lbl = uilabel(gl, 'Text', 'Flight 2 기준 시간(s):');
            lbl.Tooltip = lbl.Text;
            app.EDSyncF2Time = uieditfield(gl, 'numeric', 'Value', 0, ...
                'ValueChangedFcn', @(~,~) app.refreshSyncOffsetLabel());
            uibutton(gl, 'Text', '동기 적용', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyFlightSync(true));
            % [F-03] Capture current spinner values from main UI into both fields.
            uibutton(gl, 'Text', '현재값 가져오기', ...
                'Tooltip', '메인 UI 의 Flight 1/2 spinner 값을 그대로 가져옵니다.', ...
                'ButtonPushedFcn', @(~,~) app.editDialogCaptureCurrentFlightSync());
            uibutton(gl, 'Text', '동기 해제', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyFlightSync(false));
            % [F-04] Offset preview spans full row.
            app.EDSyncOffsetLbl = uilabel(gl, 'Text', 'Offset (t2 - t1): 0.000 s', ...
                'FontColor', [0.3 0.3 0.7], 'FontWeight', 'bold');
            app.EDSyncOffsetLbl.Layout.Column = [1 5];

            for fIdx = 1:2
                lbl = uilabel(gl, 'Text', sprintf('== Flight %d AVI sync ==', fIdx), 'FontWeight', 'bold');
                lbl.Layout.Column = [1 5];
                lbl = uilabel(gl, 'Text', 'Anchor Frame:');
                lbl.Tooltip = lbl.Text;
                ef = uieditfield(gl, 'numeric', 'Value', 0, 'Limits', [0 Inf]);
                app.(sprintf('EDVSync%dFrame', fIdx)) = ef;
                lbl = uilabel(gl, 'Text', 'Anchor Time(s):');
                lbl.Tooltip = lbl.Text;
                et = uieditfield(gl, 'numeric', 'Value', 0);
                app.(sprintf('EDVSync%dTime', fIdx)) = et;
                lbl = uilabel(gl, 'Text', 'Video FPS:');
                lbl.Tooltip = lbl.Text;
                vf = uieditfield(gl, 'numeric', 'Value', 70, 'Limits', [1 Inf]);
                app.(sprintf('EDVSync%dVFPS', fIdx)) = vf;
                lbl = uilabel(gl, 'Text', 'Data FPS:');
                lbl.Tooltip = lbl.Text;
                df = uieditfield(gl, 'numeric', 'Value', 50, 'Limits', [1 Inf]);
                app.(sprintf('EDVSync%dDFPS', fIdx)) = df;
                btnA = uibutton(gl, 'Text', '동기 적용', ...
                    'ButtonPushedFcn', @(~,~) app.editDialogApplyVideoSync(fIdx, true));
                btnA.Layout.Column = [2 3];
                btnB = uibutton(gl, 'Text', '동기 해제', ...
                    'ButtonPushedFcn', @(~,~) app.editDialogApplyVideoSync(fIdx, false));
                btnB.Layout.Column = [4 5];
                % [F-03] Capture current frame/time/fps for this flight.
                btnC = uibutton(gl, 'Text', '현재 화면값 가져오기', ...
                    'Tooltip', '메인 UI 의 현재 AVI Frame / Flight time / Hz 를 가져옵니다.', ...
                    'ButtonPushedFcn', @(~,~) app.editDialogCaptureCurrentVideoSync(fIdx));
                btnC.Layout.Column = [1 5];
            end
        end

        function buildEditTabOptions(app, parent)
            gl = uigridlayout(parent, [5 4]);
            gl.RowHeight = {'fit', '1x', 'fit', 'fit', 'fit'};   % header / tabs / reset / btn
            gl.ColumnWidth = {120, '1x', 100, 100};
            gl.RowSpacing = 6; gl.Padding = [10 10 10 10];

            uilabel(gl, 'Text', 'Flight:', 'FontWeight', 'bold');
            app.EDOptFlightDD = uidropdown(gl, 'Items', {'Flight 1', 'Flight 2'}, 'Value', 'Flight 1', ...
                'ValueChangedFcn', @(~,~) app.refreshOptionsTab());
            uibutton(gl, 'Text', '검증', ...
                'ButtonPushedFcn', @(~,~) app.editDialogValidateOptionDraft());
            uibutton(gl, 'Text', '되돌리기', ...
                'ButtonPushedFcn', @(~,~) app.editDialogRevertOptionDraft());

            % [D-05] Explicit reset path — restores RequiredColumns to first-N-data-columns
            % defaults so a user can recover after an option file replace breaks mappings.
            resetRow = uigridlayout(gl, [1 3]);
            resetRow.Layout.Row = 3; resetRow.Layout.Column = [1 4];
            resetRow.ColumnWidth = {'1x', 200, '1x'};
            uilabel(resetRow, 'Text', '');
            uibutton(resetRow, 'Text', 'Reset to default mapping', ...
                'Tooltip', '확인 후 RequiredColumns 매핑을 data file 의 첫 N개 컬럼으로 초기화', ...
                'ButtonPushedFcn', @(~,~) app.editDialogResetOptionDraftMapping());
            uilabel(resetRow, 'Text', '');

            tabs = uitabgroup(gl);
            tabs.Layout.Row = 2; tabs.Layout.Column = [1 4];
            tabReq = uitab(tabs, 'Title', 'RequiredColumns');
            tabDsp = uitab(tabs, 'Title', 'DisplayColumns');

            app.EDOptReqTable = uitable(tabReq, 'Data', table(), ...
                'ColumnEditable', [false true], ...
                'CellEditCallback', @(src, evt) app.onOptionDraftEdit('req', src, evt));
            app.EDOptReqTable.Position = [10 10 900 280];

            % [P5] Visible column removed (was not enforced anywhere). 5 editable columns now.
            app.EDOptDspTable = uitable(tabDsp, 'Data', table(), ...
                'ColumnEditable', [true true true true true], ...
                'CellEditCallback', @(src, evt) app.onOptionDraftEdit('dsp', src, evt));
            app.EDOptDspTable.Position = [10 10 900 280];

            btnRow = uigridlayout(gl, [1 3]);
            btnRow.Layout.Row = 4; btnRow.Layout.Column = [1 4];   % [D-05] 한 칸 위로 이동(reset 행 추가)
            btnRow.ColumnWidth = {'1x', 140, 160};
            uilabel(btnRow, 'Text', '');
            uibutton(btnRow, 'Text', '적용 (즉시 반영)', ...
                'BackgroundColor', [0.15 0.38 0.82], 'FontColor', 'w', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyOptionDraft());
            uibutton(btnRow, 'Text', 'option 파일 저장', ...
                'ButtonPushedFcn', @(~,~) app.editDialogWriteOptionDraft());
        end

        function buildEditTabPlot(app, parent)
            % [F-01] Plot Manager: left tree + right property panel.
            outer = uigridlayout(parent, [3 1]);
            outer.RowHeight   = {'fit', '1x', 'fit'};
            outer.ColumnWidth = {'1x'};
            outer.RowSpacing  = 6; outer.Padding = [10 10 10 10];

            % Row 1: header
            header = uigridlayout(outer, [1 6]);
            header.RowHeight   = {'fit'};
            header.ColumnWidth = {80, 120, 90, 90, 110, 110};
            header.ColumnSpacing = 4;
            uilabel(header, 'Text', 'Flight:', 'FontWeight', 'bold');
            app.EDPlotFlightDD = uidropdown(header, 'Items', {'Flight 1', 'Flight 2'}, 'Value', 'Flight 1', ...
                'ValueChangedFcn', @(~,~) app.refreshPlotTab());
            uibutton(header, 'Text', '캡처', ...
                'ButtonPushedFcn', @(~,~) app.capturePlotConfigAndRefresh());
            uibutton(header, 'Text', '재구성', ...
                'ButtonPushedFcn', @(~,~) app.editDialogRebuildPlots());
            uibutton(header, 'Text', 'Sync X→All Tabs', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSyncTabXLimAll());
            uibutton(header, 'Text', 'Sync X→Plot', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSyncSelectedPlotXLimAll());

            % Row 2: tree (left) + property panel (right)
            mid = uigridlayout(outer, [1 2]);
            mid.RowHeight   = {'1x'};
            mid.ColumnWidth = {'1x', 320};
            mid.ColumnSpacing = 6;

            app.EDPlotTree = uitree(mid, ...
                'SelectionChangedFcn', @(~,~) app.onPlotTreeSelectionChanged());

            propPanel = uipanel(mid, 'Title', '선택 항목 속성', ...
                'FontWeight', 'bold', 'Scrollable', 'on');
            pg = uigridlayout(propPanel, [12 2]);
            pg.RowHeight = repmat({'fit'}, 1, 12);
            pg.ColumnWidth = {110, '1x'};
            pg.RowSpacing = 4; pg.Padding = [6 6 6 6];

            uilabel(pg, 'Text', '이름:');
            app.EDPlotNameEdit = uieditfield(pg, 'text', 'Value', '', ...
                'Editable', 'off', 'Tooltip', 'YColumn 기반 자동 생성');
            uilabel(pg, 'Text', 'Y 데이터 항목:');
            app.EDPlotYColDD = uidropdown(pg, 'Items', {'(선택)'}, 'Value', '(선택)');
            uilabel(pg, 'Text', 'Y 라벨:');
            app.EDPlotYLabelEdit = uieditfield(pg, 'text', 'Value', '', ...
                'Tooltip', 'plot y축에 표시할 라벨');
            uilabel(pg, 'Text', 'X auto:');
            app.EDPlotXAutoCB = uicheckbox(pg, 'Text', 'XLimMode = auto', 'Value', false, ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleXAuto(src.Value));
            uilabel(pg, 'Text', 'X min:');
            app.EDPlotXMin = uieditfield(pg, 'numeric', 'Value', 0);
            uilabel(pg, 'Text', 'X max:');
            app.EDPlotXMax = uieditfield(pg, 'numeric', 'Value', 60);
            uilabel(pg, 'Text', 'Y auto:');
            app.EDPlotYAutoCB = uicheckbox(pg, 'Text', 'YLimMode = auto', 'Value', true, ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleYAuto(src.Value));
            uilabel(pg, 'Text', 'Y min:');
            app.EDPlotYMin = uieditfield(pg, 'numeric', 'Value', 0, 'Enable', 'off');
            uilabel(pg, 'Text', 'Y max:');
            app.EDPlotYMax = uieditfield(pg, 'numeric', 'Value', 1, 'Enable', 'off');
            uilabel(pg, 'Text', 'Plot height:');
            app.EDPlotHeight = uieditfield(pg, 'numeric', 'Value', 150, 'Limits', [60 600]);
            uilabel(pg, 'Text', '액션:');
            actRow = uigridlayout(pg, [1 5], 'Padding', [0 0 0 0], 'ColumnSpacing', 4);
            actRow.ColumnWidth = {52, 34, 34, 52, 64};
            uibutton(actRow, 'Text', '적용', ...
                'BackgroundColor', [0.15 0.38 0.82], 'FontColor', 'w', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyPlotProps());
            uibutton(actRow, 'Text', '↑', ...
                'Tooltip', '선택 plot 순서를 위로 이동', ...
                'ButtonPushedFcn', @(~,~) app.editDialogMoveSelectedPlot(-1));
            uibutton(actRow, 'Text', '↓', ...
                'Tooltip', '선택 plot 순서를 아래로 이동', ...
                'ButtonPushedFcn', @(~,~) app.editDialogMoveSelectedPlot(1));
            uibutton(actRow, 'Text', '복제', ...
                'ButtonPushedFcn', @(~,~) app.editDialogDuplicatePlot());
            uibutton(actRow, 'Text', '삭제(plot)', ...
                'BackgroundColor', [0.75 0.20 0.20], 'FontColor', 'w', ...
                'ButtonPushedFcn', @(~,~) app.editDialogDeleteSelectedPlot());

            % Row 3: bottom
            bottom = uigridlayout(outer, [1 3]);
            bottom.RowHeight = {'fit'};
            bottom.ColumnWidth = {130, '1x', 120};
            uilabel(bottom, 'Text', 'LinkXWithinTab:', 'FontWeight', 'bold');
            app.EDPlotLinkCB = uicheckbox(bottom, 'Text', '선택된 tab의 X축 link', 'Value', true, ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleSelectedTabLink(src.Value));
            uibutton(bottom, 'Text', '삭제(tab)', ...
                'ButtonPushedFcn', @(~,~) app.editDialogDeleteSelectedTab());
        end

        function buildEditTabExport(app, parent)
            gl = uigridlayout(parent, [8 3]);
            gl.RowHeight = {'fit', 'fit', 'fit', 'fit', '1x', 'fit', 'fit', 90};
            gl.ColumnWidth = {180, '1x', 140};
            gl.RowSpacing = 6; gl.Padding = [10 10 10 10];

            uilabel(gl, 'Text', 'Export parent 폴더:', 'FontWeight', 'bold');
            app.EDExpParentEdit = uieditfield(gl, 'text', 'Value', pwd);
            uibutton(gl, 'Text', '폴더 선택...', ...
                'ButtonPushedFcn', @(~,~) app.editDialogPickExportFolder());

            uilabel(gl, 'Text', '생성될 폴더:', 'FontWeight', 'bold');
            app.EDExpPreviewLbl = uilabel(gl, 'Text', '(자동 생성)', 'FontColor', [0.3 0.3 0.7]);
            uilabel(gl, 'Text', '');

            uilabel(gl, 'Text', 'SHA256 검증:', 'FontWeight', 'bold');
            app.EDExpHashCB = uicheckbox(gl, 'Text', '느림. 기본 off', 'Value', false);
            uilabel(gl, 'Text', '');

            uibutton(gl, 'Text', '목록 새로고침', ...
                'ButtonPushedFcn', @(~,~) app.refreshExportTab());
            uibutton(gl, 'Text', 'Export everything to folder', ...
                'BackgroundColor', [0.06 0.65 0.50], 'FontColor', 'w', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogExport());
            uilabel(gl, 'Text', '');

            app.EDExpFileTable = uitable(gl, 'Data', cell(0, 4), ...
                'ColumnName', {'Role', 'Status', 'MB', 'Path'}, ...
                'ColumnEditable', [false false false false]);
            app.EDExpFileTable.Layout.Row = 5;
            app.EDExpFileTable.Layout.Column = [1 3];

            uilabel(gl, 'Text', '누락/요약:', 'FontWeight', 'bold');
            app.EDExpMissingLbl = uilabel(gl, 'Text', '파일 0개', 'FontColor', [0.3 0.3 0.7]);
            app.EDExpMissingLbl.Layout.Column = [2 3];

            uilabel(gl, 'Text', 'Progress log:', 'FontWeight', 'bold');
            app.EDExpLogArea = uitextarea(gl, 'Value', {''}, 'Editable', 'off');
            app.EDExpLogArea.Layout.Row = 8; app.EDExpLogArea.Layout.Column = [1 3];
        end

        % ===== Refresh helpers ========================================
        function refreshProjectTab(app)
            try
                if ~isempty(app.EDProjectPathLbl) && isvalid(app.EDProjectPathLbl)
                    if isempty(app.ProjectFilePath)
                        app.EDProjectPathLbl.Text = '(없음)';
                    else
                        app.EDProjectPathLbl.Text = app.ProjectFilePath;
                    end
                end
                if ~isempty(app.EDProjectStatusLbl) && isvalid(app.EDProjectStatusLbl)
                    if app.ProjectDirty
                        app.EDProjectStatusLbl.Text = '변경됨 (미저장)';
                    elseif ~isempty(app.ProjectFilePath)
                        app.EDProjectStatusLbl.Text = '저장됨';
                    else
                        app.EDProjectStatusLbl.Text = '미저장';
                    end
                end
                if ~isempty(app.EDProjectAutosaveCB) && isvalid(app.EDProjectAutosaveCB)
                    app.EDProjectAutosaveCB.Value = logical(app.ProjectAutosaveEnabled);
                end
                if ~isempty(app.EDProjectConfirmCloseCB) && isvalid(app.EDProjectConfirmCloseCB)
                    app.EDProjectConfirmCloseCB.Value = logical(app.ProjectConfirmOnClose);
                end
                if ~isempty(app.EDProjectLastSaveLbl) && isvalid(app.EDProjectLastSaveLbl)
                    if isempty(app.ProjectLastSaveText)
                        app.EDProjectLastSaveLbl.Text = '(없음)';
                    else
                        app.EDProjectLastSaveLbl.Text = app.ProjectLastSaveText;
                    end
                end
            catch
            end
        end

        function refreshFilesTab(app)
            try
                if ~isstruct(app.EDFilesPathLbl) || isempty(fieldnames(app.EDFilesPathLbl)), return; end
                for fIdx = 1:2
                    m = app.Models(fIdx);
                    pairs = {{'data', m.dataFilePath}, {'avi', m.aviFilePath}, {'option', m.optionFilePath}};
                    for k = 1:numel(pairs)
                        key = sprintf('f%d_%s', fIdx, pairs{k}{1});
                        if isfield(app.EDFilesPathLbl, key) && isvalid(app.EDFilesPathLbl.(key))
                            v = pairs{k}{2};
                            if isempty(v), v = '(없음)'; end
                            app.EDFilesPathLbl.(key).Text = char(v);
                        end
                    end
                end
            catch
            end
        end

        function refreshSyncTab(app)
            try
                if ~isempty(app.EDSyncF1Time) && isvalid(app.EDSyncF1Time)
                    app.EDSyncF1Time.Value = app.SyncState.SyncT1;
                end
                if ~isempty(app.EDSyncF2Time) && isvalid(app.EDSyncF2Time)
                    app.EDSyncF2Time.Value = app.SyncState.SyncT2;
                end
                app.refreshSyncOffsetLabel();
                for fIdx = 1:2
                    vss = app.VideoSyncState(fIdx);
                    handles = {sprintf('EDVSync%dFrame', fIdx), vss.AnchorFrame; ...
                               sprintf('EDVSync%dTime',  fIdx), vss.AnchorTime;  ...
                               sprintf('EDVSync%dVFPS',  fIdx), vss.VideoFps;    ...
                               sprintf('EDVSync%dDFPS',  fIdx), vss.DataFps};
                    for r = 1:size(handles, 1)
                        try
                            if isprop(app, handles{r,1}) && ~isempty(app.(handles{r,1})) && isvalid(app.(handles{r,1}))
                                app.(handles{r,1}).Value = double(handles{r,2});
                            end
                        catch
                        end
                    end
                end
            catch
            end
        end

        function refreshOptionsTab(app)
            try
                if isempty(app.EDOptFlightDD) || ~isvalid(app.EDOptFlightDD), return; end
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                draft = app.OptionDrafts{fIdx};
                if isempty(draft)
                    src = app.Models(fIdx).rawDataUnscaled;
                    if isempty(src) || width(src) == 0
                        if isvalid(app.EDOptReqTable), app.EDOptReqTable.Data = table(); end
                        if isvalid(app.EDOptDspTable), app.EDOptDspTable.Data = table(); end
                        return;
                    end
                    draft = app.parseOptionFileToDraft(app.resolveOptionFilePath(fIdx), src.Properties.VariableNames);
                    app.OptionDrafts{fIdx} = draft;
                end
                % Required columns table
                reqKeys = app.REQ_KEYS;
                vals = cell(numel(reqKeys), 1);
                for r = 1:numel(reqKeys)
                    if isfield(draft.mappedCols, reqKeys{r})
                        vals{r} = char(draft.mappedCols.(reqKeys{r}));
                    else
                        vals{r} = '';
                    end
                end
                if isvalid(app.EDOptReqTable)
                    app.EDOptReqTable.Data = table(reqKeys(:), vals, ...
                        'VariableNames', {'Key', 'Column'});
                end
                % Display columns table
                if isvalid(app.EDOptDspTable)
                    n = numel(draft.displayMeta);
                    headers = cell(n,1); units = cell(n,1); fmts = cell(n,1);
                    orders = zeros(n,1); scales = ones(n,1);
                    for r = 1:n
                        headers{r} = char(draft.displayMeta(r).header);
                        units{r}   = char(draft.displayMeta(r).unit);
                        fmts{r}    = char(draft.displayMeta(r).format);
                        orders(r)  = draft.displayMeta(r).order;
                        scales(r)  = draft.displayMeta(r).scale;
                    end
                    % [P5] Visible column removed.
                    app.EDOptDspTable.Data = table(headers, units, fmts, orders, scales, ...
                        'VariableNames', {'Header', 'Unit', 'Format', 'Order', 'Scale'});
                end
            catch ME
                app.logCaught(ME, 'refreshOptionsTab');
            end
        end

        function refreshPlotTab(app)
            try
                if isempty(app.EDPlotTree) || ~isvalid(app.EDPlotTree), return; end
                delete(app.EDPlotTree.Children);
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights) >= fIdx
                    tabs = app.compactPlotTabsSpec(cfg.Flights(fIdx).PlotTabs);
                    cfg.Flights(fIdx).PlotTabs = tabs;
                    app.PlotConfigState = cfg;
                    for t = 1:numel(tabs)
                        title = sprintf('Tab %d', t);
                        if isfield(tabs(t), 'Title') && ~isempty(tabs(t).Title)
                            title = char(tabs(t).Title);
                        end
                        node = uitreenode(app.EDPlotTree, 'Text', title, 'NodeData', struct('kind', 'tab', 'tab', t));
                        if isfield(tabs(t), 'Plots')
                            for p = 1:numel(tabs(t).Plots)
                                pl = tabs(t).Plots(p);
                                lbl = sprintf('Plot %d: %s', p, char(pl.YColumn));
                                uitreenode(node, 'Text', lbl, 'NodeData', struct('kind', 'plot', 'tab', t, 'plot', p));
                            end
                        end
                    end
                    expand(app.EDPlotTree);
                end
            catch ME
                app.logCaught(ME, 'refreshPlotTab');
            end
        end

        function refreshExportTab(app)
            try
                hasPreview = ~isempty(app.EDExpPreviewLbl) && isvalid(app.EDExpPreviewLbl);
                hasTable = ~isempty(app.EDExpFileTable) && isvalid(app.EDExpFileTable);
                if ~hasPreview && ~hasTable, return; end
                if hasPreview
                    folderName = ['FlightDashboard_' char(datetime('now', 'Format', 'yyyy-MM-dd_HH-mm-ss'))];
                    app.EDExpPreviewLbl.Text = folderName;
                end
                if ~hasTable, return; end
                st = app.collectCurrentProjectState();
                [fileList, missingList] = app.buildExportFileList(st);
                rows = cell(numel(fileList) + numel(missingList) + 1, 4);
                r = 1;
                rows(r, :) = {'project', 'generated', '', app.getExportProjectPreviewPath()};
                r = r + 1;
                for k = 1:numel(fileList)
                    bytesMb = '';
                    try
                        d = dir(fileList(k).src);
                        if ~isempty(d)
                            bytesMb = sprintf('%.2f', d(1).bytes / 1024 / 1024);
                        end
                    catch
                    end
                    rows(r, :) = {fileList(k).role, 'copy', bytesMb, fileList(k).src};
                    r = r + 1;
                end
                for k = 1:numel(missingList)
                    rows(r, :) = {missingList(k).role, 'missing', '', missingList(k).src};
                    r = r + 1;
                end
                app.EDExpFileTable.Data = rows;
                if ~isempty(app.EDExpMissingLbl) && isvalid(app.EDExpMissingLbl)
                    totalFiles = numel(fileList) + 1;
                    app.EDExpMissingLbl.Text = sprintf('복사/생성 %d개, 누락 %d개', totalFiles, numel(missingList));
                    if isempty(missingList)
                        app.EDExpMissingLbl.FontColor = [0.06 0.45 0.22];
                    else
                        app.EDExpMissingLbl.FontColor = [0.75 0.20 0.20];
                    end
                end
            catch
            end
        end

        % ===== Button callbacks ========================================
        function editDialogSaveProject(app)
            if isempty(app.ProjectFilePath)
                app.editDialogSaveProjectAs(); return;
            end
            ok = app.saveProjectFile(app.ProjectFilePath);
            if ok
                try
                    uialert(app.EditDialog, 'project 저장 완료', 'Project');
                catch
                end
                app.refreshEditDialog();
            end
        end

        function editDialogSaveProjectAs(app)
            [fn, pn] = uiputfile({'*.fdproj', 'Project file'}, '저장할 project 파일');
            if isequal(fn, 0), return; end
            ok = app.saveProjectFile(fullfile(pn, fn));
            if ok
                try
                    uialert(app.EditDialog, 'project 저장 완료', 'Project');
                catch
                end
                app.refreshEditDialog();
            end
        end

        function editDialogOpenProject(app)
            [fn, pn] = uigetfile({'*.fdproj', 'Project file'}, '열 project 파일');
            if isequal(fn, 0), return; end
            app.autoLoadProjectFromFile(fullfile(pn, fn));
            app.refreshEditDialog();
        end

        function editDialogAutoLoad(app)
            if isempty(app.ProjectFilePath)
                app.editDialogOpenProject(); return;
            end
            app.autoLoadProjectFromFile(app.ProjectFilePath);
            app.refreshEditDialog();
        end

        function editDialogToggleAutosave(app, on)
            try
                app.ProjectAutosaveEnabled = logical(on);
                if ~on
                    if ~isempty(app.AutosaveTimer) && isvalid(app.AutosaveTimer)
                        stop(app.AutosaveTimer); delete(app.AutosaveTimer); app.AutosaveTimer = [];
                    end
                elseif app.ProjectDirty
                    app.markProjectDirtyAndScheduleRefresh('autosave-on');
                end
            catch ME
                app.logCaught(ME, 'editDialogToggleAutosave');
            end
        end

        function editDialogToggleCloseConfirm(app, on)
            try
                app.ProjectConfirmOnClose = logical(on);
                app.markProjectDirtyAndScheduleRefresh('close-confirm-policy');
            catch ME
                app.logCaught(ME, 'editDialogToggleCloseConfirm');
            end
        end

        function requestFileChangeAndRefresh(app, fIdx, kind)
            app.requestFileChange(fIdx, kind);
            app.refreshEditDialog();
        end

        function editDialogReloadFile(app, fIdx, kind)
            m = app.Models(fIdx);
            switch kind
                case 'data'
                    if ~isempty(m.dataFilePath) && isfile(m.dataFilePath)
                        try
                            app.parseFlightData(fIdx, m.dataFilePath);
                        catch ME
                            app.logCaught(ME, 'reload-data');
                        end
                    end
                case 'avi'
                    if ~isempty(m.aviFilePath) && isfile(m.aviFilePath)
                        try
                            app.loadAviFileFromPath(fIdx, m.aviFilePath, struct('promptOnSync', false));
                        catch ME
                            app.logCaught(ME, 'reload-avi');
                        end
                    end
                case 'option'
                    if ~isempty(m.optionFilePath) && isfile(m.optionFilePath) ...
                            && ~isempty(m.rawDataUnscaled) && width(m.rawDataUnscaled) > 0
                        draft = app.parseOptionFileToDraft(m.optionFilePath, m.rawDataUnscaled.Properties.VariableNames);
                        app.applyOptionDraftToModel(fIdx, draft, false);
                    end
            end
            app.refreshEditDialog();
        end

        function refreshSyncOffsetLabel(app)
            % [F-04] Update offset preview label whenever Sync inputs change.
            try
                if isempty(app.EDSyncOffsetLbl) || ~isvalid(app.EDSyncOffsetLbl), return; end
                t1 = 0; t2 = 0;
                if ~isempty(app.EDSyncF1Time) && isvalid(app.EDSyncF1Time), t1 = app.EDSyncF1Time.Value; end
                if ~isempty(app.EDSyncF2Time) && isvalid(app.EDSyncF2Time), t2 = app.EDSyncF2Time.Value; end
                app.EDSyncOffsetLbl.Text = sprintf('Offset (t2 - t1): %.3f s', t2 - t1);
            catch
            end
        end

        function editDialogCaptureCurrentFlightSync(app)
            % [F-03] Pull current spinner values into Flight-Flight sync inputs.
            try
                if ~isempty(app.UI) && numel(app.UI) >= 1 && isfield(app.UI(1), 'spinner') ...
                        && ~isempty(app.UI(1).spinner) && isvalid(app.UI(1).spinner)
                    app.EDSyncF1Time.Value = app.UI(1).spinner.Value;
                end
                if numel(app.UI) >= 2 && isfield(app.UI(2), 'spinner') ...
                        && ~isempty(app.UI(2).spinner) && isvalid(app.UI(2).spinner)
                    app.EDSyncF2Time.Value = app.UI(2).spinner.Value;
                end
                app.refreshSyncOffsetLabel();
            catch ME
                app.logCaught(ME, 'sync-capture-ff');
            end
        end

        function editDialogCaptureCurrentVideoSync(app, fIdx)
            % [F-03] Pull current AVI frame + flight time + Hz into Video sync inputs.
            try
                vss = app.VideoSyncState(fIdx);
                ef = app.(sprintf('EDVSync%dFrame', fIdx));
                et = app.(sprintf('EDVSync%dTime',  fIdx));
                vf = app.(sprintf('EDVSync%dVFPS',  fIdx));
                df = app.(sprintf('EDVSync%dDFPS',  fIdx));
                if vss.CurrentFrame > 0
                    ef.Value = double(vss.CurrentFrame);
                end
                % current spinner time
                if ~isempty(app.UI) && numel(app.UI) >= fIdx && isfield(app.UI(fIdx), 'spinner') ...
                        && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                    et.Value = app.UI(fIdx).spinner.Value;
                end
                if vss.VideoFps > 0, vf.Value = double(vss.VideoFps); end
                if vss.DataFps  > 0, df.Value = double(vss.DataFps);  end
            catch ME
                app.logCaught(ME, 'sync-capture-video');
            end
        end

        function editDialogApplyFlightSync(app, enabled)
            try
                t1 = 0; t2 = 0;
                if isvalid(app.EDSyncF1Time), t1 = app.EDSyncF1Time.Value; end
                if isvalid(app.EDSyncF2Time), t2 = app.EDSyncF2Time.Value; end
                app.setFlightDataSync(t1, t2, enabled);
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'sync-apply');
            end
        end

        function editDialogApplyVideoSync(app, fIdx, enabled)
            try
                af = app.(sprintf('EDVSync%dFrame', fIdx)).Value;
                at = app.(sprintf('EDVSync%dTime',  fIdx)).Value;
                vf = app.(sprintf('EDVSync%dVFPS',  fIdx)).Value;
                df = app.(sprintf('EDVSync%dDFPS',  fIdx)).Value;
                app.setVideoSync(fIdx, af, at, vf, df, enabled);
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'video-sync-apply');
            end
        end

        function onOptionDraftEdit(app, kind, ~, evt)
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                draft = app.OptionDrafts{fIdx};
                if isempty(draft), return; end
                if strcmp(kind, 'req')
                    key = char(app.EDOptReqTable.Data.Key(evt.Indices(1)));
                    draft.mappedCols.(key) = char(evt.NewData);
                elseif strcmp(kind, 'dsp')
                    r = evt.Indices(1);
                    cols = app.EDOptDspTable.Data.Properties.VariableNames;
                    field = cols{evt.Indices(2)};
                    switch field
                        case 'Header', draft.displayMeta(r).header = char(evt.NewData);
                        case 'Unit',   draft.displayMeta(r).unit   = char(evt.NewData);
                        case 'Format', draft.displayMeta(r).format = char(evt.NewData);
                        case 'Order',  draft.displayMeta(r).order  = double(evt.NewData);
                        case 'Scale'
                            s = double(evt.NewData);
                            if isnan(s) || s == 0, s = 1.0; end
                            draft.displayMeta(r).scale = s;
                    end
                end
                app.OptionDrafts{fIdx} = draft;
                app.ProjectDirty = true;
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'option-edit');
            end
        end

        function editDialogValidateOptionDraft(app)
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0
                    try
                        uialert(app.EditDialog, '비행데이터를 먼저 로드하세요.', 'Options');
                    catch
                    end
                    return;
                end
                [ok, info] = app.validateOptionDraft(app.OptionDrafts{fIdx}, src.Properties.VariableNames);
                if ok
                    try
                        uialert(app.EditDialog, '검증 통과', 'Options');
                    catch
                    end
                else
                    msg = sprintf('검증 실패\n  Broken mappings: %s\n  Broken columns: %s\n  Reasons: %s', ...
                        strjoin(info.brokenMappings, ', '), strjoin(info.brokenColumns, ', '), ...
                        strjoin(info.reasons, ', '));
                    try
                        uialert(app.EditDialog, msg, 'Options');
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'option-validate');
            end
        end

        function editDialogApplyOptionDraft(app)
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0, return; end
                [ok, ~] = app.validateOptionDraft(app.OptionDrafts{fIdx}, src.Properties.VariableNames);
                if ~ok
                    try
                        uialert(app.EditDialog, '검증 실패: Apply 차단', 'Options');
                    catch
                    end
                    return;
                end
                app.applyOptionDraftToModel(fIdx, app.OptionDrafts{fIdx}, false);
                try
                    app.setupDataUI(fIdx);
                catch
                end
                try
                    app.updateDashboard(fIdx, app.Models(fIdx).currentIndex);
                catch
                end
                app.markProjectDirtyAndScheduleRefresh('option-apply');
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'option-apply');
            end
        end

        function editDialogWriteOptionDraft(app)
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                draft = app.OptionDrafts{fIdx};
                if isempty(draft), return; end
                p = app.resolveOptionFilePath(fIdx);
                ok = app.writeOptionFileAtomic(p, draft);
                if ok
                    try
                        uialert(app.EditDialog, ['option 파일 저장 완료: ' p], 'Options');
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'option-write');
            end
        end

        function editDialogRevertOptionDraft(app)
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0, return; end
                app.OptionDrafts{fIdx} = app.parseOptionFileToDraft(app.resolveOptionFilePath(fIdx), src.Properties.VariableNames);
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'option-revert');
            end
        end

        function editDialogResetOptionDraftMapping(app)
            % [D-05] Reset RequiredColumns of the current option draft to defaults
            % (first-N data columns, paralleling parseOptionFileToDraft auto-fill).
            % Asks user to confirm because this discards manual mapping work.
            try
                fIdx = 1; if strcmp(app.EDOptFlightDD.Value, 'Flight 2'), fIdx = 2; end
                src = app.Models(fIdx).rawDataUnscaled;
                if isempty(src) || width(src) == 0
                    try
                        uialert(app.EditDialog, '비행데이터가 먼저 로드되어야 합니다.', 'Options');
                    catch
                    end
                    return;
                end
                sel = '';
                try
                    sel = uiconfirm(app.EditDialog, ...
                        sprintf(['Flight %d 의 RequiredColumns 매핑을 데이터 파일 기본값(첫 N개 컬럼)으로 ', ...
                                 '초기화 합니다.\n현재 편집 중인 매핑은 폐기됩니다. 계속하시겠습니까?'], fIdx), ...
                        'Reset mapping', ...
                        'Options', {'초기화', '취소'}, 'DefaultOption', 2, 'CancelOption', 2);
                catch
                    sel = '초기화';
                end
                if ~strcmp(sel, '초기화'), return; end

                headers  = src.Properties.VariableNames;
                reqKeys  = app.REQ_KEYS;
                mappedCols = struct();
                for i = 1:numel(reqKeys)
                    if i <= numel(headers)
                        mappedCols.(reqKeys{i}) = char(headers{i});
                    else
                        mappedCols.(reqKeys{i}) = '';
                    end
                end
                draft = app.OptionDrafts{fIdx};
                if isempty(draft) || ~isstruct(draft)
                    draft = struct('sourcePath', char(app.resolveOptionFilePath(fIdx)), ...
                                   'mappedCols', mappedCols, 'displayMeta', struct( ...
                                   'header', {}, 'unit', {}, 'format', {}, 'scale', {}, 'order', {}));
                else
                    draft.mappedCols = mappedCols;
                end
                app.OptionDrafts{fIdx} = draft;
                app.ProjectDirty = true;
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'option-reset');
            end
        end

        function capturePlotConfigAndRefresh(app)
            app.capturePlotConfigFromUi();
            app.refreshEditDialog();
        end

        function editDialogRebuildPlots(app)
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                app.rebuildPlotsFromConfig(fIdx, app.PlotConfigState);
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'plot-rebuild');
            end
        end

        function editDialogToggleSelectedTabLink(app, on)
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~isfield(nd, 'tab'), return; end
                app.setLinkXWithinTab(fIdx, nd.tab, on);
            catch ME
                app.logCaught(ME, 'plot-link');
            end
        end

        function editDialogSyncTabXLimAll(app)
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if isfield(nd, 'tab'), app.applyTabXLimToAllTabs(fIdx, nd.tab); end
            catch ME
                app.logCaught(ME, 'plot-sync-tab');
            end
        end

        function editDialogSyncSelectedPlotXLimAll(app)
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if strcmp(nd.kind, 'plot')
                    app.syncSelectedPlotXLimToAll(fIdx, nd.tab, nd.plot);
                end
            catch ME
                app.logCaught(ME, 'plot-sync-plot');
            end
        end

        function onPlotTreeSelectionChanged(app)
            % [F-01] Populate property panel from selected plot config entry.
            try
                if isempty(app.EDPlotTree) || ~isvalid(app.EDPlotTree), return; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                % populate YColumn dropdown choices from displayMeta
                ycols = {};
                if ~isempty(app.Models(fIdx).displayMeta)
                    ycols = {app.Models(fIdx).displayMeta.header};
                end
                if isempty(ycols), ycols = {'(none)'}; end
                if isfield(nd, 'kind') && strcmp(nd.kind, 'plot')
                    t = nd.tab; p = nd.plot;
                    tabs = cfg.Flights(fIdx).PlotTabs;
                    if numel(tabs) >= t && numel(tabs(t).Plots) >= p
                        spec = tabs(t).Plots(p);
                        app.EDPlotNameEdit.Value = char(spec.YColumn);
                        app.EDPlotYColDD.Items   = ycols;
                        if ismember(spec.YColumn, ycols)
                            app.EDPlotYColDD.Value = char(spec.YColumn);
                        else
                            app.EDPlotYColDD.Value = ycols{1};
                        end
                        if ~isempty(app.EDPlotYLabelEdit) && isvalid(app.EDPlotYLabelEdit)
                            if isfield(spec, 'YLabel') && ~isempty(spec.YLabel)
                                app.EDPlotYLabelEdit.Value = char(spec.YLabel);
                            else
                                app.EDPlotYLabelEdit.Value = char(spec.YColumn);
                            end
                        end
                        if numel(spec.XLim) == 2
                            app.EDPlotXMin.Value = spec.XLim(1);
                            app.EDPlotXMax.Value = spec.XLim(2);
                        end
                        autoX = isfield(spec, 'XLimMode') && strcmpi(char(spec.XLimMode), 'auto');
                        if ~isempty(app.EDPlotXAutoCB) && isvalid(app.EDPlotXAutoCB)
                            app.EDPlotXAutoCB.Value = autoX;
                        end
                        app.EDPlotXMin.Enable = ternary(autoX, 'off', 'on');
                        app.EDPlotXMax.Enable = ternary(autoX, 'off', 'on');
                        autoY = strcmpi(spec.YLimMode, 'auto');
                        app.EDPlotYAutoCB.Value = autoY;
                        app.EDPlotYMin.Enable = ternary(autoY, 'off', 'on');
                        app.EDPlotYMax.Enable = ternary(autoY, 'off', 'on');
                        if numel(spec.YLim) == 2
                            app.EDPlotYMin.Value = spec.YLim(1);
                            app.EDPlotYMax.Value = spec.YLim(2);
                        end
                        app.EDPlotHeight.Value = max(60, min(600, double(spec.Height)));
                    end
                elseif isfield(nd, 'kind') && strcmp(nd.kind, 'tab')
                    app.EDPlotNameEdit.Value = sprintf('Tab %d', nd.tab);
                    app.EDPlotYColDD.Items = ycols; app.EDPlotYColDD.Value = ycols{1};
                    if ~isempty(app.EDPlotXAutoCB) && isvalid(app.EDPlotXAutoCB)
                        app.EDPlotXAutoCB.Value = false;
                    end
                    app.EDPlotXMin.Enable = 'on';
                    app.EDPlotXMax.Enable = 'on';
                    if ~isempty(app.EDPlotYLabelEdit) && isvalid(app.EDPlotYLabelEdit)
                        app.EDPlotYLabelEdit.Value = '';
                    end
                end
            catch ME
                app.logCaught(ME, 'onPlotTreeSelectionChanged');
            end
        end

        function editDialogToggleYAuto(app, isAuto)
            try
                app.EDPlotYMin.Enable = ternary(isAuto, 'off', 'on');
                app.EDPlotYMax.Enable = ternary(isAuto, 'off', 'on');
            catch ME
                app.logCaught(ME, 'editDialogToggleYAuto');
            end
        end

        function editDialogToggleXAuto(app, isAuto)
            try
                app.EDPlotXMin.Enable = ternary(isAuto, 'off', 'on');
                app.EDPlotXMax.Enable = ternary(isAuto, 'off', 'on');
            catch ME
                app.logCaught(ME, 'editDialogToggleXAuto');
            end
        end

        function editDialogApplyPlotProps(app)
            % [F-01] Apply property panel values to the selected plot.
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~isfield(nd, 'kind') || ~strcmp(nd.kind, 'plot'), return; end
                t = nd.tab; p = nd.plot;

                axisCfg = struct();
                if ~isempty(app.EDPlotXAutoCB) && isvalid(app.EDPlotXAutoCB) && app.EDPlotXAutoCB.Value
                    axisCfg.XLimMode = 'auto';
                else
                    xLim = [app.EDPlotXMin.Value app.EDPlotXMax.Value];
                    if any(~isfinite(xLim)) || xLim(2) <= xLim(1)
                        try
                            uialert(app.EditDialog, 'X min/max 범위를 확인하세요.', 'Plot Manager');
                        catch
                        end
                        return;
                    end
                    axisCfg.XLim = xLim;
                    axisCfg.XLimMode = 'manual';
                end
                if app.EDPlotYAutoCB.Value
                    axisCfg.YLimMode = 'auto';
                else
                    yLim = [app.EDPlotYMin.Value app.EDPlotYMax.Value];
                    if any(~isfinite(yLim)) || yLim(2) <= yLim(1)
                        try
                            uialert(app.EditDialog, 'Y min/max 범위를 확인하세요.', 'Plot Manager');
                        catch
                        end
                        return;
                    end
                    axisCfg.YLimMode = 'manual';
                    axisCfg.YLim    = yLim;
                end
                app.applyPlotAxisConfig(fIdx, t, p, axisCfg);

                % Update PlotConfigState with new height + YColumn.
                % [Bug fix] YColumn change uses in-place YData replacement instead of
                % rebuildPlotsFromConfig — the latter could drop the plot when the
                % captured PlotConfigState had implicit-empty Tab(1) entries created
                % by sparse struct-array assignment.
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) >= t && numel(cfg.Flights(fIdx).PlotTabs(t).Plots) >= p
                    oldY = char(cfg.Flights(fIdx).PlotTabs(t).Plots(p).YColumn);
                    newY = char(app.EDPlotYColDD.Value);
                    if ~isempty(newY) && ~strcmp(newY, '(none)') && ~strcmp(newY, '(선택)') && ~strcmp(newY, oldY)
                        if ~app.replacePlotYColumnInPlace(fIdx, t, p, newY)
                            return;
                        end
                        cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                    end
                    if numel(cfg.Flights(fIdx).PlotTabs) >= t && numel(cfg.Flights(fIdx).PlotTabs(t).Plots) >= p
                        yLabelText = strtrim(char(app.EDPlotYLabelEdit.Value));
                        if isempty(yLabelText)
                            if isfield(cfg.Flights(fIdx).PlotTabs(t).Plots(p), 'YLabel')
                                yLabelText = char(cfg.Flights(fIdx).PlotTabs(t).Plots(p).YLabel);
                            end
                        end
                        if isempty(yLabelText)
                            yLabelText = char(cfg.Flights(fIdx).PlotTabs(t).Plots(p).YColumn);
                        end
                        app.applyPlotYLabelInPlace(fIdx, t, p, yLabelText);
                        try
                            ax = app.UI(fIdx).plotAxes{t}{p};
                            if ~isempty(ax) && isvalid(ax)
                                cfg.Flights(fIdx).PlotTabs(t).Plots(p).XLim = ax.XLim;
                                cfg.Flights(fIdx).PlotTabs(t).Plots(p).XLimMode = char(ax.XLimMode);
                                cfg.Flights(fIdx).PlotTabs(t).Plots(p).YLimMode = char(ax.YLimMode);
                                cfg.Flights(fIdx).PlotTabs(t).Plots(p).YLim = ax.YLim;
                            end
                        catch ME
                            app.logCaught(ME, 'editDialogApplyPlotProps:capture-axis');
                        end
                        cfg.Flights(fIdx).PlotTabs(t).Plots(p).Height = app.EDPlotHeight.Value;
                        cfg.Flights(fIdx).PlotTabs(t).Plots(p).YLabel = yLabelText;
                        cfg.Flights(fIdx).PlotTabs(t).Plots(p).Order = p;
                        app.applyPlotHeightInPlace(fIdx, t, p, app.EDPlotHeight.Value);
                        app.PlotConfigState = cfg;
                        app.refreshBoardOffSummaryPanel(fIdx, true);
                    else
                        return;
                    end
                end
                app.markProjectDirtyAndScheduleRefresh('plot-props');
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'plot-apply');
            end
        end

        function editDialogDuplicatePlot(app)
            % [F-01] Duplicate the selected plot inside the same tab.
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~isfield(nd, 'kind') || ~strcmp(nd.kind, 'plot'), return; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) < nd.tab, return; end
                plots = cfg.Flights(fIdx).PlotTabs(nd.tab).Plots;
                if numel(plots) < nd.plot, return; end
                dup = plots(nd.plot);
                dup.Order = numel(plots) + 1;
                plots(end+1) = dup;
                cfg.Flights(fIdx).PlotTabs(nd.tab).Plots = plots;
                app.PlotConfigState = cfg;
                app.rebuildPlotsFromConfig(fIdx, app.PlotConfigState);
                app.markProjectDirtyAndScheduleRefresh('plot-duplicate');
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'plot-duplicate');
            end
        end

        function editDialogMoveSelectedPlot(app, delta)
            % [F-01] Move the selected plot order within the current tab.
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~isfield(nd, 'kind') || ~strcmp(nd.kind, 'plot'), return; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) < nd.tab, return; end
                plots = cfg.Flights(fIdx).PlotTabs(nd.tab).Plots;
                if numel(plots) < nd.plot, return; end
                dst = nd.plot + delta;
                if dst < 1 || dst > numel(plots), return; end
                tmp = plots(nd.plot);
                plots(nd.plot) = plots(dst);
                plots(dst) = tmp;
                for k = 1:numel(plots)
                    plots(k).Order = k;
                end
                cfg.Flights(fIdx).PlotTabs(nd.tab).Plots = plots;
                app.PlotConfigState = cfg;
                app.rebuildPlotsFromConfig(fIdx, app.PlotConfigState);
                app.markProjectDirtyAndScheduleRefresh('plot-move');
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'plot-move');
            end
        end

        function editDialogDeleteSelectedPlot(app)
            % [F-01] Delete the selected plot inside its tab.
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~isfield(nd, 'kind') || ~strcmp(nd.kind, 'plot'), return; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) < nd.tab, return; end
                plots = cfg.Flights(fIdx).PlotTabs(nd.tab).Plots;
                if numel(plots) < nd.plot, return; end
                plots(nd.plot) = [];
                for k = 1:numel(plots), plots(k).Order = k; end
                cfg.Flights(fIdx).PlotTabs(nd.tab).Plots = plots;
                app.PlotConfigState = cfg;
                app.rebuildPlotsFromConfig(fIdx, app.PlotConfigState);
                app.markProjectDirtyAndScheduleRefresh('plot-delete');
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'plot-delete');
            end
        end

        function editDialogDeleteSelectedTab(app)
            try
                fIdx = 1; if strcmp(app.EDPlotFlightDD.Value, 'Flight 2'), fIdx = 2; end
                sel = app.EDPlotTree.SelectedNodes;
                if isempty(sel), return; end
                nd = sel(1).NodeData;
                if ~strcmp(nd.kind, 'tab'), return; end
                cfg = app.ensurePlotConfigShape(app.PlotConfigState);
                if numel(cfg.Flights(fIdx).PlotTabs) >= nd.tab
                    cfg.Flights(fIdx).PlotTabs(nd.tab) = [];
                    app.PlotConfigState = cfg;
                    try
                        delete(app.UI(fIdx).plotTabs(nd.tab));
                    catch
                    end
                    app.markProjectDirtyAndScheduleRefresh('tab-delete');
                end
                app.refreshEditDialog();
            catch ME
                app.logCaught(ME, 'tab-delete');
            end
        end

        function editDialogPickExportFolder(app)
            p = uigetdir(app.EDExpParentEdit.Value, 'Export parent 폴더');
            if isequal(p, 0), return; end
            app.EDExpParentEdit.Value = p;
        end

        function editDialogExport(app)
            try
                parent = app.EDExpParentEdit.Value;
                opts = struct('verifyHash', logical(app.EDExpHashCB.Value));
                ok = app.exportEverythingToFolder(parent, opts);
                lines = app.EDExpLogArea.Value;
                if ~iscell(lines), lines = {char(lines)}; end
                if ok
                    lines{end+1} = sprintf('[%s] export OK', char(datetime('now', 'Format', 'HH:mm:ss')));
                else
                    lines{end+1} = sprintf('[%s] export FAIL — 자세한 내용은 console/dialog 참고', char(datetime('now', 'Format', 'HH:mm:ss')));
                end
                app.EDExpLogArea.Value = lines;
            catch ME
                app.logCaught(ME, 'export-btn');
            end
        end
    end

    % =========================================================================
    % 데이터 파서 및 시각화 업데이트
    % =========================================================================
    methods (Access = private)
        function parseFlightData(app, fIdx, filepath)
            opts = detectImportOptions(filepath);
            opts.DataLines = [2 Inf];
            opts.VariableNamingRule = 'preserve';

            if ~isempty(opts.VariableNames)
                opts.VariableNames{1} = 'time';
            end

            validTypes = {'double', 'single', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'int64', 'uint64'};
            for k = 1:length(opts.VariableTypes)
                if ismember(opts.VariableTypes{k}, validTypes)
                    opts = setvartype(opts, opts.VariableNames{k}, 'double');
                end
            end

            dataTbl = readtable(filepath, opts);
            % [Phase 2 D4] record source path BEFORE applyOptionFile so resolveOptionFilePath
            % can fall back to model-recorded option path if set later.
            try
                app.Models(fIdx).dataFilePath = app.normalizeAbsPath(filepath);
            catch ME
                app.logCaught(ME, 'loadFlightDataFile:data-file-path');
            end
            app.applyOptionFile(fIdx, dataTbl, false);

            if any(ismissing(app.Models(fIdx).rawData), 'all')
                app.Models(fIdx).rawData = fillmissing(app.Models(fIdx).rawData, 'linear', 'DataVariables', @isnumeric);
                % Keep unscaled mirror in sync when imputation runs.
                try
                    app.Models(fIdx).rawDataUnscaled = fillmissing(app.Models(fIdx).rawDataUnscaled, 'linear', 'DataVariables', @isnumeric);
                catch ME
                    app.logCaught(ME, 'loadFlightDataFile:fillmissing-unscaled');
                end
            end
        end

        function applyOptionFile(app, fIdx, dataTbl, isMock)
            % [Phase 2] Backward-compatible entry point. Stores unscaled source (D4) then
            % delegates to parseOptionFileToDraft + applyOptionDraftToModel so repeated
            % invocations cannot double-scale.
            app.Models(fIdx).rawDataUnscaled = dataTbl;
            optPath = app.resolveOptionFilePath(fIdx);
            csvHeaders = dataTbl.Properties.VariableNames;
            draft = app.parseOptionFileToDraft(optPath, csvHeaders);
            app.applyOptionDraftToModel(fIdx, draft, isMock);
            if isempty(app.Models(fIdx).optionFilePath) && isfile(optPath)
                app.Models(fIdx).optionFilePath = app.normalizeAbsPath(optPath);
            end
        end

        function optPath = resolveOptionFilePath(app, fIdx)
            % Prefer model-recorded path; fall back to conventional optionN.dat next to pwd.
            optPath = '';
            try
                optPath = char(app.Models(fIdx).optionFilePath);
            catch
            end
            if isempty(optPath) || ~isfile(optPath)
                optPath = sprintf('option%d.dat', fIdx);
            end
        end

        function draft = parseOptionFileToDraft(app, optPath, csvHeaders)
            % Pure parser. Returns {sourcePath, mappedCols, displayMeta(struct array)}.
            reqKeys = app.REQ_KEYS;
            mappedCols = struct();
            for i = 1:length(reqKeys)
                mappedCols.(reqKeys{i}) = '';
            end
            displayMeta = struct('header', {}, 'unit', {}, 'format', {}, 'scale', {}, 'order', {});
            if ~isempty(optPath) && isfile(optPath)
                try
                    lines = readlines(optPath, 'EmptyLineRule', 'skip');
                    section = 0;
                    for i = 1:length(lines)
                        lineStr = strtrim(lines(i));
                        if startsWith(lineStr, '#'), section = section + 1; continue; end
                        if section == 1
                            parts = split(lineStr, ':');
                            if length(parts) >= 2
                                k = char(strtrim(parts(1)));
                                v = char(strtrim(parts(2)));
                                if isfield(mappedCols, k) && ismember(v, csvHeaders)
                                    mappedCols.(k) = v;
                                end
                            end
                        elseif section == 2
                            parts = split(lineStr, ',');
                            if length(parts) >= 4
                                hdr   = char(strtrim(parts(1)));
                                unit  = char(strtrim(parts(2)));
                                fmt   = char(strtrim(parts(3)));
                                order = str2double(strtrim(parts(4)));
                                if length(parts) >= 5
                                    scale = str2double(strtrim(parts(5)));
                                else
                                    scale = 1.0;
                                end
                                % D5: scale=0 guard (avoid silent zeroing of columns)
                                if isnan(scale) || scale == 0, scale = 1.0; end
                                if ~isnan(order) && ismember(hdr, csvHeaders)
                                    displayMeta(end+1) = struct('header', hdr, 'unit', unit, ...
                                        'format', fmt, 'scale', scale, 'order', order); %#ok<AGROW>
                                end
                            end
                        end
                    end
                catch ME
                    app.logCaught(ME, 'option-parse');
                end
            end
            draft = struct('sourcePath', char(optPath), ...
                           'mappedCols', mappedCols, ...
                           'displayMeta', displayMeta);
        end

        function [ok, info] = validateOptionDraft(app, draft, csvHeaders)
            % [D5] basic validation; Phase 5 extends with brokenPlots etc.
            info = struct('brokenMappings', {{}}, 'brokenColumns', {{}}, 'reasons', {{}});
            if isempty(draft) || ~isstruct(draft)
                ok = false; info.reasons{end+1} = 'empty draft'; return;
            end
            try
                reqKeys = fieldnames(draft.mappedCols);
                for i = 1:numel(reqKeys)
                    v = draft.mappedCols.(reqKeys{i});
                    if ~isempty(v) && ~ismember(v, csvHeaders)
                        info.brokenMappings{end+1} = sprintf('%s -> %s', reqKeys{i}, v);
                    end
                end
                for i = 1:numel(draft.displayMeta)
                    if ~ismember(draft.displayMeta(i).header, csvHeaders)
                        info.brokenColumns{end+1} = draft.displayMeta(i).header;
                    end
                    if isnan(draft.displayMeta(i).scale) || draft.displayMeta(i).scale == 0
                        info.reasons{end+1} = sprintf('scale 비정상: %s', draft.displayMeta(i).header);
                    end
                end
            catch ME
                app.logCaught(ME, 'option-validate');
            end
            ok = isempty(info.brokenMappings) && isempty(info.brokenColumns) && isempty(info.reasons);
        end

        function displayMeta = buildDisplayMetaFromDraft(~, displayMeta, csvHeaders, isMock)
            % Normalize order + auto-fill missing columns (used by applyOptionDraftToModel).
            numHeaders = numel(csvHeaders);
            if isempty(displayMeta)
                for i = 1:numHeaders
                    displayMeta(end+1) = struct('header', csvHeaders{i}, 'unit', '-', ...
                        'format', '%.6f', 'scale', 1.0, 'order', i); %#ok<AGROW>
                end
            else
                orders = [displayMeta.order];
                if (length(unique(orders)) == length(orders)) && (min(orders) == 1) && (max(orders) == length(orders))
                    [~, sortIdx] = sort([displayMeta.order]);
                    displayMeta = displayMeta(sortIdx);
                else
                    for i = 1:length(displayMeta), displayMeta(i).order = i; end
                end
                existingHeaders = {displayMeta.header};
                missingHeaders  = setdiff(csvHeaders, existingHeaders, 'stable');
                for i = 1:length(missingHeaders)
                    displayMeta(end+1) = struct('header', missingHeaders{i}, 'unit', '-', ...
                        'format', '%.6f', 'scale', 1.0, ...
                        'order', length(displayMeta) + i); %#ok<AGROW>
                end
            end
            if isMock
                for i = 1:length(displayMeta), displayMeta(i).scale = 1.0; end
            end
        end

        function applyOptionDraftToModel(app, fIdx, draft, isMock)
            % [Phase 2/D4 hybrid] always rebuilds rawData from rawDataUnscaled. No accumulation.
            if nargin < 4, isMock = false; end
            src = app.Models(fIdx).rawDataUnscaled;
            if isempty(src) || height(src) == 0
                return;
            end
            csvHeaders = src.Properties.VariableNames;

            % Auto-fill mappedCols defaults (first N CSV columns) if unset.
            mappedCols = draft.mappedCols;
            reqKeys    = app.REQ_KEYS;
            for i = 1:length(reqKeys)
                if (~isfield(mappedCols, reqKeys{i}) || isempty(mappedCols.(reqKeys{i}))) ...
                        && (i <= numel(csvHeaders))
                    mappedCols.(reqKeys{i}) = csvHeaders{i};
                end
            end

            displayMeta = app.buildDisplayMetaFromDraft(draft.displayMeta, csvHeaders, isMock);

            % Re-derive scaled rawData from unscaled source (D4 invariant: no double-scale).
            scaled = src;
            for i = 1:length(displayMeta)
                col = displayMeta(i).header;
                s   = displayMeta(i).scale;
                if isnumeric(s) && ~isnan(s) && s ~= 1.0 && ismember(col, scaled.Properties.VariableNames)
                    try
                        scaled.(col) = scaled.(col) * s;
                    catch ME
                        app.logCaught(ME, 'option-scale');
                    end
                end
            end

            app.Models(fIdx).rawData     = scaled;
            app.Models(fIdx).mappedCols  = mappedCols;
            app.Models(fIdx).displayMeta = displayMeta;
            app.Models(fIdx).selectedRow = 1;
            app.Models(fIdx).isMockData  = isMock;
            % Stash the resolved draft as the editor baseline.
            app.OptionDrafts{fIdx} = struct('sourcePath', char(draft.sourcePath), ...
                                            'mappedCols', mappedCols, 'displayMeta', displayMeta);
        end

        function ok = writeOptionFileAtomic(app, optPath, draft)
            % Atomic write of option file: temp -> .bak of old -> movefile.
            ok = false;
            if nargin < 3 || isempty(optPath) || isempty(draft), return; end
            try
                lines = {};
                lines{end+1} = '# RequiredColumns';
                reqKeys = app.REQ_KEYS;
                for i = 1:length(reqKeys)
                    v = '';
                    if isfield(draft.mappedCols, reqKeys{i}), v = char(draft.mappedCols.(reqKeys{i})); end
                    lines{end+1} = sprintf('%s: %s', reqKeys{i}, v); %#ok<AGROW>
                end
                lines{end+1} = '';
                lines{end+1} = '# DisplayColumns';
                for i = 1:numel(draft.displayMeta)
                    dm = draft.displayMeta(i);
                    lines{end+1} = sprintf('%s, %s, %s, %d, %g', ...
                        dm.header, dm.unit, dm.format, dm.order, dm.scale); %#ok<AGROW>
                end
                txt = sprintf('%s\n', lines{:});
                ok = app.writeTextFileAtomic(optPath, txt, 'option-write');
            catch ME
                app.logCaught(ME, 'option-write');
                try
                    uialert(app.UIFigure, sprintf('option 파일 저장 실패:\n%s', ME.message), 'Options');
                catch
                end
            end
        end

        function generateMockFlightData(app, fIdx)
            latRange = app.Models(fIdx).bounds.maxLat - app.Models(fIdx).bounds.minLat;
            lonRange = app.Models(fIdx).bounds.maxLon - app.Models(fIdx).bounds.minLon;
            if latRange <= 0, latRange = 0.1; end
            if lonRange <= 0, lonRange = 0.1; end

            minLat = app.Models(fIdx).bounds.minLat;
            maxLat = app.Models(fIdx).bounds.maxLat;
            minLon = app.Models(fIdx).bounds.minLon;
            maxLon = app.Models(fIdx).bounds.maxLon;

            currLat = minLat + latRange / 2 + (fIdx * 0.02);
            currLon = minLon + lonRange / 2 - (fIdx * 0.02);
            currAlt = 5000 + (fIdx * 500);
            currHdg = (rand() * 360) - 180;
            currRoll = 0;
            currPitch = 5;
            speed = min(latRange, lonRange) * 0.005;

            N = app.MOCK_STEP_COUNT;
            time_s   = zeros(N, 1); lat_deg = zeros(N, 1); lon_deg = zeros(N, 1);
            alt_ft   = zeros(N, 1); hdg_deg = zeros(N, 1); roll_deg = zeros(N, 1);
            pitch_deg = zeros(N, 1);

            for i = 1:N
                time_s(i) = i-1; lat_deg(i) = currLat; lon_deg(i) = currLon;
                alt_ft(i) = currAlt; hdg_deg(i) = currHdg; roll_deg(i) = currRoll; pitch_deg(i) = currPitch;

                if i > 50 && i < 100
                    currRoll = min(currRoll + 2, 45); currHdg = currHdg + currRoll * 0.1;
                elseif i >= 100 && i < 130
                    currRoll = currRoll * 0.9;
                elseif i > 150
                    currRoll = max(currRoll - 2, -45); currHdg = currHdg + currRoll * 0.1;
                else
                    currRoll = currRoll * 0.9;
                end

                if currHdg > 180, currHdg = currHdg - 360; end
                if currHdg <= -180, currHdg = currHdg + 360; end

                if i < 80
                    currPitch = 5; currAlt = currAlt + 20;
                elseif i > 120
                    currPitch = -3; currAlt = currAlt - 15;
                else
                    currPitch = 0;
                end

                currPitch = currPitch + (rand() - 0.5) * 1;
                currRoll = currRoll + (rand() - 0.5) * 2;

                if currPitch > 180, currPitch = currPitch - 360; end
                if currPitch <= -180, currPitch = currPitch + 360; end
                if currRoll > 180, currRoll = currRoll - 360; end
                if currRoll <= -180, currRoll = currRoll + 360; end

                mathAngle = (90 - currHdg) * pi / 180;
                currLon = currLon + cos(mathAngle) * speed;
                currLat = currLat + sin(mathAngle) * speed;

                if currLat > maxLat
                    currLat = maxLat - (currLat - maxLat);
                    currHdg = -currHdg;
                elseif currLat < minLat
                    currLat = minLat + (minLat - currLat);
                    currHdg = -currHdg;
                end
                if currLon > maxLon
                    currLon = maxLon - (currLon - maxLon);
                    currHdg = 180 - currHdg;
                elseif currLon < minLon
                    currLon = minLon + (minLon - currLon);
                    currHdg = 180 - currHdg;
                end

                if currHdg > 180, currHdg = currHdg - 360; end
                if currHdg <= -180, currHdg = currHdg + 360; end
            end

            optFileName = sprintf('option%d.dat', fIdx);
            baseKeys = app.REQ_KEYS;
            varNames = baseKeys;

            if isfile(optFileName)
                lines = readlines(optFileName, 'EmptyLineRule', 'skip');
                section = 0;
                for idxLine = 1:length(lines)
                    lineStr = strtrim(lines(idxLine));
                    if startsWith(lineStr, '#'), section = section + 1; continue; end
                    if section == 1
                        parts = split(lineStr, ':');
                        if length(parts) >= 2
                            k = char(strtrim(parts(1))); v = char(strtrim(parts(2)));
                            matchIdx = find(strcmp(baseKeys, k));
                            if ~isempty(matchIdx), varNames{matchIdx} = v; end
                        end
                    end
                end
            end

            mockTbl = table(time_s, roll_deg, pitch_deg, hdg_deg, alt_ft, lat_deg, lon_deg, 'VariableNames', varNames);
            app.applyOptionFile(fIdx, mockTbl, true);

            app.setupDataUI(fIdx);
            app.UI(fIdx).fileNameLabel.Text = '모의 데이터 (Auto)';
        end

        function calculateBounds(app, fIdx)
            minLat = 90; maxLat = -90; minLon = 180; maxLon = -180;
            minAlt = 99999; maxAlt = -99999; hasData = false;

            if ~isempty(app.CoastlineData)
                minLat = min(minLat, min(app.CoastlineData(:,1))); maxLat = max(maxLat, max(app.CoastlineData(:,1)));
                minLon = min(minLon, min(app.CoastlineData(:,2))); maxLon = max(maxLon, max(app.CoastlineData(:,2)));
                hasData = true;
            end

            if ~isempty(app.Models(fIdx).rawData)
                lats = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lat);
                lons = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lon);
                alts = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Alt);

                validIdx = (lats ~= 0) | (lons ~= 0);
                if any(validIdx)
                    minLat = min(minLat, min(lats(validIdx))); maxLat = max(maxLat, max(lats(validIdx)));
                    minLon = min(minLon, min(lons(validIdx))); maxLon = max(maxLon, max(lons(validIdx)));
                end
                minAlt = min(minAlt, min(alts)); maxAlt = max(maxAlt, max(alts));
                hasData = true;
            end

            if ~isempty(app.FixedAreaBounds)
                app.Models(fIdx).bounds.minLat = app.FixedAreaBounds.minLat;
                app.Models(fIdx).bounds.maxLat = app.FixedAreaBounds.maxLat;
                app.Models(fIdx).bounds.minLon = app.FixedAreaBounds.minLon;
                app.Models(fIdx).bounds.maxLon = app.FixedAreaBounds.maxLon;
                app.Models(fIdx).bounds.isValid = true;
            elseif hasData
                latPad = max((maxLat - minLat) * 0.05, 0.01); lonPad = max((maxLon - minLon) * 0.05, 0.01);
                app.Models(fIdx).bounds.minLat = minLat - latPad; app.Models(fIdx).bounds.maxLat = maxLat + latPad;
                app.Models(fIdx).bounds.minLon = minLon - lonPad; app.Models(fIdx).bounds.maxLon = maxLon + lonPad;
                app.Models(fIdx).bounds.isValid = true;
            end

            if hasData
                altPad = max((maxAlt - minAlt) * 0.1, 100);
                app.Models(fIdx).altBounds.minAlt = minAlt - altPad; app.Models(fIdx).altBounds.maxAlt = maxAlt + altPad;
            end
        end

        function setupDataUI(app, fIdx)
            if height(app.Models(fIdx).rawData) > 0
                timeCol = app.Models(fIdx).mappedCols.Time;
                times = app.Models(fIdx).rawData.(timeCol);
                dt = mean(diff(times(1:min(100, end))));
                if dt <= 0, dt = 1; end

                app.UI(fIdx).spinner.Limits = [times(1), times(end)];
                app.UI(fIdx).spinner.Step = dt;
                app.UI(fIdx).spinner.Value = times(1);

                if ~(app.SyncState.IsSynced && fIdx == 2)
                    app.UI(fIdx).spinner.Enable = 'on';
                end

                app.Models(fIdx).currentIndex = 1;
                app.calculateBounds(fIdx);

                app.initPlots(fIdx);
                app.updateDashboard(fIdx, 1);
                app.refreshBoardOffSummaryPanel(fIdx, true);
            end
        end

        function initPlots(app, fIdx)
            if isempty(app.Models(fIdx).rawData), return; end
            bnds = app.Models(fIdx).bounds;

            % --- Map 설정 ---
            axMap = app.UI(fIdx).mapAxes; cla(axMap);
            if bnds.isValid
                axis(axMap, [bnds.minLon, bnds.maxLon, bnds.minLat, bnds.maxLat]);
                daspect(axMap, [1 1 1]);
            end

            if ~isempty(app.CoastlineData)
                plot(axMap, app.CoastlineData(:,2), app.CoastlineData(:,1), 'LineStyle', 'none', ...
                     'Marker', '.', 'MarkerSize', 0.5, 'Color', [0.6 0.6 0.6]);
            end

            pathLon = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lon);
            pathLat = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lat);
            validIdx = (pathLon ~= 0) | (pathLat ~= 0);

            plot(axMap, pathLon(validIdx), pathLat(validIdx), 'Color', [0.8 0.8 0.8], 'LineWidth', 1);

            lineColor = [0.23 0.51 0.96];
            if fIdx == 2, lineColor = [0.31 0.27 0.90]; end

            firstValid = find(validIdx, 1);
            if isempty(firstValid), firstValid = 1; end

            app.UI(fIdx).hMapPath = plot(axMap, pathLon(firstValid), pathLat(firstValid), 'Color', lineColor, 'LineWidth', 2);
            app.UI(fIdx).hgMapPlane = hgtransform('Parent', axMap);
            scale = (bnds.maxLon - bnds.minLon) * 0.03;
            if scale <= 0, scale = 0.01; end
            x_base = [0, -0.5, 0.5, 0] * scale; y_base = [1, -1, -1, 1] * scale;
            patch('Parent', app.UI(fIdx).hgMapPlane, 'XData', x_base, 'YData', y_base, 'FaceColor', 'r', 'EdgeColor', [0.5 0 0], 'LineWidth', 1);

            % --- Altitude 설정 및 Y축 동적 스케일링 활성화 ---
            axAlt = app.UI(fIdx).altAxes; cla(axAlt);
            times = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Time);
            alts = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Alt);

            % 에러 방어: altXLimListener가 유효한지 체크
            if isfield(app.UI(fIdx), 'altXLimListener')
                try
                    if ~isempty(app.UI(fIdx).altXLimListener) && isvalid(app.UI(fIdx).altXLimListener)
                        delete(app.UI(fIdx).altXLimListener);
                    end
                catch ME
                    app.logCaught(ME, 'createAltitudePlot:delete-xlim-listener');
                end
            end

            % X축을 데이터 전체로 잡고, Y축은 auto 모드로 설정하여 GUI 리사이즈 시 동적으로 적응하도록 보장
            axAlt.XLim = [min(times) max(times)];
            axAlt.YLimMode = 'auto';
            plot(axAlt, times, alts, 'Color', [0.8 0.8 0.8], 'LineWidth', 1, 'HitTest', 'off');

            % [V3.10] Altitude axes는 툴바 숨김 (휠 줌/드래그 팬만 사용)
            app.UI(fIdx).altAxes.Toolbar.Visible = 'off';
            app.UI(fIdx).altAxes.Interactions = [panInteraction, zoomInteraction];

            % [개선안 3] 타임라인 두께 증가 및 투명도 반영, 마커 크기 14로 고정
            app.UI(fIdx).hAltPath = plot(axAlt, times(1), alts(1), 'Color', [0.06 0.72 0.51], 'LineWidth', 2, 'HitTest', 'off');
            app.UI(fIdx).hAltMarker = plot(axAlt, times(1), alts(1), 'p', 'MarkerFaceColor', [0.98 0.75 0.14], 'MarkerEdgeColor', [0.71 0.33 0.04], 'MarkerSize', 14, 'HitTest', 'on');
            app.UI(fIdx).timeLine = xline(axAlt, times(1), 'r', 'LineWidth', 3.0, 'Alpha', 0.5, 'HitTest', 'on');

            app.UI(fIdx).hAltMarker.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, 0, src, event);
            app.UI(fIdx).timeLine.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, 0, src, event);

            % Altitude 패널의 Zoom/Pan 시 동기화 리스너 추가
            app.UI(fIdx).altXLimListener = addlistener(axAlt, 'XLim', 'PostSet', @(~,~) app.handlePlotXLimChange(fIdx, axAlt));

            % --- 비행자세 게이지 설정 ---
            theta = linspace(0, 2*pi, 100);
            angles = 0:30:330;
            for gaugeType = 1:3
                if gaugeType == 1
                    ax = app.UI(fIdx).pitchAxes; cla(ax); app.UI(fIdx).hgPitch = hgtransform('Parent', ax); hg = app.UI(fIdx).hgPitch; offsetDeg = 180; bgColor = [0.15 0.25 0.35];
                elseif gaugeType == 2
                    ax = app.UI(fIdx).rollAxes; cla(ax); app.UI(fIdx).hgRoll = hgtransform('Parent', ax); hg = app.UI(fIdx).hgRoll; offsetDeg = 90; bgColor = [0.35 0.20 0.20];
                else
                    ax = app.UI(fIdx).hdgAxes; cla(ax); app.UI(fIdx).hgHdg = hgtransform('Parent', ax); hg = app.UI(fIdx).hgHdg; offsetDeg = 90; bgColor = [0.20 0.35 0.20];
                end

                patch(ax, cos(theta), sin(theta), bgColor, 'EdgeColor', 'k', 'LineWidth', 2);
                for i = 1:length(angles)
                    val = angles(i); if val > 180, val = val - 360; end
                    angRad = (offsetDeg - angles(i)) * pi / 180;
                    plot(ax, [0.85*cos(angRad) 1.0*cos(angRad)], [0.85*sin(angRad) 1.0*sin(angRad)], 'w', 'LineWidth', 1.5);
                    if gaugeType == 3
                        if val == 0, str = 'N'; elseif val == 90, str = 'E'; elseif val == 180 || val == -180, str = 'S'; elseif val == -90, str = 'W'; else, str = num2str(val); end
                    else
                        str = num2str(val);
                    end
                    % FontSize를 0.06으로 유지하여 원안의 숫자 크기를 적절하게 설정
                    text(ax, 0.65*cos(angRad), 0.65*sin(angRad), str, 'Color', 'w', ...
                         'HorizontalAlignment', 'center', 'FontWeight', 'bold', ...
                         'FontUnits', 'normalized', 'FontSize', 0.06);
                end

                if gaugeType == 1
                    patch(hg, [-1.15 -1.15 -1.0], [-0.08 0.08 0], bgColor, 'EdgeColor', 'k', 'LineWidth', 1);
                    plot(hg, [-0.4 0.4], [0 0], 'y', 'LineWidth', 4);
                    plot(hg, [0.2 0.3], [0 0.2], 'y', 'LineWidth', 3);
                elseif gaugeType == 2
                    patch(hg, [-0.08 0.08 0], [1.15 1.15 1.0], bgColor, 'EdgeColor', 'k', 'LineWidth', 1);
                    plot(hg, [-0.4 0.4], [0 0], 'y', 'LineWidth', 3);
                    plot(hg, [0 0], [0 0.3], 'y', 'LineWidth', 3);
                else
                    patch(hg, [-0.08 0.08 0], [1.15 1.15 1.0], bgColor, 'EdgeColor', 'k', 'LineWidth', 1);
                    plot(hg, [0 0], [-0.4 0.4], 'y', 'LineWidth', 3);
                    plot(hg, [-0.3 0.3], [0.1 0.1], 'y', 'LineWidth', 3);
                    plot(hg, [-0.15 0.15], [-0.3 -0.3], 'y', 'LineWidth', 2);
                end
                axis(ax, 'equal'); axis(ax, [-1.35 1.35 -1.35 1.35]); axis(ax, 'off');
            end
        end

        function updateDashboard(app, fIdx, index)
            if isempty(app.Models(fIdx).rawData), return; end

            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(index);
            app.UI(fIdx).currentTimeLabel.Text = sprintf('%.3f s', currTime);

            % Table
            metaList = app.Models(fIdx).displayMeta;
            dataCell = cell(length(metaList), 2);
            for i = 1:length(metaList)
                m = metaList(i);
                val = app.Models(fIdx).rawData.(m.header)(index);
                dataCell{i, 1} = sprintf('%s (%s)', m.header, m.unit);
                dataCell{i, 2} = sprintf(m.format, val);
            end
            app.UI(fIdx).dataTable.Data = dataCell;

            % Spatial
            pathLon = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lon);
            pathLat = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lat);
            currLon = pathLon(1:index);
            currLat = pathLat(1:index);

            validIdx = (currLon ~= 0) | (currLat ~= 0);
            set(app.UI(fIdx).hMapPath, 'XData', currLon(validIdx), 'YData', currLat(validIdx));

            hdg = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Heading)(index);
            roll = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Roll)(index);
            pitch = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Pitch)(index);

            lastValid = find(validIdx, 1, 'last');
            if ~isempty(lastValid)
                T_map = makehgtform('translate', [currLon(lastValid), currLat(lastValid), 0]) * makehgtform('zrotate', -hdg * pi / 180);
                set(app.UI(fIdx).hgMapPlane, 'Matrix', T_map);
            end

            times = app.Models(fIdx).rawData.(timeCol);
            alts = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Alt);

            set(app.UI(fIdx).hAltPath, 'XData', times(1:index), 'YData', alts(1:index));
            set(app.UI(fIdx).hAltMarker, 'XData', times(index), 'YData', alts(index));
            app.UI(fIdx).timeLine.Value = times(index);

            % Gauges
            app.UI(fIdx).pitchLabel.Text = sprintf('Pitch %+.3f°', pitch);
            app.UI(fIdx).rollLabel.Text  = sprintf('Roll %+.3f°', roll);
            app.UI(fIdx).hdgLabel.Text   = sprintf('Heading %+.3f°', hdg);

            set(app.UI(fIdx).hgPitch, 'Matrix', makehgtform('zrotate', -pitch * pi / 180));
            set(app.UI(fIdx).hgRoll,  'Matrix', makehgtform('zrotate', -roll * pi / 180));
            set(app.UI(fIdx).hgHdg,   'Matrix', makehgtform('zrotate', -hdg * pi / 180));

            % 비디오 및 H 영역 갱신
            % [V3.12 2.2.3] 비디오 동기 설정 시 Frame No 기반 갱신 (정확한 매핑)
            if app.VideoSyncState(fIdx).IsSynced
                try
                    targetFrame = app.timeToFrame(fIdx, currTime);
                    app.VideoSyncState(fIdx).CurrentFrame = targetFrame;
                    % [V3.14] Frame 마커 + xline + 슬라이더 + 라벨 일괄 동기화
                    app.syncFrameMarkersAndLabel(fIdx, targetFrame);
                    app.updateVideoFrameByFrameNo(fIdx, targetFrame, 'sync');  % 정확한 동기화
                catch ME
                    app.logCaught(ME, 'video-sync-dashboard');
                    try
                        app.updateVideoFrame(fIdx, currTime);  % 폴백
                    catch ME_fallback
                        app.logCaught(ME_fallback, 'video-sync-dashboard-fallback');
                    end
                end
            else
                % 동기 미설정: 기존 방식대로 시간 기반 갱신
                % app.updateVideoFrame(fIdx, currTime);  % <--- 이 줄을 주석 처리하여 완전 분리
            end
            try
                app.updatePlotTimeLines(fIdx, index, currTime);
            catch ME
                app.logCaught(ME, 'hpanel-dashboard');
            end
            app.refreshBoardOffSummaryPanel(fIdx);

            drawnow limitrate;
        end
    end

    % =========================================================================
    % UI 레이아웃 생성 팩토리 (Create Layout)
    % =========================================================================
    methods (Access = public)
        function pos = getInitialWindowPosition(app)
            screen = app.getActiveScreenArea();
            screenW = max(640, screen(3));
            screenH = max(480, screen(4));

            marginX = 24;
            marginY = 56;
            maxW = max(640, screenW - 2 * marginX);
            maxH = max(480, screenH - 2 * marginY);
            desiredW = 1420;
            desiredH = 820;

            w = min(desiredW, maxW);
            h = min(desiredH, maxH);
            x = screen(1) + round((screenW - w) / 2);
            y = screen(2) + round((screenH - h) / 2);

            pos = [x, y, w, h];
        end

        function screen = getActiveScreenArea(~)
            screen = [1 1 1440 900];
            try
                screen = get(groot, 'ScreenSize');
                monitors = get(groot, 'MonitorPositions');
                if ~isempty(monitors)
                    pointer = get(groot, 'PointerLocation');
                    idx = find(pointer(1) >= monitors(:,1) & ...
                               pointer(1) <= monitors(:,1) + monitors(:,3) & ...
                               pointer(2) >= monitors(:,2) & ...
                               pointer(2) <= monitors(:,2) + monitors(:,4), 1, 'first');
                    if isempty(idx)
                        [~, idx] = max(monitors(:,3) .* monitors(:,4));
                    end
                    screen = monitors(idx, :);
                end
            catch
            end

            if numel(screen) < 4 || screen(3) <= 0 || screen(4) <= 0
                screen = [1 1 1440 900];
            end
        end

        function figW = getFigurePixelWidth(app)
            figW = 1420;
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    oldUnits = app.UIFigure.Units;
                    app.UIFigure.Units = 'pixels';
                    figPos = app.UIFigure.Position;
                    app.UIFigure.Units = oldUnits;
                    figW = figPos(3);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'getFigureContentWidth');
            end
        end

        function widths = getResponsivePanelWidths(app)
            figW = app.getFigurePixelWidth();
            if figW < 1250
                widths = [135, 280, 170, 430];
            elseif figW < 1550
                widths = [160, 360, 210, 460];
            else
                widths = [200, 500, 250, 500];
            end
        end

        function minW = getMinVideoPanelWidth(app)
            figW = app.getFigurePixelWidth();
            if figW < 1250
                minW = 380;
            elseif figW < 1550
                minW = 420;
            else
                minW = 450;
            end
        end

        function minW = getMinPlotPanelWidth(app)
            figW = app.getFigurePixelWidth();
            if figW < 1250
                minW = 180;
            elseif figW < 1550
                minW = 220;
            else
                minW = 320;
            end
        end

        function targetWidth = clampVideoPanelWidth(app, targetWidth)
            figW = app.getFigurePixelWidth();
            minW = app.getMinVideoPanelWidth();
            if figW < 1250
                maxW = 520;
            elseif figW < 1550
                maxW = 700;
            else
                maxW = 900;
            end
            targetWidth = round(max(minW, min(targetWidth, maxW)));
        end

        function targetWidth = getVideoPanelTargetWidth(app)
            panelWidths = app.getResponsivePanelWidths();
            targetWidth = panelWidths(4);
            targetWidth = round(max(app.getMinVideoPanelWidth(), min(targetWidth, 900)));
        end

        function applyResponsiveLayout(app)
            try
                if isempty(app.UI), return; end
                anyBoardOff = ~isempty(find(app.BoardOffState, 1));
                for fIdx = 1:min(2, numel(app.UI))
                    if ~isfield(app.UI(fIdx), 'dataGrid') || ...
                       isempty(app.UI(fIdx).dataGrid) || ~isvalid(app.UI(fIdx).dataGrid)
                        continue;
                    end

                    app.reflowBoardColumns(fIdx);
                    % [High #3] Off-mode summary plots inherit width from source axes.
                    % When the window resizes, force rebuild so off-summary 1x columns
                    % re-collapse against the new container width instead of leaving blanks.
                    if anyBoardOff
                        app.refreshBoardOffSummaryPanel(fIdx, true);
                    else
                        app.refreshBoardOffSummaryPanel(fIdx);
                    end
                end
                app.updateWindowControlLabels();
                % [High #3] When any board is off, commit the layout pass eagerly so the
                % source widths re-settle before next user interaction (avoid blank gaps).
                if anyBoardOff
                    drawnow;
                else
                    drawnow limitrate;
                end
            catch ME_silent
                app.logCaught(ME_silent, 'responsiveLayout');
            end
        end

        function onFigureSizeChanged(app)
            try
                if isempty(app.UIFigure) || ~isvalid(app.UIFigure), return; end
                if isprop(app.UIFigure, 'WindowState')
                    windowState = char(app.UIFigure.WindowState);
                else
                    windowState = 'normal';
                end
                if strcmpi(windowState, 'normal') && ~app.IsRestoringWindow && ~app.IsWindowManuallyMaximized
                    app.NormalWindowPosition = app.UIFigure.Position;
                end
                app.applyResponsiveLayout();
            catch ME_silent
                app.logCaught(ME_silent, 'windowSizeChanged');
            end
        end

        function minimizeWindow(app)
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure) && isprop(app.UIFigure, 'WindowState')
                    app.UIFigure.WindowState = 'minimized';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'windowMinimize');
            end
        end

        function toggleMaximizeWindow(app)
            try
                if isempty(app.UIFigure) || ~isvalid(app.UIFigure), return; end
                if isprop(app.UIFigure, 'WindowState')
                    windowState = char(app.UIFigure.WindowState);
                    if strcmpi(windowState, 'maximized') || strcmpi(windowState, 'fullscreen')
                        restorePos = app.NormalWindowPosition;
                        app.IsRestoringWindow = true;
                        app.UIFigure.WindowState = 'normal';
                        drawnow limitrate;
                        if ~isempty(restorePos) && numel(restorePos) == 4
                            app.UIFigure.Position = restorePos;
                        end
                        app.IsRestoringWindow = false;
                        app.IsWindowManuallyMaximized = false;
                    else
                        app.NormalWindowPosition = app.UIFigure.Position;
                        app.UIFigure.WindowState = 'maximized';
                        app.IsWindowManuallyMaximized = false;
                    end
                else
                    if app.IsWindowManuallyMaximized
                        if ~isempty(app.NormalWindowPosition) && numel(app.NormalWindowPosition) == 4
                            app.UIFigure.Position = app.NormalWindowPosition;
                        end
                        app.IsWindowManuallyMaximized = false;
                    else
                        screen = app.getActiveScreenArea();
                        app.NormalWindowPosition = app.UIFigure.Position;
                        app.UIFigure.Position = screen;
                        app.IsWindowManuallyMaximized = true;
                    end
                end
                app.updateWindowControlLabels();
                app.applyResponsiveLayout();
            catch ME_silent
                app.IsRestoringWindow = false;
                app.logCaught(ME_silent, 'windowMaximize');
            end
        end

        function updateWindowControlLabels(app)
            try
                if isempty(app.WindowMaxBtn) || ~isvalid(app.WindowMaxBtn), return; end
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure) && isprop(app.UIFigure, 'WindowState')
                    windowState = char(app.UIFigure.WindowState);
                    if strcmpi(windowState, 'maximized') || strcmpi(windowState, 'fullscreen')
                        app.WindowMaxBtn.Text = '복원';
                    else
                        app.WindowMaxBtn.Text = '최대화';
                    end
                elseif app.IsWindowManuallyMaximized
                    app.WindowMaxBtn.Text = '복원';
                else
                    app.WindowMaxBtn.Text = '최대화';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'windowLabel');
            end
        end

        function sizePx = getSelectedVideoDisplaySize(app, fIdx)
            sizePx = [320, 240];
            try
                if ~isempty(app.UI) && fIdx <= numel(app.UI) && ...
                   isfield(app.UI(fIdx), 'vidResolutionDropdown') && ...
                   ~isempty(app.UI(fIdx).vidResolutionDropdown) && ...
                   isvalid(app.UI(fIdx).vidResolutionDropdown)
                    tokens = sscanf(app.UI(fIdx).vidResolutionDropdown.Value, '%dx%d');
                    if numel(tokens) == 2
                        sizePx = double(tokens(:))';
                    end
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoSize');
            end
        end

        function onVideoResolutionChanged(app, fIdx)
            try
                app.setVideoImageFrame(fIdx, app.CurrentVideoFrame{fIdx});
                app.setVideoDisplaySize(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'videoResolution');
            end
        end

        function setVideoDisplaySize(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'vidAxes') || isempty(app.UI(fIdx).vidAxes) || ...
                   ~isvalid(app.UI(fIdx).vidAxes)
                    return;
                end
                sizePx = app.getSelectedVideoDisplaySize(fIdx);
                pad = 8;
                app.UI(fIdx).vidAxes.Units = 'pixels';
                app.UI(fIdx).vidAxes.Position = [pad, pad, sizePx(1), sizePx(2)];
            catch ME_silent
                app.logCaught(ME_silent, 'videoDisplaySize');
            end
        end

        function out = resizeFrameForDisplay(app, img, sizePx)
            out = img;
            try
                if isempty(img) || numel(sizePx) ~= 2, return; end
                targetW = max(1, round(sizePx(1)));
                targetH = max(1, round(sizePx(2)));
                if size(img, 2) == targetW && size(img, 1) == targetH
                    return;
                end
                try
                    out = imresize(img, [targetH, targetW]);
                catch ME_resize
                    app.logCaught(ME_resize, 'resizeVideoFrame:imresize');
                    rowIdx = round(linspace(1, size(img, 1), targetH));
                    colIdx = round(linspace(1, size(img, 2), targetW));
                    rowIdx = max(1, min(size(img, 1), rowIdx));
                    colIdx = max(1, min(size(img, 2), colIdx));
                    out = img(rowIdx, colIdx, :);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoResize');
                out = img;
            end
        end

        function setVideoImageFrame(app, fIdx, img)
            try
                if isempty(img), return; end
                app.CurrentVideoFrame{fIdx} = img;
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'vidImageHandle') || ...
                   isempty(app.UI(fIdx).vidImageHandle) || ~isvalid(app.UI(fIdx).vidImageHandle)
                    return;
                end
                sizePx = app.getSelectedVideoDisplaySize(fIdx);
                dispFrame = app.resizeFrameForDisplay(img, sizePx);
                hImg = app.UI(fIdx).vidImageHandle;
                set(hImg, 'CData', dispFrame, 'XData', [1 sizePx(1)], 'YData', [1 sizePx(2)]);
                if isfield(app.UI(fIdx), 'vidAxes') && ~isempty(app.UI(fIdx).vidAxes) && ...
                   isvalid(app.UI(fIdx).vidAxes)
                    ax = app.UI(fIdx).vidAxes;
                    ax.XLim = [0.5, sizePx(1) + 0.5];
                    ax.YLim = [0.5, sizePx(2) + 0.5];
                    ax.DataAspectRatio = [1 1 1];
                    ax.PlotBoxAspectRatioMode = 'auto';
                    axis(ax, 'off');
                end
                app.setVideoDisplaySize(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'videoDisplayFrame');
            end
        end

        function toggleVideoControlDialog(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                dlg = app.UI(fIdx).vidControlDialog;
                if isempty(dlg) || ~isvalid(dlg), return; end
                if strcmpi(dlg.Visible, 'on')
                    app.hideVideoControlDialog(fIdx);
                else
                    try
                        figPos = app.UIFigure.Position;
                        dlg.Position(1:2) = [figPos(1) + 80, max(40, figPos(2) + figPos(4) - dlg.Position(4) - 80)];
                    catch ME_inner
                        app.logCaught(ME_inner, 'openVideoControlDialog:position');
                    end
                    dlg.Visible = 'on';
                    drawnow limitrate;
                    if isfield(app.UI(fIdx), 'vidControlBtn') && ~isempty(app.UI(fIdx).vidControlBtn) && isvalid(app.UI(fIdx).vidControlBtn)
                        app.UI(fIdx).vidControlBtn.Text = '제어창 닫기';
                    end
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoControlToggle');
            end
        end

        function hideVideoControlDialog(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                dlg = app.UI(fIdx).vidControlDialog;
                if ~isempty(dlg) && isvalid(dlg)
                    dlg.Visible = 'off';
                end
                if isfield(app.UI(fIdx), 'vidControlBtn') && ~isempty(app.UI(fIdx).vidControlBtn) && ...
                   isvalid(app.UI(fIdx).vidControlBtn)
                    app.UI(fIdx).vidControlBtn.Text = '제어창';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoControlHide');
            end
        end

        function ctrl = createVideoControlDialog(app, fIdx)
            ctrl = struct();
            dlg = uifigure('Name', sprintf('AVI 제어 - Flight Data %d', fIdx), ...
                'Visible', 'off', 'Position', [120, 120, 680, 340], ...
                'Color', [0.94 0.94 0.96], ...
                'CloseRequestFcn', @(~,~) app.hideVideoControlDialog(fIdx));
            root = uigridlayout(dlg, [3 1]);
            root.RowHeight = {58, '1x', 44};
            root.Padding = [8 8 8 8];
            root.RowSpacing = 8;

            syncPnl = uipanel(root, 'Title', '동기 설정', 'BackgroundColor', 'w');
            glSync = uigridlayout(syncPnl, [1 6], ...
                'ColumnWidth', {55, 90, 60, 105, '1x', 90}, ...
                'Padding', [6 4 6 4], 'ColumnSpacing', 6);
            uilabel(glSync, 'Text', 'Frame:', 'FontSize', 11, 'FontWeight', 'bold');
            ctrl.vidSyncFrameInput = uispinner(glSync, 'Value', 1, 'Step', 1, ...
                'Limits', [1 1e9], 'ValueDisplayFormat', '%d', 'FontSize', 11);
            uilabel(glSync, 'Text', 'Time(s):', 'FontSize', 11, 'FontWeight', 'bold');
            ctrl.vidSyncTimeInput = uispinner(glSync, 'Value', 0, 'Step', 0.1, ...
                'ValueDisplayFormat', '%.3f', 'FontSize', 11);
            uilabel(glSync, 'Text', '');
            ctrl.vidSyncBtn = uibutton(glSync, 'Text', '동기', ...
                'BackgroundColor', [0.58 0.0 0.83], 'FontColor', 'w', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.applyVideoSync(fIdx));

            vdubGroupPnl = uipanel(root, 'Title', 'Frame Navigator', ...
                'FontSize', 10, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.97 0.97 0.99], ...
                'BorderType', 'line', 'ForegroundColor', [0.1 0.2 0.5]);
            vdubGrid = uigridlayout(vdubGroupPnl, [3 1]);
            vdubGrid.RowHeight = {22, 50, 34};
            vdubGrid.Padding = [8 4 8 4];
            vdubGrid.RowSpacing = 4;
            ctrl.vidVdubLabel = uilabel(vdubGrid, ...
                'Text', 'Frame 1 / 1  (00:00:00.000)', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'FontName', 'Consolas', 'FontColor', [0.1 0.2 0.5], ...
                'HorizontalAlignment', 'center');
            ctrl.vidVdubSlider = uislider(vdubGrid, ...
                'Limits', [1 100], 'Value', 1, ...
                'MajorTicks', [1 25 50 75 100], ...
                'MinorTicks', [], ...
                'ValueChangingFcn', @(~,evt) app.onVdubSliderChanging(fIdx, evt.Value), ...
                'ValueChangedFcn',  @(src,~) app.onVdubSliderChanged(fIdx, src));
            navPnl = uipanel(vdubGrid, 'BorderType', 'none', 'BackgroundColor', [0.97 0.97 0.99]);
            glNav = uigridlayout(navPnl, [1 4], ...
                'ColumnWidth', {'1x', '1x', '1x', '1x'}, ...
                'Padding', [0 0 0 0], 'ColumnSpacing', 10);
            uibutton(glNav, 'Text', '◄◄', 'FontSize', 11, 'FontWeight', 'bold', ...
                'Tooltip', '10 프레임 뒤로 (-10)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'first'));
            uibutton(glNav, 'Text', '◄', 'FontSize', 11, 'FontWeight', 'bold', ...
                'Tooltip', '이전 frame (-1)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'prev'));
            uibutton(glNav, 'Text', '►', 'FontSize', 11, 'FontWeight', 'bold', ...
                'Tooltip', '다음 frame (+1)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'next'));
            uibutton(glNav, 'Text', '►►', 'FontSize', 11, 'FontWeight', 'bold', ...
                'Tooltip', '10 프레임 앞으로 (+10)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'last'));

            hzPnl = uipanel(root, 'BackgroundColor', 'w', 'BorderType', 'line');
            glHz = uigridlayout(hzPnl, [1 12], ...
                'ColumnWidth', {65, 24, 50, 24, 12, 55, 24, 50, 24, 16, 50, 90}, ...
                'Padding', [6 4 6 4], 'ColumnSpacing', 4);
            uilabel(glHz, 'Text', 'Video FPS:', 'FontSize', 10, 'FontWeight', 'bold');
            uibutton(glHz, 'Text', '◄', 'FontSize', 10, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'video', -1));
            ctrl.vidVideoFpsInput = uispinner(glHz, 'Value', 15, 'Step', 1, ...
                'Limits', [1 1000], 'ValueDisplayFormat', '%d', 'FontSize', 10, ...
                'ValueChangedFcn', @(src,~) app.onHzInputChanged(fIdx, 'video', src.Value));
            uibutton(glHz, 'Text', '►', 'FontSize', 10, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'video', 1));
            uilabel(glHz, 'Text', '');
            uilabel(glHz, 'Text', 'Data Hz:', 'FontSize', 10, 'FontWeight', 'bold');
            uibutton(glHz, 'Text', '◄', 'FontSize', 10, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'data', -1));
            ctrl.vidDataFpsInput = uispinner(glHz, 'Value', 50, 'Step', 1, ...
                'Limits', [1 1000], 'ValueDisplayFormat', '%d', 'FontSize', 10, ...
                'ValueChangedFcn', @(src,~) app.onHzInputChanged(fIdx, 'data', src.Value));
            uibutton(glHz, 'Text', '►', 'FontSize', 10, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'data', 1));
            uilabel(glHz, 'Text', '');
            uilabel(glHz, 'Text', 'Cache:', 'FontSize', 10, 'FontWeight', 'bold');
            ctrl.vidCacheBudget = uidropdown(glHz, ...
                'Items', {'30 MB', '50 MB', '100 MB'}, ...
                'ItemsData', [30, 50, 100], ...
                'Value', 30, 'FontSize', 10, ...
                'ValueChangedFcn', @(src,~) app.setCacheBudget(src.Value));

            ctrl.vidControlDialog = dlg;
            ctrl.vidFrameAxes = gobjects(0);
            ctrl.vidFrameXLine = gobjects(0);
            ctrl.vidFrameMarker = gobjects(0);
            app.applyLightPanelTitleContrast(dlg);
        end

        function toggleBoardVisibility(app, fIdx)
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || fIdx > numel(app.UI)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(fIdx);

                if app.BoardOffState(fIdx)
                    app.BoardOffState(fIdx) = false;
                    if isfield(app.UI(fIdx), 'boardOffPanel')
                        app.setUiVisible(app.UI(fIdx).boardOffPanel, false);
                    end
                    app.restoreBoardPanelState(fIdx);
                    app.restoreBoardPanelState(sourceIdx);
                    if isfield(app.UI(fIdx), 'boardOffSignature')
                        app.UI(fIdx).boardOffSignature = '';
                    end
                else
                    otherIdx = 3 - fIdx;
                    if otherIdx >= 1 && otherIdx <= numel(app.BoardOffState) && app.BoardOffState(otherIdx)
                        app.updateBoardToggleButtons();
                        return;
                    end
                    % [Q-03] captureBoardPanelState 호출 제거 — restoreBoardPanelState 가
                    % 현재 PanelVisible 만 사용하므로 스냅샷 불필요.
                    app.BoardOffState(fIdx) = true;
                    app.setUiVisible(app.UI(fIdx).panel, false);
                    if isfield(app.UI(fIdx), 'boardOffPanel')
                        app.setUiVisible(app.UI(fIdx).boardOffPanel, true);
                    end
                    app.reflowBoardColumns(sourceIdx);
                    app.refreshBoardOffSummaryPanel(fIdx, true);
                end

                % [Bug fix B1] Always reflow BOTH boards after any toggle so that
                % collapsed/expanded panel widths render correctly. drawnow forces an
                % immediate layout pass — without it the source board can keep stale
                % 0-width columns visible as blank space.
                app.reflowBoardColumns(fIdx);
                app.reflowBoardColumns(sourceIdx);
                app.updateBoardToggleButtons();
                drawnow;
            catch ME
                app.logCaught(ME, 'boardToggle');
            end
        end

        function sourceIdx = getBoardOffSourceIdx(~, offIdx)
            sourceIdx = 3 - offIdx;
        end

        % [Q-03] captureBoardPanelState 함수 삭제 — 더 이상 호출되지 않음.

        function restoreBoardPanelState(app, fIdx)
            % [Bug #2 fix] Do NOT overwrite PanelVisible from the pre-off snapshot.
            % The user may have toggled side panels (attitude/map/video) on the source
            % board WHILE in off mode; reflowBoardColumns must use the CURRENT PanelVisible
            % so those mid-off changes survive after board-on press.
            try
                % Make sure the board panel itself is visible again (off-board case).
                app.setUiVisible(app.UI(fIdx).panel, true);
                app.ensureBoardCorePanelsVisible(fIdx);
                app.reflowBoardColumns(fIdx);
            catch ME
                app.setUiVisible(app.UI(fIdx).panel, true);
                app.logCaught(ME, 'boardRestore');
            end
        end

        function ensureBoardCorePanelsVisible(app, fIdx)
            % [Bug fix B2] Force 데이터 뷰 / 현재 비행 정보 to be visible. These have
            % no togglePanel button but can be zero-width inside the off-mode source board.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'PanelVisible'), return; end
                % Side-panel toggles remain whatever the snapshot/user set; we only ensure
                % the info table column (#3) and H plot column (#4) come back non-zero in
                % reflowBoardColumns by leaving those cells alone here. The actual width
                % restoration happens in reflowBoardColumns which always sets widths{3}
                % from getResponsivePanelWidths and widths{4}='1x' when board is not off.
            catch ME
                app.logCaught(ME, 'restoreBoardInfoPlotColumns');
            end
        end

        function hideBoardInfoPlotColumns(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ...
                        ~isfield(app.UI(fIdx), 'dataGrid') || isempty(app.UI(fIdx).dataGrid) || ...
                        ~isvalid(app.UI(fIdx).dataGrid)
                    return;
                end
                widths = app.UI(fIdx).dataGrid.ColumnWidth;
                if numel(widths) >= 5
                    widths{3} = 0;  % current flight info
                    widths{4} = 0;  % H data-view panel
                    widths{5} = 0;  % H/I splitter
                    if isfield(app.UI(fIdx), 'PanelVisible')
                        st = app.UI(fIdx).PanelVisible;
                        if isfield(st, 'video') && st.video && numel(widths) >= 6
                            widths{6} = '1x';
                        elseif isfield(st, 'map') && st.map
                            widths{2} = '1x';
                        elseif isfield(st, 'attitude') && st.attitude
                            widths{1} = '1x';
                        end
                    end
                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                end
            catch ME
                app.logCaught(ME, 'boardHideMovedColumns');
            end
        end

        function syncBoardPanelHandles(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ~isfield(app.UI(fIdx), 'PanelVisible')
                    return;
                end
                st = app.UI(fIdx).PanelVisible;
                if isfield(st, 'attitude') && isfield(app.UI(fIdx), 'panelAttitude')
                    app.setUiVisible(app.UI(fIdx).panelAttitude, st.attitude);
                end
                if isfield(st, 'map') && isfield(app.UI(fIdx), 'panelMapAlt')
                    app.setUiVisible(app.UI(fIdx).panelMapAlt, st.map);
                end
                if isfield(st, 'video') && isfield(app.UI(fIdx), 'panelVideo')
                    app.setUiVisible(app.UI(fIdx).panelVideo, st.video);
                end
            catch ME
                app.logCaught(ME, 'boardSyncPanelHandles');
            end
        end

        function reflowBoardColumns(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ...
                        ~isfield(app.UI(fIdx), 'dataGrid') || isempty(app.UI(fIdx).dataGrid) || ...
                        ~isvalid(app.UI(fIdx).dataGrid)
                    return;
                end
                app.syncBoardPanelHandles(fIdx);
                panelWidths = app.getResponsivePanelWidths();
                widths = {panelWidths(1), panelWidths(2), panelWidths(3), '1x', 8, app.getVideoPanelTargetWidth()};
                if isfield(app.UI(fIdx), 'PanelVisible')
                    st = app.UI(fIdx).PanelVisible;
                    if isfield(st, 'attitude') && ~st.attitude, widths{1} = 0; end
                    if isfield(st, 'map') && ~st.map, widths{2} = 0; end
                    if isfield(st, 'video') && ~st.video, widths{6} = 0; end
                end
                activeOff = find(app.BoardOffState, 1);
                if ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff)
                    widths{3} = 0;
                    widths{4} = 0;
                    widths{5} = 0;
                    if isfield(app.UI(fIdx), 'PanelVisible')
                        st = app.UI(fIdx).PanelVisible;
                        if isfield(st, 'video') && st.video
                            widths{6} = '1x';
                        elseif isfield(st, 'map') && st.map
                            widths{2} = '1x';
                        elseif isfield(st, 'attitude') && st.attitude
                            widths{1} = '1x';
                        end
                    end
                end
                app.UI(fIdx).dataGrid.ColumnWidth = widths;
                app.UI(fIdx).dataGrid.Scrollable = 'on';
                app.setVideoDisplaySize(fIdx);
            catch ME
                app.logCaught(ME, 'boardReflowColumns');
            end
        end

        function updateBoardToggleButtons(app)
            labelsOff = {'상단 보드 off', '하단 보드 off'};
            labelsOn  = {'상단 보드 on', '하단 보드 on'};
            try
                if isempty(app.BoardToggleButtons), return; end
                activeOff = find(app.BoardOffState, 1);
                for k = 1:min(2, numel(app.BoardToggleButtons))
                    btn = app.BoardToggleButtons(k);
                    if isempty(btn) || ~isvalid(btn), continue; end
                    if app.BoardOffState(k)
                        btn.Text = labelsOn{k};
                        btn.Enable = 'on';
                        btn.BackgroundColor = [0.75 0.20 0.20];
                        btn.FontColor = [1 1 1];
                    else
                        btn.Text = labelsOff{k};
                        if isempty(activeOff)
                            btn.Enable = 'on';
                        else
                            btn.Enable = 'off';
                        end
                        btn.BackgroundColor = [0.18 0.18 0.22];
                        btn.FontColor = [1 1 1];
                    end
                end
            catch ME
                app.logCaught(ME, 'boardButtons');
            end
        end

        function refreshBoardOffSummaryPanel(app, fIdx, forceRebuild)
            if nargin < 3, forceRebuild = false; end
            try
                if isempty(app.UI) || fIdx > numel(app.UI)
                    return;
                end
                if ~app.BoardOffState(fIdx)
                    otherIdx = app.getBoardOffSourceIdx(fIdx);
                    if otherIdx >= 1 && otherIdx <= numel(app.BoardOffState) && app.BoardOffState(otherIdx)
                        app.refreshBoardOffSummaryPanel(otherIdx, forceRebuild);
                    end
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(fIdx);
                if sourceIdx < 1 || sourceIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'boardOffPanel') || isempty(app.UI(fIdx).boardOffPanel) || ...
                        ~isvalid(app.UI(fIdx).boardOffPanel)
                    return;
                end
                try
                    app.UI(fIdx).boardOffPanel.Title = sprintf( ...
                        'Flight Data %d - Board Off Summary (Flight Data %d info)', fIdx, sourceIdx);
                catch
                end
                app.hideBoardInfoPlotColumns(sourceIdx);

                if isfield(app.UI(sourceIdx), 'dataTable') && ~isempty(app.UI(sourceIdx).dataTable) && ...
                        isvalid(app.UI(sourceIdx).dataTable) && isfield(app.UI(fIdx), 'boardOffTable') && ...
                        ~isempty(app.UI(fIdx).boardOffTable) && isvalid(app.UI(fIdx).boardOffTable)
                    app.UI(fIdx).boardOffTable.Data = app.UI(sourceIdx).dataTable.Data;
                end

                sig = app.getBoardOffPlotSignature(sourceIdx);
                if forceRebuild || ~strcmp(sig, app.UI(fIdx).boardOffSignature)
                    app.rebuildBoardOffPlots(fIdx, sourceIdx);
                    app.UI(fIdx).boardOffSignature = sig;
                else
                    app.syncBoardOffPlotMarkers(fIdx, sourceIdx);
                end
            catch ME
                app.logCaught(ME, 'boardSummary');
            end
        end

        function sig = getBoardOffPlotSignature(app, fIdx)
            sigParts = {};
            try
                if isempty(app.UI) || fIdx > numel(app.UI)
                    sig = '';
                    return;
                end
                tabs = app.UI(fIdx).plotTabs;
                try
                    selectedIdx = find(tabs == app.UI(fIdx).tabGroup.SelectedTab, 1);
                    if isempty(selectedIdx), selectedIdx = 0; end
                catch
                    selectedIdx = 0;
                end
                sigParts{end+1} = sprintf('sel=%d;tabs=%d', selectedIdx, numel(tabs));
                for tIdx = 1:numel(tabs)
                    tabTitle = '';
                    try
                        tabTitle = char(tabs(tIdx).Title);
                    catch
                    end
                    plotCount = 0;
                    if tIdx <= numel(app.UI(fIdx).plotAxes) && ~isempty(app.UI(fIdx).plotAxes{tIdx})
                        plotCount = numel(app.UI(fIdx).plotAxes{tIdx});
                    end
                    sigParts{end+1} = sprintf('T%d:%s:%d', tIdx, tabTitle, plotCount); %#ok<AGROW>
                    for pIdx = 1:plotCount
                        yLabel = '';
                        try
                            ax = app.UI(fIdx).plotAxes{tIdx}{pIdx};
                            if ~isempty(ax) && isvalid(ax), yLabel = char(ax.YLabel.String); end
                        catch
                        end
                        yLen = 0;
                        try
                            yData = app.getPlotYData(fIdx, tIdx, pIdx);
                            yLen = numel(yData);
                        catch
                        end
                        sigParts{end+1} = sprintf('P%d:%d:%s', pIdx, yLen, yLabel); %#ok<AGROW>
                    end
                end
                sig = strjoin(sigParts, '|');
            catch
                sig = '';
            end
        end

        function rebuildBoardOffPlots(app, fIdx, sourceIdx)
            if nargin < 3, sourceIdx = app.getBoardOffSourceIdx(fIdx); end
            try
                tg = app.UI(fIdx).boardOffTabGroup;
                if isempty(tg) || ~isvalid(tg), return; end
                try
                    delete(tg.Children);
                catch ME_silent
                    app.logCaught(ME_silent, 'refreshBoardOffSummaryPanel:clear-tabs');
                end

                app.UI(fIdx).boardOffPlotTabs = [];
                app.UI(fIdx).boardOffPlotLayouts = {};
                app.UI(fIdx).boardOffPlotAxes = cell(1, app.MAX_TABS);
                app.UI(fIdx).boardOffTimeLines = cell(1, app.MAX_TABS);
                app.UI(fIdx).boardOffTimeMarkers = cell(1, app.MAX_TABS);
                app.UI(fIdx).boardOffPlotData = cell(1, app.MAX_TABS);

                sourceTabs = app.UI(sourceIdx).plotTabs;
                if isempty(sourceTabs)
                    app.createEmptyBoardOffTab(fIdx, tg, 'Tab 1');
                    return;
                end

                timeData = [];
                currIdx = 1;
                currTime = 0;
                if ~isempty(app.Models(sourceIdx).rawData)
                    currIdx = max(1, min(app.Models(sourceIdx).currentIndex, height(app.Models(sourceIdx).rawData)));
                    timeCol = app.Models(sourceIdx).mappedCols.Time;
                    timeData = app.Models(sourceIdx).rawData.(timeCol);
                    currTime = timeData(currIdx);
                end

                selectedIdx = 1;
                try
                    tmpIdx = find(sourceTabs == app.UI(sourceIdx).tabGroup.SelectedTab, 1);
                    if ~isempty(tmpIdx), selectedIdx = tmpIdx; end
                catch
                end

                for tIdx = 1:numel(sourceTabs)
                    tabTitle = sprintf('Tab %d', tIdx);
                    try
                        tabTitle = char(sourceTabs(tIdx).Title);
                    catch
                    end
                    newTab = uitab(tg, 'Title', tabTitle);
                    app.UI(fIdx).boardOffPlotTabs(end+1) = newTab;
                    plotLayout = uigridlayout(newTab, 'ColumnWidth', {'1x'}, 'RowHeight', {}, ...
                        'Padding', [5 5 5 5], 'RowSpacing', 5, 'Scrollable', 'on');
                    app.UI(fIdx).boardOffPlotLayouts{tIdx} = plotLayout;
                    app.UI(fIdx).boardOffPlotAxes{tIdx} = {};
                    app.UI(fIdx).boardOffTimeLines{tIdx} = {};
                    app.UI(fIdx).boardOffTimeMarkers{tIdx} = {};
                    app.UI(fIdx).boardOffPlotData{tIdx} = {};

                    plotCount = 0;
                    if tIdx <= numel(app.UI(sourceIdx).plotData) && ~isempty(app.UI(sourceIdx).plotData{tIdx})
                        plotCount = max(plotCount, numel(app.UI(sourceIdx).plotData{tIdx}));
                    end
                    if tIdx <= numel(app.UI(sourceIdx).plotAxes) && ~isempty(app.UI(sourceIdx).plotAxes{tIdx})
                        plotCount = max(plotCount, numel(app.UI(sourceIdx).plotAxes{tIdx}));
                    end
                    if plotCount == 0
                        plotLayout.RowHeight = {'1x'};
                        uilabel(plotLayout, 'Text', '표시할 plot 없음', ...
                            'HorizontalAlignment', 'center', 'FontColor', [0.45 0.45 0.45], 'FontWeight', 'bold');
                        continue;
                    end

                    for pIdx = 1:plotCount
                        yData = app.getPlotYData(sourceIdx, tIdx, pIdx);
                        if isempty(yData), continue; end
                        if isempty(timeData)
                            xData = 1:numel(yData);
                            currX = min(currIdx, numel(xData));
                        else
                            n = min(numel(timeData), numel(yData));
                            xData = timeData(1:n);
                            yData = yData(1:n);
                            currX = currTime;
                        end
                        rowHeightValue = app.getConfiguredPlotHeight(sourceIdx, tIdx, pIdx, app.PLOT_ROW_HEIGHT);
                        rowHeightValue = app.getLivePlotHeight(sourceIdx, tIdx, pIdx, rowHeightValue);
                        plotLayout.RowHeight{end+1} = rowHeightValue;
                        rowIdx = numel(plotLayout.RowHeight);
                        p = uipanel(plotLayout, 'BorderType', 'line', 'BackgroundColor', 'w');
                        p.Layout.Row = rowIdx;
                        p.Layout.Column = 1;
                        axGrid = uigridlayout(p, [1 1], 'Padding', [5 5 5 5]);
                        % [Perf] Removed per-plot applyLightPanelTitleContrast(p) — p has
                        % no Title text so contrast adjust is a no-op, and walking the
                        % whole panel tree per plot dominated rebuildBoardOffPlots cost.
                        ax = uiaxes(axGrid);
                        ax.Layout.Row = 1;
                        ax.Layout.Column = 1;
                        grid(ax, 'on');
                        set(ax, 'XMinorGrid', 'on', 'YMinorGrid', 'on');
                        % [R-08] Tag the summary data line for robust marker sync fallback.
                        plot(ax, xData, yData, 'LineWidth', 1.5, 'Color', [0.15 0.38 0.82], ...
                            'HitTest', 'off', 'Tag', 'fdd:dataLine');
                        xlabel(ax, 'Time(s)', 'FontWeight', 'bold', 'FontSize', 9);
                        yLabelStr = '';
                        try
                            srcAx = app.UI(sourceIdx).plotAxes{tIdx}{pIdx};
                            if ~isempty(srcAx) && isvalid(srcAx)
                                yLabelStr = char(srcAx.YLabel.String);
                                % [Bug #1 fix] Mirror source XLim only when user pinned it
                                % (XLimMode='manual'). Otherwise use the data span so a fresh
                                % source plot (whose auto XLim has not committed) cannot leak
                                % its default [0 1] into the off summary.
                                if strcmpi(char(srcAx.XLimMode), 'manual')
                                    ax.XLim = srcAx.XLim;
                                elseif numel(xData) >= 2 && xData(end) > xData(1)
                                    ax.XLim = [xData(1) xData(end)];
                                end
                                ax.YLimMode = srcAx.YLimMode;
                                if strcmpi(char(srcAx.YLimMode), 'manual')
                                    ax.YLim = srcAx.YLim;
                                end
                            elseif numel(xData) >= 2 && xData(end) > xData(1)
                                ax.XLim = [xData(1) xData(end)];
                            end
                        catch
                        end
                        ylabel(ax, yLabelStr, 'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');
                        hold(ax, 'on');
                        markerIdx = max(1, min(currIdx, numel(yData)));
                        tl = xline(ax, currX, 'r', 'LineWidth', 3.0, 'Alpha', 0.5, 'HitTest', 'on');
                        mk = plot(ax, currX, yData(markerIdx), 'p', ...
                            'MarkerFaceColor', [0.98 0.75 0.14], 'MarkerEdgeColor', [0.71 0.33 0.04], ...
                            'MarkerSize', 14, 'HitTest', 'on');
                        tl.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(sourceIdx, tIdx, src, event);
                        mk.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(sourceIdx, tIdx, src, event);
                        try
                            % [Bug fix] match source axes interactions so marker/xline
                            % ButtonDownFcn fires reliably. disableDefaultInteractivity
                            % was suppressing pick events on some MATLAB releases.
                            ax.Interactions = [panInteraction, zoomInteraction];
                            ax.Toolbar.Visible = 'off';
                            tl.PickableParts = 'visible';
                            mk.PickableParts = 'visible';
                        catch
                        end
                        app.UI(fIdx).boardOffPlotAxes{tIdx}{pIdx} = ax;
                        app.UI(fIdx).boardOffTimeLines{tIdx}{pIdx} = tl;
                        app.UI(fIdx).boardOffTimeMarkers{tIdx}{pIdx} = mk;
                        app.UI(fIdx).boardOffPlotData{tIdx}{pIdx} = yData;
                    end
                end

                if selectedIdx <= numel(app.UI(fIdx).boardOffPlotTabs)
                    try
                        tg.SelectedTab = app.UI(fIdx).boardOffPlotTabs(selectedIdx);
                    catch
                    end
                end
                app.syncBoardOffPlotMarkers(fIdx, sourceIdx);
            catch ME
                app.logCaught(ME, 'boardRebuild');
            end
        end

        function createEmptyBoardOffTab(app, fIdx, tg, tabTitle)
            newTab = uitab(tg, 'Title', tabTitle);
            app.UI(fIdx).boardOffPlotTabs = newTab;
            grid = uigridlayout(newTab, [1 1], 'Padding', [8 8 8 8]);
            uilabel(grid, 'Text', '표시할 plot 없음', ...
                'HorizontalAlignment', 'center', 'FontColor', [0.45 0.45 0.45], 'FontWeight', 'bold');
        end

        function syncBoardOffPlotMarkers(app, fIdx, sourceIdx)
            if nargin < 3, sourceIdx = app.getBoardOffSourceIdx(fIdx); end
            try
                if isempty(app.Models(sourceIdx).rawData), return; end
                currIdx = max(1, min(app.Models(sourceIdx).currentIndex, height(app.Models(sourceIdx).rawData)));
                timeCol = app.Models(sourceIdx).mappedCols.Time;
                times = app.Models(sourceIdx).rawData.(timeCol);
                currTime = times(currIdx);
                for tIdx = 1:min(numel(app.UI(fIdx).boardOffTimeLines), numel(app.UI(fIdx).boardOffPlotData))
                    if isempty(app.UI(fIdx).boardOffTimeLines{tIdx}), continue; end
                    for pIdx = 1:numel(app.UI(fIdx).boardOffTimeLines{tIdx})
                        try
                            tl = app.UI(fIdx).boardOffTimeLines{tIdx}{pIdx};
                            mk = app.UI(fIdx).boardOffTimeMarkers{tIdx}{pIdx};
                            yData = app.getPlotYData(sourceIdx, tIdx, pIdx);
                            if isempty(yData)
                                yData = app.UI(fIdx).boardOffPlotData{tIdx}{pIdx};
                            else
                                app.UI(fIdx).boardOffPlotData{tIdx}{pIdx} = yData;
                            end
                            if ~isempty(tl) && isvalid(tl), tl.Value = currTime; end
                            if ~isempty(mk) && isvalid(mk)
                                markerIdx = max(1, min(currIdx, numel(yData)));
                                set(mk, 'XData', currTime, 'YData', yData(markerIdx));
                            end
                            if tIdx <= numel(app.UI(sourceIdx).plotAxes) && pIdx <= numel(app.UI(sourceIdx).plotAxes{tIdx}) && ...
                                    pIdx <= numel(app.UI(fIdx).boardOffPlotAxes{tIdx})
                                srcAx = app.UI(sourceIdx).plotAxes{tIdx}{pIdx};
                                dstAx = app.UI(fIdx).boardOffPlotAxes{tIdx}{pIdx};
                                if ~isempty(srcAx) && isvalid(srcAx) && ~isempty(dstAx) && isvalid(dstAx)
                                    % [Bug #1 fix v2] Only mirror srcAx.XLim when the user
                                    % pinned it (XLimMode='manual'). When auto, a freshly
                                    % added source plot's XLim may still be the default
                                    % [0 1] / [0 0.x] because uiaxes auto-commit defers to
                                    % drawnow, leaking that stale value into the off summary.
                                    if strcmpi(char(srcAx.XLimMode), 'manual')
                                        dstAx.XLim = srcAx.XLim;
                                    elseif ~isempty(times)
                                        dstAx.XLim = [times(1) times(end)];
                                    end
                                    dstAx.YLimMode = srcAx.YLimMode;
                                    if strcmpi(char(srcAx.YLimMode), 'manual')
                                        dstAx.YLim = srcAx.YLim;
                                    end
                                end
                            end
                        catch ME_silent
                            app.logCaught(ME_silent, 'refreshBoardOffSummaryPanel:copy-axis');
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'boardSyncMarkers');
            end
        end

        function syncBoardOffSelectedTab(app, offIdx)
            try
                if offIdx < 1 || offIdx > numel(app.UI) || ~app.BoardOffState(offIdx)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(offIdx);
                if sourceIdx < 1 || sourceIdx > numel(app.UI), return; end
                tg = app.UI(offIdx).boardOffTabGroup;
                if isempty(tg) || ~isvalid(tg) || isempty(app.UI(offIdx).boardOffPlotTabs)
                    return;
                end
                tabIdx = find(app.UI(offIdx).boardOffPlotTabs == tg.SelectedTab, 1);
                if isempty(tabIdx), return; end
                if tabIdx <= numel(app.UI(sourceIdx).plotTabs) && ~isempty(app.UI(sourceIdx).plotTabs(tabIdx)) && ...
                        isvalid(app.UI(sourceIdx).plotTabs(tabIdx))
                    app.UI(sourceIdx).tabGroup.SelectedTab = app.UI(sourceIdx).plotTabs(tabIdx);
                    app.updateTabTimeLines(sourceIdx);
                end
            catch ME
                app.logCaught(ME, 'boardSyncSelectedTab');
            end
        end

        function boardOffAddPlotTab(app, offIdx)
            try
                if offIdx < 1 || offIdx > numel(app.BoardOffState) || ~app.BoardOffState(offIdx)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(offIdx);
                app.syncBoardOffSelectedTab(offIdx);
                app.addPlotTab(sourceIdx);
                app.refreshBoardOffSummaryPanel(offIdx, true);
            catch ME
                app.logCaught(ME, 'boardOffAddTab');
            end
        end

        function boardOffClearCurrentTab(app, offIdx)
            try
                if offIdx < 1 || offIdx > numel(app.BoardOffState) || ~app.BoardOffState(offIdx)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(offIdx);
                app.syncBoardOffSelectedTab(offIdx);
                app.clearCurrentTab(sourceIdx);
                app.refreshBoardOffSummaryPanel(offIdx, true);
            catch ME
                app.logCaught(ME, 'boardOffClearTab');
            end
        end

        function boardOffTableSelection(app, offIdx, event)
            try
                if offIdx < 1 || offIdx > numel(app.BoardOffState) || isempty(event.Indices)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(offIdx);
                app.Models(sourceIdx).selectedRow = event.Indices(1, 1);
            catch ME
                app.logCaught(ME, 'boardOffTableSelection');
            end
        end

        function boardOffPlotSelectedVariable(app, offIdx)
            try
                if offIdx < 1 || offIdx > numel(app.BoardOffState) || ~app.BoardOffState(offIdx)
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(offIdx);
                app.syncBoardOffSelectedTab(offIdx);
                app.plotSelectedVariable(sourceIdx);
                app.refreshBoardOffSummaryPanel(offIdx, true);
            catch ME
                app.logCaught(ME, 'boardOffPlotSelected');
            end
        end

        function tf = isUiVisible(~, h)
            tf = false;
            try
                if isempty(h) || ~isvalid(h), return; end
                v = h.Visible;
                if islogical(v)
                    tf = v;
                else
                    tf = strcmpi(char(v), 'on');
                end
            catch
                tf = false;
            end
        end

        function setUiVisible(~, h, tf)
            try
                if isempty(h) || ~isvalid(h), return; end
                if tf
                    h.Visible = 'on';
                else
                    h.Visible = 'off';
                end
            catch
            end
        end

        function applyLightPanelTitleContrast(app, root)
            try
                panels = findall(root, 'Type', 'uipanel');
            catch
                panels = [];
            end
            for k = 1:numel(panels)
                p = panels(k);
                try
                    if isempty(p) || ~isvalid(p) || ~isprop(p, 'Title') ...
                            || isempty(char(p.Title)) || ~isprop(p, 'ForegroundColor')
                        continue;
                    end
                    isLightBg = false;
                    if isprop(p, 'BackgroundColor')
                        bg = p.BackgroundColor;
                        if isnumeric(bg) && numel(bg) == 3
                            isLightBg = all(double(bg) >= 0.90);
                        elseif ischar(bg) || isstring(bg)
                            isLightBg = any(strcmpi(char(bg), {'w', 'white'}));
                        end
                    end
                    if isLightBg
                        p.ForegroundColor = [0 0 0];
                    end
                catch ME
                    app.logCaught(ME, 'enforceReadablePanelTitles');
                end
            end
        end

        function offUi = createBoardOffSummaryPanel(app, parentGrid, fIdx)
            pnl = uipanel(parentGrid, 'Title', sprintf('Flight Data %d - Board Off Summary', fIdx), ...
                'FontWeight', 'bold', 'FontSize', 14, 'BackgroundColor', [0.98 0.98 0.98], ...
                'Visible', 'off');
            pnl.Layout.Row = fIdx;
            pnl.Layout.Column = 1;

            root = uigridlayout(pnl, [1 2]);
            root.ColumnWidth = {300, '1x'};
            root.RowHeight = {'1x'};
            root.Padding = [4 4 4 4];
            root.ColumnSpacing = 6;

            infoPanel = uipanel(root, 'Title', '현재 비행 정보', ...
                'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', 'w', 'Scrollable', 'on');
            infoPanel.Layout.Column = 1;
            infoGrid = uigridlayout(infoPanel, [1 1], 'Padding', [0 0 0 0]);
            tblBgColor = [0.23 0.51 0.96];
            if fIdx == 2, tblBgColor = [0.31 0.27 0.90]; end
            tbl = uitable(infoGrid, 'BackgroundColor', tblBgColor, 'ForegroundColor', [1 1 1], ...
                'FontWeight', 'bold', 'RowStriping', 'off', 'ColumnName', {'항목', '값'}, ...
                'RowName', [], 'ColumnWidth', {'26x', '24x'}, 'FontSize', 11, 'FontName', 'Consolas');
            cm = uicontextmenu(app.UIFigure);
            uimenu(cm, 'Text', 'H 영역에 Plot 추가 (현재 행)', ...
                'MenuSelectedFcn', @(~,~) app.boardOffPlotSelectedVariable(fIdx));
            tbl.ContextMenu = cm;
            tbl.CellSelectionCallback = @(~, event) app.boardOffTableSelection(fIdx, event);

            plotPanel = uipanel(root, 'Title', 'H: 데이터 뷰 패널', ...
                'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', 'w');
            plotPanel.Layout.Column = 2;
            plotGrid = uigridlayout(plotPanel, [2 1], 'Padding', [2 2 2 2]);
            plotGrid.RowHeight = {28, '1x'};
            plotGrid.RowSpacing = 4;
            % [Bug fix] Use uigridlayout for the button row instead of an absolute-positioned
            % uipanel. A uipanel nested in a uigridlayout auto-normalizes child positions and
            % the previous [5 5 90 22] pixel layout was collapsing the two buttons out of view.
            btnRow = uigridlayout(plotGrid, [1 3], 'Padding', [2 2 2 2], 'ColumnSpacing', 4);
            btnRow.Layout.Row = 1;
            btnRow.ColumnWidth = {110, 120, '1x'};
            uibutton(btnRow, 'Text', '+ 빈 탭 추가', ...
                'ButtonPushedFcn', @(~,~) app.boardOffAddPlotTab(fIdx));
            uibutton(btnRow, 'Text', '현재 탭 지우기', ...
                'ButtonPushedFcn', @(~,~) app.boardOffClearCurrentTab(fIdx));
            uilabel(btnRow, 'Text', '');  % spacer

            tg = uitabgroup(plotGrid);
            tg.Layout.Row = 2;
            tg.SelectionChangedFcn = @(~,~) app.syncBoardOffSelectedTab(fIdx);
            blankTab = uitab(tg, 'Title', 'Tab 1');
            blankGrid = uigridlayout(blankTab, [1 1], 'Padding', [8 8 8 8]);
            uilabel(blankGrid, 'Text', '표시할 plot 없음', ...
                'HorizontalAlignment', 'center', 'FontColor', [0.45 0.45 0.45], 'FontWeight', 'bold');

            % [R-10] Off-summary panels are late-created, so apply title contrast here.
            app.applyLightPanelTitleContrast(pnl);
            offUi = struct('panel', pnl, 'table', tbl, 'tabGroup', tg);
        end

        function createLayout(app)
            % [V3.22 #7] 메인 레이아웃 골격 + 헤더는 buildHeaderBar로 위임
            % 비행경로별 빌드는 기존 in-place 코드 유지 (위험도 관리)
            mainLayout = uigridlayout(app.UIFigure, [2 1]);
            mainLayout.RowHeight = {'fit', '1x'};
            mainLayout.Padding = [2 2 2 2];
            mainLayout.RowSpacing = 2;

            % --- Header bar ---
            app.buildHeaderBar(mainLayout);

            % --- Body (2 비행경로 vertical stack) ---
            scrollBody = uipanel(mainLayout, 'Scrollable', 'on', 'BorderType', 'none', 'BackgroundColor', [0.94 0.94 0.96]);
            bodyGrid = uigridlayout(scrollBody, [2 1]);
            bodyGrid.ColumnWidth = {'1x'};
            bodyGrid.RowHeight = {'1x', '1x'};
            bodyGrid.Padding = [2 2 2 2];
            bodyGrid.RowSpacing = 5;

            titleStrs = {'Flight Data 1', 'Flight Data 2'};
            panelColors = {[0.98 0.98 0.98], [0.98 0.98 0.98]};
            panelWidths = app.getResponsivePanelWidths();

            UI_temp = struct('panel', {}, 'dataTable', {}, 'spinner', {}, 'currentTimeLabel', {}, 'fileNameLabel', {}, ...
                        'mapAxes', {}, 'altAxes', {}, 'pitchAxes', {}, 'rollAxes', {}, 'hdgAxes', {}, ...
                        'pitchLabel', {}, 'rollLabel', {}, 'hdgLabel', {}, ...
                        'hMapPath', {}, 'hgMapPlane', {}, 'hAltPath', {}, 'hAltMarker', {}, 'timeLine', {}, ...
                        'hgPitch', {}, 'hgRoll', {}, 'hgHdg', {}, ...
                        'tabGroup', {}, 'plotTabs', {}, 'plotLayouts', {}, 'plotAxes', {}, ...
                        'timeLines', {}, 'timeMarkers', {}, 'plotData', {}, 'xLimListeners', {}, 'altXLimListener', {}, 'vidAxes', {}, 'vidImageHandle', {}, ...
                        'dataGrid', {}, 'panelAttitude', {}, 'panelMapAlt', {}, 'panelVideo', {}, ...
                        'btnAtt', {}, 'btnMap', {}, 'btnVid', {}, 'PanelVisible', {}, ...
                        'vidContainer', {}, 'vidResolutionDropdown', {}, 'vidControlBtn', {}, 'vidControlDialog', {}, ...
                        'vidSyncFrameInput', {}, 'vidSyncTimeInput', {}, 'vidSyncBtn', {}, 'vidSyncStatus', {}, ...
                        'vidVideoFpsInput', {}, 'vidDataFpsInput', {}, ...
                        'vidFrameAxes', {}, 'vidFrameXLine', {}, 'vidFrameMarker', {}, ...
                        'vidCacheBudget', {}, 'vidVdubSlider', {}, 'vidVdubLabel', {}, ...
                        'boardOffPanel', {}, 'boardOffTable', {}, 'boardOffTabGroup', {}, ...
                        'boardOffPlotTabs', {}, 'boardOffPlotLayouts', {}, 'boardOffPlotAxes', {}, ...
                        'boardOffTimeLines', {}, 'boardOffTimeMarkers', {}, 'boardOffPlotData', {}, ...
                        'boardOffSignature', {});

            for fIdx = 1:2
                % [V3.22 #7] 비행경로 fIdx 빌드 - 섹션 가이드 (위→아래 빌드 순서):
                %   (a) 메인 패널 + 컨트롤바
                %   (b) Col 1: 비행 자세 (3 게이지)
                %   (c) Col 2: 지도 + 고도 (수직 분할)
                %   (d) Col 3: 데이터 테이블 (정보 패널)
                %   (e) Col 4: 플롯 영역(H) - tabGroup
                %   (f) Col 5: H↔I splitter (드래그 가능)
                %   (g) Col 6: 비디오 + Frame Navigator

                % --- (a) 메인 패널 + 컨트롤바 ---
                UI_temp(fIdx).panel = uipanel(bodyGrid, 'Title', titleStrs{fIdx}, 'FontWeight', 'bold', 'FontSize', 14, 'BackgroundColor', panelColors{fIdx});
                UI_temp(fIdx).panel.Layout.Row = fIdx;
                UI_temp(fIdx).panel.Layout.Column = 1;
                fGrid = uigridlayout(UI_temp(fIdx).panel, [2 1]);
                fGrid.ColumnWidth = {'1x'};
                fGrid.RowHeight = {45, '1x'};
                fGrid.Padding = [2 2 2 2];
                fGrid.RowSpacing = 2;

                controlPanel = uipanel(fGrid, 'BackgroundColor', 'w', 'BorderType', 'line');
                glCtrl = uigridlayout(controlPanel, [1 8]);
                glCtrl.ColumnWidth = {100, 150, 110, 120, '1x', 80, 85, 80};
                glCtrl.RowHeight = {'1x'};
                glCtrl.Padding = [2 2 2 2];

                uilabel(glCtrl, 'Text', '입력 시간(s):', 'FontWeight', 'bold', 'FontSize', 12);
                UI_temp(fIdx).spinner = uispinner(glCtrl, 'Enable', 'off', 'FontSize', 13, 'ValueDisplayFormat', '%.3f', ...
                                             'ValueChangedFcn', @(~, event) app.handleSpinnerChange(fIdx, event.Value));
                uilabel(glCtrl, 'Text', '실시간 현재값:', 'FontWeight', 'bold', 'FontSize', 12);
                UI_temp(fIdx).currentTimeLabel = uilabel(glCtrl, 'Text', '0.000 s', 'FontWeight', 'bold', 'FontSize', 13, 'FontColor', [0.8 0.1 0.1]);
                UI_temp(fIdx).fileNameLabel = uilabel(glCtrl, 'Text', '파일 없음', 'FontColor', [0.2 0.2 0.2], 'FontSize', 11, 'FontWeight', 'bold');

                UI_temp(fIdx).btnAtt = uibutton(glCtrl, 'Text', '자세 ▾', 'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'attitude'));
                UI_temp(fIdx).btnAtt.Layout.Column = 6;
                UI_temp(fIdx).btnMap = uibutton(glCtrl, 'Text', '지도/고도 ▾', 'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'map'));
                UI_temp(fIdx).btnMap.Layout.Column = 7;
                UI_temp(fIdx).btnVid = uibutton(glCtrl, 'Text', '비디오 ▾', 'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'video'));
                UI_temp(fIdx).btnVid.Layout.Column = 8;
                UI_temp(fIdx).PanelVisible = struct('attitude', true, 'map', true, 'video', true);

                % [레이아웃 순서 확정 및 폭 최적화] 자세(200) -> 지도/고도(500) -> 정보(250) -> H패널(1x) -> splitter(6) -> 비디오(500)
                % [PATCH UX-3] H↔I 경계 splitter 컬럼 추가
                UI_temp(fIdx).dataGrid = uigridlayout(fGrid, [1 6]);
                UI_temp(fIdx).dataGrid.ColumnWidth = {panelWidths(1), panelWidths(2), panelWidths(3), '1x', 8, panelWidths(4)};
                UI_temp(fIdx).dataGrid.RowHeight = {'1x'};
                UI_temp(fIdx).dataGrid.Padding = [0 0 0 0];
                UI_temp(fIdx).dataGrid.ColumnSpacing = 3;   % splitter 가시성
                UI_temp(fIdx).dataGrid.Scrollable = 'on';

                % --- (b) Col 1: 비행 자세 (Pitch / Roll / Heading 게이지) ---
                UI_temp(fIdx).panelAttitude = uipanel(UI_temp(fIdx).dataGrid, 'Title', '비행 자세', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', 'w');
                UI_temp(fIdx).panelAttitude.Layout.Column = 1;
                gGrid = uigridlayout(UI_temp(fIdx).panelAttitude, [3 1]);
                gGrid.RowHeight = {'1x', '1x', '1x'};
                gGrid.Padding = [2 2 2 2];
                gGrid.RowSpacing = 2;

                [UI_temp(fIdx).pitchAxes, UI_temp(fIdx).pitchLabel] = app.createGaugePanel(gGrid, 'Pitch');
                [UI_temp(fIdx).rollAxes, UI_temp(fIdx).rollLabel]   = app.createGaugePanel(gGrid, 'Roll');
                [UI_temp(fIdx).hdgAxes, UI_temp(fIdx).hdgLabel]     = app.createGaugePanel(gGrid, 'Heading');

                % --- (c) Col 2: Map (위) + Altitude (아래) ---
                UI_temp(fIdx).panelMapAlt = uipanel(UI_temp(fIdx).dataGrid, 'BorderType', 'none', 'BackgroundColor', panelColors{fIdx});
                UI_temp(fIdx).panelMapAlt.Layout.Column = 2;
                pGrid = uigridlayout(UI_temp(fIdx).panelMapAlt, [2 1]);
                pGrid.RowHeight = {'1.5x', '1x'};
                pGrid.Padding = [0 0 0 0];

                mapPnl = uipanel(pGrid, 'Title', 'Map', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', 'w');
                mapGrid = uigridlayout(mapPnl, [1 1], 'Padding', [5 5 5 5]);
                UI_temp(fIdx).mapAxes = uiaxes(mapGrid);
                hold(UI_temp(fIdx).mapAxes, 'on');
                xlabel(UI_temp(fIdx).mapAxes, 'Lon', 'FontWeight', 'bold', 'FontSize', 10);
                ylabel(UI_temp(fIdx).mapAxes, 'Lat', 'FontWeight', 'bold', 'FontSize', 10);
                set(UI_temp(fIdx).mapAxes, 'XGrid', 'on', 'YGrid', 'on', 'XMinorGrid', 'on', 'YMinorGrid', 'on', 'XMinorTick', 'on', 'YMinorTick', 'on', 'TickDir', 'out');

                % [V3.10] Map axes는 툴바 숨김 (휠 줌/드래그 팬만 사용)
                disableDefaultInteractivity(UI_temp(fIdx).mapAxes);
                UI_temp(fIdx).mapAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).mapAxes.Interactions = [panInteraction, zoomInteraction];

                altPnl = uipanel(pGrid, 'Title', 'Altitude', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', 'w');
                altGrid = uigridlayout(altPnl, [1 1], 'Padding', [5 5 5 5]);
                UI_temp(fIdx).altAxes = uiaxes(altGrid);
                hold(UI_temp(fIdx).altAxes, 'on');
                xlabel(UI_temp(fIdx).altAxes, 'Time(s)', 'FontWeight', 'bold', 'FontSize', 11);
                ylabel(UI_temp(fIdx).altAxes, 'Alt', 'FontWeight', 'bold', 'FontSize', 10);
                xtickformat(UI_temp(fIdx).altAxes, '%.0f');
                set(UI_temp(fIdx).altAxes, 'XGrid', 'on', 'YGrid', 'on', 'XMinorGrid', 'on', 'YMinorGrid', 'on', 'XMinorTick', 'on', 'YMinorTick', 'on', 'TickDir', 'out');

                % [V3.10] Altitude axes는 툴바 숨김 (휠 줌/드래그 팬만 사용)
                disableDefaultInteractivity(UI_temp(fIdx).altAxes);
                UI_temp(fIdx).altAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).altAxes.Interactions = [panInteraction, zoomInteraction];

                % --- (d) Col 3: 현재 비행 정보 (데이터 테이블) ---
                infoPanel = uipanel(UI_temp(fIdx).dataGrid, 'Title', '현재 비행 정보', 'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', 'w', 'Scrollable', 'on');
                infoPanel.Layout.Column = 3;
                glInfo = uigridlayout(infoPanel, [1 1], 'Padding', [0 0 0 0]);
                if fIdx == 1, tblBgColor = [0.23 0.51 0.96]; else, tblBgColor = [0.31 0.27 0.90]; end
                UI_temp(fIdx).dataTable = uitable(glInfo, 'BackgroundColor', tblBgColor, 'ForegroundColor', [1 1 1], 'FontWeight', 'bold', ...
                                             'RowStriping', 'off', 'ColumnName', {'항목', '값'}, 'RowName', [], ...
                                             'ColumnWidth', {'29x', '20x'}, 'FontSize', 11, 'FontName', 'Consolas');
                cm = uicontextmenu(app.UIFigure);
                uimenu(cm, 'Text', 'H 영역에 Plot 추가 (현재 탭)', 'MenuSelectedFcn', @(~,~) app.plotSelectedVariable(fIdx));
                UI_temp(fIdx).dataTable.ContextMenu = cm;
                UI_temp(fIdx).dataTable.CellSelectionCallback = @(~, event) app.handleTableSelection(fIdx, event);

                % --- (e) Col 4: H 패널 (플롯 tabGroup) ---
                hPnl = uipanel(UI_temp(fIdx).dataGrid, 'Title', 'H: 데이터 뷰 패널', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', 'w');
                hPnl.Layout.Column = 4;
                hGrid2 = uigridlayout(hPnl, [2 1]);
                hGrid2.RowHeight = {30, '1x'};
                hGrid2.Padding = [2 2 2 2];

                btnPnl = uipanel(hGrid2, 'BorderType', 'none', 'BackgroundColor', 'w');
                uibutton(btnPnl, 'Text', '+ 빈 탭 추가', 'Position', [5 5 90 22], 'ButtonPushedFcn', @(~,~) app.addPlotTab(fIdx));
                uibutton(btnPnl, 'Text', '현재 탭 지우기', 'Position', [100 5 100 22], 'ButtonPushedFcn', @(~,~) app.clearCurrentTab(fIdx));

                UI_temp(fIdx).tabGroup = uitabgroup(hGrid2);
                UI_temp(fIdx).tabGroup.SelectionChangedFcn = @(~,~) app.updateTabTimeLines(fIdx);
                UI_temp(fIdx).plotTabs = [];
                UI_temp(fIdx).plotLayouts = {};

                UI_temp(fIdx).plotAxes = cell(1, app.MAX_TABS);
                UI_temp(fIdx).timeLines = cell(1, app.MAX_TABS);
                UI_temp(fIdx).timeMarkers = cell(1, app.MAX_TABS);
                UI_temp(fIdx).plotData = cell(1, app.MAX_TABS);
                UI_temp(fIdx).xLimListeners = cell(1, app.MAX_TABS);

                % --- (f)(g) Col 5: H↔I splitter, Col 6: Video 패널 [V3.15 6행 레이아웃 + VirtualDub 그룹 응집] ---
                %   Row 1 (32px) : AVI 파일 열기 버튼 + 동기 상태 라벨
                %   Row 2 (32px) : Frame No 입력 ↔ Time 입력 + 동기 버튼 (단순화)
                %   Row 3 (1x)   : 영상 표시 영역
                %   Row 4 (~120px) : ▶ Frame Navigator 그룹 패널 (라벨+슬라이더+버튼+별표 axes)
                %   Row 5 (32px) : Video Hz / Data Hz 입력 + Cache 드롭다운
                % [PATCH UX-3] H↔I 경계 splitter (Col 5)
                UI_temp(fIdx).hiSplitter = uipanel(UI_temp(fIdx).dataGrid, ...
                    'BackgroundColor', [0.75 0.75 0.80], 'BorderType', 'line', ...
                    'BorderColor', [0.45 0.45 0.55], ...
                    'Tooltip', '드래그하여 비디오 패널 너비 조절 (H ↔ I)', ...
                    'HitTest', 'on');
                UI_temp(fIdx).hiSplitter.Layout.Column = 5;
                UI_temp(fIdx).hiSplitter.ButtonDownFcn = @(~,~) app.startHISplitterDrag(fIdx);

                UI_temp(fIdx).panelVideo = uipanel(UI_temp(fIdx).dataGrid, 'Title', 'I: AVI Video Player', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', 'w');
                UI_temp(fIdx).panelVideo.Layout.Column = 6;
                % 영상 표시 우선: 제어 기능은 별도 다이얼로그로 분리
                iGrid2 = uigridlayout(UI_temp(fIdx).panelVideo, [2 1]);
                iGrid2.RowHeight = {34, '1x'};
                iGrid2.Padding = [2 2 2 2];
                iGrid2.RowSpacing = 4;

                % Row 1: AVI 파일 열기 + 표시 해상도 + 제어창 버튼 + 동기 상태
                vBtnPnl = uipanel(iGrid2, 'BorderType', 'none', 'BackgroundColor', 'w');
                vBtnPnl.Layout.Row = 1;
                glVB = uigridlayout(vBtnPnl, [1 5], ...
                    'ColumnWidth', {110, 42, 95, 80, '1x'}, ...
                    'Padding', [3 3 3 3], 'ColumnSpacing', 5);
                uibutton(glVB, 'Text', 'AVI 파일 열기', 'FontSize', 11, 'ButtonPushedFcn', @(~,~) app.loadAviFile(fIdx));
                uilabel(glVB, 'Text', '크기:', 'FontSize', 11, 'FontWeight', 'bold');
                UI_temp(fIdx).vidResolutionDropdown = uidropdown(glVB, ...
                    'Items', {'320x240', '640x480', '720x512'}, ...
                    'Value', '720x512', 'FontSize', 11, ...
                    'ValueChangedFcn', @(~,~) app.onVideoResolutionChanged(fIdx));
                UI_temp(fIdx).vidControlBtn = uibutton(glVB, 'Text', '제어창', ...
                    'FontSize', 11, 'ButtonPushedFcn', @(~,~) app.toggleVideoControlDialog(fIdx));
                UI_temp(fIdx).vidSyncStatus = uilabel(glVB, 'Text', '동기 미설정', 'FontSize', 11, ...
                    'FontColor', [0.5 0.5 0.5], 'HorizontalAlignment', 'right');
                UI_temp(fIdx).vidSyncStatus.Layout.Column = 5;

                % Row 2: 고정 표시 해상도 영상 영역(컨테이너 스크롤 가능)
                UI_temp(fIdx).vidContainer = uipanel(iGrid2, 'BorderType', 'none', ...
                    'Scrollable', 'on', 'BackgroundColor', [0.94 0.94 0.94]);
                UI_temp(fIdx).vidContainer.Layout.Row = 2;
                UI_temp(fIdx).vidAxes = uiaxes(UI_temp(fIdx).vidContainer, ...
                    'Units', 'pixels', 'Position', [8 8 720 512]);
                axis(UI_temp(fIdx).vidAxes, 'image');
                axis(UI_temp(fIdx).vidAxes, 'off');
                disableDefaultInteractivity(UI_temp(fIdx).vidAxes);
                UI_temp(fIdx).vidAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).vidImageHandle = image(UI_temp(fIdx).vidAxes, zeros(512,720,3,'uint8'), ...
                    'XData', [1 720], 'YData', [1 512]);
                ctrl = app.createVideoControlDialog(fIdx);
                UI_temp(fIdx).vidControlDialog = ctrl.vidControlDialog;
                UI_temp(fIdx).vidSyncFrameInput = ctrl.vidSyncFrameInput;
                UI_temp(fIdx).vidSyncTimeInput = ctrl.vidSyncTimeInput;
                UI_temp(fIdx).vidSyncBtn = ctrl.vidSyncBtn;
                UI_temp(fIdx).vidVideoFpsInput = ctrl.vidVideoFpsInput;
                UI_temp(fIdx).vidDataFpsInput = ctrl.vidDataFpsInput;
                UI_temp(fIdx).vidCacheBudget = ctrl.vidCacheBudget;
                UI_temp(fIdx).vidVdubSlider = ctrl.vidVdubSlider;
                UI_temp(fIdx).vidVdubLabel = ctrl.vidVdubLabel;
                UI_temp(fIdx).vidFrameAxes = ctrl.vidFrameAxes;
                UI_temp(fIdx).vidFrameXLine = ctrl.vidFrameXLine;
                UI_temp(fIdx).vidFrameMarker = ctrl.vidFrameMarker;

                offUi = app.createBoardOffSummaryPanel(bodyGrid, fIdx);
                UI_temp(fIdx).boardOffPanel = offUi.panel;
                UI_temp(fIdx).boardOffTable = offUi.table;
                UI_temp(fIdx).boardOffTabGroup = offUi.tabGroup;
                UI_temp(fIdx).boardOffPlotTabs = [];
                UI_temp(fIdx).boardOffPlotLayouts = {};
                UI_temp(fIdx).boardOffPlotAxes = cell(1, app.MAX_TABS);
                UI_temp(fIdx).boardOffTimeLines = cell(1, app.MAX_TABS);
                UI_temp(fIdx).boardOffTimeMarkers = cell(1, app.MAX_TABS);
                UI_temp(fIdx).boardOffPlotData = cell(1, app.MAX_TABS);
                UI_temp(fIdx).boardOffSignature = '';
            end

            linkaxes([UI_temp(1).mapAxes, UI_temp(2).mapAxes], 'xy');
            app.UI = UI_temp;

            % [V3.22 #5] UI 평면 struct를 그룹화된 view로 alias - 신규 코드는 그룹 경로 사용
            % 기존 평면 필드(app.UI(fIdx).mapAxes 등)도 그대로 유지 → 100% 호환
            app.buildUIGroups();
        end

        % [V3.22 #5] 평면 UI struct를 그룹화된 view(struct)로 묶어 별도 속성에 저장
        % - app.UIGroup(fIdx).attitude.rollAxes = app.UI(fIdx).rollAxes  (alias)
        % - 새 코드는 app.UIGroup(...) 경로를 권장; 기존 코드는 app.UI(...) 그대로
        % - 핸들 객체이므로 alias가 동일 객체를 가리켜 변경 시 양쪽 모두 동기됨
        function buildUIGroups(app)
            % [V3.22 #5] 평면 UI struct를 그룹화된 view(struct array, 1x2)로 묶음
            % - 핸들 객체이므로 alias가 동일 객체를 가리켜 변경 시 양쪽 모두 동기됨
            UIGroup_temp = struct([]);
            for fIdx = 1:2
                u = app.UI(fIdx);
                grp = struct();

                % 자세(Attitude) 그룹
                grp.attitude = struct( ...
                    'panel',      u.panelAttitude, ...
                    'pitchAxes',  u.pitchAxes,  'pitchLabel', u.pitchLabel, 'hgPitch', u.hgPitch, ...
                    'rollAxes',   u.rollAxes,   'rollLabel',  u.rollLabel,  'hgRoll',  u.hgRoll, ...
                    'hdgAxes',    u.hdgAxes,    'hdgLabel',   u.hdgLabel,   'hgHdg',   u.hgHdg);

                % 지도/고도(MapAlt) 그룹
                grp.map = struct( ...
                    'panel',      u.panelMapAlt, ...
                    'mapAxes',    u.mapAxes, ...
                    'altAxes',    u.altAxes, ...
                    'hMapPath',   u.hMapPath, ...
                    'hgMapPlane', u.hgMapPlane, ...
                    'hAltPath',   u.hAltPath, ...
                    'hAltMarker', u.hAltMarker, ...
                    'timeLine',   u.timeLine, ...
                    'altXLimListener', u.altXLimListener);

                % 비디오 + Frame Navigator 그룹
                grp.video = struct( ...
                    'panel',           u.panelVideo, ...
                    'container',       u.vidContainer, ...
                    'vidAxes',         u.vidAxes, ...
                    'imageHandle',     u.vidImageHandle, ...
                    'resolution',      u.vidResolutionDropdown, ...
                    'controlBtn',      u.vidControlBtn, ...
                    'controlDialog',   u.vidControlDialog, ...
                    'syncFrameInput',  u.vidSyncFrameInput, ...
                    'syncTimeInput',   u.vidSyncTimeInput, ...
                    'syncBtn',         u.vidSyncBtn, ...
                    'syncStatus',      u.vidSyncStatus, ...
                    'videoFpsInput',   u.vidVideoFpsInput, ...
                    'dataFpsInput',    u.vidDataFpsInput, ...
                    'cacheBudget',     u.vidCacheBudget, ...
                    'vdubSlider',      u.vidVdubSlider, ...
                    'vdubLabel',       u.vidVdubLabel, ...
                    'frameAxes',       u.vidFrameAxes, ...
                    'frameXLine',      u.vidFrameXLine, ...
                    'frameMarker',     u.vidFrameMarker);

                % 플롯(H 영역) 그룹 - cell array는 struct() ctor 회피
                grpPlots = struct();
                grpPlots.tabGroup       = u.tabGroup;
                grpPlots.plotTabs       = u.plotTabs;
                grpPlots.plotLayouts    = u.plotLayouts;
                grpPlots.plotAxes       = u.plotAxes;
                grpPlots.timeLines      = u.timeLines;
                grpPlots.timeMarkers    = u.timeMarkers;
                grpPlots.plotData       = u.plotData;
                grpPlots.xLimListeners  = u.xLimListeners;
                grp.plots = grpPlots;

                % 컨트롤 헤더 그룹
                grp.controls = struct( ...
                    'spinner',          u.spinner, ...
                    'currentTimeLabel', u.currentTimeLabel, ...
                    'fileNameLabel',    u.fileNameLabel, ...
                    'btnAtt',           u.btnAtt, ...
                    'btnMap',           u.btnMap, ...
                    'btnVid',           u.btnVid);

                % 데이터 테이블 + 컨테이너
                grp.data = struct( ...
                    'panel',     u.panel, ...
                    'dataTable', u.dataTable, ...
                    'dataGrid',  u.dataGrid);

                if isempty(UIGroup_temp)
                    UIGroup_temp = grp;
                else
                    UIGroup_temp(fIdx) = grp;
                end
            end
            app.UIGroup = UIGroup_temp;
        end

        % [V3.22 #7] 메인 윈도우 상단 헤더 바 (파일 선택 / Debug / Sync 입력)
        % - createLayout에서 분리하여 헤더 영역 변경이 메인 빌더에 영향 없도록 함
        function buildHeaderBar(app, mainLayout)
            hHeaderPanel = uipanel(mainLayout, 'BackgroundColor', 'w', 'BorderType', 'none');
            glHeader = uigridlayout(hHeaderPanel, [1 12]);
            glHeader.ColumnWidth = {140, 140, 140, 110, 110, '1x', 80, 150, 150, 72, 80, 110};
            glHeader.RowHeight = {'fit'};
            glHeader.Padding = [5 5 5 5];
            glHeader.ColumnSpacing = 5;

            uibutton(glHeader, 'Text', '비행경로 1 선택', 'BackgroundColor', [0.15 0.38 0.82], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleFlightFile(1));
            uibutton(glHeader, 'Text', '비행경로 2 선택', 'BackgroundColor', [0.31 0.27 0.90], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleFlightFile(2));
            uibutton(glHeader, 'Text', '해안선 정보', 'BackgroundColor', [0.06 0.65 0.50], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleCoastFile());
            app.BoardToggleButtons = gobjects(1, 2);
            app.BoardToggleButtons(1) = uibutton(glHeader, 'Text', '상단 보드 off', ...
                'BackgroundColor', [0.18 0.18 0.22], 'FontColor', 'w', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) app.toggleBoardVisibility(1));
            app.BoardToggleButtons(2) = uibutton(glHeader, 'Text', '하단 보드 off', ...
                'BackgroundColor', [0.18 0.18 0.22], 'FontColor', 'w', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) app.toggleBoardVisibility(2));
            uilabel(glHeader, 'Text', '');

            % [V3.15 항목 5-3] DebugMode GUI 체크박스
            uicheckbox(glHeader, 'Text', 'Debug', 'Value', false, ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'Tooltip', 'XLim 변경, 캐시 변동 등 디버그 로그를 콘솔에 출력', ...
                'ValueChangedFcn', @(src,~) app.toggleDebugMode(src.Value));

            app.SyncInput = uieditfield(glHeader, 'text', 'Value', '', 'Tooltip', 'ex: 23.4, 34.4', 'FontSize', 13);
            app.SyncBtn = uibutton(glHeader, 'Text', '비행시간 동기', 'BackgroundColor', [0.58 0.0 0.83], 'FontColor', 'w', ...
                               'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.toggleSync());
            app.WindowMinBtn = uibutton(glHeader, 'Text', '최소화', ...
                'FontSize', 12, 'ButtonPushedFcn', @(~, ~) app.minimizeWindow());
            app.WindowMaxBtn = uibutton(glHeader, 'Text', '최대화', ...
                'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.toggleMaximizeWindow());

            % [Audit fix #1] Entry point to the modeless settings/edit dialog.
            try
                uibutton(glHeader, 'Text', '⚙ 설정/편집', ...
                    'BackgroundColor', [0.20 0.20 0.25], 'FontColor', 'w', ...
                    'FontSize', 12, 'FontWeight', 'bold', ...
                    'Tooltip', 'Project/Files/Sync/Options/Plot Manager/Export 편집기 열기', ...
                    'ButtonPushedFcn', @(~,~) app.openEditDialog());
            catch ME_silent
                app.logCaught(ME_silent, 'buildHeaderBar:edit-button');
            end
            app.updateBoardToggleButtons();
        end

        function [ax, lbl] = createGaugePanel(~, parentPnl, titleStr)
            grid = uigridlayout(parentPnl, [2 1]);
            grid.RowHeight = {20, '1x'};
            grid.Padding = [0 0 0 0];
            grid.RowSpacing = 0;

            lbl = uilabel(grid, 'Text', [titleStr ' +0.000'], 'FontWeight', 'bold', 'FontSize', 12, 'HorizontalAlignment', 'center');
            axPnl = uipanel(grid, 'BorderType', 'none', 'BackgroundColor', 'w');

            axGrid = uigridlayout(axPnl, [1 1], 'Padding', [0 0 0 0]);
            ax = uiaxes(axGrid);
            set(ax, 'XTick', [], 'YTick', [], 'XColor', 'none', 'YColor', 'none', 'Color', 'none');
            ax.Toolbar.Visible = 'off';
            disableDefaultInteractivity(ax);

            hold(ax, 'on');
            ax.DataAspectRatio = [1 1 1];
            ax.PlotBoxAspectRatio = [1 1 1];
            axis(ax, [-1.35 1.35 -1.35 1.35]);
            axis(ax, 'off');
        end
    end

    % =========================================================================
    % [Phase 1] Project state model + JSON .fdproj I/O
    % - createDefaultProjectState / collectCurrentProjectState / applyProjectState
    % - loadProjectFile / saveProjectFile / saveProjectAutosave
    % - normalizeProjectPaths / migrateProjectState (D7)
    % - markProjectDirtyAndScheduleRefresh / applyPendingDialogChanges (D2)
    % =========================================================================
    methods (Access = private)
        function st = createDefaultProjectState(app)
            % Skeleton matching design §4. Phases 2-6 fill PlotConfig / FlightSync details.
            flightTpl = struct( ...
                'Name', '', 'DataFile', '', 'AviFile', '', 'OptionFile', '', ...
                'VideoResolution', '', ...
                'VideoSync', struct('IsSynced', false, 'AnchorFrame', 0, ...
                                    'AnchorTime', 0, 'VideoFps', 70, 'DataFps', 50));
            st = struct( ...
                'Version',     app.ProjectFileVersion, ...
                'SavedAt',     '', ...
                'PathMode',    'absolute', ...
                'Flights',     [flightTpl, flightTpl], ...
                'FlightSync',  struct('IsSynced', false, 'SyncT1', 0, 'SyncT2', 0), ...
                'ProjectSettings', struct('ConfirmOnClose', true, 'AutosaveEnabled', true), ...
                'PlotConfig',  struct(), ...
                'UiState',     struct('WindowPosition', [], 'EditDialogPosition', [], 'ActiveTab', 'Project'), ...
                'AuxFiles',    {{}});
            for i = 1:2
                st.Flights(i).Name = sprintf('Flight %d', i);
            end
        end

        function st = collectCurrentProjectState(app)
            % Snapshot the live runtime into a .fdproj-shaped struct.
            st = app.createDefaultProjectState();
            try
                st.SavedAt = char(datetime('now','TimeZone','local','Format','yyyy-MM-dd''T''HH:mm:ssXXX'));
            catch
                st.SavedAt = char(datetime('now','Format','yyyy-MM-dd HH:mm:ss'));
            end
            for fIdx = 1:2
                try
                    m = app.Models(fIdx);
                    st.Flights(fIdx).Name       = sprintf('Flight %d', fIdx);
                    st.Flights(fIdx).DataFile   = app.normalizeAbsPath(m.dataFilePath);
                    st.Flights(fIdx).AviFile    = app.normalizeAbsPath(m.aviFilePath);
                    st.Flights(fIdx).OptionFile = app.normalizeAbsPath(m.optionFilePath);
                    vss = app.VideoSyncState(fIdx);
                    st.Flights(fIdx).VideoSync = struct( ...
                        'IsSynced',    logical(vss.IsSynced), ...
                        'AnchorFrame', double(vss.AnchorFrame), ...
                        'AnchorTime',  double(vss.AnchorTime), ...
                        'VideoFps',    double(vss.VideoFps), ...
                        'DataFps',     double(vss.DataFps));
                    if ~isempty(app.UI) && numel(app.UI) >= fIdx ...
                            && isfield(app.UI(fIdx), 'videoResLabel') ...
                            && ~isempty(app.UI(fIdx).videoResLabel) && isvalid(app.UI(fIdx).videoResLabel)
                        st.Flights(fIdx).VideoResolution = char(app.UI(fIdx).videoResLabel.Text);
                    end
                catch ME
                    app.logCaught(ME, 'collectCurrentProjectState:flight');
                end
            end
            try
                st.FlightSync = struct( ...
                    'IsSynced', logical(app.SyncState.IsSynced), ...
                    'SyncT1',   double(app.SyncState.SyncT1), ...
                    'SyncT2',   double(app.SyncState.SyncT2));
            catch ME
                app.logCaught(ME, 'collectCurrentProjectState:flight-sync');
            end
            try
                st.ProjectSettings = struct( ...
                    'ConfirmOnClose', logical(app.ProjectConfirmOnClose), ...
                    'AutosaveEnabled', logical(app.ProjectAutosaveEnabled));
            catch ME
                app.logCaught(ME, 'collectCurrentProjectState:settings');
            end
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    st.UiState.WindowPosition = app.UIFigure.Position;
                end
            catch ME
                app.logCaught(ME, 'collectCurrentProjectState:window-position');
            end
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    st.UiState.EditDialogPosition = app.EditDialog.Position;
                end
            catch ME
                app.logCaught(ME, 'collectCurrentProjectState:edit-dialog-position');
            end
            % Phase 4 will populate PlotConfig; preserve any cached structure for now.
            if ~isempty(app.PlotConfigState)
                st.PlotConfig = app.PlotConfigState;
            end
        end

        function applyProjectState(app, st, ~)
            % Apply a loaded .fdproj-shaped struct to runtime state.
            if isempty(st), return; end
            st = app.migrateProjectState(st);
            try
                if isfield(st, 'FlightSync') && ~isempty(st.FlightSync)
                    app.SyncState.IsSynced = logical(st.FlightSync.IsSynced);
                    app.SyncState.SyncT1   = double(st.FlightSync.SyncT1);
                    app.SyncState.SyncT2   = double(st.FlightSync.SyncT2);
                end
            catch ME
                app.logCaught(ME, 'applyProjectStateToApp:flight-sync');
            end
            if isfield(st, 'Flights')
                for fIdx = 1:min(numel(st.Flights), 2)
                    try
                        f = st.Flights(fIdx);
                        if isfield(f, 'DataFile'),   app.Models(fIdx).dataFilePath   = char(f.DataFile);   end
                        if isfield(f, 'AviFile'),    app.Models(fIdx).aviFilePath    = char(f.AviFile);    end
                        if isfield(f, 'OptionFile'), app.Models(fIdx).optionFilePath = char(f.OptionFile); end
                        if isfield(f, 'VideoSync') && ~isempty(f.VideoSync)
                            vs = f.VideoSync;
                            app.VideoSyncState(fIdx).IsSynced    = logical(vs.IsSynced);
                            app.VideoSyncState(fIdx).AnchorFrame = double(vs.AnchorFrame);
                            app.VideoSyncState(fIdx).AnchorTime  = double(vs.AnchorTime);
                            app.VideoSyncState(fIdx).VideoFps    = double(vs.VideoFps);
                            app.VideoSyncState(fIdx).DataFps     = double(vs.DataFps);
                        end
                    catch ME
                        app.logCaught(ME, 'applyProjectStateToApp:video-sync');
                    end
                end
            end
            if isfield(st, 'ProjectSettings') && ~isempty(st.ProjectSettings)
                try
                    ps = st.ProjectSettings;
                    if isfield(ps, 'ConfirmOnClose')
                        app.ProjectConfirmOnClose = logical(ps.ConfirmOnClose);
                    end
                    if isfield(ps, 'AutosaveEnabled')
                        app.ProjectAutosaveEnabled = logical(ps.AutosaveEnabled);
                    end
                catch ME
                    app.logCaught(ME, 'applyProjectStateToApp:settings');
                end
            end
            if isfield(st, 'UiState')
                try
                    if isfield(st.UiState, 'WindowPosition') && ~isempty(st.UiState.WindowPosition) ...
                            && ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                        app.UIFigure.Position = st.UiState.WindowPosition;
                    end
                catch ME
                    app.logCaught(ME, 'applyProjectStateToApp:window-position');
                end
            end
            if isfield(st, 'PlotConfig')
                app.PlotConfigState = st.PlotConfig;
            end
            app.ProjectState = st;
            % [Medium 1] dirty=false 는 caller 가 file load 까지 완료한 후에만 의미가 있음.
            % autoLoadProjectFromFile 은 이후 loadCompletedCleanly 플래그로 다시 결정함.
            % 직접 호출(예: 외부 import) 시에도 caller 가 후속 결정을 내려야 한다.
            app.ProjectDirty = false;
            % [Review High #3] Edit Dialog 가 열려 있으면 모든 탭의 표시 값을 새 project
            % 상태로 즉시 재동기화 — Sync / Plot / Files / Options 라벨이 stale 로 남지 않음.
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    app.refreshEditDialog();
                end
            catch ME, app.logCaught(ME, 'applyProjectState:refresh'); end
        end

        function st = migrateProjectState(app, st)
            % [D7] in-memory migration entry point. v1->v1 passthrough; future versions extend switch.
            if isempty(st), return; end
            if ~isfield(st, 'Version') || isempty(st.Version)
                st.Version = 1;
            end
            switch double(st.Version)
                case 1
                    % v1 schema matches createDefaultProjectState; nothing to migrate.
                otherwise
                    msg = sprintf('알 수 없는 project version: %g (지원=%d)', double(st.Version), app.ProjectFileVersion);
                    try
                        uialert(app.UIFigure, msg, 'Project version');
                    catch
                        warning('%s', msg);
                    end
                    error('FlightDataDashboard:UnsupportedProjectVersion', '%s', msg);
            end
        end

        function st = loadProjectFile(app, filePath)
            % Read and validate a .fdproj file. Caller decides whether to applyProjectState.
            % [D-02] If <filePath>.autosave.json exists and is newer than filePath,
            % prompt user: restore autosave / use original / cancel.
            st = [];
            if nargin < 2 || isempty(filePath) || ~isfile(filePath), return; end
            [resolvedPath, cancelled] = app.resolveAutosaveChoice(filePath);
            if cancelled, return; end
            try
                txt = fileread(resolvedPath);
                st  = jsondecode(txt);
                st  = app.migrateProjectState(st);
                if isfield(st, 'SavedAt') && ~isempty(st.SavedAt)
                    app.ProjectLastSaveText = char(st.SavedAt);
                else
                    app.ProjectLastSaveText = '';
                end
                % Bind ProjectFilePath to the canonical project (not the autosave) so
                % subsequent saveProjectFile overwrites the user-facing file.
                app.ProjectFilePath = app.normalizeAbsPath(filePath);
                if ~strcmp(resolvedPath, filePath)
                    % [D-02] mark dirty so the recovered state is persisted on next save.
                    app.ProjectDirty = true;
                end
            catch ME
                app.logCaught(ME, 'project-load');
                try
                    uialert(app.UIFigure, sprintf('project 파일 로드 실패:\n%s', ME.message), 'Project');
                catch
                end
                st = [];
            end
        end

        function [chosenPath, cancelled] = resolveAutosaveChoice(app, filePath)
            % [D-02] Detect <filePath>.autosave.json and ask the user which to load.
            chosenPath = filePath;
            cancelled  = false;
            try
                autoPath = [filePath '.autosave.json'];
                if ~isfile(autoPath), return; end
                autoInfo = dir(autoPath);
                mainInfo = dir(filePath);
                if isempty(autoInfo) || isempty(mainInfo), return; end
                if autoInfo(1).datenum <= mainInfo(1).datenum
                    % autosave older than current project; safe to ignore
                    try
                        delete(autoPath);
                    catch
                    end
                    return;
                end
                msg = sprintf(['이전 세션이 정상 종료되지 않아 자동 백업이 남아 있습니다.\n\n', ...
                               '자동 백업: %s\n원본 project: %s\n\n', ...
                               '자동 백업을 사용하면 마지막 저장 이후의 편집을 복구할 수 있습니다.'], ...
                              char(autoInfo(1).date), char(mainInfo(1).date));
                sel = '';
                try
                    sel = uiconfirm(app.UIFigure, msg, 'Project 복구', ...
                        'Options', {'자동 백업 복구', '원본 사용', '취소'}, ...
                        'DefaultOption', 1, 'CancelOption', 3);
                catch
                    sel = '원본 사용';
                end
                switch sel
                    case '자동 백업 복구'
                        chosenPath = autoPath;
                    case '취소'
                        cancelled = true;
                    otherwise
                        % keep chosenPath = filePath; remove stale autosave
                        try
                            delete(autoPath);
                        catch
                        end
                end
            catch ME
                app.logCaught(ME, 'autosave-detect');
            end
        end

        function ok = writeTextFileAtomic(app, targetPath, txt, logTag)
            ok = false;
            if nargin < 4 || isempty(logTag), logTag = 'atomic-write'; end
            if isempty(targetPath), return; end
            txt = char(txt);
            tmp = [targetPath '.tmp'];
            fid = -1;
            try
                fid = fopen(tmp, 'w');
                if fid < 0
                    error('FlightDataDashboard:AtomicOpen', '임시 파일 열기 실패: %s', tmp);
                end
                written = fwrite(fid, txt, 'char');
                if written ~= numel(txt)
                    error('FlightDataDashboard:AtomicWriteShort', ...
                        '파일 쓰기 불완전: %s (%d/%d)', tmp, written, numel(txt));
                end
                closeStatus = fclose(fid);
                fid = -1;
                if closeStatus ~= 0
                    error('FlightDataDashboard:AtomicClose', '파일 닫기 실패: %s', tmp);
                end
                if isfile(targetPath)
                    try
                        [bakOk, bakMsg, bakId] = copyfile(targetPath, [targetPath '.bak'], 'f');
                        if ~bakOk
                            if isempty(bakId), bakId = 'FlightDataDashboard:BackupCopy'; end
                            app.logCaught(MException(bakId, 'backup 실패: %s', bakMsg), [logTag ':backup']);
                        end
                    catch ME_bak
                        app.logCaught(ME_bak, [logTag ':backup']);
                    end
                end
                [moveOk, moveMsg, moveId] = movefile(tmp, targetPath, 'f');
                if ~moveOk
                    if isempty(moveId), moveId = 'FlightDataDashboard:AtomicMove'; end
                    error(moveId, 'movefile 실패: %s', moveMsg);
                end
                ok = true;
            catch ME
                if fid > 0
                    try
                        fclose(fid);
                    catch
                    end
                end
                try
                    if isfile(tmp), delete(tmp); end
                catch ME_del
                    app.logCaught(ME_del, [logTag ':tmp-cleanup']);
                end
                rethrow(ME);
            end
        end

        function ok = saveProjectFile(app, filePath)
            % Atomic write: temp file + movefile + .bak of previous.
            ok = false;
            if nargin < 2 || isempty(filePath)
                filePath = app.ProjectFilePath;
            end
            if isempty(filePath), return; end
            try
                % [P4] capture live plot UI state right before persistence so the saved
                % project reflects current XLim/YLim/YLimMode without losing YColumn.
                try
                    app.capturePlotConfigFromUi();
                catch ME
                    app.logCaught(ME, 'saveProjectToFile:plot-capture');
                end
                st  = app.collectCurrentProjectState();
                txt = jsonencode(st, 'PrettyPrint', true);
                if ~app.writeTextFileAtomic(filePath, txt, 'project-save')
                    return;
                end
                app.ProjectFilePath = app.normalizeAbsPath(filePath);
                app.ProjectState    = st;
                app.ProjectDirty    = false;
                try
                    app.ProjectLastSaveText = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
                catch
                    app.ProjectLastSaveText = char(st.SavedAt);
                end
                app.clearProjectAutosave();
                ok = true;
            catch ME
                app.logCaught(ME, 'project-save');
                try
                    uialert(app.UIFigure, sprintf('project 저장 실패:\n%s', ME.message), 'Project');
                catch
                end
            end
        end

        function saveProjectAutosave(app)
            % [D2] crash-safe snapshot while edits are dirty. Lives next to project file or in tempdir.
            try
                if ~app.ProjectDirty, return; end
                if isempty(app.ProjectFilePath)
                    base = fullfile(tempdir, 'FlightDashboard.fdproj');
                else
                    base = app.ProjectFilePath;
                end
                autoPath = [base '.autosave.json'];
                % [P4] autosave the live plot UI state too.
                try
                    app.capturePlotConfigFromUi();
                catch ME_pc
                    app.logCaught(ME_pc, 'autosaveProject:plot-capture');
                end
                st  = app.collectCurrentProjectState();
                txt = jsonencode(st, 'PrettyPrint', true);
                app.writeTextFileAtomic(autoPath, txt, 'project-autosave');
            catch ME
                app.logCaught(ME, 'project-autosave');
            end
        end

        function clearProjectAutosave(app)
            try
                if isempty(app.ProjectFilePath), return; end
                autoPath = [app.ProjectFilePath '.autosave.json'];
                if isfile(autoPath), delete(autoPath); end
            catch ME
                app.logCaught(ME, 'clearProjectAutosave');
            end
        end

        function out = normalizeAbsPath(~, p)
            % Convert to absolute form when the file exists; otherwise return as-is.
            out = char(p);
            if isempty(out), return; end
            try
                jf = java.io.File(out);
                if jf.isAbsolute()
                    out = char(jf.getCanonicalPath());
                else
                    out = char(java.io.File(fullfile(pwd, out)).getCanonicalPath());
                end
            catch
                % fallback: use what(p) when file exists, else leave as-is
                try
                    if isfile(out)
                        info = dir(out);
                        out  = fullfile(info(1).folder, info(1).name);
                    end
                catch
                end
            end
        end

        function st = normalizeProjectPaths(app, st)
            % Used by Export (Phase 6) to rewrite paths to a new folder. Default: absolute normalize.
            if isempty(st), return; end
            if isfield(st, 'Flights')
                for i = 1:numel(st.Flights)
                    st.Flights(i).DataFile   = app.normalizeAbsPath(st.Flights(i).DataFile);
                    st.Flights(i).AviFile    = app.normalizeAbsPath(st.Flights(i).AviFile);
                    st.Flights(i).OptionFile = app.normalizeAbsPath(st.Flights(i).OptionFile);
                end
            end
            if isfield(st, 'AuxFiles') && iscell(st.AuxFiles)
                for i = 1:numel(st.AuxFiles)
                    st.AuxFiles{i} = app.normalizeAbsPath(st.AuxFiles{i});
                end
            end
        end

        function markProjectDirtyAndScheduleRefresh(app, ~)
            % [D2] mark dirty + (re)start single-shot debounce timer.
            app.ProjectDirty = true;
            try
                if isempty(app.EditApplyTimer) || ~isvalid(app.EditApplyTimer)
                    app.EditApplyTimer = timer( ...
                        'ExecutionMode', 'singleShot', ...
                        'StartDelay', app.EditApplyDelaySec, ...
                        'TimerFcn', @(~,~) app.applyPendingDialogChanges());
                else
                    if strcmpi(app.EditApplyTimer.Running, 'on'), stop(app.EditApplyTimer); end
                    app.EditApplyTimer.StartDelay = app.EditApplyDelaySec;
                end
                start(app.EditApplyTimer);
            catch ME
                app.logCaught(ME, 'project-dirty:edit-apply-timer');
            end
            try
                if app.ProjectAutosaveEnabled && (isempty(app.AutosaveTimer) || ~isvalid(app.AutosaveTimer))
                    app.AutosaveTimer = timer( ...
                        'ExecutionMode', 'fixedSpacing', ...
                        'Period', app.AutosaveIntervalSec, ...
                        'StartDelay', app.AutosaveIntervalSec, ...
                        'TimerFcn', @(~,~) app.saveProjectAutosave());
                    start(app.AutosaveTimer);
                end
            catch ME
                app.logCaught(ME, 'project-dirty:autosave-timer');
            end
        end

        function applyPendingDialogChanges(app)
            % Default applier: refresh data UI for any flights with loaded data.
            % Phases 2-4 extend this with option/sync/plot specific re-applies.
            try
                for fIdx = 1:2
                    try
                        if ~isempty(app.Models(fIdx).rawData) && height(app.Models(fIdx).rawData) > 0
                            app.setupDataUI(fIdx);
                            app.refreshSyncUi(fIdx);
                        end
                    catch ME
                        app.logCaught(ME, 'apply-pending-dialog:flight-refresh');
                    end
                end
                app.LastEditApplyTime = datetime('now');
                % [Audit fix #1] keep dialog status/values in sync after debounce fires
                try
                    app.refreshEditDialog();
                catch ME
                    app.logCaught(ME, 'apply-pending-dialog:refresh-edit-dialog');
                end
            catch ME
                app.logCaught(ME, 'apply-pending-dialog');
            end
        end

        % =================================================================
        % [Phase 3] Programmatic sync setters (consumed by future Sync tab).
        % These reuse the existing UI refresh paths so the main window stays
        % consistent regardless of who initiated the change.
        % =================================================================
        function setFlightDataSync(app, syncT1, syncT2, enabled)
            if nargin < 4, enabled = true; end
            if ~enabled
                app.SyncState.IsSynced = false;
                try
                    if ~isempty(app.SyncBtn) && isvalid(app.SyncBtn)
                        app.SyncBtn.Text = '비행시간 동기';
                        app.SyncBtn.BackgroundColor = [0.58 0.0 0.83];
                    end
                    if ~isempty(app.SyncInput) && isvalid(app.SyncInput)
                        app.SyncInput.Enable = 'on';
                    end
                    if numel(app.UI) >= 2 && isfield(app.UI(2), 'spinner') ...
                            && ~isempty(app.UI(2).spinner) && isvalid(app.UI(2).spinner) ...
                            && ~isempty(app.Models(2).rawData)
                        app.UI(2).spinner.Enable = 'on';
                    end
                catch ME
                    app.logCaught(ME, 'flight-sync-off:update-ui');
                end
                app.markProjectDirtyAndScheduleRefresh('flight-sync-off');
                return;
            end
            if isempty(app.Models(1).rawData) || isempty(app.Models(2).rawData)
                try
                    uialert(app.UIFigure, '두 경로 데이터가 모두 로드되어야 합니다.', 'Sync');
                catch
                end
                return;
            end
            app.SyncState.SyncT1   = double(syncT1);
            app.SyncState.SyncT2   = double(syncT2);
            app.SyncState.IsSynced = true;
            try
                if ~isempty(app.SyncBtn) && isvalid(app.SyncBtn)
                    app.SyncBtn.Text = '비행시간 동기 해제';
                    app.SyncBtn.BackgroundColor = [0.8 0.2 0.2];
                end
                if ~isempty(app.SyncInput) && isvalid(app.SyncInput)
                    app.SyncInput.Value  = sprintf('%g, %g', syncT1, syncT2);
                    app.SyncInput.Enable = 'off';
                end
                if numel(app.UI) >= 2 && isfield(app.UI(2), 'spinner') ...
                        && ~isempty(app.UI(2).spinner) && isvalid(app.UI(2).spinner)
                    app.UI(2).spinner.Enable = 'off';
                end
            catch ME
                app.logCaught(ME, 'setFlightDataSync:disable-spinner');
            end
            try
                timeCol1 = app.Models(1).mappedCols.Time;
                idx1 = app.findClosestIndexByTime(app.Models(1).rawData.(timeCol1), syncT1);
                app.applyTimeChange(1, idx1);
            catch ME
                app.logCaught(ME, 'setFlightDataSync:apply-time');
            end
            app.markProjectDirtyAndScheduleRefresh('flight-sync-on');
        end

        function setVideoSync(app, fIdx, anchorFrame, anchorTime, videoFps, dataFps, enabled)
            if nargin < 7, enabled = true; end
            if ~enabled
                app.resetVideoSync(fIdx);
                app.markProjectDirtyAndScheduleRefresh('video-sync-off');
                return;
            end
            if isempty(app.VideoState(fIdx).videoReader)
                try
                    uialert(app.UIFigure, '먼저 AVI 파일을 로드하세요.', 'Sync');
                catch
                end
                return;
            end
            if isempty(app.Models(fIdx).rawData)
                try
                    uialert(app.UIFigure, '먼저 비행데이터를 로드하세요.', 'Sync');
                catch
                end
                return;
            end
            if ~isnumeric(videoFps) || videoFps < 1 || ~isnumeric(dataFps) || dataFps < 1
                try
                    uialert(app.UIFigure, 'Hz 값은 1 이상이어야 합니다.', 'Sync');
                catch
                end
                return;
            end
            totalFrames = app.VideoSyncState(fIdx).TotalFrames;
            if anchorFrame < 1 || (totalFrames > 0 && anchorFrame > totalFrames)
                try
                    uialert(app.UIFigure, sprintf('Frame은 1~%d 범위여야 합니다.', totalFrames), 'Sync');
                catch
                end
                return;
            end
            app.VideoSyncState(fIdx).AnchorFrame = double(anchorFrame);
            app.VideoSyncState(fIdx).AnchorTime  = double(anchorTime);
            app.VideoSyncState(fIdx).VideoFps    = double(videoFps);
            app.VideoSyncState(fIdx).DataFps     = double(dataFps);
            app.VideoSyncState(fIdx).IsSynced    = true;
            % Push the same Hz/anchor values into the live spinners if present.
            try
                if isfield(app.UI(fIdx), 'vidSyncFrameInput') && ~isempty(app.UI(fIdx).vidSyncFrameInput) ...
                        && isvalid(app.UI(fIdx).vidSyncFrameInput)
                    app.UI(fIdx).vidSyncFrameInput.Value = double(anchorFrame);
                end
                if isfield(app.UI(fIdx), 'vidSyncTimeInput') && ~isempty(app.UI(fIdx).vidSyncTimeInput) ...
                        && isvalid(app.UI(fIdx).vidSyncTimeInput)
                    app.UI(fIdx).vidSyncTimeInput.Value = double(anchorTime);
                end
                if isfield(app.UI(fIdx), 'vidVideoFpsInput') && ~isempty(app.UI(fIdx).vidVideoFpsInput) ...
                        && isvalid(app.UI(fIdx).vidVideoFpsInput)
                    app.UI(fIdx).vidVideoFpsInput.Value = double(videoFps);
                end
                if isfield(app.UI(fIdx), 'vidDataFpsInput') && ~isempty(app.UI(fIdx).vidDataFpsInput) ...
                        && isvalid(app.UI(fIdx).vidDataFpsInput)
                    app.UI(fIdx).vidDataFpsInput.Value = double(dataFps);
                end
                if isfield(app.UI(fIdx), 'vidSyncBtn') && ~isempty(app.UI(fIdx).vidSyncBtn) ...
                        && isvalid(app.UI(fIdx).vidSyncBtn)
                    app.UI(fIdx).vidSyncBtn.Text = '동기 해제';
                    app.UI(fIdx).vidSyncBtn.BackgroundColor = [0.8 0.2 0.2];
                end
                if isfield(app.UI(fIdx), 'vidSyncStatus') && ~isempty(app.UI(fIdx).vidSyncStatus) ...
                        && isvalid(app.UI(fIdx).vidSyncStatus)
                    app.UI(fIdx).vidSyncStatus.Text = sprintf('동기 완료 (frame %d ↔ %.3fs)', ...
                        double(anchorFrame), double(anchorTime));
                    app.UI(fIdx).vidSyncStatus.FontColor = [0.0 0.5 0.0];
                end
            catch ME
                app.logCaught(ME, 'setVideoSync:status');
            end
            app.refreshSyncUi(fIdx);
            app.markProjectDirtyAndScheduleRefresh('video-sync-on');
        end

        function refreshSyncUi(app, fIdx)
            % Push current VideoSyncState into spinners/labels without firing callbacks.
            try
                vss = app.VideoSyncState(fIdx);
                if isfield(app.UI(fIdx), 'vidVideoFpsInput') && ~isempty(app.UI(fIdx).vidVideoFpsInput) ...
                        && isvalid(app.UI(fIdx).vidVideoFpsInput) && vss.VideoFps > 0
                    if app.UI(fIdx).vidVideoFpsInput.Value ~= vss.VideoFps
                        app.UI(fIdx).vidVideoFpsInput.Value = vss.VideoFps;
                    end
                end
                if isfield(app.UI(fIdx), 'vidDataFpsInput') && ~isempty(app.UI(fIdx).vidDataFpsInput) ...
                        && isvalid(app.UI(fIdx).vidDataFpsInput) && vss.DataFps > 0
                    if app.UI(fIdx).vidDataFpsInput.Value ~= vss.DataFps
                        app.UI(fIdx).vidDataFpsInput.Value = vss.DataFps;
                    end
                end
                if isfield(app.UI(fIdx), 'vidSyncStatus') && ~isempty(app.UI(fIdx).vidSyncStatus) ...
                        && isvalid(app.UI(fIdx).vidSyncStatus)
                    if vss.IsSynced
                        app.UI(fIdx).vidSyncStatus.Text = sprintf('동기 완료 (frame %d ↔ %.3fs)', ...
                            double(vss.AnchorFrame), double(vss.AnchorTime));
                        app.UI(fIdx).vidSyncStatus.FontColor = [0.0 0.5 0.0];
                    else
                        app.UI(fIdx).vidSyncStatus.Text = '동기 미설정';
                        app.UI(fIdx).vidSyncStatus.FontColor = [0.5 0.5 0.5];
                    end
                end
            catch ME
                app.logCaught(ME, 'clearVideoSync:status');
            end
        end
    end

    % =========================================================================
    % [V3.22 #6] Static wrapper - 외부 함수 호출을 클래스 경유로 추상화
    % - 향후 +flightdash 패키지 분리 시 이 wrapper만 한 줄 수정
    % - 현재는 file-level 외부 함수에 위임 (parfeval은 두 형태 모두 받음)
    % - 사용 권장: parfeval(pool, @FlightDataDashboard.workerDecodeFrame, ...)
    % =========================================================================
    methods (Static, Access = public)
        function img = workerDecodeFrame(filePath, frameNo, fps, maxSlots)
            % 미래 마이그레이션: flightdash.asyncDecodeFramePersistent 로 교체
            if nargin < 4
                img = asyncDecodeFramePersistent(filePath, frameNo, fps);
            else
                img = asyncDecodeFramePersistent(filePath, frameNo, fps, maxSlots);
            end
        end

        function workerCleanupCache()
            % 미래 마이그레이션: flightdash.cleanupAsyncDecodeCache 로 교체
            cleanupAsyncDecodeCache();
        end
    end
end

% =========================================================================
% [V3.19 (1)] 외부 함수: parfeval worker용 비동기 디코딩
% parfeval은 클래스 메서드를 직접 받지 못하므로 file-level function 정의
% worker는 자체 VideoReader를 생성해 디코딩 후 frame 반환
% =========================================================================
% =========================================================================
% [V3.21 #2-A / V3.22 #4] persistent VideoReader worker function
% - 매 호출마다 VR 재생성(50ms) → persistent로 재사용(3ms)
% - 파일 경로 변경 시에만 VR 재생성
% - maxSlots: 호출처에서 전달 (기본 4) - 채널별 VR 독립 보유
% =========================================================================
function out = ternary(cond, ifTrue, ifFalse)
    % Simple ternary helper for UI Enable / mode string toggles.
    if cond, out = ifTrue; else, out = ifFalse; end
end

function i_restoreIsUpdating(app, fIdx, prevValue)
    % [Major 4] onCleanup target — restore IsUpdating(fIdx) even if the body throws.
    try
        if isempty(app) || ~isvalid(app), return; end
        if fIdx >= 1 && fIdx <= numel(app.IsUpdating)
            app.IsUpdating(fIdx) = logical(prevValue);
        end
    catch
    end
end

function img = asyncDecodeFramePersistent(filePath, frameNo, fps, maxSlots)
    % [PATCH] 다중 슬롯 LRU 캐시 (채널별 VR 독립 보유, 파일락/메모리누수 방지)
    persistent cache   % struct array: .path, .sig, .vr, .lastUse
    img = [];
    if nargin < 4 || isempty(maxSlots) || maxSlots < 1
        maxSlots = 4;
    end
    maxSlots = max(1, round(double(maxSlots)));

    % [PATCH] cleanup 분기: 모든 슬롯 VR delete 후 캐시 비우기
    if ischar(filePath) && strcmp(filePath, '__CLEANUP__')
        if ~isempty(cache)
            for k = 1:numel(cache)
                try
                    if ~isempty(cache(k).vr) && isvalid(cache(k).vr)
                        delete(cache(k).vr);
                    end
                catch
                end
            end
        end
        cache = [];
        return;
    end

    try
        fileSig = asyncDecodeFileSignature(filePath);
        if isempty(fileSig), return; end
        if isempty(cache), cache = struct('path',{},'sig',{},'vr',{},'lastUse',{}); end
        if ~isempty(cache) && ~isfield(cache, 'sig')
            for k = 1:numel(cache)
                try
                    if isfield(cache, 'vr') && ~isempty(cache(k).vr) && isvalid(cache(k).vr)
                        delete(cache(k).vr);
                    end
                catch
                end
            end
            cache = struct('path',{},'sig',{},'vr',{},'lastUse',{});
        end

        % Same path can point to a replaced AVI. Drop stale readers before
        % the normal lookup so workers never decode from an old file handle.
        for k = numel(cache):-1:1
            if strcmp(cache(k).path, filePath) && ~strcmp(cache(k).sig, fileSig)
                try
                    if ~isempty(cache(k).vr) && isvalid(cache(k).vr)
                        delete(cache(k).vr);
                    end
                catch
                end
                cache(k) = [];
            end
        end

        % 슬롯 탐색
        idx = 0;
        for k = 1:numel(cache)
            if strcmp(cache(k).path, filePath) && strcmp(cache(k).sig, fileSig) && ...
                    ~isempty(cache(k).vr) && isvalid(cache(k).vr)
                idx = k; break;
            end
        end

        if idx == 0
            % LRU 축출 (꽉 찬 경우 가장 오래된 슬롯 delete)
            if numel(cache) >= maxSlots
                ages = zeros(1, numel(cache));
                for k = 1:numel(cache)
                    if cache(k).lastUse ~= 0
                        ages(k) = toc(cache(k).lastUse);
                    else
                        ages(k) = inf;
                    end
                end
                [~, victim] = max(ages);
                try
                    delete(cache(victim).vr);
                catch
                end
                cache(victim) = [];
            end
            newSlot = struct('path', filePath, 'sig', fileSig, ...
                             'vr', VideoReader(filePath), 'lastUse', uint64(0));
            cache(end+1) = newSlot;
            idx = numel(cache);
        end
        cache(idx).lastUse = tic;
        vr = cache(idx).vr;

        try
            img = read(vr, frameNo);
        catch
            relTime = (frameNo - 1) / max(1, fps);
            relTime = max(0, min(relTime, vr.Duration - 0.05));
            vr.CurrentTime = relTime;
            if hasFrame(vr), img = readFrame(vr); end
        end
    catch
        img = [];
    end
end

function sig = asyncDecodeFileSignature(filePath)
    sig = '';
    try
        if isempty(filePath) || ~isfile(filePath)
            return;
        end
        info = dir(filePath);
        if isempty(info)
            return;
        end
        sig = sprintf('%s|%d|%.17g', char(filePath), info(1).bytes, info(1).datenum);
    catch
        sig = char(filePath);
    end
end

% [PATCH] 워커 persistent 캐시 정리 함수
% - asyncDecodeFramePersistent의 cleanup 분기를 호출하여 모든 VR delete + persistent clear
function cleanupAsyncDecodeCache()
    try
        asyncDecodeFramePersistent('__CLEANUP__', 0, 0);
    catch
    end
    try
        clear asyncDecodeFramePersistent
    catch
    end
end
