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
        LastDisplayedFrame  = [0, 0]        % [PATCH] 동일 프레임 조기 반환용
        HISplitterFIdx      = 0             % [PATCH UX-3] H/I 경계 드래그 중인 채널
        IsDraggingSplitter  = false         % [PATCH UX-3b] splitter 드래그 상태 플래그
        FrameCache          = {{}, {}}      % [V3.13 C-1] 비행경로별 프레임 캐시
        FrameCacheKeys      = {[], []}      % [V3.13 C-1] 비행경로별 캐시 키 순서 (LRU)
        DynamicCacheLimit   = [50, 50]      % [V3.14 항목 3] 비행경로별 동적 계산된 최대 캐시 프레임 수
        CacheBudgetMB       = 30            % [V3.14 항목 3] 비행경로당 캐시 메모리 예산(MB) - GUI에서 조정
        LastSliderUpdate    = {uint64(0), uint64(0)}  % [PATCH] tic 핸들(채널별)
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
        OptionDrafts         = {[], []}        % per-flight option editor draft buffers (Phase 2 fills)
        PlotConfigState      = []              % captured PlotConfig (Phase 4 fills)
        EditDialog           = []              % handle to edit uifigure (modeless)
        EditApplyTimer       = []              % single-shot debounce timer (D2)
        EditApplyDelaySec    = 0.35            % timer StartDelay
        LastEditApplyTime    = NaT              % time of last applyPendingDialogChanges()
        AutosaveTimer        = []              % .fdproj.autosave snapshot timer (D2)
        AutosaveIntervalSec  = 30              % snapshot every N seconds while dirty
        ProjectFileVersion   = 1               % current .fdproj schema version
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

            close(findobj('Type', 'figure', 'Name', '비행 데이터 리뷰 대시보드 (Dual)'));
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end

            app.createLayout();
            try
                app.UIFigure.SizeChangedFcn = @(~,~) app.onFigureSizeChanged();
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
            app.applyResponsiveLayout();

            for i = 1:2
                app.addPlotTab(i);
                app.VideoState(i).vidImageHandle = app.UI(i).vidImageHandle;
            end
        end

        function delete(app)
            % [V3.20 (5)] 명시적 리소스 정리: VideoReader, AsyncPool, futures
            try
                for fIdx = 1:2
                    try
                        if ~isempty(app.UI) && numel(app.UI) >= fIdx && ...
                           isfield(app.UI(fIdx), 'vidControlDialog') && ...
                           ~isempty(app.UI(fIdx).vidControlDialog) && isvalid(app.UI(fIdx).vidControlDialog)
                            delete(app.UI(fIdx).vidControlDialog);
                        end
                    catch ME, app.logCaught(ME, 'silent'); end
                    % VideoReader 정리
                    try
                        if ~isempty(app.VideoState(fIdx).videoReader) && ...
                           isvalid(app.VideoState(fIdx).videoReader)
                            delete(app.VideoState(fIdx).videoReader);
                        end
                    catch ME, app.logCaught(ME, 'silent'); end
                    % 진행 중 비동기 future 취소
                    try
                        if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                            cancel(app.AsyncFutures{fIdx});
                        end
                    catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end

            % [PATCH / V3.22 #6] 워커 persistent VR 명시 해제 → 파일락 즉시 반환
            try
                if ~isempty(app.AsyncPool) && isvalid(app.AsyncPool)
                    parfevalOnAll(app.AsyncPool, @FlightDataDashboard.workerCleanupCache, 0);
                end
            catch ME, app.logCaught(ME, 'silent'); end

            % [Phase 1 D2] stop debounce + autosave timers before tearing down UI
            try
                if ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer)
                    try, stop(app.EditApplyTimer); catch, end %#ok<NOCOM>
                    delete(app.EditApplyTimer);
                    app.EditApplyTimer = [];
                end
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if ~isempty(app.AutosaveTimer) && isvalid(app.AutosaveTimer)
                    try, stop(app.AutosaveTimer); catch, end %#ok<NOCOM>
                    delete(app.AutosaveTimer);
                    app.AutosaveTimer = [];
                end
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    delete(app.EditDialog);
                    app.EditDialog = [];
                end
            catch ME, app.logCaught(ME, 'silent'); end

            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    delete(app.UIFigure);
                end
            catch ME, app.logCaught(ME, 'silent'); end
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
    % 프라이빗 메서드: 파일 로드 및 메인 로직
    % =========================================================================
    methods (Access = private)
        function handleFlightFile(app, fIdx)
            [filename, pathname] = uigetfile('*.csv', sprintf('비행경로 %d 파일 선택', fIdx));
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
            try
                fullpath = fullfile(pathname, filename);
                app.parseFlightData(fIdx, fullpath);

                timeCol = app.Models(fIdx).mappedCols.Time;
                if ~issorted(app.Models(fIdx).rawData.(timeCol), 'strictascend')
                    errordlg('시간 데이터가 순차적으로 증가하지 않거나 중복되었습니다.', '데이터 오류');
                    close(d);
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
                                if isfield(app.UI(fIdx), 'vidDataFpsInput') && isvalid(app.UI(fIdx).vidDataFpsInput)
                                    app.UI(fIdx).vidDataFpsInput.Value = estFps;
                                end
                            end
                        end
                    end
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
                app.setupDataUI(fIdx);

                % [수정 2] 비행 데이터 파싱 후, 이미 영상이 열려있다면 Video FPS 강제 재계산
                if app.VideoSyncState(fIdx).TotalFrames > 0
                    times = app.Models(fIdx).rawData.(timeCol);
                    maxTime = max(times);
                    if maxTime > 0
                        newFps = app.VideoSyncState(fIdx).TotalFrames / maxTime;
                        app.VideoSyncState(fIdx).VideoFps = newFps; % 소수점 정밀도 저장

                        if isfield(app.UI(fIdx), 'vidVideoFpsInput') && any(isvalid(app.UI(fIdx).vidVideoFpsInput))
                            app.UI(fIdx).vidVideoFpsInput.Value = round(newFps);
                        end
                        % 재계산된 FPS를 바탕으로 슬라이더 위의 총 시간 텍스트 즉시 갱신
                        app.updateVdubFrameLabel(fIdx, app.VideoSyncState(fIdx).CurrentFrame);
                    end
                end

                app.UI(fIdx).fileNameLabel.Text = filename;
                close(d);
            catch e
                try
                    if ~isempty(d) && isvalid(d), close(d); end
                catch ME, app.logCaught(ME, 'silent'); end
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
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                end
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
                    targetWidth = app.getVideoPanelTargetWidth(fIdx);
                    widths{6} = targetWidth; % 5를 6으로 수정
                    app.UI(fIdx).btnVid.Text = '비디오 ▾';
                else
                    widths{6} = 0;           % 5를 6으로 수정
                    app.UI(fIdx).btnVid.Text = '비디오 ▸';
                end
            end
            app.UI(fIdx).dataGrid.ColumnWidth = widths;
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
            [fname, pname] = uigetfile({'*.avi;*.mp4;*.mkv', 'Video Files (*.avi, *.mp4)'}, sprintf('비디오 선택 %d', fIdx));
            if isequal(fname, 0), return; end
            fullPath = fullfile(pname, fname);

            % 1) 사용자 확인 (기존 동기 설정 해제)
            if ~app.confirmVideoReplace(fIdx), return; end

            % 2) 프레임 캐시 무효화
            app.invalidateFrameCache(fIdx);

            % 3) 기존 VR/Future 정리 + startTime 산출
            startTime = app.computeStartTimeFromFlightData(fIdx);
            app.cleanupVideoResources(fIdx);

            % 4) VideoReader 생성
            vr = app.openVideoReader(fIdx, fullPath, fname);
            if isempty(vr), return; end
            app.VideoState(fIdx).videoStartTime = startTime;
            app.VideoState(fIdx).videoReader.CurrentTime = 0;
            app.LastVideoUpdate{fIdx} = uint64(0);

            % 5) TotalFrames 산정 + UI 위젯 동기화
            app.applyVideoLoadedUI(fIdx, vr);

            % 6) 첫 프레임 로드 + 표시 + 캐시 저장
            app.loadFirstFrame(fIdx);
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
        function invalidateFrameCache(app, fIdx)
            app.FrameCache{fIdx}        = {};
            app.FrameCacheKeys{fIdx}    = [];
            app.FrameCacheHits{fIdx}    = [];
            app.FrameCacheLastUse{fIdx} = [];
            app.CacheBytesUsed(fIdx)    = 0;
            app.LastDisplayedFrame(fIdx) = 0;
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
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                    cancel(app.AsyncFutures{fIdx});
                    app.AsyncFutures{fIdx} = [];
                end
            catch ME, app.logCaught(ME, 'silent'); end
        end

        % [V3.22 #3-5] VideoReader 생성 (실패 시 errordlg + [] 반환)
        function vr = openVideoReader(app, fIdx, fullPath, fname)
            vr = [];
            try
                vr = VideoReader(fullPath);
                app.VideoState(fIdx).videoReader = vr;
                app.VideoFilePath{fIdx} = fullPath;
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
            try
                totalFrames = app.computeTotalFrames(fIdx, vr);
                app.VideoSyncState(fIdx).TotalFrames = max(1, totalFrames);

                % [수정 1] 비행 데이터가 먼저 로드되어 있다면 전체시간 기준으로 FPS 강제 계산
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
                    catch
                    end
                end

                % 상태 변수에는 소수점까지 저장하고, UI에는 반올림하여 표시
                app.VideoSyncState(fIdx).VideoFps = actualFps;
                if isfield(app.UI(fIdx), 'vidVideoFpsInput') && any(isvalid(app.UI(fIdx).vidVideoFpsInput))
                    app.UI(fIdx).vidVideoFpsInput.Value = round(actualFps);
                end

                app.VideoSyncState(fIdx).CurrentFrame = 1;
                app.adjustCacheSize(fIdx);

                if isfield(app.UI(fIdx), 'vidSyncFrameInput') && any(isvalid(app.UI(fIdx).vidSyncFrameInput))
                    maxF = max(1, app.VideoSyncState(fIdx).TotalFrames);
                    app.UI(fIdx).vidSyncFrameInput.Limits = [1 maxF];
                    if app.UI(fIdx).vidSyncFrameInput.Value > maxF
                        app.UI(fIdx).vidSyncFrameInput.Value = 1;
                    end
                end

                app.updateVdubSliderRange(fIdx);
                app.updateVdubFrameLabel(fIdx, 1);
                app.adjustVideoPanelWidth(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'applyVideoLoadedUI');
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
            catch ME, app.logCaught(ME, 'Video:vfrCheck'); end
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
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
            end

            if ~isempty(firstFrame)
                app.setVideoImageFrame(fIdx, firstFrame);
                app.cacheStoreFrame(fIdx, 1, firstFrame);
            end
        end

        % [V3.12 2.1] 영상 가로:세로 비율에 따라 비디오 패널 너비 동적 조정
        function adjustVideoPanelWidth(app, fIdx)
            try
                targetWidth = app.getVideoPanelTargetWidth(fIdx);

                if app.UI(fIdx).PanelVisible.video
                    widths = app.UI(fIdx).dataGrid.ColumnWidth;
                    widths{6} = targetWidth;  % 5를 6으로 수정
                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                end
                app.setVideoDisplaySize(fIdx);
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [V3.15 항목 5-3] DebugMode GUI 체크박스 콜백
        function toggleDebugMode(app, val)
            try
                app.DebugMode = logical(val);
                fprintf('[Debug] DebugMode = %s\n', mat2str(app.DebugMode));
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [V3.14 항목 5] VideoReader 유효성 검사 헬퍼 (일관성 있는 가드)
        function tf = isVideoReady(app, fIdx)
            tf = false;
            try
                if fIdx < 1 || fIdx > 2, return; end
                vr = app.VideoState(fIdx).videoReader;
                h = app.VideoState(fIdx).vidImageHandle;
                tf = ~isempty(vr) && isvalid(vr) && ~isempty(h) && isvalid(h);
            catch ME_silent
                app.logCaught(ME_silent, 'isVideoReady');
                tf = false;
            end
        end

        % [V3.14 VirtualDub UI] Frame 슬라이더 범위 갱신 (영상 로드 시)
        function updateVdubSliderRange(app, fIdx)
            try
                if isfield(app.UI(fIdx), 'vidVdubSlider') && isvalid(app.UI(fIdx).vidVdubSlider)
                    maxF = max(2, app.VideoSyncState(fIdx).TotalFrames);
                    sld = app.UI(fIdx).vidVdubSlider;
                    sld.Limits = [1, maxF];
                    sld.Value = 1;
                    ticks = round(linspace(1, maxF, 5));
                    sld.MajorTicks = ticks;
                    sld.MajorTickLabels = arrayfun(@num2str, ticks, 'UniformOutput', false); % 지수 표기 방지
                    sld.MinorTicks = [];
                end
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [V3.14 VirtualDub UI] Frame N / Total (HH:MM:SS.mmm) 라벨 갱신
        % [V3.15 항목 5-1] milliseconds 정확도 개선 (floor + 0.5) + 캐리오버
        function updateVdubFrameLabel(app, fIdx, frameNo)
            try
                if ~isfield(app.UI(fIdx), 'vidVdubLabel') || ~isvalid(app.UI(fIdx).vidVdubLabel)
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            cleanupObj = onCleanup(@() app.clearGoToFrameFlag(fIdx)); %#ok<NASGU>

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
                                if isfield(app.UI(fIdx), 'spinner') && isvalid(app.UI(fIdx).spinner)
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
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
            end
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
                        try, app.updateDashboard(fIdx, app.Models(fIdx).currentIndex); catch, end
                        app.IsUpdating(fIdx) = false;
                    end
                    return;
                end
                app.goToFrame(fIdx, src.Value, 'final');
                % [V3.19 (2)] 슬라이더 드래그 종료 시 adaptive prefetch
                app.prefetchAdjacentFrames(fIdx);
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [V3.16 / V3.17 (8)] goToFrame 재진입 플래그 해제 (onCleanup 콜백)
        function clearGoToFrameFlag(app, fIdx)
            app.InGoToFrame(fIdx) = false;
            if ~any(app.InGoToFrame), app.State = 'IDLE'; end
        end

        % [V3.17 (7)] 디코딩 진행 중 플래그 해제 (onCleanup 콜백)
        function clearDecodingFlag(app, fIdx)
            app.IsDecoding(fIdx) = false;
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
            try
                % stack은 길이가 다른 struct array일 수 있어 cell로 wrap → 차원 불일치 회피
                stackCell = {[]};
                try, stackCell = {ME.stack}; catch, end
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

            if ~app.DebugMode, return; end
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
                tstr = '';
                try
                    tstr = char(datetime(log(k).time, 'Format', 'HH:mm:ss.SSS'));
                catch
                    try, tstr = datestr(log(k).time, 'HH:MM:SS.FFF'); catch, tstr = ''; end %#ok<DATST>
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
        function startAsyncDecode(app, fIdx, frameNo)
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
                    catch ME, app.logCaught(ME, 'Async:gcp'); end

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
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
                app.AsyncTargetFrame(fIdx) = frameNo;
                fps = app.VideoSyncState(fIdx).VideoFps;
                filePath = app.VideoFilePath{fIdx};

                % [V3.21 #2-A / V3.22 #4 / V3.22 #6] persistent VR worker 함수 사용
                % static wrapper를 통해 향후 +flightdash 패키지 마이그레이션 가능
                fut = parfeval(app.AsyncPool, @FlightDataDashboard.workerDecodeFrame, 1, ...
                    filePath, frameNo, fps, app.WORKER_VR_CACHE_SLOTS);
                app.AsyncFutures{fIdx} = fut;

                % [V3.21 #1-A] afterEach에 myGen 캡처 → 완료 시 generation 비교
                afterEach(fut, @(img) app.onAsyncDecodeComplete(fIdx, frameNo, myGen, img), 1, ...
                    'PassFuture', false);
            catch e
                if app.DebugMode
                    fprintf('[Async] startAsyncDecode error: %s\n', e.message);
                end
            end
        end

        % [V3.19 (1) / V3.21 #1-A / V3.21 #3-A] 비동기 디코딩 완료 콜백 (main thread)
        % - generation 비교로 stale 결과 차단
        % - displayFrame 단일 출구 통과 (write-through)
        function onAsyncDecodeComplete(app, fIdx, frameNo, gen, img)
            try
                if isempty(img), return; end
                if gen ~= app.AsyncGen(fIdx)
                    if app.DebugMode
                        fprintf('[Async] stale result discarded (gen=%d, current=%d)\n', ...
                            gen, app.AsyncGen(fIdx));
                    end
                    return;
                end
                % [V3.21 #3-A] Layer 3 단일 출구 통과
                app.displayFrame(fIdx, frameNo, img, false);
                app.AsyncTargetFrame(fIdx) = NaN;
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
                    app.updateVideoFrameByFrameNo(fIdx, target, 'autoplay');
                end
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [V3.14 VirtualDub UI] Frame 마커/슬라이더/라벨 일괄 동기화 헬퍼
        function syncFrameMarkersAndLabel(app, fIdx, frameNo)
            try
                % [수정] 사용하지 않는 옛날 마커 갱신 코드는 완전히 삭제하여 에러 원천 차단

                % 1. 슬라이더 위치 갱신
                if isfield(app.UI(fIdx), 'vidVdubSlider') && any(isvalid(app.UI(fIdx).vidVdubSlider))
                    if abs(app.UI(fIdx).vidVdubSlider.Value - frameNo) > 0.5
                        app.UI(fIdx).vidVdubSlider.Value = frameNo;
                    end
                end

                % 2. 라벨 텍스트 갱신 (에러 없이 안전하게 도달)
                app.updateVdubFrameLabel(fIdx, frameNo);

            catch ME_silent
                app.logCaught(ME_silent, 'silent');
            end
        end

        % [V3.12] 비디오 동기 상태 초기화
        function resetVideoSync(app, fIdx)
            app.VideoSyncState(fIdx).IsSynced = false;
            app.VideoSyncState(fIdx).AnchorFrame = 0;
            app.VideoSyncState(fIdx).AnchorTime = 0;
            try
                if isfield(app.UI(fIdx), 'vidSyncBtn') && isvalid(app.UI(fIdx).vidSyncBtn)
                    app.UI(fIdx).vidSyncBtn.Text = '동기';
                    app.UI(fIdx).vidSyncBtn.BackgroundColor = [0.58 0.0 0.83];
                end
                if isfield(app.UI(fIdx), 'vidSyncStatus') && isvalid(app.UI(fIdx).vidSyncStatus)
                    app.UI(fIdx).vidSyncStatus.Text = '동기 미설정';
                    app.UI(fIdx).vidSyncStatus.FontColor = [0.5 0.5 0.5];
                end
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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

            % [PATCH] 동일 프레임 조기 반환 - GUI/디코딩 부하 동시 절감
            if app.LastDisplayedFrame(fIdx) == clampedFrame, return; end

            % Layer 1: 캐시 lookup
            cached = app.cacheGetFrame(fIdx, clampedFrame);
            if ~isempty(cached)
                app.displayFrame(fIdx, clampedFrame, cached, true);  % cacheHit=true
                return;
            end

            % 디코딩 진행 중이면 skip (coalescing으로 후처리)
            if app.IsDecoding(fIdx), return; end

            % 전략 선택: async vs sync
            if app.UseAsyncDecode && strcmp(source, 'drag')
                app.startAsyncDecode(fIdx, clampedFrame);
                return;
            end

            % Layer 2: 동기 디코딩
            app.IsDecoding(fIdx) = true;
            cleanup2 = onCleanup(@() app.clearDecodingFlag(fIdx)); %#ok<NASGU>

            img = app.decodeFrameSync(fIdx, clampedFrame);
            if ~isempty(img)
                app.displayFrame(fIdx, clampedFrame, img, false);  % cacheHit=false
            end
        end

        % [V3.21 #3-A Layer 2] 동기 디코딩 (read or 폴백)
        function img = decodeFrameSync(app, fIdx, clampedFrame)
            img = [];
            vr = app.VideoState(fIdx).videoReader;

            % [PATCH Async 1.2 / V3.22 #4] 작은 step 휴리스틱 - 직전 표시 프레임 근처면 readFrame 순차
            % MP4 역방향 seek는 매우 비싸므로 전진 방향 작은 step만 readFrame 사용
            try
                lastF = app.LastDisplayedFrame(fIdx);
                fps = app.VideoSyncState(fIdx).VideoFps;
                if fps <= 0, fps = 70; end
                step = clampedFrame - lastF;
                if lastF > 0 && step >= 1 && step <= app.MAX_SEQ_READ_STEP
                    for k = 1:step
                        if hasFrame(vr), img = readFrame(vr); else, img = []; break; end
                    end
                    if ~isempty(img), return; end
                end
            catch ME, app.logCaught(ME, 'decodeSync:seq'); end

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
                catch ME, app.logCaught(ME, 'decodeSync:fallback');
                    img = [];
                end
            end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end

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
            catch ME, app.logCaught(ME, 'silent'); end

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
            catch ME, app.logCaught(ME, 'silent'); end

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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME_silent, app.logCaught(ME_silent, 'silent'); end
        end

        % [PATCH UX-3] H↔I 패널 경계 splitter 드래그 핸들러
        function startHISplitterDrag(app, fIdx)
            try
                app.HISplitterFIdx = fIdx;
                app.IsDraggingSplitter = true;
                app.UIFigure.WindowButtonMotionFcn = @(~,~) app.hiSplitterMotion();
                app.UIFigure.WindowButtonUpFcn    = @(~,~) app.stopHISplitterDrag();
                if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'left-right'; end
            catch ME, app.logCaught(ME, 'HISplitter:start'); end
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
            catch ME, app.logCaught(ME, 'HISplitter:motion'); end
        end

        function stopHISplitterDrag(app)
            try
                app.UIFigure.WindowButtonMotionFcn = '';
                app.UIFigure.WindowButtonUpFcn    = '';
                if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'arrow'; end
                app.IsDraggingSplitter = false;
                app.HISplitterFIdx = 0;
                drawnow limitrate;
            catch ME, app.logCaught(ME, 'HISplitter:stop'); end
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
            catch ME, app.logCaught(ME, 'silent'); end

            try
                if ~isempty(app.DraggedMarker) && isvalid(app.DraggedMarker)
                    app.DraggedMarker.HitTest = 'on';
                    % 기존 Axes 상호작용(Pan/Zoom) 복원
                    ax = app.DraggedMarker.Parent;
                    if isvalid(ax) && isprop(ax, 'Interactions') && ~isempty(app.DraggedMarker.UserData)
                        ax.Interactions = app.DraggedMarker.UserData;
                    end
                end
            catch ME, app.logCaught(ME, 'silent'); end

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
                catch ME, app.logCaught(ME, 'silent'); end
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
                    app.IsUpdating(fIdx) = true;
                    try
                        app.updateDashboard(fIdx, idx);
                    catch e
                        warning('stopPlotMarkerDrag 전체 동기화 오류: %s', e.message);
                    end
                    app.IsUpdating(fIdx) = false;
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
            catch ME, app.logCaught(ME, 'silent'); end

            % Altitude 패널 XLim 리스너 제어
            try
                if isfield(app.UI(fIdx), 'altXLimListener')
                    L = app.UI(fIdx).altXLimListener;
                    if ~isempty(L) && isvalid(L)
                        L.Enabled = enabled;
                    end
                end
            catch ME, app.logCaught(ME, 'silent'); end
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

                if isfield(app.UI(fIdx), 'dataTable') && isvalid(app.UI(fIdx).dataTable)
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

                if isfield(app.UI(fIdx), 'pitchLabel') && isvalid(app.UI(fIdx).pitchLabel)
                    app.UI(fIdx).pitchLabel.Text = sprintf('Pitch %+.3f°', pitch);
                end
                if isfield(app.UI(fIdx), 'rollLabel') && isvalid(app.UI(fIdx).rollLabel)
                    app.UI(fIdx).rollLabel.Text = sprintf('Roll %+.3f°', roll);
                end
                if isfield(app.UI(fIdx), 'hdgLabel') && isvalid(app.UI(fIdx).hdgLabel)
                    app.UI(fIdx).hdgLabel.Text = sprintf('Heading %+.3f°', hdg);
                end

                if isfield(app.UI(fIdx), 'hgPitch') && isvalid(app.UI(fIdx).hgPitch)
                    set(app.UI(fIdx).hgPitch, 'Matrix', makehgtform('zrotate', -pitch * pi / 180));
                end
                if isfield(app.UI(fIdx), 'hgRoll') && isvalid(app.UI(fIdx).hgRoll)
                    set(app.UI(fIdx).hgRoll, 'Matrix', makehgtform('zrotate', -roll * pi / 180));
                end
                if isfield(app.UI(fIdx), 'hgHdg') && isvalid(app.UI(fIdx).hgHdg)
                    set(app.UI(fIdx).hgHdg, 'Matrix', makehgtform('zrotate', -hdg * pi / 180));
                end
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
                if isfield(app.UI(fIdx), 'hAltMarker') && isvalid(app.UI(fIdx).hAltMarker)
                    set(app.UI(fIdx).hAltMarker, 'XData', currTime, 'YData', alts(idx));
                end
                if isfield(app.UI(fIdx), 'timeLine') && isvalid(app.UI(fIdx).timeLine)
                    app.UI(fIdx).timeLine.Value = currTime;
                end

                % 현재시간 라벨 (매우 가벼움)
                if isfield(app.UI(fIdx), 'currentTimeLabel') && isvalid(app.UI(fIdx).currentTimeLabel)
                    app.UI(fIdx).currentTimeLabel.Text = sprintf('%.3f s', currTime);
                end

                % 스피너 갱신 (가벼움)
                if isfield(app.UI(fIdx), 'spinner') && isvalid(app.UI(fIdx).spinner)
                    if abs(app.UI(fIdx).spinner.Value - currTime) > eps
                        app.UI(fIdx).spinner.Value = currTime;
                    end
                end
                app.updateNumericPanelsOnly(fIdx, idx);
            catch ME, app.logCaught(ME, 'silent'); end

            % [V3.12 1.1] Map 비행경로 + 빨간 삼각형 실시간 갱신 (가벼움)
            try
                pathLon = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lon);
                pathLat = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Lat);
                currLon = pathLon(1:idx);
                currLat = pathLat(1:idx);
                validIdx = (currLon ~= 0) | (currLat ~= 0);

                if isfield(app.UI(fIdx), 'hMapPath') && isvalid(app.UI(fIdx).hMapPath)
                    set(app.UI(fIdx).hMapPath, 'XData', currLon(validIdx), 'YData', currLat(validIdx));
                end

                hdg = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Heading)(idx);
                lastValid = find(validIdx, 1, 'last');
                if ~isempty(lastValid) && isfield(app.UI(fIdx), 'hgMapPlane') && isvalid(app.UI(fIdx).hgMapPlane)
                    T_map = makehgtform('translate', [currLon(lastValid), currLat(lastValid), 0]) * makehgtform('zrotate', -hdg * pi / 180);
                    set(app.UI(fIdx).hgMapPlane, 'Matrix', T_map);
                end
            catch ME, app.logCaught(ME, 'silent'); end

            % H 패널 책장 넘기기 + 마커 갱신 (개선안 A의 IsProgrammaticXLim 가드 작동)
            app.updatePlotTimeLines(fIdx, idx, currTime);

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
                catch ME, app.logCaught(ME, 'silent'); end
            end

            % 동기화 모드: 경로 1 드래그 시 경로 2도 경량 업데이트
            if app.SyncState.IsSynced && fIdx == 1 && ~isempty(app.Models(2).rawData)
                targetT2 = app.SyncState.SyncT2 + (currTime - app.SyncState.SyncT1);
                timeCol2 = app.Models(2).mappedCols.Time;
                idx2 = app.findClosestIndexByTime(app.Models(2).rawData.(timeCol2), targetT2);
                if ~isequal(app.Models(2).currentIndex, idx2)
                    % [V3.17 (4)(11)] InCascade 인스턴스 속성으로 cascade 가드
                    app.InCascade = true;
                    app.updateMarkersOnly(2, idx2);
                    app.InCascade = false;
                end
            end

            % [V3.17 (5)] cascade 외부 + goToFrame 미경유 시에만 drawnow
            % goToFrame은 자체 종료 시 drawnow 호출하므로 중복 방지
            if isOuter && ~any(app.InGoToFrame)
                drawnow limitrate;
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
            app.updatePlotTimeLines(fIdx, currIdx, currTime);
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
                            app.IsProgrammaticXLim(fIdx) = true;   % ⭐ 리스너 가드 ON
                            firstAx.XLim = [newMin, newMax];
                            app.IsProgrammaticXLim(fIdx) = false;  % ⭐ 리스너 가드 OFF
                        elseif currTime < xMin
                            newMax = xMin;
                            newMin = xMin - xWidth;
                            while currTime < newMin
                                newMax = newMin;
                                newMin = newMin - xWidth;
                            end
                            app.IsProgrammaticXLim(fIdx) = true;   % ⭐ 리스너 가드 ON
                            firstAx.XLim = [newMin, newMax];
                            app.IsProgrammaticXLim(fIdx) = false;  % ⭐ 리스너 가드 OFF
                        end
                    end
                catch
                    app.IsProgrammaticXLim(fIdx) = false;  % 예외 시 플래그 복원
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
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end

            app.UI(fIdx).plotAxes{tabIdx} = {};
            app.UI(fIdx).timeLines{tabIdx} = {};
            app.UI(fIdx).timeMarkers{tabIdx} = {};
            app.UI(fIdx).plotData{tabIdx} = {};
            app.UI(fIdx).xLimListeners{tabIdx} = {};
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
                catch ME, app.logCaught(ME, 'silent'); end
            end
            app.UI(fIdx).plotTabs = [];
            app.UI(fIdx).plotLayouts = {};
            app.UI(fIdx).plotAxes = cell(1, app.MAX_TABS);
            app.UI(fIdx).timeLines = cell(1, app.MAX_TABS);
            app.UI(fIdx).timeMarkers = cell(1, app.MAX_TABS);
            app.UI(fIdx).plotData = cell(1, app.MAX_TABS);
            app.UI(fIdx).xLimListeners = cell(1, app.MAX_TABS);

            app.addPlotTab(fIdx);
        end

        function deleteGraphicsHandles(~, handleCell)
            if isempty(handleCell), return; end
            for k = 1:length(handleCell)
                h = handleCell{k};
                try
                    if ~isempty(h) && isvalid(h)
                        delete(h);
                    end
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
            end
        end

        function deleteListeners(~, listenerCell)
            if isempty(listenerCell), return; end
            for k = 1:length(listenerCell)
                L = listenerCell{k};
                try
                    if ~isempty(L) && isvalid(L)
                        delete(L);
                    end
                catch ME_silent, app.logCaught(ME_silent, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end

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
            plot(ax, tData, yData, 'LineWidth', 1.5, 'Color', [0.15 0.38 0.82]);
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
            try, app.recordPlotInConfig(fIdx, tabIdx, struct( ...
                    'YColumn', yCol, 'YLabel', yLabelStr, ...
                    'XLim', ax.XLim, 'YLimMode', char(ax.YLimMode), ...
                    'YLim', ax.YLim, 'Height', app.PLOT_ROW_HEIGHT)); catch, end

            drawnow;
        end
    end

    % =========================================================================
    % [Phase 4] PlotConfig capture/apply + LinkXWithinTab gating (D3)
    % =========================================================================
    methods (Access = private)
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
            catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end
            try
                axesCell = app.UI(fIdx).plotAxes{tabIdx};
                if iscell(axesCell), allAxes = [axesCell{:}]; else, allAxes = axesCell; end
                if numel(allAxes) > 1
                    if enabled, linkaxes(allAxes, 'x'); else, linkaxes(allAxes, 'off'); end
                end
            catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end
            app.markProjectDirtyAndScheduleRefresh('linkx-off');
        end

        function recordPlotInConfig(app, fIdx, tabIdx, entry)
            cfg = app.ensurePlotConfigShape(app.PlotConfigState);
            try
                if numel(cfg.Flights(fIdx).PlotTabs) < tabIdx
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Title          = sprintf('Tab %d', tabIdx);
                    cfg.Flights(fIdx).PlotTabs(tabIdx).LinkXWithinTab = true;
                    cfg.Flights(fIdx).PlotTabs(tabIdx).Plots          = [];
                end
                plots = cfg.Flights(fIdx).PlotTabs(tabIdx).Plots;
                if isempty(plots)
                    plots = entry;
                else
                    plots(end+1) = entry; %#ok<AGROW>
                end
                cfg.Flights(fIdx).PlotTabs(tabIdx).Plots = plots;
                app.PlotConfigState = cfg;
            catch ME, app.logCaught(ME, 'silent'); end
        end

        function cfg = capturePlotConfigFromUi(app)
            cfg = app.ensurePlotConfigShape(app.PlotConfigState);
            for fIdx = 1:2
                try
                    if ~isfield(app.UI(fIdx), 'plotAxes') || isempty(app.UI(fIdx).plotAxes)
                        continue;
                    end
                    numTabs = numel(app.UI(fIdx).plotAxes);
                    for tabIdx = 1:numTabs
                        axesCell = app.UI(fIdx).plotAxes{tabIdx};
                        plots = struct('YColumn', {}, 'YLabel', {}, 'XLim', {}, ...
                                       'YLimMode', {}, 'YLim', {}, 'Height', {}, 'Order', {});
                        if iscell(axesCell)
                            for p = 1:numel(axesCell)
                                ax = axesCell{p};
                                if isempty(ax) || ~isvalid(ax), continue; end
                                ylabStr = '';
                                try, ylabStr = char(ax.YLabel.String); catch, end
                                plots(end+1) = struct('YColumn', '', 'YLabel', ylabStr, ...
                                    'XLim', ax.XLim, 'YLimMode', char(ax.YLimMode), ...
                                    'YLim', ax.YLim, 'Height', app.PLOT_ROW_HEIGHT, ...
                                    'Order', p); %#ok<AGROW>
                            end
                        end
                        titleStr = sprintf('Tab %d', tabIdx);
                        try, titleStr = char(app.UI(fIdx).plotTabs(tabIdx).Title); catch, end
                        link = app.getLinkXWithinTab(fIdx, tabIdx);
                        cfg.Flights(fIdx).PlotTabs(tabIdx) = struct( ...
                            'Title', titleStr, 'LinkXWithinTab', link, 'Plots', plots);
                    end
                catch ME, app.logCaught(ME, 'silent'); end
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
                xChanged = isfield(axisCfg, 'XLim') && ~isequal(ax.XLim, axisCfg.XLim);
                if xChanged && app.getLinkXWithinTab(fIdx, tabIdx)
                    app.disableLinkXOnIndividualEdit(fIdx, tabIdx);
                end
                if isfield(axisCfg, 'XLim'),     ax.XLim     = axisCfg.XLim; end
                if isfield(axisCfg, 'YLim'),     ax.YLim     = axisCfg.YLim; end
                if isfield(axisCfg, 'YLimMode'), ax.YLimMode = axisCfg.YLimMode; end
            catch ME, app.logCaught(ME, 'silent'); end
        end

        function syncSelectedPlotXLimToAll(app, fIdx, tabIdx, plotIdx)
            % Apply this plot's X range to every plot in every tab of every flight.
            try
                axesCell = app.UI(fIdx).plotAxes{tabIdx};
                if ~iscell(axesCell) || numel(axesCell) < plotIdx, return; end
                srcAx = axesCell{plotIdx};
                if isempty(srcAx) || ~isvalid(srcAx), return; end
                xlim = srcAx.XLim;
            catch ME, app.logCaught(ME, 'silent'); return; end
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
                catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end
            app.markProjectDirtyAndScheduleRefresh('xlim-tab');
        end

        function applyTabXLimToAllTabs(app, fIdx, srcTabIdx)
            try
                srcAxesCell = app.UI(fIdx).plotAxes{srcTabIdx};
                if ~iscell(srcAxesCell) || isempty(srcAxesCell), return; end
                srcAx = srcAxesCell{1};
                if isempty(srcAx) || ~isvalid(srcAx), return; end
                xlim = srcAx.XLim;
            catch ME, app.logCaught(ME, 'silent'); return; end
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
                catch ME, app.logCaught(ME, 'silent'); end
            end
            app.markProjectDirtyAndScheduleRefresh('xlim-all-tabs');
        end

        function rebuildPlotsFromConfig(app, fIdx, cfg)
            % Lightweight rebuild stub: clears tabs then re-adds plots by YColumn order.
            % Full UI rebuild matches setupDataUI semantics; left for follow-up.
            if isempty(cfg) || ~isstruct(cfg) || ~isfield(cfg, 'Flights') ...
                    || numel(cfg.Flights) < fIdx
                return;
            end
            tabs = cfg.Flights(fIdx).PlotTabs;
            if isempty(tabs), return; end
            try, app.clearAllTabs(fIdx); catch, end
            for t = 1:numel(tabs)
                try, app.addPlotTab(fIdx); catch, end
                if isfield(tabs(t), 'Plots') && ~isempty(tabs(t).Plots)
                    for p = 1:numel(tabs(t).Plots)
                        yCol = tabs(t).Plots(p).YColumn;
                        if isempty(yCol), continue; end
                        idx = find(strcmp({app.Models(fIdx).displayMeta.header}, yCol), 1);
                        if ~isempty(idx)
                            app.Models(fIdx).selectedRow = idx;
                            try, app.plotSelectedVariable(fIdx); catch, end
                        end
                    end
                end
                if isfield(tabs(t), 'LinkXWithinTab')
                    app.setLinkXWithinTab(fIdx, t, tabs(t).LinkXWithinTab);
                end
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
            catch ME, app.logCaught(ME, 'silent'); end
            app.applyOptionFile(fIdx, dataTbl, false);

            if any(ismissing(app.Models(fIdx).rawData), 'all')
                app.Models(fIdx).rawData = fillmissing(app.Models(fIdx).rawData, 'linear', 'DataVariables', @isnumeric);
                % Keep unscaled mirror in sync when imputation runs.
                try
                    app.Models(fIdx).rawDataUnscaled = fillmissing(app.Models(fIdx).rawDataUnscaled, 'linear', 'DataVariables', @isnumeric);
                catch ME, app.logCaught(ME, 'silent'); end
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
                catch ME, app.logCaught(ME, 'option-parse'); end
            end
            draft = struct('sourcePath', char(optPath), ...
                           'mappedCols', mappedCols, ...
                           'displayMeta', displayMeta);
        end

        function [ok, info] = validateOptionDraft(app, draft, csvHeaders) %#ok<INUSL>
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
                        info.brokenMappings{end+1} = sprintf('%s -> %s', reqKeys{i}, v); %#ok<AGROW>
                    end
                end
                for i = 1:numel(draft.displayMeta)
                    if ~ismember(draft.displayMeta(i).header, csvHeaders)
                        info.brokenColumns{end+1} = draft.displayMeta(i).header; %#ok<AGROW>
                    end
                    if isnan(draft.displayMeta(i).scale) || draft.displayMeta(i).scale == 0
                        info.reasons{end+1} = sprintf('scale 비정상: %s', draft.displayMeta(i).header); %#ok<AGROW>
                    end
                end
            catch ME, app.logCaught(ME, 'option-validate'); end
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
                    catch ME, app.logCaught(ME, 'option-scale'); end
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
                lines{end+1} = '# RequiredColumns'; %#ok<AGROW>
                reqKeys = app.REQ_KEYS;
                for i = 1:length(reqKeys)
                    v = '';
                    if isfield(draft.mappedCols, reqKeys{i}), v = char(draft.mappedCols.(reqKeys{i})); end
                    lines{end+1} = sprintf('%s: %s', reqKeys{i}, v); %#ok<AGROW>
                end
                lines{end+1} = ''; %#ok<AGROW>
                lines{end+1} = '# DisplayColumns'; %#ok<AGROW>
                for i = 1:numel(draft.displayMeta)
                    dm = draft.displayMeta(i);
                    lines{end+1} = sprintf('%s, %s, %s, %d, %g', ...
                        dm.header, dm.unit, dm.format, dm.order, dm.scale); %#ok<AGROW>
                end
                tmp = [optPath '.tmp'];
                fid = fopen(tmp, 'w');
                if fid < 0, error('FlightDataDashboard:OptionWrite', '임시 파일 열기 실패: %s', tmp); end
                cleanup = onCleanup(@() fclose(fid));
                fprintf(fid, '%s\n', lines{:});
                clear cleanup;
                if isfile(optPath)
                    try, copyfile(optPath, [optPath '.bak'], 'f'); catch, end
                end
                movefile(tmp, optPath, 'f');
                ok = true;
            catch ME
                app.logCaught(ME, 'option-write');
                try, uialert(app.UIFigure, sprintf('option 파일 저장 실패:\n%s', ME.message), 'Options'); catch, end
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
                catch ME, app.logCaught(ME, 'silent'); end
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
                catch
                    app.updateVideoFrame(fIdx, currTime);  % 폴백
                end
            else
                % 동기 미설정: 기존 방식대로 시간 기반 갱신
                % app.updateVideoFrame(fIdx, currTime);  % <--- 이 줄을 주석 처리하여 완전 분리
            end
            app.updatePlotTimeLines(fIdx, index, currTime);

            drawnow limitrate;
        end
    end

    % =========================================================================
    % UI 레이아웃 생성 팩토리 (Create Layout)
    % =========================================================================
    methods (Access = private)
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
                app.logCaught(ME_silent, 'silent');
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

        function targetWidth = getVideoPanelTargetWidth(app, fIdx)
            panelWidths = app.getResponsivePanelWidths();
            targetWidth = panelWidths(4);
            targetWidth = round(max(app.getMinVideoPanelWidth(), min(targetWidth, 900)));
        end

        function applyResponsiveLayout(app)
            try
                if isempty(app.UI), return; end
                panelWidths = app.getResponsivePanelWidths();
                for fIdx = 1:min(2, numel(app.UI))
                    if ~isfield(app.UI(fIdx), 'dataGrid') || ...
                       isempty(app.UI(fIdx).dataGrid) || ~isvalid(app.UI(fIdx).dataGrid)
                        continue;
                    end

                    widths = {panelWidths(1), panelWidths(2), panelWidths(3), '1x', 8, app.getVideoPanelTargetWidth(fIdx)};
                    if isfield(app.UI(fIdx), 'PanelVisible')
                        if ~app.UI(fIdx).PanelVisible.attitude, widths{1} = 0; end
                        if ~app.UI(fIdx).PanelVisible.map, widths{2} = 0; end
                        if ~app.UI(fIdx).PanelVisible.video, widths{6} = 0; end
                    end

                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                    app.UI(fIdx).dataGrid.Scrollable = 'on';
                    app.setVideoDisplaySize(fIdx);
                end
                app.updateWindowControlLabels();
                drawnow limitrate;
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
                    app.logCaught(ME_resize, 'silent');
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
                        app.logCaught(ME_inner, 'silent');
                    end
                    dlg.Visible = 'on';
                    drawnow limitrate;
                    if isfield(app.UI(fIdx), 'vidControlBtn') && isvalid(app.UI(fIdx).vidControlBtn)
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
                        'vidCacheBudget', {}, 'vidVdubSlider', {}, 'vidVdubLabel', {});

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
                                             'ColumnWidth', {'1.45x', '1x'}, 'FontSize', 11, 'FontName', 'Consolas');
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
                    UIGroup_temp(fIdx) = grp; %#ok<AGROW>
                end
            end
            app.UIGroup = UIGroup_temp;
        end

        % [V3.22 #7] 메인 윈도우 상단 헤더 바 (파일 선택 / Debug / Sync 입력)
        % - createLayout에서 분리하여 헤더 영역 변경이 메인 빌더에 영향 없도록 함
        function buildHeaderBar(app, mainLayout)
            hHeaderPanel = uipanel(mainLayout, 'BackgroundColor', 'w', 'BorderType', 'none');
            glHeader = uigridlayout(hHeaderPanel, [1 9]);
            glHeader.ColumnWidth = {140, 140, 140, '1x', 80, 150, 150, 72, 80};
            glHeader.RowHeight = {'fit'};
            glHeader.Padding = [5 5 5 5];
            glHeader.ColumnSpacing = 5;

            uibutton(glHeader, 'Text', '비행경로 1 선택', 'BackgroundColor', [0.15 0.38 0.82], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleFlightFile(1));
            uibutton(glHeader, 'Text', '비행경로 2 선택', 'BackgroundColor', [0.31 0.27 0.90], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleFlightFile(2));
            uibutton(glHeader, 'Text', '해안선 정보', 'BackgroundColor', [0.06 0.65 0.50], 'FontColor', 'w', ...
                     'FontSize', 13, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) app.handleCoastFile());
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
                catch ME, app.logCaught(ME, 'silent'); end
            end
            try
                st.FlightSync = struct( ...
                    'IsSynced', logical(app.SyncState.IsSynced), ...
                    'SyncT1',   double(app.SyncState.SyncT1), ...
                    'SyncT2',   double(app.SyncState.SyncT2));
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    st.UiState.WindowPosition = app.UIFigure.Position;
                end
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    st.UiState.EditDialogPosition = app.EditDialog.Position;
                end
            catch ME, app.logCaught(ME, 'silent'); end
            % Phase 4 will populate PlotConfig; preserve any cached structure for now.
            if ~isempty(app.PlotConfigState)
                st.PlotConfig = app.PlotConfigState;
            end
        end

        function applyProjectState(app, st, opts)
            % Apply a loaded .fdproj-shaped struct to runtime state.
            % opts.skipFiles = true skips heavy data/AVI loads (Phase 5 owns full path).
            if nargin < 3 || isempty(opts), opts = struct(); end
            if ~isfield(opts, 'skipFiles'), opts.skipFiles = true; end
            if isempty(st), return; end
            st = app.migrateProjectState(st);
            try
                if isfield(st, 'FlightSync') && ~isempty(st.FlightSync)
                    app.SyncState.IsSynced = logical(st.FlightSync.IsSynced);
                    app.SyncState.SyncT1   = double(st.FlightSync.SyncT1);
                    app.SyncState.SyncT2   = double(st.FlightSync.SyncT2);
                end
            catch ME, app.logCaught(ME, 'silent'); end
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
                    catch ME, app.logCaught(ME, 'silent'); end
                end
            end
            if isfield(st, 'UiState')
                try
                    if isfield(st.UiState, 'WindowPosition') && ~isempty(st.UiState.WindowPosition) ...
                            && ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                        app.UIFigure.Position = st.UiState.WindowPosition;
                    end
                catch ME, app.logCaught(ME, 'silent'); end
            end
            if isfield(st, 'PlotConfig')
                app.PlotConfigState = st.PlotConfig;
            end
            app.ProjectState = st;
            app.ProjectDirty = false;
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
                        warning(msg);
                    end
                    error('FlightDataDashboard:UnsupportedProjectVersion', msg);
            end
        end

        function st = loadProjectFile(app, filePath)
            % Read and validate a .fdproj file. Caller decides whether to applyProjectState.
            st = [];
            if nargin < 2 || isempty(filePath) || ~isfile(filePath), return; end
            try
                txt = fileread(filePath);
                st  = jsondecode(txt);
                st  = app.migrateProjectState(st);
                app.ProjectFilePath = app.normalizeAbsPath(filePath);
            catch ME
                app.logCaught(ME, 'project-load');
                try, uialert(app.UIFigure, sprintf('project 파일 로드 실패:\n%s', ME.message), 'Project'); catch, end
                st = [];
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
                st  = app.collectCurrentProjectState();
                txt = jsonencode(st, 'PrettyPrint', true);
                tmp = [filePath '.tmp'];
                fid = fopen(tmp, 'w');
                if fid < 0, error('FlightDataDashboard:ProjectWrite', '임시 파일 열기 실패: %s', tmp); end
                cleanup = onCleanup(@() fclose(fid));
                fwrite(fid, txt, 'char');
                clear cleanup;
                if isfile(filePath)
                    try, copyfile(filePath, [filePath '.bak'], 'f'); catch, end
                end
                movefile(tmp, filePath, 'f');
                app.ProjectFilePath = app.normalizeAbsPath(filePath);
                app.ProjectState    = st;
                app.ProjectDirty    = false;
                app.clearProjectAutosave();
                ok = true;
            catch ME
                app.logCaught(ME, 'project-save');
                try, uialert(app.UIFigure, sprintf('project 저장 실패:\n%s', ME.message), 'Project'); catch, end
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
                st  = app.collectCurrentProjectState();
                txt = jsonencode(st, 'PrettyPrint', true);
                fid = fopen(autoPath, 'w');
                if fid < 0, return; end
                cleanup = onCleanup(@() fclose(fid));
                fwrite(fid, txt, 'char');
            catch ME, app.logCaught(ME, 'silent'); end
        end

        function clearProjectAutosave(app)
            try
                if isempty(app.ProjectFilePath), return; end
                autoPath = [app.ProjectFilePath '.autosave.json'];
                if isfile(autoPath), delete(autoPath); end
            catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end
            try
                if isempty(app.AutosaveTimer) || ~isvalid(app.AutosaveTimer)
                    app.AutosaveTimer = timer( ...
                        'ExecutionMode', 'fixedSpacing', ...
                        'Period', app.AutosaveIntervalSec, ...
                        'StartDelay', app.AutosaveIntervalSec, ...
                        'TimerFcn', @(~,~) app.saveProjectAutosave());
                    start(app.AutosaveTimer);
                end
            catch ME, app.logCaught(ME, 'silent'); end
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
                    catch ME, app.logCaught(ME, 'silent'); end
                end
                app.LastEditApplyTime = datetime('now');
            catch ME, app.logCaught(ME, 'silent'); end
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
                catch ME, app.logCaught(ME, 'silent'); end
                app.markProjectDirtyAndScheduleRefresh('flight-sync-off');
                return;
            end
            if isempty(app.Models(1).rawData) || isempty(app.Models(2).rawData)
                try, uialert(app.UIFigure, '두 경로 데이터가 모두 로드되어야 합니다.', 'Sync'); catch, end
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
            catch ME, app.logCaught(ME, 'silent'); end
            try
                timeCol1 = app.Models(1).mappedCols.Time;
                idx1 = app.findClosestIndexByTime(app.Models(1).rawData.(timeCol1), syncT1);
                app.applyTimeChange(1, idx1);
            catch ME, app.logCaught(ME, 'silent'); end
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
                try, uialert(app.UIFigure, '먼저 AVI 파일을 로드하세요.', 'Sync'); catch, end
                return;
            end
            if isempty(app.Models(fIdx).rawData)
                try, uialert(app.UIFigure, '먼저 비행데이터를 로드하세요.', 'Sync'); catch, end
                return;
            end
            if ~isnumeric(videoFps) || videoFps < 1 || ~isnumeric(dataFps) || dataFps < 1
                try, uialert(app.UIFigure, 'Hz 값은 1 이상이어야 합니다.', 'Sync'); catch, end
                return;
            end
            totalFrames = app.VideoSyncState(fIdx).TotalFrames;
            if anchorFrame < 1 || (totalFrames > 0 && anchorFrame > totalFrames)
                try, uialert(app.UIFigure, sprintf('Frame은 1~%d 범위여야 합니다.', totalFrames), 'Sync'); catch, end
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
            catch ME, app.logCaught(ME, 'silent'); end
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
            catch ME, app.logCaught(ME, 'silent'); end
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
function img = asyncDecodeFrame(filePath, frameNo, fps)
    img = [];
    try
        vr = VideoReader(filePath);
        try
            img = read(vr, frameNo);
        catch
            relTime = (frameNo - 1) / max(1, fps);
            relTime = max(0, min(relTime, vr.Duration - 0.05));
            vr.CurrentTime = relTime;
            if hasFrame(vr)
                img = readFrame(vr);
            end
        end
    catch
        img = [];
    end
end

% =========================================================================
% [V3.21 #2-A / V3.22 #4] persistent VideoReader worker function
% - 매 호출마다 VR 재생성(50ms) → persistent로 재사용(3ms)
% - 파일 경로 변경 시에만 VR 재생성
% - maxSlots: 호출처에서 전달 (기본 4) - 채널별 VR 독립 보유
% =========================================================================
function img = asyncDecodeFramePersistent(filePath, frameNo, fps, maxSlots)
    % [PATCH] 다중 슬롯 LRU 캐시 (채널별 VR 독립 보유, 파일락/메모리누수 방지)
    persistent cache   % struct array: .path, .vr, .lastUse
    img = [];
    if nargin < 4 || isempty(maxSlots) || maxSlots < 1
        maxSlots = 4;
    end

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
        if isempty(cache), cache = struct('path',{},'vr',{},'lastUse',{}); end

        % 슬롯 탐색
        idx = 0;
        for k = 1:numel(cache)
            if strcmp(cache(k).path, filePath) && ~isempty(cache(k).vr) && isvalid(cache(k).vr)
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
                try, delete(cache(victim).vr); catch, end
                cache(victim) = [];
            end
            newSlot = struct('path', filePath, 'vr', VideoReader(filePath), 'lastUse', uint64(0));
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
