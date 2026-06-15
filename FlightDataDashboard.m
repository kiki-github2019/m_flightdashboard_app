classdef FlightDataDashboard < matlab.apps.AppBase
    % =========================================================================
    % Flight data review dashboard - V3.22 (refactor: module decomposition + cache data-structure improvement)
    % Description:
    %   [V3.22 changes]
    %   - #1 ErrorLog ring buffer (silent catch also post-mortem-inspectable)
    %        + dumpErrorLog(n, filterTag) helper method
    %   - #2 switch cacheGetFrame to lastUse-counter-based O(1) lookup
    %        (remove cell-array reference shuffle -> less GC pressure on large-frame lookup)
    %        cacheStoreFrame does in-place update + lastUse sync management
    %        evictByScore gains a lastUse arg -> score = (hits * recency) / bytes
    %   - #3 decompose loadAviFile into 6 helpers:
    %        confirmVideoReplace / invalidateFrameCache / computeStartTimeFromFlightData
    %        cleanupVideoResources / openVideoReader / applyVideoLoadedUI
    %        computeTotalFrames / loadFirstFrame
    %   - #4 magic-number constants: ASYNC_WORKER_COUNT, WORKER_VR_CACHE_SLOTS,
    %        MAX_SEQ_READ_STEP, MAX_PENDING_ITERS
    %   - #5 UIGroup alias: group the flat UI struct into attitude/map/video/plots/controls/data
    %        Existing flat fields are kept as-is (100% compatible); new code uses groups
    %   - #6 Static wrapper: workerDecodeFrame / workerCleanupCache
    %        -> secures a future +flightdash package migration option
    %   - #7 decompose createLayout: extract buildHeaderBar + add flight-path loop section guides
    %
    %   [Layout Improvement L1~L4 Applied - 2026-06-06]
    %   - board-off 4-row bodyGrid, 4px splitters, map/altitude independent toggles
    %   - responsive attitude gauge reflow, layout preset picker, draggable splitters
    %
    %   [V3.21 #1-A] Generation counter (AsyncGen): increments on each startAsyncDecode call,
    %     captures myGen on the future -> compared in onAsyncDecodeComplete to discard stale
    %     results. Even for the same frame, a generation mismatch is ignored -> blocks races.
    %   [V3.21 #3-A] 3-layer separation:
    %     Layer 1 requestFrame: entry point + cache lookup + sync/async strategy selection
    %     Layer 2 decodeFrameSync / startAsyncDecode: decoding (strategy pattern)
    %     Layer 3 displayFrame: display + cache store (write-through single exit)
    %     The existing updateVideoFrameByFrameNo delegates to requestFrame (compat).
    %   [V3.21 #2-A] persistent VideoReader in worker:
    %     asyncDecodeFramePersistent external function reuses the VR via a persistent var
    %     -> ~50ms->3ms per call. Recreates VR only when the file changes.
    %   [V3.20 kept] explicit resource cleanup, standardized sync-log prefix.
    %   [V3.19 kept] async decoding, adaptive prefetch, weighted LRU.
    %   [V3.18 kept] cache lookup clamp, full Pending drain, hard limit 1.0.
    %   [V3.17 kept] InGoToFrame coalescing, IsDecoding guard.
    % =========================================================================

    % ---------------------------------------------------------------------
    % Constants (magic-number removal)
    % ---------------------------------------------------------------------
    properties (Constant, Access = private)
        MAX_TABS          = 10
        MAX_PLOTS_PER_TAB = 12
        PLOT_ROW_HEIGHT   = 150     % per-plot panel height inside the H area (px)
        LAYOUT_SPLITTER_THICKNESS = 4
        MOCK_STEP_COUNT   = 200     % mock data step count
        VIDEO_THROTTLE_S  = 0.05    % video frame update throttle interval (s)
        SLIDER_THROTTLE_S = 0.03    % [V3.15 item 1] slider update min interval (s) - 33fps cap
        VIDEO_DIALOG_FOLLOW_S = 0.18 % [#5] Video dialog follower poll period (s)
        MAX_CACHE_FRAMES  = 200     % [V3.14] absolute upper bound (DynamicCacheLimit applies only at or below this)
        MIN_CACHE_FRAMES  = 5       % [V3.14] absolute lower bound
        REQ_KEYS          = {'Time', 'Roll', 'Pitch', 'Heading', 'Alt', 'Lat', 'Lon'}
        % [V3.22 #4] magic-number constants
        ASYNC_WORKER_COUNT    = 2    % parallel pool worker count (process pool)
        WORKER_VR_CACHE_SLOTS = 4    % worker persistent VideoReader LRU slot count
        MAX_SEQ_READ_STEP     = 4    % max step for sequential readFrame (random seek beyond this)
        MAX_PENDING_ITERS     = 10   % goToFrame Pending-drain loop max iterations
        PATH3D_FULL_MAX_POINTS = 5000 % max rendered points for dotted full 3D trajectory
        PATH3D_PAST_MAX_POINTS = 3000 % max rendered points for solid past 3D trajectory
    end

    properties (Access = public)
        UIFigure
        UI
        UIGroup           % [V3.22 #5] alias grouping UI into attitude/map/video/plots/controls/data
        SyncInput
        SyncBtn

        Models
        SyncState
        VideoState
        VideoSyncState    % [V3.12] video-flightdata sync info (array [1x2])
        WindowMinBtn
        WindowMaxBtn
        BoardToggleButtons
        LayoutPresetButtons
        HeaderLayoutPresetDD

        CoastlineData
        FixedAreaBounds

        DebugMode         = false   % [V3.14 item 6] when true, log zoom/pan off etc.
        State             = 'IDLE'  % [V3.17 (8)] 'IDLE' | 'DRAGGING' | 'UPDATING' | 'DECODING'
        UseAsyncDecode    = false   % [V3.19 (1)] enable async decoding (requires Parallel Toolbox)
    end

    properties (Access = private)
        LastVideoUpdate     = {uint64(0), uint64(0)}  % [PATCH] tic handles (per channel)
        IsUpdating          = [false, false] % recursion-prevention flag
        IsDraggingMarker    = false         % marker drag state flag
        DraggedMarker       = []            % graphics handle currently being dragged
        IsProgrammaticXLim  = [false, false] % [V3.11 A] block listener on programmatic XLim change (page turning etc.)
        DraggedFIdx         = 0             % [V3.11 B] fIdx being dragged
        DraggedFromVideo    = false         % [V3.12] whether drag started from the video frame marker
        VideoThrottleDyn    = 0.05          % [V3.12] (unused since V3.13, kept)
        LastDragTime        = {uint64(0), uint64(0)}  % [PATCH] per-channel tic handles
        LastDisplayedFrame  = [0, 0]        % [PATCH] frame actually shown on screen (display path only)
        LastDecodedFrame    = [0, 0]        % [Stabilization P1] last decode/read result frame (seq readFrame heuristic only)
        LastRequestedFrame  = [NaN, NaN]    % [Stabilization P1] most recently requested frame (user basis)
        PendingVideoFrame   = [NaN, NaN]    % [Stabilization P1] latest video frame request arriving during decode
        PendingVideoMode    = {'', ''}      % [Stabilization P1] source mode of the above frame request
        IsDeleting          = false         % [Stabilization P2] delete/close re-entry guard
        HISplitterFIdx      = 0             % [PATCH UX-3] channel dragging the H/I boundary
        IsDraggingSplitter  = false         % [PATCH UX-3b] splitter drag state flag
        BodyRowSplitter     = []            % [Layout] upper/lower board row splitter
        IsDraggingRowSplitter = false       % [Layout] row splitter drag state
        BodyRowSplitRatio   = 0.5           % [Layout] top board ratio in normal mode
        RowSplitterStartPoint = [0, 0]      % [Layout] drag start pointer
        RowSplitterStartRatio = 0.5         % [Layout] ratio at drag start
        IsDraggingColumnSplitter = false    % [Layout] general dashboard column splitter drag state
        DraggedColumnSplitterInfo = struct('fIdx', 0, 'leftCol', 0, 'rightCol', 0)
        ColumnSplitterStartPoint = [0, 0]
        ColumnSplitterStartWidths = {}
        UserColumnWidths = {struct(), struct()}   % [v4-R3] adjustable fixed-width struct per fIdx (attitudeWidth/mapAltWidth/infoWidth). plot/splitter/hidden not stored.
        FrameCache          = {{}, {}}      % [V3.13 C-1] per-flight-path frame cache
        FrameCacheKeys      = {[], []}      % [V3.13 C-1] per-flight-path cache key order (LRU)
        DynamicCacheLimit   = [50, 50]      % [V3.14 item 3] per-flight-path dynamically computed max cache frame count
        CacheBudgetMB       = 100           % [v-fix6] per-flight-path cache memory budget (MB) default 100 - adjustable in GUI
        LastSliderUpdate    = {uint64(0), uint64(0)}  % [PATCH] tic handles (per channel)
        LastDragTableUpdate = [uint64(0), uint64(0)]  % [Perf] dataTable throttle (during drag)
        InGoToFrame         = [false, false] % [V3.16] goToFrame re-entry guard flag
        PendingFrame        = [NaN, NaN]     % [V3.17 (1)(9)] latest frame request arriving during processing
        PendingMode         = {'', ''}        % [V3.17 (1)(9)] latest mode arriving during processing
        InCascade           = false          % [V3.17 (4)(11)] cascade recursion guard (instance property)
        InBoardToggle       = false          % [bug#4] toggleBoardVisibility re-entry guard
        IsDecoding          = [false, false] % [V3.17 (7)] decoding-in-progress guard
        CacheBytesUsed      = [0, 0]         % [V3.17 (6)] per-flight-path actual memory used (bytes)
        FrameCacheHits      = {[], []}        % [V3.19 (3)] access count per frame (weighted LRU)
        FrameCacheLastUse   = {[], []}        % [V3.22 #2] last-use tic per frame (uint64) - LRU basis
        FrameCacheUseCounter = uint64(0)      % [V3.22 #2] monotonic-increasing use counter (tic replacement)
        AsyncPool           = []              % [V3.19 (1)] parallel pool handle
        AsyncFutures        = {[], []}        % [V3.19 (1)] in-flight parfeval future
        AsyncTargetFrame    = [NaN, NaN]      % [V3.19 (1)] frame No being async-decoded
        AsyncGen            = [0, 0]          % [V3.21 #1-A] generation counter (race blocking)
        VideoFilePath       = {'', ''}        % [V3.19 (1)] for the worker to create its own VideoReader
        CurrentVideoFrame   = {[], []}        % latest original frame to re-render when display resolution changes
        VideoDialogFollowTimer = []           % poll timer that moves the AVI control dialog along when the Video Player moves
        VideoDialogLastViewerPos = {[], []}   % last Video Player position (per channel)
        FlightPlayTimer      = {[], []}        % flight data row playback timers
        FlightPlayActive     = [false, false]
        FlightPlayFps        = 20    % [#8] changing this requires a FlightPlayTimer restart (stop->start) for Period to apply
        PendingFlightSyncAnchor = struct('T1', NaN, 'T2', NaN, ...   % [Sync Search] sync-basis candidate
            'Source1', '', 'Source2', '', 'Index1', NaN, 'Index2', NaN, 'Value1', NaN, 'Value2', NaN)
        SyncSearchDialogs    = {[], []}        % [Sync Search] search dialog handle (lifecycle tracking)
        LastInfoTableSelectionValid = [false, false]   % [Sync Search] whether an actual row selection happened
        NormalWindowPosition = []             % last normal window position (for maximize restore)
        IsRestoringWindow   = false           % prevent SizeChanged save during restore
        IsWindowManuallyMaximized = false     % fallback for versions without WindowState support
        DragVelocity        = [0, 0]          % [V3.19 (2)] frames/sec (sign: direction)
        DragVelocitySamples = {[], []}        % [V3.19 (2)] recent samples (for moving average)
        % [V3.22 #1] keep in ring buffer so silent catch is also post-mortem-inspectable
        % - stack stored cell-wrapped (avoid struct-array dimension mismatch)
        ErrorLog            = struct('time', {}, 'tag', {}, 'identifier', {}, 'message', {}, 'stack', {})
        ErrorLogCapacity    = 200             % [V3.22 #1] ring buffer max size

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
        BoardPanelVisibleSnapshot = {struct(), struct()} % PanelVisible/ColumnWidth restore snapshot before board-off entry
        BodyGrid             = []              % [L1 C-1] handle to bodyGrid (for dynamic RowHeight change)
        BoardOffSourceRatio  = 1.0             % [v4-R1] off: source 100% (summary dropped). active board shown alone. (clamp 0.5~1.0)
        CurrentLayoutPreset  = 'custom'        % [L3] active layout preset name
        UserLayoutPresets    = struct('Name', {}, 'SavedAt', {}, 'Layout', {})  % [L5] project-persisted custom layout snapshots
        Path3DVisible        = [false, false]  % [3D Path P1] desired dialog visibility for project round-trip/board-off restore
        Path3DAttitudeEnabled = false           % [3D Path P2 #4] gate drone attitude rotation; default off until ENU/NED alignment verified

        % [Audit fix #1] Edit dialog UI handles (all default to [])
        EditDialogStatusLbl  = []
        EditDialogDirtyLbl   = []
        EditDialogTimeLbl    = []
        EDProjectPathLbl     = []
        EDProjectStatusLbl   = []
        EDProjectAutosaveCB  = []
        EDProjectConfirmCloseCB = []
        EDProjectLastSaveLbl = []
        EDProjectLayoutLbl   = []
        EDProjectLayoutPresetDD = []
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
        % [F-01] Plot Manager property panel handle
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
        % Constructor and initialization
        % ---------------------------------------------------------------------
        function app = FlightDataDashboard()
            app.Models = [app.createEmptyModel(), app.createEmptyModel()];
            app.SyncState = struct('IsSynced', false, 'SyncT1', 0, 'SyncT2', 0);
            app.VideoState = struct('videoReader', {[], []}, 'videoStartTime', {0, 0}, 'vidImageHandle', {[], []});
            % [V3.12] VideoSyncState init: per-flight-path sync info
            app.VideoSyncState = struct( ...
                'IsSynced',     {false, false}, ...     % whether sync setup is complete
                'AnchorFrame',  {0, 0}, ...             % sync-basis frame number
                'AnchorTime',   {0, 0}, ...             % sync-basis flight time (s)
                'VideoFps',     {70, 70}, ...           % video Hz (default 70)
                'DataFps',      {50, 50}, ...           % flight-data Hz (default 50)
                'TotalFrames',  {0, 0}, ...             % video total frame count
                'CurrentFrame', {1, 1});                % current frame position
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
            % (was: close(findobj('Type', 'figure', 'Name', 'Flight Data Review Dashboard (Dual)')); )
            app.NormalWindowPosition = app.getInitialWindowPosition();
            app.UIFigure = uifigure('Name', '비행 데이터 리뷰 대시보드 (Dual)', ...
                                    'Units', 'pixels', ...
                                    'Position', app.NormalWindowPosition, ...
                                    'Color', app.getLightTheme().windowBg, ...
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
            app.applyLightTheme(app.UIFigure);  % v4-Theme: unify entire window to light
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
            % [V3.20 (5)] explicit resource cleanup: VideoReader, AsyncPool, futures
            % [Stabilization P2] re-entry guard so partial cleanup cannot run twice
            if app.IsDeleting, return; end
            app.IsDeleting = true;
            app.IsDraggingSplitter = false;
            app.IsDraggingRowSplitter = false;
            app.IsDraggingColumnSplitter = false;
            app.stopVideoDialogFollowTimer();
            % [bug#3] stop all timers first right after IsDeleting -> blocks the window where a
            %          callback re-fires during later handle delete / queue drain (#1/#2 guards = double safety). handle delete
            %          is done later (L4xx, per-fIdx) and is idempotent since already stopped.
            try
                for tIdx = 1:numel(app.FlightPlayTimer)
                    tmr = app.FlightPlayTimer{tIdx};
                    if ~isempty(tmr) && isvalid(tmr) && strcmpi(tmr.Running, 'on'), stop(tmr); end
                end
            catch ME
                app.logCaught(ME, 'delete:early-stop-flightplay');
            end
            try
                if ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer) && strcmpi(app.EditApplyTimer.Running, 'on')
                    stop(app.EditApplyTimer);
                end
            catch ME
                app.logCaught(ME, 'delete:early-stop-editapply');
            end
            try
                if ~isempty(app.AutosaveTimer) && isvalid(app.AutosaveTimer) && strcmpi(app.AutosaveTimer.Running, 'on')
                    stop(app.AutosaveTimer);
                end
            catch ME
                app.logCaught(ME, 'delete:early-stop-autosave');
            end
            app.disableAxesInteractionsBeforeDelete(app.UIFigure, 'delete:uifigure-axes');
            try
                for fIdx = 1:2
                    try
                        app.stopFlightPlay(fIdx);
                        if numel(app.FlightPlayTimer) >= fIdx && ~isempty(app.FlightPlayTimer{fIdx}) ...
                                && isvalid(app.FlightPlayTimer{fIdx})
                            delete(app.FlightPlayTimer{fIdx});
                        end
                        app.FlightPlayTimer{fIdx} = [];
                    catch ME
                        app.logCaught(ME, 'delete:flight-play-timer');
                    end
                    try
                        % v-fix3: Sync Search dialog cleanup
                        if numel(app.SyncSearchDialogs) >= fIdx && ~isempty(app.SyncSearchDialogs{fIdx}) ...
                                && isvalid(app.SyncSearchDialogs{fIdx})
                            delete(app.SyncSearchDialogs{fIdx});
                        end
                        app.SyncSearchDialogs{fIdx} = [];
                    catch ME
                        app.logCaught(ME, 'delete:sync-search-dialog');
                    end
                    try
                        if ~isempty(app.UI) && numel(app.UI) >= fIdx && ...
                           isfield(app.UI(fIdx), 'vidViewerDialog') && ...
                           ~isempty(app.UI(fIdx).vidViewerDialog) && isvalid(app.UI(fIdx).vidViewerDialog)
                            app.disableAxesInteractionsBeforeDelete(app.UI(fIdx).vidViewerDialog, 'delete:vid-viewer-dialog-axes');
                            delete(app.UI(fIdx).vidViewerDialog);
                        end
                    catch ME
                        app.logCaught(ME, 'delete:vid-viewer-dialog');
                    end
                    try
                        if ~isempty(app.UI) && numel(app.UI) >= fIdx && ...
                           isfield(app.UI(fIdx), 'vidControlDialog') && ...
                           ~isempty(app.UI(fIdx).vidControlDialog) && isvalid(app.UI(fIdx).vidControlDialog)
                            app.disableAxesInteractionsBeforeDelete(app.UI(fIdx).vidControlDialog, 'delete:vid-control-dialog-axes');
                            delete(app.UI(fIdx).vidControlDialog);
                        end
                    catch ME
                        app.logCaught(ME, 'delete:vid-control-dialog');
                    end
                    try
                        if ~isempty(app.UI) && numel(app.UI) >= fIdx && ...
                           isfield(app.UI(fIdx), 'path3DDialog') && ...
                           ~isempty(app.UI(fIdx).path3DDialog) && isvalid(app.UI(fIdx).path3DDialog)
                            app.disableAxesInteractionsBeforeDelete(app.UI(fIdx).path3DDialog, 'delete:path3D-dialog-axes');
                            delete(app.UI(fIdx).path3DDialog);
                            app.UI(fIdx).path3DDialog = [];
                        end
                    catch ME
                        app.logCaught(ME, 'delete:path3D-dialog');
                    end
                    % VideoReader cleanup
                    try
                        if ~isempty(app.VideoState(fIdx).videoReader) && ...
                           isvalid(app.VideoState(fIdx).videoReader)
                            delete(app.VideoState(fIdx).videoReader);
                        end
                    catch ME
                        app.logCaught(ME, 'delete:video-reader');
                    end
                    % cancel in-flight async futures
                    try
                        if ~isempty(app.AsyncFutures{fIdx}) && isvalid(app.AsyncFutures{fIdx})
                            cancel(app.AsyncFutures{fIdx});
                        end
                    catch ME
                        % [Medium 2] precise subsystem tag - cleanup path
                        app.logCaught(ME, 'delete:future-cancel');
                    end
                end
                % clear cache (free memory immediately)
                app.FrameCache = {{}, {}};
                app.FrameCacheKeys = {[], []};
                app.FrameCacheHits = {[], []};
                app.FrameCacheLastUse = {[], []};   % [V3.22 #2] reset LRU counter
                app.FrameCacheUseCounter = uint64(0);
                app.CacheBytesUsed = [0, 0];
                app.AsyncGen = [0, 0];   % [V3.21 #1-A] generation reset
                app.LastDisplayedFrame = [0, 0];   % [PATCH] reset early-return key
            catch ME
                app.logCaught(ME, 'delete:cache-reset');
            end

            % [PATCH / V3.22 #6] explicitly release worker persistent VR -> return file lock immediately
            try
                if ~isempty(app.AsyncPool) && isvalid(app.AsyncPool)
                    parfevalOnAll(app.AsyncPool, @FlightDataDashboard.workerCleanupCache, 0);
                else
                    % [A1] on invalid pool, directly clean the client-side persistent cache (double safety)
                    cleanupAsyncDecodeCache();
                end
            catch ME
                app.logCaught(ME, 'delete:worker-cache-cleanup');
                % [A1] also guarantee client-side cleanup on parfevalOnAll exception
                try
                    cleanupAsyncDecodeCache();
                catch
                end
            end

            % [Phase 1 D2] stop debounce + autosave timers before tearing down UI
            try
                if ~isempty(app.EditApplyTimer) && isvalid(app.EditApplyTimer)
                    try
                        stop(app.EditApplyTimer);
                    catch ME_stop
                        app.logCaught(ME_stop, 'delete:edit-apply-timer-stop');
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
                    catch ME_stop
                        app.logCaught(ME_stop, 'delete:autosave-timer-stop');
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

        function disableAxesInteractionsBeforeDelete(app, rootObj, tag)
            if nargin < 3 || isempty(tag), tag = 'disableAxesInteractionsBeforeDelete'; end
            try
                if isempty(rootObj) || ~isvalid(rootObj), return; end
                axesList = findall(rootObj, 'Type', 'axes');
            catch ME
                app.logCaught(ME, [tag ':findall']);
                return;
            end
            for k = 1:numel(axesList)
                ax = axesList(k);
                try
                    if isempty(ax) || ~isvalid(ax), continue; end
                    try
                        disableDefaultInteractivity(ax);
                    catch ME_disable
                        app.logCaught(ME_disable, [tag ':disable-default']);
                    end
                    if isprop(ax, 'Interactions')
                        ax.Interactions = [];
                    end
                    if isprop(ax, 'Toolbar') && ~isempty(ax.Toolbar)
                        ax.Toolbar.Visible = 'off';
                    end
                    if isprop(ax, 'ButtonDownFcn')
                        ax.ButtonDownFcn = [];
                    end
                catch ME
                    app.logCaught(ME, [tag ':axis']);
                end
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
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            bodyAttitude = struct('bodyX', '', 'bodyY', '', 'bodyZ', '');
            model.wayPoints = wayPoints;
            model.bodyAttitude = bodyAttitude;
            model.option = struct();
            model.option.wayPoints = wayPoints;
            model.option.bodyAttitude = bodyAttitude;
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
                    btn = gobjects(0); %#ok<NASGU>
                    routeName = '';   %#ok<NASGU> togglePanel fallback target
                    switch lower(char(pnlName))
                        case 'attitude', btn = app.UI(fIdx).btnAtt;            routeName = 'attitude';
                        case {'map', 'maponly'}, btn = app.UI(fIdx).btnMap;    routeName = 'mapOnly';
                        case 'altonly',  btn = app.UI(fIdx).btnAlt;            routeName = 'altOnly';
                        case {'path3d', '3d'}, btn = app.UI(fIdx).btnPath3D;   routeName = 'path3D';
                        case 'info',     btn = app.UI(fIdx).btnInfo;           routeName = 'info';
                        case {'dataview', 'plot'}, btn = app.UI(fIdx).btnDataView; routeName = 'dataView';
                        case 'video',    btn = app.UI(fIdx).btnVid;            routeName = 'video';
                        otherwise
                            error('FlightDataDashboard:UnknownPanelToggle', ...
                                  'Unknown panel toggle: %s', char(pnlName));
                    end
                    % v2-B: if no btn handle, call togglePanel directly (info/dataView header buttons removed)
                    if strcmp(routeName, 'path3D')
                        app.btnPath3DPushed(fIdx);
                    elseif isempty(btn) || ~isvalid(btn)
                        app.togglePanel(fIdx, routeName);
                    else
                        cb = btn.ButtonPushedFcn;
                        cb(btn, []);
                    end
                case 'pushBoardToggleButton'
                    fIdx = varargin{1};
                    btn = app.BoardToggleButtons(fIdx);
                    cb = btn.ButtonPushedFcn;
                    cb(btn, []);
                case 'togglePanel',                   app.togglePanel(varargin{:});
                case 'toggleBoardVisibility',         app.toggleBoardVisibility(varargin{:});
                case 'applyLayoutPreset',             app.applyLayoutPreset(varargin{:});
                case 'setBodyRowSplitRatio',          app.setBodyRowSplitRatio(varargin{:});
                case 'simulateColumnSplitterDrag',     app.simulateColumnSplitterDrag(varargin{:});
                case 'saveCurrentLayoutPreset',        app.saveCurrentLayoutPresetForTest(varargin{:});
                case 'applySavedLayoutPreset',         app.applySavedLayoutPresetForTest(varargin{:});
                case 'deleteSavedLayoutPreset',        app.deleteSavedLayoutPresetForTest(varargin{:});
                case 'roundTripProjectLayoutState'
                    beforeState = app.getTestState();
                    st = app.collectCurrentProjectState();
                    app.applyProjectState(st, []);
                    afterState = app.getTestState();
                    [ok, issues] = app.compareRoundTripLayoutState(beforeState, afterState);
                    varargout{1} = struct('Before', beforeState, 'After', afterState, ...
                                          'ProjectState', st, 'Ok', ok, 'Issues', {issues});
                case 'boardOffAddPlotTab',            app.boardOffAddPlotTab(varargin{:});
                case 'boardOffClearCurrentTab',       app.boardOffClearCurrentTab(varargin{:});
                case 'boardOffPlotSelectedVariable',  app.boardOffPlotSelectedVariable(varargin{:});
                case 'applyTimeChange',               app.applyTimeChange(varargin{:});
                case 'toggleFlightPlayControlPanel',  app.toggleFlightPlayControlPanel(varargin{:});
                case 'moveFlightDataFrame',           app.moveFlightDataFrame(varargin{:});
                case 'refreshFlightPlayControlPanel', app.refreshFlightPlayControlPanel(varargin{:});
                case 'handleFlightPlaySliderChange',  app.handleFlightPlaySliderChange(varargin{:});
                case 'handleFlightPlayFrameInputChange', app.handleFlightPlayFrameInputChange(varargin{:});
                case 'handleFlightPlayTimeInputChange', app.handleFlightPlayTimeInputChange(varargin{:});
                case 'startFlightPlay',               app.startFlightPlay(varargin{:});
                case 'stopFlightPlay',                app.stopFlightPlay(varargin{:});
                case 'isFlightPlayTimerAlive'
                    % v5-J: timer handle exists + Running state (for stop/cleanup verification)
                    fk = varargin{1};
                    alive = false;
                    try
                        if fk >= 1 && fk <= numel(app.FlightPlayTimer) ...
                                && ~isempty(app.FlightPlayTimer{fk}) && isvalid(app.FlightPlayTimer{fk})
                            alive = strcmpi(app.FlightPlayTimer{fk}.Running, 'on');
                        end
                    catch
                        alive = false;
                    end
                    varargout{1} = alive;
                case 'setFlightDataSync',             app.setFlightDataSync(varargin{:});
                case 'searchFlightDataValue',         ok = app.searchFlightDataValue(varargin{:}); if nargout, varargout{1} = ok; end
                case 'computeSyncSearchRows'
                    fIdx = varargin{1}; target = varargin{2};
                    yCol = app.Models(fIdx).displayMeta(app.Models(fIdx).selectedRow).header;
                    tCol = app.Models(fIdx).mappedCols.Time;
                    varargout{1} = app.computeSyncSearchRows(app.Models(fIdx).rawData.(yCol), ...
                        app.Models(fIdx).rawData.(tCol), target);
                case 'setPendingSyncAnchor'
                    % optional 3rd~5th args: Source/Index/Value metadata (preserved same as the UI path)
                    fk = varargin{1}; tv = varargin{2};
                    src = ''; idx = NaN; val = NaN;
                    if numel(varargin) >= 3, src = varargin{3}; end
                    if numel(varargin) >= 4, idx = varargin{4}; end
                    if numel(varargin) >= 5, val = varargin{5}; end
                    if fk == 1
                        app.PendingFlightSyncAnchor.T1 = tv;
                        app.PendingFlightSyncAnchor.Source1 = src;
                        app.PendingFlightSyncAnchor.Index1 = idx;
                        app.PendingFlightSyncAnchor.Value1 = val;
                    else
                        app.PendingFlightSyncAnchor.T2 = tv;
                        app.PendingFlightSyncAnchor.Source2 = src;
                        app.PendingFlightSyncAnchor.Index2 = idx;
                        app.PendingFlightSyncAnchor.Value2 = val;
                    end
                case 'applyPendingSyncAnchor',        app.syncSearchApply([]);
                case 'getPendingSyncAnchor',          varargout{1} = app.PendingFlightSyncAnchor;
                case 'getOpenDialogHandlesForTest',   varargout{1} = app.getOpenDialogHandlesForTest();
                case 'computeSyncSearchRowsRaw',      varargout{1} = app.computeSyncSearchRows(varargin{:});
                case 'getSelectedInfoValueForTest'
                    % v-fix6: actual current index value of the selected item (secures the exact target)
                    fk = varargin{1};
                    try
                        yCol = app.Models(fk).displayMeta(app.Models(fk).selectedRow).header;
                        ix = max(1, min(height(app.Models(fk).rawData), round(app.Models(fk).currentIndex)));
                        val = double(app.Models(fk).rawData.(yCol)(ix));
                    catch
                        val = NaN;
                    end
                    varargout{1} = val;
                case 'getInfoTableMenuTexts'
                    % v-fix9: collect normal/board-off info-table context-menu item texts
                    fIdx = varargin{1};
                    tbl = [];
                    if numel(varargin) >= 2 && strcmpi(char(varargin{2}), 'boardoff')
                        if isfield(app.UI(fIdx), 'boardOffTable'), tbl = app.UI(fIdx).boardOffTable; end
                    else
                        if isfield(app.UI(fIdx), 'dataTable'), tbl = app.UI(fIdx).dataTable; end
                    end
                    texts = {};
                    try
                        if ~isempty(tbl) && isvalid(tbl) && ~isempty(tbl.ContextMenu) && isvalid(tbl.ContextMenu)
                            kids = tbl.ContextMenu.Children;
                            for ki = 1:numel(kids)
                                if isprop(kids(ki), 'Text'), texts{end+1} = char(kids(ki).Text); end %#ok<AGROW>
                            end
                        end
                    catch
                    end
                    varargout{1} = texts;
                case 'setVideoSync',                  app.setVideoSync(varargin{:});
                case 'saveProjectFile',               varargout{1} = app.saveProjectFile(varargin{:});
                case 'loadProjectFile',               varargout{1} = app.loadProjectFile(varargin{:});
                case 'autoLoadProjectFromFile',       app.autoLoadProjectFromFile(varargin{:});
                case 'editDialogOpenProjectFromPath'
                    % v-fixD: same defensive pattern as production editDialogAutoLoad
                    try
                        app.autoLoadProjectFromFile(varargin{1});
                    catch ME
                        try
                            app.logCaught(ME, 'test:editDialogOpenProjectFromPath:autoLoad');
                        catch
                        end
                    end
                    app.safeRefreshEditDialog('test:editDialogOpenProjectFromPath:refresh');
                case 'setVideoViewerVisible',         app.setVideoViewerVisible(varargin{:});
                case 'toggleVideoControlDialog',      app.toggleVideoControlDialog(varargin{:});
                case 'hideVideoControlDialog',        app.hideVideoControlDialog(varargin{:});
                case 'setPath3DDialogVisible',        app.setPath3DDialogVisible(varargin{:});
                case 'getPath3DState',                varargout{1} = app.getPath3DStateForTest();
                case 'path3DYawNedToEnu',             varargout{1} = app.path3DYawNedToEnu(varargin{:});
                case 'goToFrame',                     app.goToFrame(varargin{:});
                case 'loadAviFileFromPath',           varargout{1} = app.loadAviFileFromPath(varargin{:});
                case 'plotSelectedVariable',          app.plotSelectedVariable(varargin{:});
                case 'addPlotTab',                    app.addPlotTab(varargin{:});
                case 'getTestState',                  varargout{1} = app.getTestState();
                case 'collectCurrentProjectState',    varargout{1} = app.collectCurrentProjectState();
                case 'applyProjectState'
                    if numel(varargin) < 2
                        app.applyProjectState(varargin{1}, []);
                    else
                        app.applyProjectState(varargin{:});
                    end
                case 'setSelectedRow'
                    fIdx = varargin{1}; row = varargin{2};
                    app.Models(fIdx).selectedRow = row;
                    if fIdx >= 1 && fIdx <= numel(app.LastInfoTableSelectionValid)
                        app.LastInfoTableSelectionValid(fIdx) = true;   % v-fix: treat a test selection as valid too
                    end
                case 'clearPendingSyncAnchor',        app.clearPendingSyncAnchor([]);
                % v-runner: EditDialog auto-test dispatch
                case 'openEditDialog',                app.openEditDialog(); if nargout, varargout{1} = app.EditDialog; end
                case 'closeEditDialog',               app.closeEditDialog();
                case 'applyPendingDialogChanges',     app.applyPendingDialogChanges();
                case 'editDialogSaveProject',         app.editDialogSaveProject();
                case 'editDialogSaveProjectAs',       app.editDialogSaveProjectAs();
                case 'setProjectFilePath'
                    % v-fixG: test-only setter that presets/clears ProjectFilePath so the auto-runner
                    %         takes the non-modal editDialogSaveProject path.
                    % v-fixM4: varargout{1} = previous value. Caller can use it for restore.
                    if nargout >= 1, varargout{1} = char(app.ProjectFilePath); end
                    if isempty(varargin) || isempty(varargin{1})
                        app.ProjectFilePath = '';
                    else
                        app.ProjectFilePath = app.normalizeAbsPath(varargin{1});
                    end
                    try
                        app.refreshProjectTab();
                    catch ME_pathRefresh
                        app.logCaught(ME_pathRefresh, 'testHook:setProjectFilePath:refreshProjectTab');
                    end
                case 'editDialogApplyOptionDraft',    app.editDialogApplyOptionDraft();
                case 'capturePlotConfigAndRefresh',   app.capturePlotConfigAndRefresh();
                case 'editDialogRebuildPlots',        app.editDialogRebuildPlots();
                case 'editDialogToggleXAuto',         app.editDialogToggleXAuto(varargin{:});
                case 'editDialogToggleYAuto',         app.editDialogToggleYAuto(varargin{:});
                case 'editDialogApplyPlotProps',      app.editDialogApplyPlotProps();
                case 'editDialogSyncTabXLimAll',      app.editDialogSyncTabXLimAll();
                case 'editDialogSyncSelectedPlotXLimAll', app.editDialogSyncSelectedPlotXLimAll();
                case 'switchEditDialogTab'
                    % varargin{1} = tab title ('Project'/'Files'/'Sync'/'Options'/'Plot Manager'/'Export')
                    if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                        tg = findall(app.EditDialog, 'Type', 'uitabgroup');
                        if ~isempty(tg)
                            tabs = tg(1).Children;
                            target = char(varargin{1});
                            for tI = 1:numel(tabs)
                                try
                                    if strcmp(char(tabs(tI).Title), target)
                                        tg(1).SelectedTab = tabs(tI);
                                        break;
                                    end
                                catch
                                end
                            end
                        end
                    end
                otherwise
                    error('FlightDataDashboard:UnknownTestHook', ...
                          'Unknown testHook method: %s', methodName);
            end
        end

        function state = getTestState(app)
            % [Testing] Read-only UI/model snapshot for auto_test_runner.m.
            state = struct();
            state.BoardOffState = logical(app.BoardOffState);
            state.CurrentLayoutPreset = char(app.CurrentLayoutPreset);
            state.BoardOffSourceRatio = double(app.BoardOffSourceRatio);
            state.BodyRowSplitRatio = double(app.BodyRowSplitRatio);
            state.ProjectFilePath = char(app.ProjectFilePath);
            state.ProjectDirty = logical(app.ProjectDirty);
            state.ProjectLastSaveText = char(app.ProjectLastSaveText);
            state.SyncState = app.SyncState;
            state.EditDialogVisible = false;
            try
                state.EditDialogVisible = ~isempty(app.EditDialog) && isvalid(app.EditDialog) && app.isUiVisible(app.EditDialog);
            catch ME
                app.logCaught(ME, 'test:get-edit-dialog-visible');
            end
            state.vidViewerDialogVisible = false(1, 2);
            state.vidControlDialogVisible = false(1, 2);
            state.path3DDialogVisible = false(1, 2);
            state.path3DDesiredVisible = logical(app.Path3DVisible);
            try
                for vIdx = 1:min(2, numel(app.UI))
                    if isfield(app.UI(vIdx), 'vidViewerDialog') && ~isempty(app.UI(vIdx).vidViewerDialog) ...
                            && isvalid(app.UI(vIdx).vidViewerDialog)
                        state.vidViewerDialogVisible(vIdx) = app.isUiVisible(app.UI(vIdx).vidViewerDialog);
                    end
                    if isfield(app.UI(vIdx), 'vidControlDialog') && ~isempty(app.UI(vIdx).vidControlDialog) ...
                            && isvalid(app.UI(vIdx).vidControlDialog)
                        state.vidControlDialogVisible(vIdx) = app.isUiVisible(app.UI(vIdx).vidControlDialog);
                    end
                    if isfield(app.UI(vIdx), 'path3DDialog') && ~isempty(app.UI(vIdx).path3DDialog) ...
                            && isvalid(app.UI(vIdx).path3DDialog)
                        state.path3DDialogVisible(vIdx) = app.isUiVisible(app.UI(vIdx).path3DDialog);
                    end
                end
            catch ME
                app.logCaught(ME, 'test:get-video-dialog-visible');
            end
            state.UserLayoutPresetCount = numel(app.UserLayoutPresets);
            state.UserLayoutPresetNames = {};
            if ~isempty(app.UserLayoutPresets) && isstruct(app.UserLayoutPresets)
                try
                    state.UserLayoutPresetNames = arrayfun(@(p) char(p.Name), ...
                        app.UserLayoutPresets, 'UniformOutput', false);
                catch ME
                    app.logCaught(ME, 'test:get-layout-preset-names');
                end
            end
            state.BodyRowSplitterVisible = false;
            state.BodyRowHeight = {};
            try
                if ~isempty(app.BodyGrid) && isvalid(app.BodyGrid)
                    state.BodyRowHeight = app.BodyGrid.RowHeight;
                end
                if ~isempty(app.BodyRowSplitter) && isvalid(app.BodyRowSplitter)
                    state.BodyRowSplitterVisible = app.isUiVisible(app.BodyRowSplitter);
                end
            catch ME
                app.logCaught(ME, 'test:get-body-row-height');
            end
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
            panelVisible = struct('attitude', false, 'map', false, ...
                'mapOnly', false, 'altOnly', false, 'video', false, ...
                'info', true, 'dataView', true);
            s = struct( ...
                'exists', false, ...
                'panelVisible', false, ...
                'PanelVisible', panelVisible, ...
                'sideHandleVisible', panelVisible, ...
                'dataLoaded', false, ...
                'rawDataRows', 0, ...
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
                'columnSplitterVisible', [], ...
                'attitudeGridRows', 0, ...
                'attitudeGridColumns', 0, ...
                'attitudeLabelFontSize', NaN, ...
                'plotTabCount', 0, ...
                'selectedPlotTab', 0, ...
                'plotCounts', [], ...
                'totalPlotCount', 0, ...
                'selectedTabPlotCount', 0, ...
                'altMarkerInteractive', false, ...
                'altLineInteractive', false, ...
                'flightPlay', struct('buttonValid', false, 'panelValid', false, 'panelVisible', false, ...
                                     'sliderValid', false, 'sliderValue', NaN, 'sliderLimits', [NaN NaN], ...
                                     'frameInputValid', false, 'frameValue', NaN, ...
                                     'timeInputValid', false, 'timeValue', NaN, ...
                                     'playActive', false, 'playButtonText', ''), ...
                'videoSync', struct('IsSynced', false, 'AnchorFrame', 0, 'AnchorTime', 0, ...
                                    'VideoFps', 0, 'DataFps', 0, 'TotalFrames', 0, 'CurrentFrame', 0), ...
                'boardOffPanelVisible', false, ...
                'arrangementMode', 'normal', ...
                'boardOff', struct('tableRows', 0, 'buttonTexts', {{}}, 'tabCount', 0, ...
                                   'selectedTab', 0, 'plotCounts', [], 'totalPlotCount', 0, ...
                                   'markerCount', 0, 'interactiveMarkerCount', 0, ...
                                   'lineCount', 0, 'interactiveLineCount', 0, ...
                                   'firstMarkerX', NaN, 'firstLineX', NaN), ...
                'path3DDesiredVisible', false, ...
                'path3DDialogVisible', false, ...
                'path3DAxesValid', false, ...
                'path3DDroneTransformValid', false, ...
                'path3DBodyAxesValid', false, ...
                'path3DPastPointCount', 0);
        end

        function s = collectTestBoardState(app, fIdx)
            s = app.emptyTestBoardState();
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                s.exists = true;
                s.panelVisible = app.isUiVisible(app.UI(fIdx).panel);

                if isfield(app.UI(fIdx), 'PanelVisible')
                    names = {'attitude', 'mapOnly', 'altOnly', 'video', 'info', 'dataView'};
                    for iName = 1:numel(names)
                        nm = names{iName};
                        if isfield(app.UI(fIdx).PanelVisible, nm)
                            s.PanelVisible.(nm) = logical(app.UI(fIdx).PanelVisible.(nm));
                        end
                    end
                    s.PanelVisible.map = s.PanelVisible.mapOnly || s.PanelVisible.altOnly;
                end
                if isfield(app.UI(fIdx), 'panelAttitude')
                    s.sideHandleVisible.attitude = app.isUiVisible(app.UI(fIdx).panelAttitude);
                end
                if isfield(app.UI(fIdx), 'panelMapAlt')
                    s.sideHandleVisible.map = app.isUiVisible(app.UI(fIdx).panelMapAlt);
                end
                if isfield(app.UI(fIdx), 'vidViewerDialog') && ~isempty(app.UI(fIdx).vidViewerDialog) ...
                        && isvalid(app.UI(fIdx).vidViewerDialog)
                    s.sideHandleVisible.video = app.isUiVisible(app.UI(fIdx).vidViewerDialog);
                elseif isfield(app.UI(fIdx), 'panelVideo')
                    s.sideHandleVisible.video = app.isUiVisible(app.UI(fIdx).panelVideo);
                end
                if numel(app.Path3DVisible) >= fIdx
                    s.path3DDesiredVisible = logical(app.Path3DVisible(fIdx));
                end
                if isfield(app.UI(fIdx), 'path3DDialog') && ~isempty(app.UI(fIdx).path3DDialog) ...
                        && isvalid(app.UI(fIdx).path3DDialog)
                    s.path3DDialogVisible = app.isUiVisible(app.UI(fIdx).path3DDialog);
                end
                if isfield(app.UI(fIdx), 'path3DAxes') && ~isempty(app.UI(fIdx).path3DAxes) ...
                        && isvalid(app.UI(fIdx).path3DAxes)
                    s.path3DAxesValid = true;
                end
                if isfield(app.UI(fIdx), 'path3DDroneTransform') && ~isempty(app.UI(fIdx).path3DDroneTransform) ...
                        && isvalid(app.UI(fIdx).path3DDroneTransform)
                    s.path3DDroneTransformValid = true;
                end
                if isfield(app.UI(fIdx), 'path3DBodyAxes') && ~isempty(app.UI(fIdx).path3DBodyAxes)
                    try
                        s.path3DBodyAxesValid = all(isvalid(app.UI(fIdx).path3DBodyAxes));
                    catch
                        s.path3DBodyAxesValid = false;
                    end
                end
                if isfield(app.UI(fIdx), 'path3DPastTrajectory') && ~isempty(app.UI(fIdx).path3DPastTrajectory) ...
                        && isvalid(app.UI(fIdx).path3DPastTrajectory)
                    s.path3DPastPointCount = numel(app.UI(fIdx).path3DPastTrajectory.XData);
                end
                if isfield(app.UI(fIdx), 'panelAttitudeGrid') && ~isempty(app.UI(fIdx).panelAttitudeGrid) ...
                        && isvalid(app.UI(fIdx).panelAttitudeGrid)
                    s.attitudeGridRows = numel(app.UI(fIdx).panelAttitudeGrid.RowHeight);
                    s.attitudeGridColumns = numel(app.UI(fIdx).panelAttitudeGrid.ColumnWidth);
                end
                if isfield(app.UI(fIdx), 'pitchLabel') && ~isempty(app.UI(fIdx).pitchLabel) ...
                        && isvalid(app.UI(fIdx).pitchLabel)
                    s.attitudeLabelFontSize = double(app.UI(fIdx).pitchLabel.FontSize);
                end

                s.dataLoaded = ~isempty(app.Models(fIdx).rawData);
                if s.dataLoaded
                    s.rawDataRows = height(app.Models(fIdx).rawData);
                end
                s.aviLoaded = ~isempty(app.VideoState(fIdx).videoReader);
                s.currentIndex = double(app.Models(fIdx).currentIndex);
                s.selectedRow = double(app.Models(fIdx).selectedRow);
                if s.dataLoaded && isfield(app.Models(fIdx).mappedCols, 'Time')
                    timeCol = app.Models(fIdx).mappedCols.Time;
                    idx = app.clampedCurrentIndex(fIdx);
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
                s.flightPlay = app.collectFlightPlayTestState(fIdx);

                if isfield(app.UI(fIdx), 'dataGrid') && ~isempty(app.UI(fIdx).dataGrid) && isvalid(app.UI(fIdx).dataGrid)
                    widths = app.UI(fIdx).dataGrid.ColumnWidth;
                    s.dataGridColumnWidth = widths;
                    if numel(widths) >= 7
                        s.infoColumnHidden = app.isTestWidthZero(widths{5});
                        s.plotColumnHidden = app.isTestWidthZero(widths{7});
                        s.splitterColumnHidden = app.isTestWidthZero(widths{4}) && app.isTestWidthZero(widths{6});
                    elseif numel(widths) >= 5
                        s.infoColumnHidden = app.isTestWidthZero(widths{3});
                        s.plotColumnHidden = app.isTestWidthZero(widths{4});
                        s.splitterColumnHidden = app.isTestWidthZero(widths{5});
                    end
                end
                if isfield(app.UI(fIdx), 'colSplitters') && ~isempty(app.UI(fIdx).colSplitters)
                    s.columnSplitterVisible = false(1, numel(app.UI(fIdx).colSplitters));
                    for sIdx = 1:numel(app.UI(fIdx).colSplitters)
                        sp = app.UI(fIdx).colSplitters(sIdx);
                        if ~isempty(sp) && isvalid(sp)
                            s.columnSplitterVisible(sIdx) = app.isUiVisible(sp);
                        end
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

                if isfield(app.UI(fIdx), 'arrangementMode') && ~isempty(app.UI(fIdx).arrangementMode)
                    s.arrangementMode = char(app.UI(fIdx).arrangementMode);
                end

                if isfield(app.UI(fIdx), 'boardOffPanel') && ~isempty(app.UI(fIdx).boardOffPanel) ...
                        && isvalid(app.UI(fIdx).boardOffPanel)
                    s.boardOffPanelVisible = app.isUiVisible(app.UI(fIdx).boardOffPanel);
                    % v3-fix: under the new board-off policy, boardOffPanel is non-primary (hidden).
                    % when hidden/non-primary, skip the heavy findall scan (prevents case 48 hard-crash).
                    if s.boardOffPanelVisible
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
                end
                % v3-fix: if boardOffPanel is hidden, skip all sub-scans (prevents Online crash)
                if ~s.boardOffPanelVisible
                    return;
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

        function fp = collectFlightPlayTestState(app, fIdx)
            fp = struct('buttonValid', false, 'panelValid', false, 'panelVisible', false, ...
                        'sliderValid', false, 'sliderValue', NaN, 'sliderLimits', [NaN NaN], ...
                        'frameInputValid', false, 'frameValue', NaN, ...
                        'timeInputValid', false, 'timeValue', NaN, ...
                        'playActive', false, 'playButtonText', '');
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                fp.playActive = fIdx <= numel(app.FlightPlayActive) && logical(app.FlightPlayActive(fIdx));
                if isfield(app.UI(fIdx), 'btnFlightPlayControl') && ~isempty(app.UI(fIdx).btnFlightPlayControl) ...
                        && isvalid(app.UI(fIdx).btnFlightPlayControl)
                    fp.buttonValid = true;
                end
                if isfield(app.UI(fIdx), 'flightPlayControlPanel') && ~isempty(app.UI(fIdx).flightPlayControlPanel) ...
                        && isvalid(app.UI(fIdx).flightPlayControlPanel)
                    fp.panelValid = true;
                    fp.panelVisible = app.isUiVisible(app.UI(fIdx).flightPlayControlPanel);
                end
                if isfield(app.UI(fIdx), 'flightPlaySlider') && ~isempty(app.UI(fIdx).flightPlaySlider) ...
                        && isvalid(app.UI(fIdx).flightPlaySlider)
                    fp.sliderValid = true;
                    fp.sliderValue = double(app.UI(fIdx).flightPlaySlider.Value);
                    fp.sliderLimits = double(app.UI(fIdx).flightPlaySlider.Limits);
                end
                if isfield(app.UI(fIdx), 'flightPlayFrameInput') && ~isempty(app.UI(fIdx).flightPlayFrameInput) ...
                        && isvalid(app.UI(fIdx).flightPlayFrameInput)
                    fp.frameInputValid = true;
                    fp.frameValue = double(app.UI(fIdx).flightPlayFrameInput.Value);
                end
                if isfield(app.UI(fIdx), 'flightPlayTimeInput') && ~isempty(app.UI(fIdx).flightPlayTimeInput) ...
                        && isvalid(app.UI(fIdx).flightPlayTimeInput)
                    fp.timeInputValid = true;
                    fp.timeValue = double(app.UI(fIdx).flightPlayTimeInput.Value);
                end
                if isfield(app.UI(fIdx), 'flightPlayBtnPlayPause') && ~isempty(app.UI(fIdx).flightPlayBtnPlayPause) ...
                        && isvalid(app.UI(fIdx).flightPlayBtnPlayPause)
                    fp.playButtonText = char(app.UI(fIdx).flightPlayBtnPlayPause.Text);
                end
            catch ME
                app.logCaught(ME, 'test:get-flight-play-state');
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

        function [ok, issues] = compareRoundTripLayoutState(app, beforeState, afterState)
            issues = cell(1, 32);
            issueCount = 0;
            try
                if ~isequal(logical(beforeState.BoardOffState), logical(afterState.BoardOffState))
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'BoardOffState mismatch';
                end
                if abs(double(beforeState.BodyRowSplitRatio) - double(afterState.BodyRowSplitRatio)) > 1e-6
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'BodyRowSplitRatio mismatch';
                end
                if ~app.layoutSpecCellsEqual(beforeState.BodyRowHeight, afterState.BodyRowHeight)
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'BodyRowHeight mismatch';
                end
                if ~strcmp(char(beforeState.CurrentLayoutPreset), char(afterState.CurrentLayoutPreset))
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'CurrentLayoutPreset mismatch';
                end
                if double(beforeState.UserLayoutPresetCount) ~= double(afterState.UserLayoutPresetCount)
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'UserLayoutPresetCount mismatch';
                end
                if isfield(beforeState, 'path3DDesiredVisible') && isfield(afterState, 'path3DDesiredVisible') ...
                        && ~isequal(logical(beforeState.path3DDesiredVisible), logical(afterState.path3DDesiredVisible))
                    issueCount = issueCount + 1;
                    issues{issueCount} = 'Path3DVisible mismatch';
                end
                for fIdx = 1:2
                    fields = {'attitude', 'mapOnly', 'altOnly', 'video', 'info', 'dataView'};
                    for k = 1:numel(fields)
                        nm = fields{k};
                        try
                            if logical(beforeState.boards(fIdx).PanelVisible.(nm)) ~= ...
                                    logical(afterState.boards(fIdx).PanelVisible.(nm))
                                issueCount = issueCount + 1;
                                issues{issueCount} = sprintf('Flight %d PanelVisible.%s mismatch', fIdx, nm);
                            end
                        catch
                            issueCount = issueCount + 1;
                            issues{issueCount} = sprintf('Flight %d PanelVisible.%s missing', fIdx, nm);
                        end
                    end
                    if ~app.layoutSpecCellsEqual(beforeState.boards(fIdx).dataGridColumnWidth, ...
                            afterState.boards(fIdx).dataGridColumnWidth)
                        issueCount = issueCount + 1;
                        issues{issueCount} = sprintf('Flight %d ColumnWidth mismatch', fIdx);
                    end
                end
            catch ME
                issueCount = issueCount + 1;
                issues{issueCount} = sprintf('roundTrip compare failed: %s', ME.message);
            end
            issues = issues(1:issueCount);
            ok = isempty(issues);
        end

        function tf = layoutSpecCellsEqual(app, a, b)
            tf = isequal(app.normalizeLayoutSpecCellsForCompare(a), ...
                         app.normalizeLayoutSpecCellsForCompare(b));
        end

        function out = normalizeLayoutSpecCellsForCompare(~, in)
            if isempty(in)
                out = {};
                return;
            end
            if isstring(in)
                in = cellstr(in);
            elseif ischar(in)
                in = {in};
            elseif isnumeric(in) || islogical(in)
                in = num2cell(in);
            end
            if ~iscell(in)
                out = {};
                return;
            end
            in = reshape(in, 1, []);
            out = cell(size(in));
            for i = 1:numel(in)
                v = in{i};
                if isnumeric(v)
                    out{i} = sprintf('%.9g', double(v(1)));
                elseif islogical(v)
                    out{i} = sprintf('%d', logical(v(1)));
                elseif isstring(v) || ischar(v)
                    out{i} = strtrim(char(v));
                else
                    out{i} = class(v);
                end
            end
        end
    end

    % =========================================================================
    % single entry point for time change (handles sync/update/recursion-prevention in one place)
    % =========================================================================
    methods (Access = private)
        function applyTimeChange(app, fIdx, index)
            % [C2] priority: data-side time change is the entry point. If VideoSyncState(fIdx).IsSynced,
            % updateDashboard moves the video frame to follow (data->video). Conversely during video
            % drag(DraggedFromVideo), processFrameInternal moves the data (video->data),
            % and this function's re-entry is blocked by the IsUpdating guard. So when both are active,
            % the "last user input source" wins, and the reverse-direction sync runs one-way via the guard.
            if app.IsUpdating(fIdx), return; end
            if isempty(app.Models(fIdx).rawData), return; end

            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(index);
            app.Models(fIdx).currentIndex = index;

            % --- refresh the relevant flight-path view ---
            app.IsUpdating(fIdx) = true;
            try
                app.updateDashboard(fIdx, index);
                app.updatePath3DAtTime(fIdx, currTime);
                if abs(app.UI(fIdx).spinner.Value - currTime) > eps
                    app.UI(fIdx).spinner.Value = currTime;
                end
                % v-sync: when AVI sync is active, move the video frame in sync (case49 fix)
                try
                    vss = app.VideoSyncState(fIdx);
                    if vss.IsSynced && vss.TotalFrames > 0 && ~app.InGoToFrame(fIdx)
                        targetFrame = app.timeToFrame(fIdx, currTime);
                        if isfinite(targetFrame) && targetFrame ~= vss.CurrentFrame
                            app.goToFrame(fIdx, targetFrame, 'final');
                        end
                    end
                catch ME_sync
                    app.logCaught(ME_sync, 'applyTimeChange:videoSync');
                end
            catch e
                warning('FlightDataDashboard:ApplyTimeChange', 'applyTimeChange 오류: %s', e.message);
            end
            app.IsUpdating(fIdx) = false;

            % --- sync: when path 1 changes, path 2 follows too ---
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
    % Callback-accessible methods: file load and main logic
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

            % [V3.12] if an existing video sync setup exists, release it after user confirm
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
            % [Major 6] unify uiprogressdlg cleanup with the same pattern as autoLoadProjectFromFile
            % onCleanup + safeClose -> no dialog leftover no matter which branch returns/throws.
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

                % [V3.12] auto-compute flight-data Hz then refresh the input field
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

                % [fix 2] after parsing flight data, if video is already open, force-recompute Video FPS
                if app.VideoSyncState(fIdx).TotalFrames > 0
                    times = app.Models(fIdx).rawData.(timeCol);
                    maxTime = max(times);
                    if maxTime > 0
                        newFps = app.VideoSyncState(fIdx).TotalFrames / maxTime;
                        app.VideoSyncState(fIdx).VideoFps = newFps; % store decimal precision

                        if isfield(app.UI(fIdx), 'vidVideoFpsInput') && ~isempty(app.UI(fIdx).vidVideoFpsInput) && any(isvalid(app.UI(fIdx).vidVideoFpsInput))
                            app.UI(fIdx).vidVideoFpsInput.Value = round(newFps);
                        end
                        % immediately refresh the total-time text above the slider based on the recomputed FPS
                        app.updateVdubFrameLabel(fIdx, app.VideoSyncState(fIdx).CurrentFrame);
                    end
                end

                app.UI(fIdx).fileNameLabel.Text = filename;
                % [Major 6] dialog cleanup is handled by onCleanup - removed explicit close
            catch e
                % [V3.20 (3)] detailed error log
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
                if fIdx >= 1 && fIdx <= numel(app.LastInfoTableSelectionValid)
                    app.LastInfoTableSelectionValid(fIdx) = true;   % v-fix: record that an actual selection happened
                end
            end
        end

        function UIFigureCloseRequest(app, ~, ~)
            % [Stabilization P2] do not run the close path twice
            if app.IsDeleting, return; end
            canClose = true;

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
                                    if ~strcmp(cont, '그래도 닫기')
                                        return;
                                    end
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
                                if ~strcmp(cont, '그래도 닫기')
                                    return;
                                end
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
                canClose = false;
            end
            if ~canClose, return; end

            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                end
                app.IsDraggingSplitter = false;
                app.IsDraggingRowSplitter = false;
                app.IsDraggingColumnSplitter = false;
            catch ME_silent
                app.logCaught(ME_silent, 'close-request:clear-window-callbacks');
            end
            delete(app);
        end

        function togglePanel(app, fIdx, pnlName)
            % panel show/hide toggle (pixel-fixed resizing)
            % [L1 B-1] split into 'mapOnly' / 'altOnly' keys. 'map' is a backward-compat alias.
            app.CurrentLayoutPreset = 'custom';
            app.updateLayoutPresetButtons();
            if strcmp(pnlName, 'map')
                % if both on, turn both off; if both off, turn both on (keep legacy 1-shot behavior).
                anyOn = app.UI(fIdx).PanelVisible.mapOnly || app.UI(fIdx).PanelVisible.altOnly;
                target = ~anyOn;
                app.UI(fIdx).PanelVisible.mapOnly = target;
                app.UI(fIdx).PanelVisible.altOnly = target;
                app.applyMapAltVisibility(fIdx);
                app.reflowBoardColumns(fIdx);
                app.refreshBoardOffSummaryPanel(fIdx, true);
                return;
            end

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
            elseif strcmp(pnlName, 'mapOnly') || strcmp(pnlName, 'altOnly')
                % [L1 B-1] independent map/altitude toggle - header column shows if either is visible
                app.applyMapAltVisibility(fIdx);
                anyVisible = app.UI(fIdx).PanelVisible.mapOnly || app.UI(fIdx).PanelVisible.altOnly;
                if anyVisible
                    panelWidths = app.getResponsivePanelWidths();
                    widths{2} = panelWidths(2);
                else
                    widths{2} = 0;
                end
            elseif strcmp(pnlName, 'video')
                % v5-A: the auto-open-during-board-off block is handled by the guard inside setVideoViewerVisible
                app.setVideoViewerVisible(fIdx, newState, false);
                widths{5} = 0;
                widths{6} = 0;
            elseif strcmp(pnlName, 'info') || strcmp(pnlName, 'dataView')
                app.refreshPanelToggleButtons(fIdx);
            end
            app.UI(fIdx).dataGrid.ColumnWidth = widths;
            app.reflowBoardColumns(fIdx);
            app.refreshBoardOffSummaryPanel(fIdx, true);
        end

        function applyMapAltVisibility(app, fIdx)
            % v2-C: use horizontal orientation on a board-off active source.
            try
                activeOff = find(app.BoardOffState, 1);
                isHorizontal = ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff);
                if isHorizontal
                    app.setMapAltArrangement(fIdx, 'horizontal');
                else
                    app.setMapAltArrangement(fIdx, 'vertical');
                end
                pv = app.UI(fIdx).PanelVisible;
                mapOn = pv.mapOnly;  altOn = pv.altOnly;
                % refresh btn label
                if isfield(app.UI(fIdx), 'btnMap') && ~isempty(app.UI(fIdx).btnMap) && isvalid(app.UI(fIdx).btnMap)
                    app.UI(fIdx).btnMap.Text = ternary(mapOn, '지도 ▾', '지도 ▸');
                end
                if isfield(app.UI(fIdx), 'btnAlt') && ~isempty(app.UI(fIdx).btnAlt) && isvalid(app.UI(fIdx).btnAlt)
                    app.UI(fIdx).btnAlt.Text = ternary(altOn, '고도 ▾', '고도 ▸');
                end
            catch ME
                app.logCaught(ME, 'applyMapAltVisibility');
            end
        end

        function setMapAltArrangement(app, fIdx, orientation)
            % v2-C1: Map/Altitude vertical(default) or horizontal(board-off) layout.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                pv = app.UI(fIdx).PanelVisible;
                mapOn = pv.mapOnly; altOn = pv.altOnly;
                hasGrid = isfield(app.UI(fIdx), 'panelMapAltGrid') ...
                          && ~isempty(app.UI(fIdx).panelMapAltGrid) ...
                          && isvalid(app.UI(fIdx).panelMapAltGrid);
                hasMap = isfield(app.UI(fIdx), 'panelMap') ...
                          && ~isempty(app.UI(fIdx).panelMap) && isvalid(app.UI(fIdx).panelMap);
                hasAlt = isfield(app.UI(fIdx), 'panelAlt') ...
                          && ~isempty(app.UI(fIdx).panelAlt) && isvalid(app.UI(fIdx).panelAlt);
                if hasMap, app.UI(fIdx).panelMap.Visible = mapOn; end
                if hasAlt, app.UI(fIdx).panelAlt.Visible = altOn; end
                if ~hasGrid, return; end
                g = app.UI(fIdx).panelMapAltGrid;
                if strcmp(orientation, 'horizontal') && mapOn && altOn
                    g.RowHeight = {'1x'};
                    g.ColumnWidth = {'1x', '1x'};
                    if hasMap
                        try
                            app.UI(fIdx).panelMap.Layout.Row = 1;
                            app.UI(fIdx).panelMap.Layout.Column = 1;
                        catch
                        end
                    end
                    if hasAlt
                        try
                            app.UI(fIdx).panelAlt.Layout.Row = 1;
                            app.UI(fIdx).panelAlt.Layout.Column = 2;
                        catch
                        end
                    end
                elseif strcmp(orientation, 'horizontal') && (mapOn || altOn)
                    % visible alone -> fill
                    g.RowHeight = {'1x'};
                    g.ColumnWidth = {'1x'};
                    if mapOn && hasMap
                        try
                            app.UI(fIdx).panelMap.Layout.Row = 1;
                            app.UI(fIdx).panelMap.Layout.Column = 1;
                        catch
                        end
                    end
                    if altOn && hasAlt
                        try
                            app.UI(fIdx).panelAlt.Layout.Row = 1;
                            app.UI(fIdx).panelAlt.Layout.Column = 1;
                        catch
                        end
                    end
                else
                    % vertical
                    g.ColumnWidth = {'1x'};
                    if mapOn && altOn
                        g.RowHeight = {'1.5x', '1x'};
                    elseif mapOn
                        g.RowHeight = {'1x', 0};
                    elseif altOn
                        g.RowHeight = {0, '1x'};
                    else
                        g.RowHeight = {'1x', 0};
                    end
                    if hasMap
                        try
                            app.UI(fIdx).panelMap.Layout.Row = 1;
                            app.UI(fIdx).panelMap.Layout.Column = 1;
                        catch
                        end
                    end
                    if hasAlt
                        try
                            app.UI(fIdx).panelAlt.Layout.Row = 2;
                            app.UI(fIdx).panelAlt.Layout.Column = 1;
                        catch
                        end
                    end
                end
                app.UI(fIdx).panelMapAlt.Visible = mapOn || altOn;
            catch ME
                app.logCaught(ME, 'setMapAltArrangement');
            end
        end

        function refreshPanelToggleButtons(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ~isfield(app.UI(fIdx), 'PanelVisible')
                    return;
                end
                pv = app.UI(fIdx).PanelVisible;
                if isfield(app.UI(fIdx), 'btnAtt') && ~isempty(app.UI(fIdx).btnAtt) && isvalid(app.UI(fIdx).btnAtt)
                    app.UI(fIdx).btnAtt.Text = ternary(pv.attitude, '자세 ▾', '자세 ▸');
                end
                if isfield(app.UI(fIdx), 'btnInfo') && ~isempty(app.UI(fIdx).btnInfo) && isvalid(app.UI(fIdx).btnInfo)
                    app.UI(fIdx).btnInfo.Text = ternary(pv.info, '정보 ▾', '정보 ▸');
                end
                if isfield(app.UI(fIdx), 'btnDataView') && ~isempty(app.UI(fIdx).btnDataView) && isvalid(app.UI(fIdx).btnDataView)
                    app.UI(fIdx).btnDataView.Text = ternary(pv.dataView, 'plot ▾', 'plot ▸');
                end
                app.refreshPath3DButton(fIdx);
                app.applyMapAltVisibility(fIdx);
            catch ME
                app.logCaught(ME, 'refreshPanelToggleButtons');
            end
        end

        % ---------------------------------------------------------------------
        % video and sync
        % ---------------------------------------------------------------------
        function tf = areBothFlightDataLoaded(app)
            try
                tf = numel(app.Models) >= 2 ...
                    && ~isempty(app.Models(1).rawData) && height(app.Models(1).rawData) > 0 ...
                    && ~isempty(app.Models(2).rawData) && height(app.Models(2).rawData) > 0;
            catch
                tf = false;
            end
        end

        function color = getFlightTableBgColor(app, fIdx) %#ok<INUSD>
            % v3 P14: flight identity color -> use subtle accent only. dataTable body stays white (theme).
            t = app.getLightTheme();
            color = t.tableRowBgA;
        end

        function color = getFlightIdentityAccent(~, fIdx)
            % v3 P14: per-flight identity accent (for border / header tint).
            if fIdx == 2
                color = [0.31 0.27 0.90];
            else
                color = [0.23 0.51 0.96];
            end
        end

        function refreshGlobalSyncControls(app)
            try
                if isempty(app.SyncBtn) || ~isvalid(app.SyncBtn) || isempty(app.SyncInput) || ~isvalid(app.SyncInput)
                    return;
                end
                hasBoth = app.areBothFlightDataLoaded();
                if ~hasBoth
                    app.SyncBtn.Enable = 'off';
                    app.SyncInput.Enable = 'off';
                    if ~app.SyncState.IsSynced
                        app.styleToolbarButton(app.SyncBtn, '↔', '비행시간 동기', 'disabled');
                    end
                    return;
                end
                app.SyncBtn.Enable = 'on';
                if app.SyncState.IsSynced
                    app.SyncInput.Enable = 'off';
                    app.styleToolbarButton(app.SyncBtn, '⟲', '동기 해제', 'active');
                else
                    app.SyncInput.Enable = 'on';
                    app.styleToolbarButton(app.SyncBtn, '↔', '비행시간 동기', 'accent');
                end
            catch ME
                app.logCaught(ME, 'refreshGlobalSyncControls');
            end
        end

        function toggleSync(app)
            if app.SyncState.IsSynced
                app.SyncState.IsSynced = false;
                app.refreshGlobalSyncControls();
                if ~isempty(app.Models(2).rawData)
                    app.UI(2).spinner.Enable = 'on';
                end
                return;
            end

            if ~app.areBothFlightDataLoaded()
                app.refreshGlobalSyncControls();
                errordlg('두 경로 데이터가 모두 로드되어야 합니다.', '데이터 부족');
                return;
            end

            inputStr = app.SyncInput.Value;
            tokens = regexp(inputStr, '^\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)\s*$', 'tokens');
            if isempty(tokens)
                errordlg('입력 형식이 올바르지 않습니다. 예: "23.4, 34.4"', '형식 오류');
                return;
            end
            if isempty(app.Models(1).rawData) || isempty(app.Models(2).rawData)
                app.refreshGlobalSyncControls();
                errordlg('두 경로 데이터가 모두 로드되어야 합니다.', '데이터 부족');
                return;
            end

            t1 = str2double(tokens{1}{1});
            t2 = str2double(tokens{1}{2});
            app.SyncState.SyncT1 = t1;
            app.SyncState.SyncT2 = t2;
            app.SyncState.IsSynced = true;

            app.styleToolbarButton(app.SyncBtn, '⟲', '동기 해제', 'active');
            app.SyncInput.Enable = 'off';
            app.refreshGlobalSyncControls();
            app.UI(2).spinner.Enable = 'off';

            timeCol1 = app.Models(1).mappedCols.Time;
            idx1 = app.findClosestIndexByTime(app.Models(1).rawData.(timeCol1), t1);
            app.applyTimeChange(1, idx1);

            % [V3.20 (2)] sync debug log (SyncState - mapping between the two flight-data time axes)
            if app.DebugMode
                fprintf('[FlightSync] enabled: T1=%.3fs ↔ T2=%.3fs (offset=%.3fs)\n', ...
                    t1, t2, t2 - t1);
            end
        end

        % [V3.22 #3] loadAviFile decomposition - orchestrator + 6-step helpers
        % steps: 1) user confirm -> 2) cache invalidate -> 3) cleanup existing resources
        %       4) create VR -> 5) TotalFrames + UI sync -> 6) load first frame
        % each step has a clear exit condition on failure and a limited responsibility
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

            % [High #2] same-path detection - do not bump AsyncGen on preserveSync reopen.
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

            % [High #2] keep AsyncGen when preserveSync + same-path reopen.
            app.invalidateFrameCache(fIdx, ~(opts.preserveSync && samePath));

            % [High #4] release the worker persistent VR cache when the AVI path actually changed.
            % a same-path reopen skips this since slot reuse is more efficient.
            % also clears any leftover file lock on abnormal exit, just before the next load.
            if ~samePath
                try
                    if ~isempty(app.AsyncPool) && isvalid(app.AsyncPool)
                        parfevalOnAll(app.AsyncPool, @FlightDataDashboard.workerCleanupCache, 0);
                    end
                catch ME
                    app.logCaught(ME, 'loadAvi:worker-cache-cleanup');
                end
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

        % --------- loadAviFile helpers (V3.22 #3) ---------

        % [V3.22 #3-1] user-confirm dialog when an existing sync setup exists
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

        % [V3.22 #3-2] clear frame cache (including LastUse/Hits)
        function invalidateFrameCache(app, fIdx, bumpAsyncGen)
            % [High #2] bumpAsyncGen defaults true. In flows that reopen the same AVI (like preserveSync
            % reopen), the caller passes false to avoid over-triggering stale-rejection.
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

        % [V3.22 #3-3] extract flight-data first time (for start offset)
        function startTime = computeStartTimeFromFlightData(app, fIdx)
            startTime = 0;
            if ~isempty(app.Models(fIdx).rawData) && isfield(app.Models(fIdx).mappedCols, 'Time')
                timeCol = app.Models(fIdx).mappedCols.Time;
                if ~isempty(timeCol) && ismember(timeCol, app.Models(fIdx).rawData.Properties.VariableNames)
                    startTime = app.Models(fIdx).rawData.(timeCol)(1);
                end
            end
        end

        % [V3.22 #3-4] explicit cleanup of existing VideoReader / async future
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

        % [V3.22 #3-5] create VideoReader (on failure: errordlg + return [])
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

        % [V3.22 #3-6] compute TotalFrames + sync related UI widgets/spinner/slider
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
                        actualFps = totalFrames / maxTime; % precise decimal FPS computation
                    else
                        actualFps = 15;
                    end
                else
                    % if no flight data yet, default 15 FPS
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
                catch ME
                    app.logCaught(ME, 'applyVideoLoadedUI:totalFrames-fallback');
                end
                % Surface the failure visibly so user knows video is not usable.
                try
                    uialert(app.UIFigure, ...
                        sprintf('Flight %d 영상 메타데이터 로드 실패. 슬라이더/라벨 갱신을 건너뜁니다.', fIdx), ...
                        'Video')
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

        % [V3.22 #3-7] compute TotalFrames (prefer NumFrames, fallback: Duration*FrameRate)
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

            % warn on suspected VFR/MP4
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

        % [V3.22 #3-8] decode the first frame precisely to display + store in cache
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

        % [V3.12 2.1] dynamically adjust video panel width by the video aspect ratio
        function adjustVideoPanelWidth(app, fIdx)
            % v4-R2: removed dialog auto-show. On resize, adjust only the display size.
            try
                app.setVideoDisplaySize(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'adjustVideoPanelWidth');
            end
        end

        % [V3.14 item 3] dynamic cache size computation: resolution + user budget based
        function adjustCacheSize(app, fIdx)
            try
                vr = app.VideoState(fIdx).videoReader;
                if isempty(vr) || ~isvalid(vr)
                    app.DynamicCacheLimit(fIdx) = app.MAX_CACHE_FRAMES;
                    return;
                end

                % memory per frame (RGB uint8 basis)
                bytesPerFrame = vr.Width * vr.Height * 3;
                if bytesPerFrame <= 0
                    app.DynamicCacheLimit(fIdx) = app.MAX_CACHE_FRAMES;
                    return;
                end

                % compute max frame count from the user budget
                budgetBytes = app.CacheBudgetMB * 1024 * 1024;
                maxFrames = floor(budgetBytes / bytesPerFrame);

                % apply absolute upper/lower bounds
                maxFrames = max(app.MIN_CACHE_FRAMES, min(maxFrames, app.MAX_CACHE_FRAMES));
                app.DynamicCacheLimit(fIdx) = maxFrames;

                if app.DebugMode
                    fprintf('[Cache] fIdx=%d, %dx%d, budget=%dMB, limit=%d frames\n', ...
                        fIdx, vr.Width, vr.Height, app.CacheBudgetMB, maxFrames);
                end

                % if the current cache exceeds the limit, weighted evict (V3.22 #2)
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

        % [V3.14 item 3] called when the user changes the cache budget in the GUI
        % [V3.15 item 3-1] isVideoReady guard blocks unnecessary calls on the video-not-loaded path
        function setCacheBudget(app, budgetMB)
            try
                if budgetMB <= 0, return; end
                app.CacheBudgetMB = budgetMB;
                % recompute cache limit only for the path whose video is loaded (of the two)
                for fIdx = 1:2
                    if app.isVideoReady(fIdx)   % [V3.15 item 3-1] guard
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

        % [V3.15 item 5-3] DebugMode GUI checkbox callback
        function toggleDebugMode(app, val)
            try
                app.DebugMode = logical(val);
                fprintf('[Debug] DebugMode = %s\n', mat2str(app.DebugMode));
            catch ME_silent
                app.logCaught(ME_silent, 'toggleDebugMode');
            end
        end

        % [V3.14 item 5] VideoReader validity-check helper (consistent guard)
        % [Medium #6] also check TotalFrames > 0 - on applyVideoLoadedUI core failure
        % vr can be valid but a half-loaded state with TotalFrames=0 is possible, so return false.
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

        % [V3.14 VirtualDub UI] update Frame slider range (when video loaded)
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
                    sld.MajorTickLabels = arrayfun(@num2str, ticks, 'UniformOutput', false); % prevent exponential notation
                    sld.MinorTicks = [];
                end
            catch ME_silent
                app.logCaught(ME_silent, 'updateVdubSliderRange');
            end
        end

        % [V3.14 VirtualDub UI] update Frame N / Total (HH:MM:SS.mmm) label
        % [V3.15 item 5-1] improve milliseconds accuracy (floor + 0.5) + carryover
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

                % [V3.15 item 5-1] correct floating-point error via floor + 0.5
                ms = floor(mod(tSec, 1) * 1000 + 0.5);
                % if rounding makes it 1000, carry over to the seconds unit
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

        % [V3.15 item 2 / V3.16 / V3.17 (1)(9)] goToFrame() - single formal entry point
        % - V3.16: InGoToFrame re-entry guard + onCleanup
        % - V3.17 (1)(9): coalescing - a new request during processing is stored in PendingFrame, then
        %                 auto-absorbed when current processing completes (prevents losing the latest frame)
        % - V3.17 (8): show State = 'UPDATING'
        function goToFrame(app, fIdx, frameNo, mode)
            if nargin < 4, mode = 'final'; end

            % [V3.17 (1)(9)] if processing, store the latest request in Pending and exit
            % auto-handled in the coalescing loop just before current processing completes
            if app.InGoToFrame(fIdx)
                app.PendingFrame(fIdx) = frameNo;
                app.PendingMode{fIdx}  = mode;
                return;
            end

            app.InGoToFrame(fIdx) = true;
            app.State = 'UPDATING';
            cleanupObj = onCleanup(@() app.clearGoToFrameFlag(fIdx));

            % core processing loop (coalescing support)
            app.processFrameInternal(fIdx, frameNo, mode);

            % [V3.17 (1)(9) / V3.18 (3) / V3.22 #4] full Pending-drain loop
            % - continue instead of break to process all accumulated Pending
            % - MAX_PENDING_ITERS safety net prevents infinite loop
            maxIter = app.MAX_PENDING_ITERS;
            iter = 0;
            while ~isnan(app.PendingFrame(fIdx)) && iter < maxIter
                pf = app.PendingFrame(fIdx);
                pm = app.PendingMode{fIdx};
                app.PendingFrame(fIdx) = NaN;
                app.PendingMode{fIdx}  = '';
                iter = iter + 1;
                % continue instead of break even for the same frame -> process the next accumulated Pending
                if pf == app.VideoSyncState(fIdx).CurrentFrame
                    continue;
                end
                app.processFrameInternal(fIdx, pf, pm);
            end
            if iter >= maxIter && app.DebugMode
                fprintf('[goToFrame] Pending loop hit max iterations (fIdx=%d)\n', fIdx);
            end

            % [V3.17 (5)] single drawnow at goToFrame exit (both drag/final)
            drawnow limitrate;
        end

        % [V3.17 (1)(9)] goToFrame core processing logic (bypasses re-entry guard - coalescing only)
        function processFrameInternal(app, fIdx, frameNo, mode)
            if isempty(mode), mode = 'final'; end

            % 1. range check + clamp
            totalF = app.VideoSyncState(fIdx).TotalFrames;
            if totalF < 1, return; end
            frameNo = round(frameNo);
            frameNo = max(1, min(frameNo, totalF));

            % 2. if unchanged - drag just exits, final+IsSynced does a one-time data-side
            %    consistency check (even if frame is the same, spinner/currentIndex may have
            %    drifted from external manipulation. v-fixM3).
            if app.VideoSyncState(fIdx).CurrentFrame == frameNo
                if strcmp(mode, 'final') ...
                        && app.VideoSyncState(fIdx).IsSynced ...
                        && ~isempty(app.Models(fIdx).rawData)
                    app.syncDataSideToFrame(fIdx, frameNo, 'final');
                    app.refreshBoardOffSummaryPanel(fIdx);
                end
                return;
            end
            app.VideoSyncState(fIdx).CurrentFrame = frameNo;

            % 3. sync all display elements at once
            app.syncFrameMarkersAndLabel(fIdx, frameNo);

            % 4. update video (select source by mode)
            if strcmp(mode, 'drag')
                app.updateVideoFrameByFrameNo(fIdx, frameNo, 'drag');
            else
                app.updateVideoFrameByFrameNo(fIdx, frameNo, 'sync');
            end

            % 5. in sync mode, update the flight-data side too
            if app.VideoSyncState(fIdx).IsSynced && ~isempty(app.Models(fIdx).rawData)
                app.syncDataSideToFrame(fIdx, frameNo, mode);
            end
            app.refreshBoardOffSummaryPanel(fIdx);
        end

        % v-fixM3: split out the data-side sync block of processFrameInternal.
        %   - normal path: called right after a video frame change (both drag/final).
        %   - same-frame final path: even if the video frame is unchanged, idempotently
        %     reconcile currentIndex/spinner stale possibility (drag is not called).
        function syncDataSideToFrame(app, fIdx, frameNo, mode)
            try
                targetTime = app.frameToTime(fIdx, frameNo);
                timeCol = app.Models(fIdx).mappedCols.Time;
                times = app.Models(fIdx).rawData.(timeCol);
                targetTime = max(times(1), min(targetTime, times(end)));
                idx = app.findClosestIndexByTime(times, targetTime);

                indexChanged = ~isequal(app.Models(fIdx).currentIndex, idx);
                finalRefresh = strcmp(mode, 'final');
                if indexChanged || finalRefresh
                    prevDraggedFromVideo = app.DraggedFromVideo;
                    prevUpdating = app.IsUpdating(fIdx);
                    app.DraggedFromVideo = true;
                    cleanupVideoSyncFlags = onCleanup(@() app.restoreVideoSyncFlags( ...
                        fIdx, prevDraggedFromVideo, prevUpdating));
                    try
                        if strcmp(mode, 'drag')
                            if indexChanged
                                app.updateMarkersOnly(fIdx, idx);
                            end
                        else
                            app.IsUpdating(fIdx) = true;
                            app.Models(fIdx).currentIndex = idx;
                            app.updateDashboard(fIdx, idx);
                            if isfield(app.UI(fIdx), 'spinner') && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                                currDataTime = app.Models(fIdx).rawData.(timeCol)(idx);
                                if abs(app.UI(fIdx).spinner.Value - currDataTime) > eps
                                    app.UI(fIdx).spinner.Value = currDataTime;
                                end
                            end
                        end
                    catch e
                        app.logCaught(e, 'syncDataSideToFrame:update');
                    end
                    delete(cleanupVideoSyncFlags);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'syncDataSideToFrame:resolve');
            end
        end

        % [V3.15 item 1] slider drag-in-progress callback (ValueChangingFcn)
        % - 0.03s(33fps) throttle prevents decode-queue buildup
        % - call goToFrame in 'drag' mode -> lightweight update only
        function onVdubSliderChanging(app, fIdx, evtValue)
            % slider throttle: ignore if called too frequently
            if app.throttleHit('LastSliderUpdate', fIdx, app.SLIDER_THROTTLE_S), return; end

            % [V3.19 (2)] measure drag velocity (for adaptive prefetch)
            app.updateDragVelocity(fIdx, round(evtValue));

            app.goToFrame(fIdx, evtValue, 'drag');
        end

        % [V3.15 item 1] slider drag-end callback (ValueChangedFcn)
        % - call goToFrame in 'final' mode -> guarantees one full panel sync
        % - [V3.16] even for the same frame it may be right after drag mode, so force updateDashboard
        function onVdubSliderChanged(app, fIdx, src)
            try
                target = round(src.Value);
                if app.VideoSyncState(fIdx).CurrentFrame == target
                    % drag mode calls only updateMarkersOnly -> table/gauge can be stale
                    % one forced final-mode call guarantees full sync
                    if app.VideoSyncState(fIdx).IsSynced && ~isempty(app.Models(fIdx).rawData)
                        app.syncDataSideToFrame(fIdx, target, 'final');
                        app.refreshBoardOffSummaryPanel(fIdx);
                    end
                    app.prefetchAdjacentFrames(fIdx);
                    return;
                end
                app.goToFrame(fIdx, src.Value, 'final');
                % [V3.19 (2)] adaptive prefetch at slider drag-end
                app.prefetchAdjacentFrames(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'onVdubSliderChanged');
            end
        end

        % [V3.16 / V3.17 (8)] release goToFrame re-entry flag (onCleanup callback)
        function clearGoToFrameFlag(app, fIdx)
            app.InGoToFrame(fIdx) = false;
            if ~any(app.InGoToFrame), app.State = 'IDLE'; end
        end

        % [V3.17 (7)] release decoding-in-progress flag (onCleanup callback)
        function clearDecodingFlag(app, fIdx)
            app.IsDecoding(fIdx) = false;
            % [Stabilization P1] Drain the latest queued user request, if any.
            try
                app.drainPendingVideoRequest(fIdx);
            catch ME
                app.logCaught(ME, 'video-pending-drain');
            end
        end

        % [V3.17 (2)] only check cache existence (no LRU update)
        % [V3.18 (1)] lookup clamp consistency
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

        % [V3.19 (2)] track drag velocity (exponential moving average)
        function updateDragVelocity(app, fIdx, newFrame)
            try
                if app.LastDragTime{fIdx} == 0, app.LastDragTime{fIdx} = tic; end
                nowT = toc(app.LastDragTime{fIdx});   % [PATCH] per-channel relative seconds
                samples = app.DragVelocitySamples{fIdx};

                if isempty(samples)
                    samples = struct('time', nowT, 'frame', newFrame);
                else
                    last = samples(end);
                    dt = nowT - last.time;
                    if dt > 0.001
                        instantV = (newFrame - last.frame) / dt;
                        % exponential moving average (alpha=0.3)
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

        % [PATCH] tic/toc-based throttle helper - returns false on expiry + refreshes handle
        function hit = throttleHit(app, slotName, fIdx, limitS)
            % #4: the hit(throttled) path reads via direct indexing without copying the whole cell.
            t0 = app.(slotName){fIdx};
            if t0 ~= 0 && toc(t0) < limitS
                hit = true; return;
            end
            slot = app.(slotName);
            slot{fIdx} = tic;
            app.(slotName) = slot;
            hit = false;
        end

        % [PATCH] DebugMode-gated catch logging helper (hot-path safe)
        function logCaught(app, ME, tag)
            % [V3.22 #1] keep both silent/non-silent in the ring buffer
            % - console output only when DebugMode (silent tag skips console output)
            % - ring buffer always kept -> post-mortem via app.dumpErrorLog()
            % [Medium] during delete, suppress only the console; preserve the ring-buffer tag.
            try
                appValid = ~isempty(app) && isvalid(app);
            catch
                appValid = false;
            end
            if ~appValid
                return;
            end

            try
                suppressConsole = logical(app.IsDeleting);
            catch
                suppressConsole = true;
            end
            try
                % stack may be a struct array of differing length, so cell-wrap -> avoid dimension mismatch
                stackCell = {[]};
                try
                    stackCell = {ME.stack};
                catch
                end
                tagText = '';
                identifierText = '';
                messageText = '';
                try
                    tagText = char(tag);
                catch
                end
                try
                    identifierText = char(ME.identifier);
                catch
                end
                try
                    messageText = char(ME.message);
                catch
                end
                entry = struct( ...
                    'time',       datetime('now'), ...
                    'tag',        tagText, ...
                    'identifier', identifierText, ...
                    'message',    messageText, ...
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
                % never throw even if the ring buffer itself fails.
                % [C6] even if the stack-including entry append failed, try to preserve minimal info(tag/message)
                % - clear stack to [] to avoid dimension conflict. ({[]} = scalar struct)
                try
                    minEntry = struct('time', datetime('now'), 'tag', tagText, ...
                        'identifier', identifierText, 'message', messageText, 'stack', {[]});
                    if isempty(app.ErrorLog)
                        app.ErrorLog = minEntry;
                    else
                        app.ErrorLog(end+1) = minEntry;
                    end
                catch
                end
            end

            try
                debugMode = logical(app.DebugMode);
            catch
                debugMode = false;
            end
            if suppressConsole || ~debugMode
                return;
            end
            try
                if strcmpi(tagText, 'silent')
                    return;
                end
                fprintf('[%s] %s: %s\n', tagText, identifierText, messageText);
            catch
            end
        end

        % [V3.22 #1] for post-mortem: print the accumulated error log to console
        % usage: app.dumpErrorLog()         -> print all
        %         app.dumpErrorLog(20)        -> latest 20
        %         app.dumpErrorLog(20, 'Async') -> of latest 20, only tags containing 'Async'
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

        % [V3.19 (1) / V3.20 (5-2)] start async decoding
        % - prefer thread pool (zero serialization cost), fallback to process pool if unsupported
        % - if both fail, auto-fallback to UseAsyncDecode=false (no retry)
        % [PATCH Async 1.1] do not use thread pool - persistent VR shared across workers
        %                   causes a race condition. process pool has per-worker independent memory.
        % [Static fix] Async path intentionally does NOT set IsDecoding.
        % IsDecoding/PendingVideoFrame are sync-decode coalescing state.
        % AsyncFutures/AsyncTargetFrame/AsyncGen are async in-flight state:
        % every new async request cancels/invalidates the previous future, and
        % completion displays only when generation + target + CurrentFrame match.
        function ok = startAsyncDecode(app, fIdx, frameNo)
            ok = false;
            try
                % prepare parallel pool (lazy-create if absent)
                if isempty(app.AsyncPool) || ~isvalid(app.AsyncPool)
                    poolOk = false;
                    % [PATCH] reuse existing pool if possible (but reject threads)
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

                    % create a new process pool
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

                    % failure: disable permanently
                    if ~poolOk
                        app.UseAsyncDecode = false;
                        if app.DebugMode
                            fprintf('[Async] disabled - falling back to sync decode\n');
                        end
                        return;
                    end
                end

                % [V3.21 #1-A] increment generation counter - issue a new request
                app.AsyncGen(fIdx) = app.AsyncGen(fIdx) + 1;
                myGen = app.AsyncGen(fIdx);

                % cancel previous future (discard stale result)
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

                % [V3.21 #2-A / V3.22 #4 / V3.22 #6] use the persistent VR worker function
                % via the static wrapper to allow a future +flightdash package migration
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

        % [V3.19 (1) / V3.21 #1-A / V3.21 #3-A] async decode complete callback (main thread)
        % - block stale results via generation comparison
        % - pass through the displayFrame single exit (write-through)
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

        function onAsyncDecodeFinally(app, fIdx, frameNo, gen, fut)
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
            catch ME
                app.logCaught(ME, 'async-finally:detach');
            end
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

        % [V3.18 (4) / V3.19 (2)] adaptive prefetch: prefetch range based on drag velocity/direction
        function prefetchAdjacentFrames(app, fIdx)
            try
                if ~app.isVideoReady(fIdx), return; end
                cur = app.VideoSyncState(fIdx).CurrentFrame;
                total = app.VideoSyncState(fIdx).TotalFrames;

                v = app.DragVelocity(fIdx);   % frames/sec (sign = direction)
                speed = abs(v);

                % [V3.19 (2)] velocity-based prefetch range
                if speed < 30
                    offsets = [-3:-1, 1:3];        % slow: even both directions
                elseif speed < 100
                    if v > 0
                        offsets = [-2, -1, 1:7];   % forward dominant
                    else
                        offsets = [-7:-1, 1, 2];   % backward dominant
                    end
                else
                    if v > 0
                        offsets = 1:12;            % fast: deep only in the travel direction
                    else
                        offsets = -12:-1;
                    end
                end

                if app.DebugMode
                    fprintf('[Prefetch] fIdx=%d, v=%.1f f/s, %d offsets\n', fIdx, v, length(offsets));
                end

                % reset for the next drag
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

        % [V3.14 VirtualDub UI] navigation button callback (prev-prev / prev / next / next-next)
        % [V3.15 item 2] use the goToFrame single entry point
        function onVdubNav(app, fIdx, action)
            try
                if ~app.isVideoReady(fIdx), return; end
                cur = app.VideoSyncState(fIdx).CurrentFrame;
                total = app.VideoSyncState(fIdx).TotalFrames;
                if total < 1, return; end

                switch action
                    % v-fix4: +-1 / +-10 / +-20 frame move (keep legacy first/last aliases)
                    case 'back20',         newFrame = max(1, cur - 20);
                    case {'back10','first'}, newFrame = max(1, cur - 10);
                    case 'prev',           newFrame = max(1, cur - 1);
                    case 'next',           newFrame = min(total, cur + 1);
                    case {'fwd10','last'}, newFrame = min(total, cur + 10);
                    case 'fwd20',          newFrame = min(total, cur + 20);
                    otherwise,             newFrame = cur;
                end

                if newFrame == cur, return; end
                app.goToFrame(fIdx, newFrame, 'final');
            catch ME_silent
                app.logCaught(ME_silent, 'onVdubNav');
            end
        end

        % [V3.14 VirtualDub UI] helper to sync Frame marker/slider/label at once
        function syncFrameMarkersAndLabel(app, fIdx, frameNo)
            try
                % [fix] fully delete the old unused marker-update code to eliminate errors at the source

                % 1. update slider position
                if isfield(app.UI(fIdx), 'vidVdubSlider') && ~isempty(app.UI(fIdx).vidVdubSlider) ...
                        && isvalid(app.UI(fIdx).vidVdubSlider)
                    if abs(app.UI(fIdx).vidVdubSlider.Value - frameNo) > 0.5
                        app.UI(fIdx).vidVdubSlider.Value = frameNo;
                    end
                end

                % 2. update label text (reaches safely without error)
                app.updateVdubFrameLabel(fIdx, frameNo);

            catch ME_silent
                app.logCaught(ME_silent, 'video-marker-label');
            end
        end

        % [V3.12] init video sync state
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

        % [V3.12 2.2.3] sync button callback - input validation and sync setup
        function applyVideoSync(app, fIdx)
            % sync-release mode
            if app.VideoSyncState(fIdx).IsSynced
                app.resetVideoSync(fIdx);
                return;
            end

            % 1. validate video/data loaded
            if isempty(app.VideoState(fIdx).videoReader)
                errordlg('먼저 AVI 파일을 로드하세요.', '동기 오류'); return;
            end
            if isempty(app.Models(fIdx).rawData)
                errordlg('먼저 비행데이터(CSV)를 로드하세요.', '동기 오류'); return;
            end

            % 2. extract input values
            frameNo = app.UI(fIdx).vidSyncFrameInput.Value;
            timeVal = app.UI(fIdx).vidSyncTimeInput.Value;

            % 3. range check
            totalFrames = app.VideoSyncState(fIdx).TotalFrames;
            timeCol = app.Models(fIdx).mappedCols.Time;
            times = app.Models(fIdx).rawData.(timeCol);

            if frameNo < 1 || frameNo > totalFrames
                errordlg(sprintf('Frame No는 1 ~ %d 범위여야 합니다.', totalFrames), '범위 오류'); return;
            end
            if timeVal < times(1) || timeVal > times(end)
                errordlg(sprintf('Time(s)는 %.3f ~ %.3f 범위여야 합니다.', times(1), times(end)), '범위 오류'); return;
            end

            % 4. update Hz values
            vfpsUI = app.UI(fIdx).vidVideoFpsInput.Value;
            dfps = app.UI(fIdx).vidDataFpsInput.Value;
            if vfpsUI < 1 || dfps < 1
                errordlg('Hz 값은 1 이상이어야 합니다.', '입력 오류'); return;
            end

            % [fix 3] logic to prevent decimal-precision loss
            % if the rounded internal decimal FPS equals the current UI spinner value,
            % treat it as the user not having manually changed the spinner, and keep the precise internal decimal FPS.
            if round(app.VideoSyncState(fIdx).VideoFps) == vfpsUI
                % do nothing (keep decimal precision)
            else
                app.VideoSyncState(fIdx).VideoFps = vfpsUI; % update only when the user changed the spinner
            end

            app.VideoSyncState(fIdx).DataFps = dfps;

            % 5. store sync info
            app.VideoSyncState(fIdx).IsSynced = true;
            app.VideoSyncState(fIdx).AnchorFrame = frameNo;
            app.VideoSyncState(fIdx).AnchorTime = timeVal;

            % 6. UI feedback
            app.UI(fIdx).vidSyncBtn.Text = '동기 해제';
            app.UI(fIdx).vidSyncBtn.BackgroundColor = [0.8 0.2 0.2];
            app.UI(fIdx).vidSyncStatus.Text = sprintf('동기 완료 (F%d ↔ %.3fs)', frameNo, timeVal);
            app.UI(fIdx).vidSyncStatus.FontColor = [0.06 0.65 0.50];

            % [V3.14 item 4 / V3.17 (6) / V3.19 (3) / V3.22 #2] invalidate cache on sync reset
            app.FrameCache{fIdx} = {};
            app.FrameCacheKeys{fIdx} = [];
            app.FrameCacheHits{fIdx} = [];
            app.FrameCacheLastUse{fIdx} = [];
            app.CacheBytesUsed(fIdx) = 0;
            app.LastDisplayedFrame(fIdx) = 0;   % [PATCH] reset early-return key
            if app.DebugMode
                fprintf('[VideoSync] fIdx=%d, anchor F%d ↔ %.3fs, vfps=%d, dfps=%d, cache cleared\n', ...
                    fIdx, frameNo, timeVal, vfpsUI, dfps);
            end
        end

        % [V3.12 2.2.3.1] Hz input +/- arrow button callback (1Hz steps)
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

                % reflect into VideoSyncState immediately (even before sync setup)
                if strcmp(target, 'video')
                    app.VideoSyncState(fIdx).VideoFps = newVal;
                else
                    app.VideoSyncState(fIdx).DataFps = newVal;
                end
            catch ME_silent
                app.logCaught(ME_silent, 'adjustHzValue');
            end
        end

        % [V3.12 2.2.3.1] Hz direct-input callback (spinner ValueChangedFcn)
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

        % [V3.12 2.2.3] Frame No -> Time mapping (anchor-based linear)
        function timeVal = frameToTime(app, fIdx, frameNo)
            s = app.VideoSyncState(fIdx);
            if s.VideoFps <= 0
                timeVal = s.AnchorTime; return;
            end
            timeVal = s.AnchorTime + (frameNo - s.AnchorFrame) / s.VideoFps;
        end

        % [V3.12 2.2.3] Time -> Frame No mapping
        function frameNo = timeToFrame(app, fIdx, timeVal)
            s = app.VideoSyncState(fIdx);
            frameNo = round(s.AnchorFrame + (timeVal - s.AnchorTime) * s.VideoFps);
            frameNo = max(1, min(frameNo, s.TotalFrames));
        end

        % [V3.13 C-1] frame cache lookup (LRU)
        % [V3.18 (1)] apply clamp to lookup too - consistent with the store key
        function img = cacheGetFrame(app, fIdx, frameNo)
            % [V3.22 #2] handle LRU update via lastUse counter only
            % old: delete from cell array then re-insert at end -> large-frame reference shuffle
            % new: update only the lastUse array -> the cache cell itself stays intact
            img = [];
            try
                % [V3.18 (1)] safety net: protect even if the caller missed the clamp
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

                % [V3.22 #2] monotonic-increasing use counter + lastUse update
                app.FrameCacheUseCounter = app.FrameCacheUseCounter + 1;
                lastUse = app.FrameCacheLastUse{fIdx};
                % length sync (defensive)
                if numel(lastUse) < numel(keys)
                    lastUse(end+1:numel(keys)) = 0;
                end
                lastUse(foundIdx) = app.FrameCacheUseCounter;
                app.FrameCacheLastUse{fIdx} = lastUse;

                % [V3.19 (3)] update hit counter (for weighted LRU score)
                hits = app.FrameCacheHits{fIdx};
                if numel(hits) < numel(keys)
                    hits(end+1:numel(keys)) = 1;
                end
                hits(foundIdx) = hits(foundIdx) + 1;
                app.FrameCacheHits{fIdx} = hits;
            catch ME_silent
                app.logCaught(ME_silent, 'cacheGet');
                img = [];
            end
        end

        % [V3.13 C-1 / V3.14 / V3.17 (6) / V3.19 (3) / V3.22 #2] frame cache store
        % - weighted LRU: score = (hits * lastUseRecency) / bytes
        %   -> protect frequently + recently accessed small frames, evict old large frames first
        function cacheStoreFrame(app, fIdx, frameNo, img)
            try
                keys    = app.FrameCacheKeys{fIdx};
                cache   = app.FrameCache{fIdx};
                hits    = app.FrameCacheHits{fIdx};
                lastUse = app.FrameCacheLastUse{fIdx};

                % [PATCH] length sync - bidirectional correction
                nKeys = numel(keys);
                if numel(hits) < nKeys, hits(end+1:nKeys) = 1;
                elseif numel(hits) > nKeys, hits = hits(1:nKeys); end
                if numel(lastUse) < nKeys, lastUse(end+1:nKeys) = 0;
                elseif numel(lastUse) > nKeys, lastUse = lastUse(1:nKeys); end

                % monotonic-increasing use counter
                app.FrameCacheUseCounter = app.FrameCacheUseCounter + 1;
                useNow = app.FrameCacheUseCounter;

                % if already present, in-place update (no cell rearrangement)
                foundIdx = find(keys == frameNo, 1);
                if ~isempty(foundIdx)
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) - numel(cache{foundIdx});
                    cache{foundIdx}    = img;
                    lastUse(foundIdx)  = useNow;
                    % keep accumulating hits (do not reset hit count on overwrite)
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) + numel(img);
                else
                    % new add (append at end)
                    keys(end+1)    = frameNo;
                    cache{end+1}   = img;
                    hits(end+1)    = 1;
                    lastUse(end+1) = useNow;
                    app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) + numel(img);
                end

                % weighted evict when frame count exceeds the limit
                limit = app.DynamicCacheLimit(fIdx);
                if limit < app.MIN_CACHE_FRAMES, limit = app.MIN_CACHE_FRAMES; end
                if limit > app.MAX_CACHE_FRAMES, limit = app.MAX_CACHE_FRAMES; end

                [keys, cache, hits, lastUse] = app.evictByScore(fIdx, keys, cache, hits, lastUse, limit, false);

                % [V3.18 (5)] absolute memory hard limit
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

        % [V3.22 #2] unified weighted-LRU evict helper (shared for frame-count / bytes limits)
        % - byBytes=false: limit is frame count
        % - byBytes=true : limit is cumulative bytes
        % - score = (hits * recency) / bytes
        %   recency: larger lastUse(more recent) is more protected. The oldest items differ by useCounter delta
        function [keys, cache, hits, lastUse] = evictByScore(app, fIdx, keys, cache, hits, lastUse, limit, byBytes)
            while length(keys) > 1
                if byBytes
                    if app.CacheBytesUsed(fIdx) <= limit, break; end
                else
                    if length(keys) <= limit, break; end
                end
                bytesArr = cellfun(@numel, cache);
                % recency normalization: relative to the newest item (0~1)
                useNow = double(app.FrameCacheUseCounter);
                if useNow <= 0, useNow = 1; end
                recency = double(lastUse) ./ useNow;
                recency = max(recency, 0.01);   % protect 0
                scores = (double(hits) .* recency) ./ max(double(bytesArr), 1);

                % the newest (last-added) item is not protected and is evaluated by score only, but
                % for safety pick the victim only up to length(keys)-1
                [~, evictIdx] = min(scores(1:end-1));
                app.CacheBytesUsed(fIdx) = app.CacheBytesUsed(fIdx) - bytesArr(evictIdx);
                keys(evictIdx)    = [];
                cache(evictIdx)   = [];
                hits(evictIdx)    = [];
                lastUse(evictIdx) = [];
            end
        end

        % =====================================================================
        % [V3.21 #3-A] 3-layer separation structure - clear responsibility
        %
        %   Layer 1: requestFrame  - entry point + cache lookup + strategy selection
        %   Layer 2: decodeFrameSync - sync decoding (read or fallback)
        %            startAsyncDecode - async decoding (separate method, existing)
        %   Layer 3: displayFrame  - display + cache store (single exit)
        %
        % the existing updateVideoFrameByFrameNo delegates to requestFrame for compat.
        % =====================================================================

        % [V3.21 #3-A Layer 1] Frame request entry point
        % source: 'drag' / 'autoplay' / 'sync' / 'force'
        function requestFrame(app, fIdx, frameNo, source)
            if nargin < 4, source = 'force'; end

            % validity check
            if ~app.isVideoReady(fIdx), return; end

            % autoplay throttle branch
            if strcmp(source, 'autoplay')
                if app.throttleHit('LastVideoUpdate', fIdx, app.VIDEO_THROTTLE_S), return; end
            end

            % clamp (lookup/store key consistency)
            totalF = app.VideoSyncState(fIdx).TotalFrames;
            clampedFrame = max(1, min(round(frameNo), max(1, totalF)));

            % [Stabilization P1] Track the latest user-requested frame.
            app.LastRequestedFrame(fIdx) = clampedFrame;

            % early return for the same frame - based on the actually displayed frame
            if app.LastDisplayedFrame(fIdx) == clampedFrame, return; end

            % Layer 1: cache lookup
            cached = app.cacheGetFrame(fIdx, clampedFrame);
            if ~isempty(cached)
                app.displayFrame(fIdx, clampedFrame, cached, true);  % cacheHit=true
                return;
            end

            % [Stabilization P1] if decoding, keep only the latest pending then return.
            % on decode complete, clearDecodingFlag/onAsyncDecodeComplete calls drainPendingVideoRequest.
            if app.IsDecoding(fIdx)
                app.PendingVideoFrame(fIdx) = clampedFrame;
                app.PendingVideoMode{fIdx}  = source;
                return;
            end

            % [Stabilization P0] a 'final' entry invalidates the in-progress async result
            if strcmp(source, 'final')
                app.AsyncGen(fIdx) = app.AsyncGen(fIdx) + 1;
                app.AsyncTargetFrame(fIdx) = NaN;
            end

            % strategy selection: async vs sync
            if app.UseAsyncDecode && strcmp(source, 'drag')
                if app.startAsyncDecode(fIdx, clampedFrame)
                    return;
                end
                % Async unavailable/failure: continue through sync path once.
            end

            % Layer 2: sync decoding
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

        % [V3.21 #3-A Layer 2] sync decoding (read or fallback)
        function img = decodeFrameSync(app, fIdx, clampedFrame)
            img = [];
            vr = app.VideoState(fIdx).videoReader;

            % [PATCH Async 1.2 / V3.22 #4] small-step heuristic - readFrame sequentially if near the last shown frame
            % MP4 backward seek is very expensive, so use readFrame only for small forward steps
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
                % fallback: CurrentTime + readFrame
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

        % [V3.21 #3-A Layer 3] single display exit - all decode results pass through here
        function displayFrame(app, fIdx, frameNo, img, isCacheHit)
            try
                if ~app.isVideoReady(fIdx) || isempty(img), return; end
                app.setVideoImageFrame(fIdx, img);
                app.LastDisplayedFrame(fIdx) = frameNo;   % [PATCH] early-return key

                % cache store (only when not a hit - cache-first write-through)
                if ~isCacheHit
                    app.cacheStoreFrame(fIdx, frameNo, img);
                end
            catch ME
                app.logCaught(ME, 'displayFrame');
            end
        end

        % [V3.13 / V3.14 / V3.21 compat] the existing updateVideoFrameByFrameNo
        % delegates to requestFrame (keeps external caller compatibility)
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
        % handler for marker click & drag events (hardened against stuck)
        % ---------------------------------------------------------------------
        function startPlotMarkerDrag(app, fIdx, ~, src, event)
            % run only on left mouse button click (exclude right-click etc.)
            if event.Button ~= 1, return; end
            if isempty(app.Models(fIdx).rawData), return; end
            if app.SyncState.IsSynced && fIdx == 2, return; end
            if app.IsDraggingSplitter || app.IsDraggingRowSplitter || app.IsDraggingColumnSplitter
                return;
            end

            % activate drag state and turn off object HitTest
            app.IsDraggingMarker = true;
            app.DraggedMarker = src;
            app.DraggedFIdx = fIdx;   % [V3.11 B] for full sync at drag end
            app.DraggedFromVideo = false;   % [V3.12] started from the flight-data side
            app.VideoThrottleDyn = 0.05;    % [V3.12] dynamic throttle initial value 20fps
            app.LastDragTime{fIdx} = tic;
            app.State = 'DRAGGING';   % [V3.17 (8)]
            src.HitTest = 'off';

            % turn off the axes' default operations (Pan/Zoom) during drag (prevents mouse-up being swallowed)
            try
                ax = src.Parent;
                if isvalid(ax) && isprop(ax, 'Interactions')
                    app.DraggedMarker.UserData = ax.Interactions; % back up existing settings
                    ax.Interactions = []; % disable built-in Pan during drag
                end
            catch ME
                app.logCaught(ME, 'startPlotMarkerDrag:disable-interactions');
            end

            % [V3.11 B] suspend the XLim listener during drag
            app.setXLimListenersEnabled(fIdx, false);

            % [V3.11 C] switch xline to opaque (Alpha=1) during drag -> faster rendering
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

        % [V3.12 2.2.2] video Frame marker drag-start handler
        function startVideoFrameDrag(app, fIdx, src, event)
            if event.Button ~= 1, return; end
            if isempty(app.VideoState(fIdx).videoReader), return; end

            app.IsDraggingMarker = true;
            app.DraggedMarker = src;
            app.DraggedFIdx = fIdx;
            app.DraggedFromVideo = true;   % * drag started from the video side
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

            % suspend XLim listener (same policy as flight data)
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

                % [V3.13] removed the V3.12 dynamic throttle call - use source-based compromise throttle

                % [V3.11 C] update via the lightweight path only during drag
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

        % [V3.12 2.2.2] video Frame marker drag-motion handler
        % [V3.12 2.2.2] video Frame marker star drag-motion handler
        % [V3.15 item 2] refactored to use the goToFrame single entry point
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

                % [V3.19 (2)] measure drag velocity (for adaptive prefetch)
                app.updateDragVelocity(fIdx, targetFrame);

                % [V3.15 item 2] pass through the single entry point - lightweight update in 'drag' mode
                app.goToFrame(fIdx, targetFrame, 'drag');
                drawnow limitrate;
            catch ME_silent
                app.logCaught(ME_silent, 'videoFrameDragMotion');
            end
        end

        % [V3.12 video dynamic throttle computation]
        % - if drag moves fast, increase the throttle interval to reduce video update frequency (down to 5fps)
        % - if slow, decrease the interval so the video follows smoothly (up to 20fps)
        function computeDynamicVideoThrottle(app)
            try
                fIdx = app.DraggedFIdx;
                if fIdx < 1 || fIdx > 2, return; end
                if app.LastDragTime{fIdx} == 0, app.LastDragTime{fIdx} = tic; return; end
                dt = toc(app.LastDragTime{fIdx});
                app.LastDragTime{fIdx} = tic;

                if dt <= 0, return; end

                % the closer the move frequency is to 60fps (smaller dt), the less the video updates
                % dt=0.016(60fps) → throttle 0.20 (5fps)
                % dt=0.05 (20fps) → throttle 0.10 (10fps)
                % dt=0.1+(10fps or less) -> throttle 0.05 (20fps)
                if dt < 0.025
                    target = 0.20;
                elseif dt < 0.06
                    target = 0.10;
                else
                    target = 0.05;
                end

                % smooth transition (exponential weighted moving average)
                app.VideoThrottleDyn = 0.7 * app.VideoThrottleDyn + 0.3 * target;
            catch ME_silent
                app.logCaught(ME_silent, 'computeDynamicVideoThrottle');
            end
        end

        % [PATCH UX-3] H<->I panel boundary splitter drag handler
        function startHISplitterDrag(app, fIdx)
            try
                if fIdx >= 1 && fIdx <= numel(app.UI) && isfield(app.UI(fIdx), 'dataGrid') ...
                        && ~isempty(app.UI(fIdx).dataGrid) && isvalid(app.UI(fIdx).dataGrid) ...
                        && numel(app.UI(fIdx).dataGrid.ColumnWidth) >= 8
                    return;
                end
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
                % ensure the min widths of the H panel('1x') and video panel fit the current window size
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
            % fully reset callbacks and drag state
            wasDraggingFIdx = app.DraggedFIdx;
            app.IsDraggingMarker = false;
            app.State = 'IDLE';   % [V3.17 (8)] restore IDLE at drag end

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
                    % restore the original Axes interactions (Pan/Zoom)
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
            app.DraggedFromVideo = false;   % [V3.12] reset the video drag flag
            app.VideoThrottleDyn = 0.05;    % [V3.12] restore the default throttle value

            % [V3.11 C] restore xline Alpha to 0.5
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

            % [V3.11 B] restore XLim listeners (recover listeners suspended at drag start)
            if wasDraggingFIdx >= 1 && wasDraggingFIdx <= 2
                app.setXLimListenersEnabled(wasDraggingFIdx, true);
            end

            % [V3.11 C] one full dashboard sync at drag end
            % (final reflection of table/gauge/map/video updated only via the lightweight path during drag)
            for fIdx = 1:2
                if ~isempty(app.Models(fIdx).rawData)
                    idx = app.Models(fIdx).currentIndex;
                    % [Major 4] pin IsUpdating restore to onCleanup (restore guaranteed even on exception path)
                    prevUpdating = app.IsUpdating(fIdx);
                    app.IsUpdating(fIdx) = true;
                    cleanupUpdating = onCleanup(@() app.restoreIsUpdating(fIdx, prevUpdating));
                    try
                        app.updateDashboard(fIdx, idx);
                    catch e
                        warning('FlightDataDashboard:StopPlotMarkerDrag', ...
                            'stopPlotMarkerDrag 전체 동기화 오류: %s', e.message);
                    end
                    clear cleanupUpdating  % explicit cleanup (makes the next iteration's prevUpdating capture safe)
                    % [V3.18 (4)] warm up adjacent frames after drag end (use idle CPU)
                    app.prefetchAdjacentFrames(fIdx);
                end
            end
        end

        % ---------------------------------------------------------------------
        % [V3.11 B] batch-control XLim listeners (suspend/restore during drag)
        % ---------------------------------------------------------------------
        function setXLimListenersEnabled(app, fIdx, enabled)
            % control XLim listeners of all tabs inside the H panel
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

            % control the Altitude panel XLim listener
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
        % [V3.11 C / V3.12 extension] lightweight update path (drag-only)
        % - V3.11: marker/xline + current-time label + H panel page turning
        % - V3.12 1.1: add Map flight-path + red-triangle real-time update
        % - V3.12 2.2.3: when video sync is set, update the Frame marker + video frame
        % - current flight info/attitude numbers update immediately even during drag
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
                app.setAttitudeValueText(fIdx, pitch, roll, hdg);

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
            % [V3.17 (4)(11)] moved persistent inCascade -> InCascade instance property
            % [V3.17 (5)] drawnow is handled externally (goToFrame), so guard the self call
            isOuter = ~app.InCascade;

            app.Models(fIdx).currentIndex = idx;
            timeCol = app.Models(fIdx).mappedCols.Time;
            currTime = app.Models(fIdx).rawData.(timeCol)(idx);

            try
                altCol = app.Models(fIdx).mappedCols.Alt;
                alts = app.Models(fIdx).rawData.(altCol);

                % update Altitude panel marker + xline
                if isfield(app.UI(fIdx), 'hAltMarker') && ~isempty(app.UI(fIdx).hAltMarker) && isvalid(app.UI(fIdx).hAltMarker)
                    set(app.UI(fIdx).hAltMarker, 'XData', currTime, 'YData', alts(idx));
                end
                if isfield(app.UI(fIdx), 'timeLine') && ~isempty(app.UI(fIdx).timeLine) && isvalid(app.UI(fIdx).timeLine)
                    app.UI(fIdx).timeLine.Value = currTime;
                end

                % current-time label (very light)
                if isfield(app.UI(fIdx), 'currentTimeLabel') && ~isempty(app.UI(fIdx).currentTimeLabel) && isvalid(app.UI(fIdx).currentTimeLabel)
                    app.UI(fIdx).currentTimeLabel.Text = sprintf('%.3f s', currTime);
                end

                % spinner update (light)
                if isfield(app.UI(fIdx), 'spinner') && ~isempty(app.UI(fIdx).spinner) && isvalid(app.UI(fIdx).spinner)
                    if abs(app.UI(fIdx).spinner.Value - currTime) > eps
                        app.UI(fIdx).spinner.Value = currTime;
                    end
                end
                app.updateNumericPanelsOnly(fIdx, idx);
            catch ME
                app.logCaught(ME, 'clearCurrentTab:delete-children');
            end

            % [V3.12 1.1] Map flight-path + red-triangle real-time update (light)
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

            % H panel page turning + marker update (the IsProgrammaticXLim guard of plan A works)
            try
                app.updatePlotTimeLines(fIdx, idx, currTime);
                app.updatePath3DAtTime(fIdx, currTime);
            catch ME
                app.logCaught(ME, 'hpanel-update');
            end

            % [V3.12 2.2.3] when video sync is set, update the Frame marker + video frame
            % (only when the drag did not start from the video side - prevents infinite loop)
            % [PATCH UX-1] update only when Sync is explicitly active AND video is ready
            if app.VideoSyncState(fIdx).IsSynced && ~app.DraggedFromVideo ...
                    && app.isVideoReady(fIdx) && app.VideoSyncState(fIdx).AnchorFrame > 0
                try
                    targetFrame = app.timeToFrame(fIdx, currTime);
                    app.VideoSyncState(fIdx).CurrentFrame = targetFrame;

                    % [V3.14] sync Frame marker + xline + slider + label at once
                    app.syncFrameMarkersAndLabel(fIdx, targetFrame);

                    % [V3.13 compromise] keep throttling video update on flight-data drag
                    app.updateVideoFrameByFrameNo(fIdx, targetFrame, 'autoplay');
                catch ME
                    app.logCaught(ME, 'clearAllTabs:delete-tab');
                end
            end

            % sync mode: when path 1 is dragged, lightweight-update path 2 too
            if app.SyncState.IsSynced && fIdx == 1 && ~isempty(app.Models(2).rawData)
                targetT2 = app.SyncState.SyncT2 + (currTime - app.SyncState.SyncT1);
                timeCol2 = app.Models(2).mappedCols.Time;
                idx2 = app.findClosestIndexByTime(app.Models(2).rawData.(timeCol2), targetT2);
                if ~isequal(app.Models(2).currentIndex, idx2)
                    % [V3.17 (4)(11)] cascade guard via the InCascade instance property
                    % [Major 3] restore via onCleanup only - removed manual restore (prevents double call / clarifies intent)
                    prevCascade = app.InCascade;
                    app.InCascade = true;
                    cleanupCascade = onCleanup(@() app.restoreInCascade(prevCascade));
                    app.updateMarkersOnly(2, idx2);
                end
            end

            % [V3.17 (5)] drawnow only when outside cascade + not via goToFrame
            % goToFrame calls drawnow on its own exit, so avoid duplication
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

        function restoreInBoardToggle(app)
            % [bug#4] release the toggleBoardVisibility re-entry guard (always false - re-entry is blocked).
            try
                app.InBoardToggle = false;
            catch ME
                app.logCaught(ME, 'board-toggle-restore');
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

        function idx = findClosestIndexByTime(app, timeArray, targetTime)
            % PRECONDITION: timeArray assumed monotonic increasing (time axis) - binary search.
            %               if unsorted the result is inaccurate (warn once only in DebugMode).
            if isempty(timeArray), idx = 1; return; end
            if isnan(targetTime), idx = 1; return; end
            try
                if app.DebugMode && ~issorted(timeArray)
                    app.logCaught(MException('FDD:UnsortedTime', 'timeArray not sorted'), 'findClosest:precond');
                end
            catch
            end

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

            % [feature kept] H panel auto page panning (Auto-Page Panning)
            % when zoomed in and the marker leaves the screen, move the X axis keeping the existing zoom width
            % [V3.11 A] block handlePlotXLimChange listener infinite recursion on XLim change
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
                            app.IsProgrammaticXLim(fIdx) = true;   % listener guard ON
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
                            app.IsProgrammaticXLim(fIdx) = true;   % listener guard ON
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
        % H area tab and multi-plot management
        % ---------------------------------------------------------------------
        function addPlotTab(app, fIdx)
            nTabs = length(app.UI(fIdx).plotTabs);
            if nTabs >= app.MAX_TABS
                errordlg(sprintf('최대 %d개의 탭만 생성할 수 있습니다.', app.MAX_TABS), '알림');
                return;
            end

            tTheme = app.getLightTheme();   % v-style
            newTab = uitab(app.UI(fIdx).tabGroup, 'Title', sprintf('Tab %d', nTabs+1), ...
                'BackgroundColor', [1 1 1], 'ForegroundColor', tTheme.textPrimary);
            app.UI(fIdx).plotTabs(end+1) = newTab;

            plotLayout = uigridlayout(newTab, 'ColumnWidth', {'1x'}, 'RowHeight', {}, ...
                                      'Padding', [5 5 5 5], 'RowSpacing', 5, 'Scrollable', 'on', ...
                                      'BackgroundColor', [1 1 1]);

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
                    app.disableAxesInteractionsBeforeDelete(targetLayout, 'clearCurrentTab:axes');
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
                        app.disableAxesInteractionsBeforeDelete(app.UI(fIdx).plotTabs(i), 'clearAllTabs:axes');
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
            % [V3.11 A] if it is a programmatic XLim change (page turning etc.), ignore the listener
            %           -> blocks the dragged marker position from being force-jumped to center
            if app.IsProgrammaticXLim(fIdx), return; end

            % =======================================================
            % [V3.8 reinforcement] programmatically force the toolbar Zoom/Pan mode Off
            % - in case zoom/pan mode was turned on via an external API or another path
            %   block marker stuck at the source from WindowButtonUp event interception
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

            % [bug fully fixed] when the X-axis range changed by zoom/pan etc.
            % safely force-reset any drag state that might remain
            if app.IsDraggingMarker
                app.stopPlotMarkerDrag();
            end

            % [zoom-sync core] on zoom/move, get the center time then sync the dashboard
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

            % Y-axis auto scale: fully prevents the marker disappearing off the Y axis when zoomed in
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

            % [Manual visual test] H-plot card/axis readability colors.
            % MATLAB uiaxes does not provide a separate "Y-axis-only background"
            % property.  Therefore, set the surrounding plot card/grid background
            % and the axes background to a light color, then set YColor/YLabel.Color
            % to a high-contrast dark color.

            plotCardBg = [0.97 0.99 1.00];      % very light blue-white background
            axisBg     = [1.00 1.00 1.00];      % white plotting area
            yAxisFg    = [0.02 0.16 0.28];      % dark blue/navy for Y ticks + label
            xAxisFg    = [0.02 0.16 0.28];      % dark blue/navy for X ticks + label
            gridFg     = [0.72 0.82 0.88];      % soft blue-gray grid
            p = uipanel(targetLayout, 'BorderType', 'line', ...
                'BackgroundColor', plotCardBg, ...
                'ForegroundColor', [0.55 0.68 0.78]);

            p.Layout.Row = newRowIdx;
            p.Layout.Column = 1;

            %axGrid = uigridlayout(p, 'ColumnWidth', {'1x'}, 'RowHeight', {'1x'}, 'Padding', [5 5 5 5]);
            axGrid = uigridlayout(p, ...
                'ColumnWidth', {'1x'}, ...
                'RowHeight', {'1x'}, ...
                'Padding', [34 14 12 26], ...   % left/bottom padding for readable Y/X labels
                'BackgroundColor', plotCardBg);
            ax = uiaxes(axGrid);
            ax.Layout.Row = 1;
            ax.Layout.Column = 1;
            try
                ax.Color = axisBg;
            catch
            end
            try
                ax.XColor = xAxisFg;
            catch
            end
            try
                ax.YColor = yAxisFg;
            catch
            end
            try
                ax.GridColor = gridFg;
            catch
            end
            try
                ax.MinorGridColor = gridFg;
            catch
            end
            try
                ax.FontSize = 11;
            catch
            end
            try
                ax.FontWeight = 'bold';
            catch
            end
            try
                ax.TickLabelInterpreter = 'none';
            catch
            end

            % [V3.10] custom toolbar for H panel Tab plots only (Restore/ZoomIn/ZoomOut/Pan)
            %         Map/Altitude/video/gauge axes keep the toolbar hidden
            %         also allow default wheel-zoom/drag-pan interactions
            %         stuck defense is handled by handlePlotXLimChange's zoom/pan off logic
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
            
            %xlabel(ax, 'Time(s)', 'FontWeight', 'bold', 'FontSize', 9);
            %ylabel(ax, yLabelStr, 'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');

            xlabel(ax, 'Time(s)', ...
                'FontWeight', 'bold', ...
                'FontSize', 11, ...
                'Color', xAxisFg);
            ylabel(ax, yLabelStr, ...
                'FontWeight', 'bold', ...
                'FontSize', 11, ...
                'Color', yAxisFg, ...
                'Interpreter', 'none');

            hold(ax, 'on');
            currIdx = app.Models(fIdx).currentIndex;
            currTime = tData(currIdx);
            currY = yData(currIdx);

            % [plan 3] greatly increase line width(3.0), translucency(0.5), and marker size(14)
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
                % [Review Medium #4] Order is always rewritten as the array index - so stale Order after
                % duplicate/delete does not conflict on sort/persist.
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

            % v-fix8: if the EditDialog is open, show progress on top of it + disable buttons
            progressParent = app.UIFigure;
            if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                progressParent = app.EditDialog;
                app.setEditDialogControlsEnabled(false);
            end
            cleanupEnable = onCleanup(@() app.setEditDialogControlsEnabled(true));
            drawnow;
            d = uiprogressdlg(progressParent, 'Title', 'Export', ...
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
                try
                    app.logCaught(ME, 'auto-load');
                catch
                end
                try
                    appValid = ~isempty(app) && isvalid(app);
                catch
                    appValid = false;
                end
                if ~appValid
                    return;
                end
                try
                    app.ProjectDirty = true;   % [Critical 1] keep dirty on exception
                catch
                end
                try
                    parentFig = app.UIFigure;
                    if ~isempty(parentFig) && isvalid(parentFig)
                        uialert(parentFig, sprintf('project 자동 로드 실패:\n%s', ME.message), 'Project');
                    end
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

            tED = app.getLightTheme();   % v-r2: window+outer light theme
            % [step1] protect the entire new-EditDialog build - on a build exception, clean the partial figure then rethrow
            try
            fig = uifigure('Name', '설정/프로젝트 편집기', ...
                           'Position', pos, 'Resize', 'on', ...
                           'Color', tED.windowBg, ...
                           'CloseRequestFcn', @(~,~) app.closeEditDialog());
            app.EditDialog = fig;

            outer = uigridlayout(fig, [3 1]);
            outer.BackgroundColor = tED.windowBg;
            outer.RowHeight    = {28, '1x', 28};
            outer.ColumnWidth  = {'1x'};
            outer.Padding      = [6 6 6 6];
            outer.RowSpacing   = 4;

            % Top status bar
            statusGrid = uigridlayout(outer, [1 3]);
            statusGrid.RowHeight = {'fit'};
            statusGrid.ColumnWidth = {'1x', 200, 160};
            app.EditDialogStatusLbl = uilabel(statusGrid, 'Text', '준비', 'FontSize', 12, ...
                'FontColor', tED.textPrimary, 'FontWeight', 'bold');
            app.EditDialogDirtyLbl  = uilabel(statusGrid, 'Text', '변경 없음', ...
                'FontSize', 12, 'HorizontalAlignment', 'right', 'FontColor', tED.textSecondary);
            app.EditDialogTimeLbl   = uilabel(statusGrid, 'Text', '', ...
                'FontSize', 11, 'HorizontalAlignment', 'right', 'FontColor', tED.textSecondary);

            tabs = uitabgroup(outer);
            tabProject = uitab(tabs, 'Title', 'Project',      'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);
            tabFiles   = uitab(tabs, 'Title', 'Files',        'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);
            tabSync    = uitab(tabs, 'Title', 'Sync',         'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);
            tabOpts    = uitab(tabs, 'Title', 'Options',      'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);
            tabPlot    = uitab(tabs, 'Title', 'Plot Manager', 'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);
            tabExport  = uitab(tabs, 'Title', 'Export',       'BackgroundColor', tED.surfaceBg, 'ForegroundColor', tED.textPrimary);

            app.buildEditTabProject(tabProject);
            app.buildEditTabFiles(tabFiles);
            app.buildEditTabSync(tabSync);
            app.buildEditTabOptions(tabOpts);
            app.buildEditTabPlot(tabPlot);
            app.buildEditTabExport(tabExport);
            app.applyLightTheme(fig);  % v4-Theme

            % Bottom button row
            bottom = uigridlayout(outer, [1 4]);
            bottom.RowHeight = {'fit'};
            bottom.ColumnWidth = {'1x', 120, 120, 100};
            uilabel(bottom, 'Text', '');
            uibutton(bottom, 'Text', '적용 (즉시 반영)', ...
                'BackgroundColor', tED.toolbarBlueBg, 'FontColor', tED.toolbarBlueFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.applyPendingDialogChanges());
            uibutton(bottom, 'Text', 'project 저장', ...
                'BackgroundColor', tED.toolbarGreenBg, 'FontColor', tED.toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveProject());
            uibutton(bottom, 'Text', '닫기', ...
                'BackgroundColor', tED.toolbarGrayBg, 'FontColor', tED.toolbarGrayFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.closeEditDialog());

            app.refreshEditDialog();
            catch ME
                try
                    if exist('fig', 'var') && ~isempty(fig) && isvalid(fig)
                        delete(fig);
                    end
                catch
                end
                app.EditDialog = [];
                app.logCaught(ME, 'dialog:editDialog:build');
                rethrow(ME);
            end
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
            catch ME
                app.logCaught(ME, 'closeEditDialog:clear-pending-timer');
            end
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

        function setEditDialogStatus(app, state)
            % [step2] update the EditDialog top status label (best-effort). 5 states:
            %   ready/changed/applied/saved/error. no-op if the label is not created/invalid. no effect on main behavior.
            try
                lbl = app.EditDialogStatusLbl;
                if isempty(lbl) || ~isvalid(lbl) || ~isprop(lbl, 'Text'), return; end
                switch char(state)
                    case '변경됨', txt = '변경됨'; col = [0.72 0.45 0.05];   % amber
                    case '적용됨', txt = '적용됨'; col = [0.00 0.33 0.62];   % blue
                    case '저장됨', txt = '저장됨'; col = [0.06 0.45 0.22];   % green
                    case '오류',   txt = '오류';   col = [0.75 0.20 0.20];   % red
                    otherwise,     txt = '준비';   col = [0.10 0.18 0.25];   % neutral
                end
                lbl.Text = txt;
                if isprop(lbl, 'FontColor'), lbl.FontColor = col; end
            catch ME
                app.logCaught(ME, 'editDialog:setStatus');
            end
        end

        function refreshEditDialog(app)
            % Refresh status, paths, sync values, option drafts, plot tree if dialog open.
            % [Review Medium #5] guard every ED* handle access with ~isempty + isvalid.
            try
                if isempty(app.EditDialog) || ~isvalid(app.EditDialog), return; end
                if ~isempty(app.EditDialogDirtyLbl) && isvalid(app.EditDialogDirtyLbl)
                    tEd = app.getLightTheme();   % v-style
                    if app.ProjectDirty
                        app.EditDialogDirtyLbl.Text = '변경됨 ●';
                        app.EditDialogDirtyLbl.FontColor = tEd.warningRed;
                    else
                        app.EditDialogDirtyLbl.Text = '변경 없음';
                        app.EditDialogDirtyLbl.FontColor = tEd.textSecondary;
                    end
                end
                if ~isempty(app.EditDialogTimeLbl) && isvalid(app.EditDialogTimeLbl) ...
                        && ~isnat(app.LastEditApplyTime)
                    app.EditDialogTimeLbl.Text = sprintf('마지막 적용 %s', ...
                        char(datetime(app.LastEditApplyTime, 'Format', 'HH:mm:ss')));
                end
                % Refresh per-tab content if the handles still exist.
                % [Medium #5] each sub-refresh call also has its own try/catch to block cascading failure.
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
            gl = uigridlayout(parent, [9 4]);
            gl.RowHeight = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
            gl.ColumnWidth = {120, '1x', 100, 100};
            gl.RowSpacing = 6; gl.Padding = [10 10 10 10];

            uilabel(gl, 'Text', 'Project 파일:', 'FontWeight', 'bold');
            app.EDProjectPathLbl = uilabel(gl, 'Text', '(없음)', 'FontColor', app.getLightTheme().accentBlueText);
            app.EDProjectPathLbl.Layout.Column = 2;
            uibutton(gl, 'Text', '열기...', ...
                'ButtonPushedFcn', @(~,~) app.editDialogOpenProject());
            uibutton(gl, 'Text', '다른 이름으로...', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveProjectAs());

            uilabel(gl, 'Text', '저장:', 'FontWeight', 'bold');
            app.EDProjectStatusLbl = uilabel(gl, 'Text', '미저장', 'FontColor', app.getLightTheme().textSecondary);
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
            app.EDProjectLastSaveLbl = uilabel(gl, 'Text', '(없음)', 'FontColor', app.getLightTheme().accentBlueText);
            app.EDProjectLastSaveLbl.Layout.Column = [2 4];

            uilabel(gl, 'Text', 'Layout preset:', 'FontWeight', 'bold');
            app.EDProjectLayoutLbl = uilabel(gl, 'Text', '0개 / custom', 'FontColor', app.getLightTheme().accentBlueText);
            app.EDProjectLayoutLbl.Layout.Column = 2;
            btn = uibutton(gl, 'Text', '현재 레이아웃 저장', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSaveLayoutPreset());
            btn.Layout.Column = [3 4];

            uilabel(gl, 'Text', '저장된 preset:', 'FontWeight', 'bold');
            app.EDProjectLayoutPresetDD = uidropdown(gl, 'Items', {'(없음)'}, 'Value', '(없음)');
            app.EDProjectLayoutPresetDD.Layout.Column = 2;
            uibutton(gl, 'Text', '적용', 'ButtonPushedFcn', @(~,~) app.editDialogApplySavedLayoutPreset());
            uibutton(gl, 'Text', '삭제', 'ButtonPushedFcn', @(~,~) app.editDialogDeleteSavedLayoutPreset());
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
                    lbl = uilabel(gl, 'Text', '(없음)', 'FontColor', app.getLightTheme().accentBlueText);
                    lbl.Layout.Column = 2;
                    app.EDFilesPathLbl.(sprintf('f%d_%s', fIdx, kind)) = lbl;
                    uibutton(gl, 'Text', '변경...', ...
                        'ButtonPushedFcn', @(~,~) app.requestFileChangeAndRefresh(fIdx, kind));
                    uibutton(gl, 'Text', '다시 로드', ...
                        'ButtonPushedFcn', @(~,~) app.editDialogReloadFile(fIdx, kind));
                end
            end
            uibutton(gl, 'Text', 'Export everything to folder', ...
                'BackgroundColor', app.getLightTheme().toolbarGreenBg, 'FontColor', app.getLightTheme().toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogExport());
        end

        function buildEditTabSync(app, parent)
            % [F-03/F-04] Adds "import current screen values" buttons + offset preview label.
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
                'FontColor', app.getLightTheme().accentBlueText, 'FontWeight', 'bold');
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

            % v5-F: if Data is a table, ColumnFormat is ignored and warns - provide a dropdown via a categorical variable
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
            btnRow.Layout.Row = 4; btnRow.Layout.Column = [1 4];   % [D-05] move up one cell (add a reset row)
            btnRow.ColumnWidth = {'1x', 140, 160};
            uilabel(btnRow, 'Text', '');
            uibutton(btnRow, 'Text', '적용 (즉시 반영)', ...
                'BackgroundColor', app.getLightTheme().toolbarBlueBg, 'FontColor', app.getLightTheme().toolbarBlueFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyOptionDraft());
            uibutton(btnRow, 'Text', 'option 파일 저장', ...
                'ButtonPushedFcn', @(~,~) app.editDialogWriteOptionDraft());
        end

        function buildEditTabPlot(app, parent)
            % [F-01] Plot Manager: left tree + right property panel.
            tPm = app.getLightTheme();   % v-r2
            outer = uigridlayout(parent, [3 1]);
            outer.RowHeight   = {'fit', '1x', 'fit'};
            outer.ColumnWidth = {'1x'};
            outer.RowSpacing  = 6; outer.Padding = [10 10 10 10];

            % Row 1: header
            header = uigridlayout(outer, [1 6]);
            header.RowHeight   = {'fit'};
            header.ColumnWidth = {80, 120, 90, 90, 110, 110};
            header.ColumnSpacing = 4;
            uilabel(header, 'Text', 'Flight:', 'FontWeight', 'bold', 'FontColor', tPm.textPrimary);
            app.EDPlotFlightDD = uidropdown(header, 'Items', {'Flight 1', 'Flight 2'}, 'Value', 'Flight 1', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12, ...
                'ValueChangedFcn', @(~,~) app.refreshPlotTab());
            uibutton(header, 'Text', '캡처', ...
                'BackgroundColor', tPm.toolbarYellowBg, 'FontColor', tPm.toolbarYellowFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.capturePlotConfigAndRefresh());
            uibutton(header, 'Text', '재구성', ...
                'BackgroundColor', tPm.toolbarBlueBg, 'FontColor', tPm.toolbarBlueFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogRebuildPlots());
            uibutton(header, 'Text', 'Sync X→All Tabs', ...
                'BackgroundColor', tPm.toolbarGreenBg, 'FontColor', tPm.toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSyncTabXLimAll());
            uibutton(header, 'Text', 'Sync X→Plot', ...
                'BackgroundColor', tPm.toolbarGreenBg, 'FontColor', tPm.toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogSyncSelectedPlotXLimAll());

            % Row 2: tree (left) + property panel (right)
            mid = uigridlayout(outer, [1 2]);
            mid.BackgroundColor = tPm.surfaceBg;   % v3-C: light around the tree
            mid.RowHeight   = {'1x'};
            mid.ColumnWidth = {'1x', 320};
            mid.ColumnSpacing = 6;

            % v3-C: wrap uitree in a light panel to remove the black background
            treeWrap = uipanel(mid, 'BorderType', 'line', 'BackgroundColor', tPm.treeBg, ...
                'BorderColor', tPm.borderColor);
            treeWrapGrid = uigridlayout(treeWrap, [1 1], 'Padding', [2 2 2 2], 'BackgroundColor', tPm.treeBg);
            app.EDPlotTree = uitree(treeWrapGrid, ...
                'SelectionChangedFcn', @(~,~) app.onPlotTreeSelectionChanged());
            try
                app.EDPlotTree.BackgroundColor = tPm.treeBg;
            catch
            end
            try
                app.EDPlotTree.FontColor = tPm.treeFg;
            catch
            end

            propPanel = uipanel(mid, 'Title', '선택 항목 속성', ...
                'FontWeight', 'bold', 'Scrollable', 'on');
            pg = uigridlayout(propPanel, [12 2]);
            pg.RowHeight = repmat({'fit'}, 1, 12);
            pg.ColumnWidth = {110, '1x'};
            pg.RowSpacing = 4; pg.Padding = [6 6 6 6];

            uilabel(pg, 'Text', '이름:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotNameEdit = uieditfield(pg, 'text', 'Value', '', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12, ...
                'Editable', 'off', 'Tooltip', 'YColumn 기반 자동 생성');
            uilabel(pg, 'Text', 'Y 데이터 항목:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotYColDD = uidropdown(pg, 'Items', {'(선택)'}, 'Value', '(선택)', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', 'Y 라벨:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotYLabelEdit = uieditfield(pg, 'text', 'Value', '', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12, ...
                'Tooltip', 'plot y축에 표시할 라벨');
            uilabel(pg, 'Text', 'X auto:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotXAutoCB = uicheckbox(pg, 'Text', 'XLimMode = auto', 'Value', false, ...
                'FontColor', tPm.textPrimary, 'FontWeight', 'bold', ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleXAuto(src.Value));
            uilabel(pg, 'Text', 'X min:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotXMin = uieditfield(pg, 'numeric', 'Value', 0, ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', 'X max:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotXMax = uieditfield(pg, 'numeric', 'Value', 60, ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', 'Y auto:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotYAutoCB = uicheckbox(pg, 'Text', 'YLimMode = auto', 'Value', true, ...
                'FontColor', tPm.textPrimary, 'FontWeight', 'bold', ...
                'ValueChangedFcn', @(src,~) app.editDialogToggleYAuto(src.Value));
            uilabel(pg, 'Text', 'Y min:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotYMin = uieditfield(pg, 'numeric', 'Value', 0, 'Enable', 'off', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', 'Y max:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotYMax = uieditfield(pg, 'numeric', 'Value', 1, 'Enable', 'off', ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', 'Plot height:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            app.EDPlotHeight = uieditfield(pg, 'numeric', 'Value', 150, 'Limits', [60 600], ...
                'BackgroundColor', [1 1 1], 'FontColor', tPm.textPrimary, 'FontSize', 12);
            uilabel(pg, 'Text', '액션:', 'FontColor', tPm.textPrimary, 'FontWeight', 'bold');
            actRow = uigridlayout(pg, [1 5], 'Padding', [0 0 0 0], 'ColumnSpacing', 4);
            actRow.ColumnWidth = {52, 34, 34, 52, 64};
            uibutton(actRow, 'Text', '적용', ...
                'BackgroundColor', tPm.toolbarBlueBg, 'FontColor', tPm.toolbarBlueFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogApplyPlotProps());
            uibutton(actRow, 'Text', '↑', ...
                'BackgroundColor', tPm.toolbarGrayBg, 'FontColor', tPm.toolbarGrayFg, 'FontWeight', 'bold', ...
                'Tooltip', '선택 plot 순서를 위로 이동', ...
                'ButtonPushedFcn', @(~,~) app.editDialogMoveSelectedPlot(-1));
            uibutton(actRow, 'Text', '↓', ...
                'BackgroundColor', tPm.toolbarGrayBg, 'FontColor', tPm.toolbarGrayFg, 'FontWeight', 'bold', ...
                'Tooltip', '선택 plot 순서를 아래로 이동', ...
                'ButtonPushedFcn', @(~,~) app.editDialogMoveSelectedPlot(1));
            uibutton(actRow, 'Text', '복제', ...
                'BackgroundColor', tPm.toolbarGrayBg, 'FontColor', tPm.toolbarGrayFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogDuplicatePlot());
            uibutton(actRow, 'Text', '삭제(plot)', ...
                'BackgroundColor', tPm.btnWarningBg, 'FontColor', tPm.btnWarningFg, 'FontWeight', 'bold', ...
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
            app.EDExpPreviewLbl = uilabel(gl, 'Text', '(자동 생성)', 'FontColor', app.getLightTheme().accentBlueText);
            uilabel(gl, 'Text', '');

            uilabel(gl, 'Text', 'SHA256 검증:', 'FontWeight', 'bold');
            app.EDExpHashCB = uicheckbox(gl, 'Text', '느림. 기본 off', 'Value', false);
            uilabel(gl, 'Text', '');

            uibutton(gl, 'Text', '목록 새로고침', ...
                'ButtonPushedFcn', @(~,~) app.refreshExportTab());
            uibutton(gl, 'Text', 'Export everything to folder', ...
                'BackgroundColor', app.getLightTheme().toolbarGreenBg, 'FontColor', app.getLightTheme().toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.editDialogExport());
            uilabel(gl, 'Text', '');

            app.EDExpFileTable = uitable(gl, 'Data', cell(0, 4), ...
                'ColumnName', {'Role', 'Status', 'MB', 'Path'}, ...
                'ColumnEditable', [false false false false]);
            app.EDExpFileTable.Layout.Row = 5;
            app.EDExpFileTable.Layout.Column = [1 3];

            uilabel(gl, 'Text', '누락/요약:', 'FontWeight', 'bold');
            app.EDExpMissingLbl = uilabel(gl, 'Text', '파일 0개', 'FontColor', app.getLightTheme().accentBlueText);
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
                if ~isempty(app.EDProjectLayoutLbl) && isvalid(app.EDProjectLayoutLbl)
                    app.EDProjectLayoutLbl.Text = sprintf('%d개 / %s', ...
                        numel(app.UserLayoutPresets), char(app.CurrentLayoutPreset));
                end
                if ~isempty(app.EDProjectLayoutPresetDD) && isvalid(app.EDProjectLayoutPresetDD)
                    if isempty(app.UserLayoutPresets)
                        app.EDProjectLayoutPresetDD.Items = {'(없음)'};
                        app.EDProjectLayoutPresetDD.Value = '(없음)';
                    else
                        names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                        app.EDProjectLayoutPresetDD.Items = names;
                        if ~any(strcmp(app.EDProjectLayoutPresetDD.Value, names))
                            app.EDProjectLayoutPresetDD.Value = names{1};
                        end
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
                src = app.Models(fIdx).rawDataUnscaled;
                csvHeaders = {};
                if ~isempty(src) && width(src) > 0
                    csvHeaders = src.Properties.VariableNames;
                end
                draft = app.OptionDrafts{fIdx};
                if isempty(draft)
                    if isempty(csvHeaders)
                        if isvalid(app.EDOptReqTable), app.EDOptReqTable.Data = table(); end
                        if isvalid(app.EDOptDspTable), app.EDOptDspTable.Data = table(); end
                        return;
                    end
                    draft = app.parseOptionFileToDraft(app.resolveOptionFilePath(fIdx), csvHeaders);
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
                    % v5-F: a table Data + ColumnFormat combo is ignored/warns - provide a dropdown via categorical
                    choices = [{''}, csvHeaders(:)'];
                    colVals = vals;
                    if numel(choices) >= 2
                        try
                            colVals = categorical(vals, choices);
                        catch
                            colVals = vals;
                        end
                    end
                    app.EDOptReqTable.Data = table(reqKeys(:), colVals, ...
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
                app.safeRefreshEditDialog('editDialogSaveProject:refresh');   % v-fixE
                app.setEditDialogStatus('저장됨');   % [step2] save ok -> saved
            else
                app.setEditDialogStatus('오류');     % [step2] save failed -> error
            end
        end

        function editDialogSaveProjectAs(app)
            [fn, pn] = uiputfile({'*.fdproj', 'Project file'}, '저장할 project 파일');
            if isequal(fn, 0), return; end   % user cancel -> status unchanged
            ok = app.saveProjectFile(fullfile(pn, fn));
            if ok
                try
                    uialert(app.EditDialog, 'project 저장 완료', 'Project');
                catch
                end
                app.safeRefreshEditDialog('editDialogSaveProjectAs:refresh');   % v-fixE
                app.setEditDialogStatus('저장됨');   % [#1] Save As ok -> saved
            else
                app.setEditDialogStatus('오류');     % [#1] Save As failed -> error
            end
        end

        function editDialogOpenProject(app)
            [fn, pn] = uigetfile({'*.fdproj', 'Project file'}, '열 project 파일');
            if isequal(fn, 0), return; end
            try
                app.autoLoadProjectFromFile(fullfile(pn, fn));   % v-fixE: isolate the load exception
            catch ME
                try
                    app.logCaught(ME, 'editDialogOpenProject:autoLoad');
                catch
                end
            end
            app.safeRefreshEditDialog('editDialogOpenProject:refresh');
        end

        function editDialogAutoLoad(app)
            if isempty(app.ProjectFilePath)
                app.editDialogOpenProject(); return;
            end
            try
                app.autoLoadProjectFromFile(app.ProjectFilePath);   % v-fix: isolate so a load exception does not propagate to refresh
            catch ME
                try
                    app.logCaught(ME, 'editDialogAutoLoad:autoLoad');
                catch
                end
            end
            app.safeRefreshEditDialog('editDialogAutoLoad:refresh');
        end

        function safeRefreshEditDialog(app, tag)
            % v-fixE: safe wrapper for refreshEditDialog (app/EditDialog validity + IsDeleting guard)
            if nargin < 2 || isempty(tag), tag = 'safeRefreshEditDialog'; end
            try
                if isempty(app) || ~isvalid(app) || app.IsDeleting, return; end
            catch
                return;
            end
            try
                if isempty(app.EditDialog) || ~isvalid(app.EditDialog), return; end
            catch
                return;
            end
            try
                app.refreshEditDialog();
            catch ME
                try
                    app.logCaught(ME, tag);
                catch
                end
            end
        end

        function editDialogSaveLayoutPreset(app)
            try
                ts = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
                defaultName = sprintf('layout_%s', ts);
                presetName = defaultName;
                try
                    answer = inputdlg({'프리셋 이름:'}, 'Layout preset 저장', 1, {defaultName});
                    if isempty(answer), return; end
                    presetName = strtrim(char(answer{1}));
                    if isempty(presetName), presetName = defaultName; end
                catch
                end
                layout = app.collectLayoutUiState();
                layout.LayoutPresets = struct('Name', {}, 'SavedAt', {}, 'Layout', {});
                preset = struct('Name', presetName, 'SavedAt', ts, 'Layout', layout);
                names = {};
                if ~isempty(app.UserLayoutPresets) && isstruct(app.UserLayoutPresets)
                    names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                end
                hit = find(strcmp(names, presetName), 1);
                if isempty(hit)
                    if numel(app.UserLayoutPresets) >= 5
                        try
                            uialert(app.EditDialog, '사용자 layout preset은 최대 5개까지 저장할 수 있습니다. 기존 preset을 삭제한 후 다시 저장하세요.', 'Layout preset');
                        catch
                        end
                        return;
                    end
                    app.UserLayoutPresets(end + 1) = preset;
                else
                    app.UserLayoutPresets(hit) = preset;
                end
                app.updateLayoutPresetButtons();
                app.markProjectDirtyAndScheduleRefresh('layout-preset-save');
                app.refreshProjectTab();
            catch ME
                app.logCaught(ME, 'editDialogSaveLayoutPreset');
            end
        end

        function editDialogApplySavedLayoutPreset(app)
            try
                if isempty(app.EDProjectLayoutPresetDD) || ~isvalid(app.EDProjectLayoutPresetDD), return; end
                presetName = char(app.EDProjectLayoutPresetDD.Value);
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, presetName), 1);
                if isempty(hit), return; end
                app.applyLayoutUiState(app.UserLayoutPresets(hit).Layout);
                app.CurrentLayoutPreset = presetName;
                app.updateLayoutPresetButtons();
                app.markProjectDirtyAndScheduleRefresh('layout-preset-apply');
                app.refreshProjectTab();
            catch ME
                app.logCaught(ME, 'editDialogApplySavedLayoutPreset');
            end
        end

        function editDialogDeleteSavedLayoutPreset(app)
            try
                if isempty(app.EDProjectLayoutPresetDD) || ~isvalid(app.EDProjectLayoutPresetDD), return; end
                presetName = char(app.EDProjectLayoutPresetDD.Value);
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, presetName), 1);
                if isempty(hit), return; end
                app.UserLayoutPresets(hit) = [];
                app.updateLayoutPresetButtons();
                app.markProjectDirtyAndScheduleRefresh('layout-preset-delete');
                app.refreshProjectTab();
            catch ME
                app.logCaught(ME, 'editDialogDeleteSavedLayoutPreset');
            end
        end

        function saveCurrentLayoutPresetForTest(app, presetName)
            try
                presetName = strtrim(char(presetName));
                if isempty(presetName), presetName = 'test-layout'; end
                layout = app.collectLayoutUiState();
                layout.LayoutPresets = struct('Name', {}, 'SavedAt', {}, 'Layout', {});
                preset = struct('Name', presetName, ...
                    'SavedAt', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), ...
                    'Layout', layout);
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, presetName), 1);
                if isempty(hit)
                    if numel(app.UserLayoutPresets) >= 5
                        error('FlightDataDashboard:LayoutPresetLimit', 'Layout preset slot limit reached');
                    end
                    app.UserLayoutPresets(end + 1) = preset;
                else
                    app.UserLayoutPresets(hit) = preset;
                end
                app.updateLayoutPresetButtons();
            catch ME
                app.logCaught(ME, 'saveCurrentLayoutPresetForTest');
                rethrow(ME);
            end
        end

        function applySavedLayoutPresetForTest(app, presetName)
            try
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, char(presetName)), 1);
                if isempty(hit)
                    error('FlightDataDashboard:LayoutPresetNotFound', 'Layout preset not found');
                end
                app.applyLayoutUiState(app.UserLayoutPresets(hit).Layout);
                app.CurrentLayoutPreset = char(presetName);
                app.updateLayoutPresetButtons();
            catch ME
                app.logCaught(ME, 'applySavedLayoutPresetForTest');
                rethrow(ME);
            end
        end

        function deleteSavedLayoutPresetForTest(app, presetName)
            try
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, char(presetName)), 1);
                if isempty(hit)
                    error('FlightDataDashboard:LayoutPresetNotFound', 'Layout preset not found');
                end
                app.UserLayoutPresets(hit) = [];
                app.updateLayoutPresetButtons();
            catch ME
                app.logCaught(ME, 'deleteSavedLayoutPresetForTest');
                rethrow(ME);
            end
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
                        try
                            currIdx = app.clampedCurrentIndex(fIdx);
                            timeCol = app.Models(fIdx).mappedCols.Time;
                            currTime = app.Models(fIdx).rawData.(timeCol)(currIdx);
                            app.updatePlotTimeLines(fIdx, currIdx, currTime);
                        catch ME
                            app.logCaught(ME, 'plot-apply:restore-current-marker');
                        end
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

        function setEditDialogControlsEnabled(app, tf)
            % v-fix8: toggle enable of all buttons/dropdowns/fields in the EditDialog
            try
                if isempty(app.EditDialog) || ~isvalid(app.EditDialog), return; end
                types = {'uibutton', 'uidropdown', 'uieditfield', 'uispinner', 'uicheckbox'};
                for ti = 1:numel(types)
                    try
                        ctrls = findall(app.EditDialog, 'Type', types{ti});
                    catch
                        ctrls = [];
                    end
                    for k = 1:numel(ctrls)
                        try
                            if isprop(ctrls(k), 'Enable')
                                ctrls(k).Enable = ternary(tf, 'on', 'off');
                            end
                        catch
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'editDialogControlsEnabled');
            end
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
    % data parser and visualization update
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
            % [Phase1 3D path] additive named sections (backward-compatible).
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            bodyAttitude = struct('bodyX', '', 'bodyY', '', 'bodyZ', '');
            if ~isempty(optPath) && isfile(optPath)
                try
                    lines = readlines(optPath, 'EmptyLineRule', 'skip');
                    section = 0;
                    namedMode = '';   % '', 'waypoint', 'bodyattitude' (named sections; positional 1/2 unaffected)
                    for i = 1:length(lines)
                        lineStr = strtrim(lines(i));
                        if startsWith(lineStr, '#')
                            section = section + 1;
                            hdrTxt = lower(strtrim(erase(char(lineStr), '#')));
                            if contains(hdrTxt, 'waypoint')
                                namedMode = 'waypoint';
                            elseif contains(hdrTxt, 'bodyattitude') || contains(hdrTxt, 'body attitude')
                                namedMode = 'bodyattitude';
                            else
                                namedMode = '';
                            end
                            continue;
                        end
                        if strcmp(namedMode, 'waypoint')
                            % row: name = lat, lon, alt[, label]
                            try
                                kv = split(char(lineStr), '=');
                                if numel(kv) >= 2
                                    nm = strtrim(kv{1});
                                    vals = split(strtrim(strjoin(kv(2:end), '=')), ',');
                                    if numel(vals) >= 3
                                        lat = str2double(strtrim(vals{1}));
                                        lon = str2double(strtrim(vals{2}));
                                        alt = str2double(strtrim(vals{3}));
                                        if numel(vals) >= 4 && ~isempty(strtrim(vals{4}))
                                            lbl = strtrim(vals{4});
                                        else
                                            lbl = nm;
                                        end
                                        if isfinite(lat) && isfinite(lon) && isfinite(alt)
                                            wayPoints(end+1) = struct('label', char(lbl), ...
                                                'lat', lat, 'lon', lon, 'alt', alt); %#ok<AGROW>
                                        else
                                            app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                                        end
                                    else
                                        app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                                    end
                                else
                                    app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                                end
                            catch
                                app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                            end
                            continue;
                        elseif strcmp(namedMode, 'bodyattitude')
                            % key: bodyX/bodyY/bodyZ = columnName
                            kv = split(char(lineStr), '=');
                            if numel(kv) >= 2
                                bk = strtrim(kv{1});
                                bv = strtrim(strjoin(kv(2:end), '='));
                                if any(strcmpi(bk, {'bodyX', 'bodyY', 'bodyZ'})) && ismember(bv, csvHeaders)
                                    bodyAttitude.(['body' upper(bk(end))]) = bv;
                                end
                            end
                            continue;
                        end
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
                           'displayMeta', displayMeta, ...
                           'wayPoints', wayPoints, ...
                           'bodyAttitude', bodyAttitude);
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
                if isfield(draft, 'bodyAttitude') && isstruct(draft.bodyAttitude)
                    bodyKeys = {'bodyX', 'bodyY', 'bodyZ'};
                    for bIdx = 1:numel(bodyKeys)
                        key = bodyKeys{bIdx};
                        if isfield(draft.bodyAttitude, key)
                            v = char(draft.bodyAttitude.(key));
                            if ~isempty(v) && ~ismember(v, csvHeaders)
                                info.brokenColumns{end+1} = v;
                            end
                        end
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
            app.invalidateInfoTableSelection(fIdx);   % v-fix: row meaning changed -> invalidate selection
            app.Models(fIdx).isMockData  = isMock;
            [wayPoints, bodyAttitude] = app.normalizePath3DOptionDraft(draft, csvHeaders);
            app.Models(fIdx).wayPoints = wayPoints;
            app.Models(fIdx).bodyAttitude = bodyAttitude;
            app.Models(fIdx).option = struct();
            app.Models(fIdx).option.wayPoints = wayPoints;
            app.Models(fIdx).option.bodyAttitude = bodyAttitude;
            % Stash the resolved draft as the editor baseline.
            app.OptionDrafts{fIdx} = struct('sourcePath', char(draft.sourcePath), ...
                                            'mappedCols', mappedCols, 'displayMeta', displayMeta, ...
                                            'wayPoints', wayPoints, 'bodyAttitude', bodyAttitude);
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
                    if isfield(draft.mappedCols, reqKeys{i})
                        v = char(draft.mappedCols.(reqKeys{i}));
                    end
                    lines{end+1} = sprintf('%s: %s', reqKeys{i}, v); %#ok<AGROW>
                end
                lines{end+1} = '';
                lines{end+1} = '# DisplayColumns';
                for i = 1:numel(draft.displayMeta)
                    dm = draft.displayMeta(i);
                    lines{end+1} = sprintf('%s, %s, %s, %d, %g', ...
                        dm.header, dm.unit, dm.format, dm.order, dm.scale); %#ok<AGROW>
                end
                if isfield(draft, 'wayPoints') && ~isempty(draft.wayPoints)
                    lines{end+1} = '';
                    lines{end+1} = '# WayPoint';
                    for wpIdx = 1:numel(draft.wayPoints)
                        wp = draft.wayPoints(wpIdx);
                        label = sprintf('WP%d', wpIdx);
                        if isfield(wp, 'label') && ~isempty(wp.label)
                            label = char(wp.label);
                        end
                        lines{end+1} = sprintf('%s = %.10g, %.10g, %.10g, %s', ...
                            label, double(wp.lat), double(wp.lon), double(wp.alt), label); %#ok<AGROW>
                    end
                end
                if isfield(draft, 'bodyAttitude') && isstruct(draft.bodyAttitude)
                    ba = draft.bodyAttitude;
                    bodyLines = {};
                    if isfield(ba, 'bodyX') && ~isempty(ba.bodyX)
                        bodyLines{end+1} = sprintf('bodyX = %s', char(ba.bodyX)); %#ok<AGROW>
                    end
                    if isfield(ba, 'bodyY') && ~isempty(ba.bodyY)
                        bodyLines{end+1} = sprintf('bodyY = %s', char(ba.bodyY)); %#ok<AGROW>
                    end
                    if isfield(ba, 'bodyZ') && ~isempty(ba.bodyZ)
                        bodyLines{end+1} = sprintf('bodyZ = %s', char(ba.bodyZ)); %#ok<AGROW>
                    end
                    if ~isempty(bodyLines)
                        lines{end+1} = '';
                        lines{end+1} = '# BodyAttitude';
                        lines = [lines, bodyLines]; %#ok<AGROW>
                    end
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
            % v-fix3: per-flight independent bounds. If rawData exists, base on that flight's data only.
            % CoastlineData is included in bounds only in the no-rawData fallback.
            % FixedAreaBounds applies only when there is no rawData (forced common-bounds fallback).
            minLat = 90; maxLat = -90; minLon = 180; maxLon = -180;
            minAlt = 99999; maxAlt = -99999; hasData = false;
            hasOwnData = ~isempty(app.Models(fIdx).rawData);

            if ~hasOwnData && ~isempty(app.CoastlineData)
                minLat = min(minLat, min(app.CoastlineData(:,1))); maxLat = max(maxLat, max(app.CoastlineData(:,1)));
                minLon = min(minLon, min(app.CoastlineData(:,2))); maxLon = max(maxLon, max(app.CoastlineData(:,2)));
                hasData = true;
            end

            if hasOwnData
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

            if ~hasOwnData && ~isempty(app.FixedAreaBounds)
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

        function setupDataUI(app, fIdx, resetIndex)
            if nargin < 3
                resetIndex = true;
            end
            if height(app.Models(fIdx).rawData) > 0
                timeCol = app.Models(fIdx).mappedCols.Time;
                times = app.Models(fIdx).rawData.(timeCol);
                dt = mean(diff(times(1:min(100, end))));
                if dt <= 0, dt = 1; end
                if resetIndex
                    currIdx = 1;
                    % v-fix5: invalidate stale selection state when new data is loaded
                    app.invalidateInfoTableSelection(fIdx);
                else
                    currIdx = app.clampedCurrentIndex(fIdx);
                end

                app.UI(fIdx).spinner.Limits = [times(1), times(end)];
                app.UI(fIdx).spinner.Step = dt;
                app.UI(fIdx).spinner.Value = times(currIdx);

                if ~(app.SyncState.IsSynced && fIdx == 2)
                    app.UI(fIdx).spinner.Enable = 'on';
                end

                app.Models(fIdx).currentIndex = currIdx;
                app.calculateBounds(fIdx);

                app.initPlots(fIdx);
                app.updateDashboard(fIdx, currIdx);
                app.refreshFlightPlayControlPanel(fIdx);
                app.refreshBoardOffSummaryPanel(fIdx, true);
                app.refreshGlobalSyncControls();
            end
        end

        function initPlots(app, fIdx)
            if isempty(app.Models(fIdx).rawData), return; end
            bnds = app.Models(fIdx).bounds;

            % --- Map setup ---
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

            % --- Altitude setup and Y-axis dynamic scaling enable ---
            axAlt = app.UI(fIdx).altAxes; cla(axAlt);
            times = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Time);
            alts = app.Models(fIdx).rawData.(app.Models(fIdx).mappedCols.Alt);

            % error defense: check whether altXLimListener is valid
            if isfield(app.UI(fIdx), 'altXLimListener')
                try
                    if ~isempty(app.UI(fIdx).altXLimListener) && isvalid(app.UI(fIdx).altXLimListener)
                        delete(app.UI(fIdx).altXLimListener);
                    end
                catch ME
                    app.logCaught(ME, 'createAltitudePlot:delete-xlim-listener');
                end
            end

            % set the X axis to the full data and the Y axis to auto mode so it adapts dynamically on GUI resize
            axAlt.XLim = [min(times) max(times)];
            axAlt.YLimMode = 'auto';
            plot(axAlt, times, alts, 'Color', [0.8 0.8 0.8], 'LineWidth', 1, 'HitTest', 'off');

            % [V3.10] Altitude axes hide the toolbar (use wheel-zoom/drag-pan only)
            app.UI(fIdx).altAxes.Toolbar.Visible = 'off';
            app.UI(fIdx).altAxes.Interactions = [panInteraction, zoomInteraction];

            % [plan 3] increase timeline thickness and reflect transparency, fix marker size to 14
            app.UI(fIdx).hAltPath = plot(axAlt, times(1), alts(1), 'Color', [0.06 0.72 0.51], 'LineWidth', 2, 'HitTest', 'off');
            app.UI(fIdx).hAltMarker = plot(axAlt, times(1), alts(1), 'p', 'MarkerFaceColor', [0.98 0.75 0.14], 'MarkerEdgeColor', [0.71 0.33 0.04], 'MarkerSize', 14, 'HitTest', 'on');
            app.UI(fIdx).timeLine = xline(axAlt, times(1), 'r', 'LineWidth', 3.0, 'Alpha', 0.5, 'HitTest', 'on');

            app.UI(fIdx).hAltMarker.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, 0, src, event);
            app.UI(fIdx).timeLine.ButtonDownFcn = @(src, event) app.startPlotMarkerDrag(fIdx, 0, src, event);

            % add a sync listener for Altitude panel Zoom/Pan
            app.UI(fIdx).altXLimListener = addlistener(axAlt, 'XLim', 'PostSet', @(~,~) app.handlePlotXLimChange(fIdx, axAlt));

            % --- flight attitude gauge setup ---
            theta = linspace(0, 2*pi, 100);
            angles = 0:30:330;
            for gaugeType = 1:3
                tg = app.getLightTheme();   % v2-D: theme-driven gauge colors
                if gaugeType == 1
                    ax = app.UI(fIdx).pitchAxes; cla(ax); app.UI(fIdx).hgPitch = hgtransform('Parent', ax); hg = app.UI(fIdx).hgPitch; offsetDeg = 180; bgColor = tg.gaugePitchBg;   valueField = 'pitchValueText';
                elseif gaugeType == 2
                    ax = app.UI(fIdx).rollAxes;  cla(ax); app.UI(fIdx).hgRoll  = hgtransform('Parent', ax); hg = app.UI(fIdx).hgRoll;  offsetDeg = 90;  bgColor = tg.gaugeRollBg;    valueField = 'rollValueText';
                else
                    ax = app.UI(fIdx).hdgAxes;   cla(ax); app.UI(fIdx).hgHdg   = hgtransform('Parent', ax); hg = app.UI(fIdx).hgHdg;   offsetDeg = 90;  bgColor = tg.gaugeHeadingBg; valueField = 'hdgValueText';
                end

                patch(ax, cos(theta), sin(theta), bgColor, 'EdgeColor', tg.borderColor, 'LineWidth', 2);
                for i = 1:length(angles)
                    val = angles(i); if val > 180, val = val - 360; end
                    angRad = (offsetDeg - angles(i)) * pi / 180;
                    plot(ax, [0.85*cos(angRad) 1.0*cos(angRad)], [0.85*sin(angRad) 1.0*sin(angRad)], 'Color', tg.gaugeTickFg, 'LineWidth', 1.5);
                    if gaugeType == 3
                        if val == 0, str = 'N'; elseif val == 90, str = 'E'; elseif val == 180 || val == -180, str = 'S'; elseif val == -90, str = 'W'; else, str = num2str(val); end
                    else
                        str = num2str(val);
                    end
                    text(ax, 0.65*cos(angRad), 0.65*sin(angRad), str, 'Color', tg.gaugeTickFg, ...
                         'HorizontalAlignment', 'center', 'FontWeight', 'bold', ...
                         'FontUnits', 'normalized', 'FontSize', 0.115, 'Clipping', 'off');
                end

                if gaugeType == 1
                    patch(hg, [-1.15 -1.15 -1.0], [-0.08 0.08 0], tg.gaugeNeedleFg, 'EdgeColor', tg.borderColor, 'LineWidth', 1);
                    plot(hg, [-0.4 0.4], [0 0], 'Color', tg.gaugeNeedleFg, 'LineWidth', 4);
                    plot(hg, [0.2 0.3], [0 0.2], 'Color', tg.gaugeNeedleFg, 'LineWidth', 3);
                elseif gaugeType == 2
                    patch(hg, [-0.08 0.08 0], [1.15 1.15 1.0], tg.gaugeNeedleFg, 'EdgeColor', tg.borderColor, 'LineWidth', 1);
                    plot(hg, [-0.4 0.4], [0 0], 'Color', tg.gaugeNeedleFg, 'LineWidth', 3);
                    plot(hg, [0 0], [0 0.3], 'Color', tg.gaugeNeedleFg, 'LineWidth', 3);
                else
                    patch(hg, [-0.08 0.08 0], [1.15 1.15 1.0], tg.gaugeNeedleFg, 'EdgeColor', tg.borderColor, 'LineWidth', 1);
                    plot(hg, [0 0], [-0.4 0.4], 'Color', tg.gaugeNeedleFg, 'LineWidth', 3);
                    plot(hg, [-0.3 0.3], [0.1 0.1], 'Color', tg.gaugeNeedleFg, 'LineWidth', 3);
                    plot(hg, [-0.15 0.15], [-0.3 -0.3], 'Color', tg.gaugeNeedleFg, 'LineWidth', 2);
                end
                % v2-D3: removed the duplicate inner value text - the text object itself is not created.
                % use only the external labels (pitchLabel/rollLabel/hdgLabel).
                app.UI(fIdx).(valueField) = gobjects(0);
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
            app.setAttitudeValueText(fIdx, pitch, roll, hdg);

            set(app.UI(fIdx).hgPitch, 'Matrix', makehgtform('zrotate', -pitch * pi / 180));
            set(app.UI(fIdx).hgRoll,  'Matrix', makehgtform('zrotate', -roll * pi / 180));
            set(app.UI(fIdx).hgHdg,   'Matrix', makehgtform('zrotate', -hdg * pi / 180));

            % video and H area update
            % [V3.12 2.2.3] Frame-No-based update when video sync is set (precise mapping)
            if app.VideoSyncState(fIdx).IsSynced
                try
                    targetFrame = app.timeToFrame(fIdx, currTime);
                    app.VideoSyncState(fIdx).CurrentFrame = targetFrame;
                    % [V3.14] sync Frame marker + xline + slider + label at once
                    app.syncFrameMarkersAndLabel(fIdx, targetFrame);
                    app.updateVideoFrameByFrameNo(fIdx, targetFrame, 'sync');  % precise sync
                catch ME
                    app.logCaught(ME, 'video-sync-dashboard');
                    try
                        app.updateVideoFrame(fIdx, currTime);  % fallback
                    catch ME_fallback
                        app.logCaught(ME_fallback, 'video-sync-dashboard-fallback');
                    end
                end
            else
                % sync not set: time-based update as before
                % app.updateVideoFrame(fIdx, currTime);  % <--- commented out this line for full separation
            end
            try
                app.updatePlotTimeLines(fIdx, index, currTime);
            catch ME
                app.logCaught(ME, 'hpanel-dashboard');
            end
            app.refreshFlightPlayControlPanel(fIdx);
            app.refreshBoardOffSummaryPanel(fIdx);
            app.updatePath3DAtTime(fIdx, currTime);

            % [R3] project restore/sync refresh etc. may lose the altitude marker/xline interaction
            % callback, so best-effort re-attach (GUI drag stability + case118).
            app.ensureAltitudeMarkerCallbacks(fIdx);

            drawnow limitrate;
        end

        function ensureAltitudeMarkerCallbacks(app, fIdx)
            % [R3] restore hAltMarker / timeLine HitTest/PickableParts/ButtonDownFcn.
            % after project restore/sync refresh, the callback can be empty or HitTest='off', killing
            % marker drag - prevents that regression (case118 'altitude marker/xline callback missing').
            try
                if isempty(app.UI) || fIdx < 1 || fIdx > numel(app.UI), return; end
                dragCb = @(src, event) app.startPlotMarkerDrag(fIdx, 0, src, event);
                if isfield(app.UI(fIdx), 'hAltMarker')
                    mk = app.UI(fIdx).hAltMarker;
                    if ~isempty(mk) && isgraphics(mk) && isvalid(mk)
                        if isprop(mk, 'HitTest'), mk.HitTest = 'on'; end
                        if isprop(mk, 'PickableParts'), mk.PickableParts = 'visible'; end
                        if isprop(mk, 'ButtonDownFcn') && isempty(mk.ButtonDownFcn)
                            mk.ButtonDownFcn = dragCb;
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'timeLine')
                    tl = app.UI(fIdx).timeLine;
                    if ~isempty(tl) && isgraphics(tl) && isvalid(tl)
                        if isprop(tl, 'HitTest'), tl.HitTest = 'on'; end
                        if isprop(tl, 'PickableParts'), tl.PickableParts = 'visible'; end
                        if isprop(tl, 'ButtonDownFcn') && isempty(tl.ButtonDownFcn)
                            tl.ButtonDownFcn = dragCb;
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'ensureAltitudeMarkerCallbacks');
            end
        end

        function idx = clampedCurrentIndex(app, fIdx)
            % clamp currentIndex to [1, rawData row count] (1 if rawData empty).
            % read-only, side-effect-free - 1:1 extraction of the repeated identical expression (behavior unchanged).
            idx = max(1, min(app.Models(fIdx).currentIndex, height(app.Models(fIdx).rawData)));
        end

        function ui = createFlightPlayControlPanel(app, parent, fIdx, t)
            pnl = uipanel(parent, 'Title', 'Flight Data Play Control', ...
                'BackgroundColor', t.surfaceAltBg, 'ForegroundColor', t.textPrimary, ...
                'FontWeight', 'bold', 'Visible', 'off');
            g = uigridlayout(pnl, [3 1]);
            g.BackgroundColor = t.surfaceAltBg;
            g.RowHeight = {22, 30, 34};
            g.Padding = [6 3 6 3];
            status = uilabel(g, 'Text', 'Row 1 / 1 (0.000 s)', 'FontWeight', 'bold', ...
                'FontColor', t.textPrimary, 'FontSize', 11);

            nav = uigridlayout(g, [1 7]);
            nav.BackgroundColor = t.surfaceAltBg;
            nav.ColumnWidth = repmat({'1x'}, 1, 7);
            nav.Padding = [0 0 0 0];
            nav.ColumnSpacing = 4;
            mkBtn = @(txt, cb) uibutton(nav, 'Text', txt, 'FontWeight', 'bold', ...
                'BackgroundColor', t.toolbarGrayBg, 'FontColor', t.toolbarGrayFg, ...
                'ButtonPushedFcn', cb);
            ui.btnBack20 = mkBtn('<<<', @(~,~) app.moveFlightDataFrame(fIdx, -20));
            ui.btnBack10 = mkBtn('<<',  @(~,~) app.moveFlightDataFrame(fIdx, -10));
            ui.btnPrev   = mkBtn('<',   @(~,~) app.moveFlightDataFrame(fIdx, -1));
            ui.btnPlayPause = uibutton(nav, 'Text', 'Play', 'FontWeight', 'bold', ...
                'BackgroundColor', t.toolbarGreenBg, 'FontColor', t.toolbarGreenFg, ...
                'ButtonPushedFcn', @(~,~) app.toggleFlightPlay(fIdx));
            ui.btnNext   = mkBtn('>',   @(~,~) app.moveFlightDataFrame(fIdx, 1));
            ui.btnFwd10  = mkBtn('>>',  @(~,~) app.moveFlightDataFrame(fIdx, 10));
            ui.btnFwd20  = mkBtn('>>>', @(~,~) app.moveFlightDataFrame(fIdx, 20));

            ctl = uigridlayout(g, [1 5]);
            ctl.BackgroundColor = t.surfaceAltBg;
            ctl.ColumnWidth = {55, 90, 55, 110, '1x'};
            ctl.Padding = [0 0 0 0];
            uilabel(ctl, 'Text', 'Frame:', 'FontWeight', 'bold', 'FontColor', t.textPrimary);
            frameInput = uispinner(ctl, 'Limits', [1 2], 'Value', 1, 'Step', 1, ...
                'ValueChangedFcn', @(src,~) app.handleFlightPlayFrameInputChange(fIdx, src.Value));
            uilabel(ctl, 'Text', 'Time(s):', 'FontWeight', 'bold', 'FontColor', t.textPrimary);
            timeInput = uispinner(ctl, 'Limits', [0 1], 'Value', 0, 'Step', 0.1, ...
                'ValueDisplayFormat', '%.3f', 'ValueChangedFcn', @(src,~) app.handleFlightPlayTimeInputChange(fIdx, src.Value));
            slider = uislider(ctl, 'Limits', [1 2], 'Value', 1, ...
                'ValueChangedFcn', @(src,~) app.handleFlightPlaySliderChange(fIdx, src.Value));
            ui.panel = pnl;
            ui.grid = g;
            ui.statusLabel = status;
            ui.slider = slider;
            ui.frameInput = frameInput;
            ui.timeInput = timeInput;
        end

        function toggleFlightPlayControlPanel(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if ~app.isFlightPlayUiReady(fIdx), return; end
                showPanel = ~app.isUiVisible(app.UI(fIdx).flightPlayControlPanel);
                app.setUiVisible(app.UI(fIdx).flightPlayControlPanel, showPanel);
                if isfield(app.UI(fIdx), 'flightPlayHostGrid') && ~isempty(app.UI(fIdx).flightPlayHostGrid) ...
                        && isvalid(app.UI(fIdx).flightPlayHostGrid)
                    if showPanel
                        app.UI(fIdx).flightPlayHostGrid.RowHeight = {30, 130, '1x'};
                    else
                        app.UI(fIdx).flightPlayHostGrid.RowHeight = {30, 0, '1x'};
                    end
                end
                if isfield(app.UI(fIdx), 'btnFlightPlayControl') && isvalid(app.UI(fIdx).btnFlightPlayControl)
                    app.UI(fIdx).btnFlightPlayControl.Text = ternary(showPanel, '재생 닫기', '재생 제어');
                end
                app.refreshFlightPlayControlPanel(fIdx);
            catch ME
                app.logCaught(ME, 'flight-play:toggle-panel');
            end
        end

        function tf = isFlightPlayUiReady(app, fIdx)
            tf = false;
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                tf = ~isempty(app.UI) && fIdx >= 1 && fIdx <= numel(app.UI) ...
                    && isfield(app.UI(fIdx), 'flightPlayControlPanel') ...
                    && ~isempty(app.UI(fIdx).flightPlayControlPanel) ...
                    && isvalid(app.UI(fIdx).flightPlayControlPanel);
            catch
                tf = false;
            end
        end

        function [ok, fIdx] = validateFlightPlayIndex(app, fIdx)
            ok = false;
            try
                if nargin < 2 || isempty(fIdx) || ~isscalar(fIdx) || ~isfinite(double(fIdx))
                    fIdx = NaN;
                    return;
                end
                fIdx = round(double(fIdx));
                % v-fixC: validate UI/Models/FlightPlayActive array lengths all
                ok = fIdx >= 1 && fIdx <= 2 ...
                    && ~isempty(app.UI) && fIdx <= numel(app.UI) ...
                    && ~isempty(app.Models) && fIdx <= numel(app.Models) ...
                    && ~isempty(app.FlightPlayActive) && fIdx <= numel(app.FlightPlayActive);
            catch
                fIdx = NaN;
                ok = false;
            end
        end

        function refreshFlightPlayControlPanel(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if ~app.isFlightPlayUiReady(fIdx), return; end
                try
                    panelVisible = app.isUiVisible(app.UI(fIdx).flightPlayControlPanel);
                catch
                    panelVisible = false;
                end
                try
                    playing = fIdx <= numel(app.FlightPlayActive) && logical(app.FlightPlayActive(fIdx));
                catch
                    playing = false;
                end
                if ~panelVisible && ~playing
                    return;
                end
                hasData = ~isempty(app.Models(fIdx).rawData) && height(app.Models(fIdx).rawData) > 0 ...
                    && isfield(app.Models(fIdx).mappedCols, 'Time');
                nRows = 1; idx = 1; currTime = 0; timeLimits = [0 1];
                if hasData
                    nRows = max(1, height(app.Models(fIdx).rawData));
                    idx = max(1, min(nRows, round(app.Models(fIdx).currentIndex)));
                    timeCol = app.Models(fIdx).mappedCols.Time;
                    times = app.Models(fIdx).rawData.(timeCol);
                    currTime = double(times(idx));
                    timeLimits = [double(min(times)), double(max(times))];
                    if timeLimits(1) == timeLimits(2), timeLimits(2) = timeLimits(1) + 1; end
                end
                rowLimits = [1 max(2, nRows)];
                app.setNumericControlValue(app.UI(fIdx).flightPlaySlider, rowLimits, idx);
                app.setNumericControlValue(app.UI(fIdx).flightPlayFrameInput, rowLimits, idx);
                app.setNumericControlValue(app.UI(fIdx).flightPlayTimeInput, timeLimits, currTime);
                if isvalid(app.UI(fIdx).flightPlayStatusLabel)
                    app.UI(fIdx).flightPlayStatusLabel.Text = sprintf('Row %d / %d (%.3f s)', idx, nRows, currTime);
                end
                if isvalid(app.UI(fIdx).flightPlayBtnPlayPause)
                    app.UI(fIdx).flightPlayBtnPlayPause.Text = ternary(app.FlightPlayActive(fIdx), 'Pause', 'Play');
                end
            catch ME
                app.logCaught(ME, 'flight-play:refresh');
            end
        end

        function collapseFlightPlayControlPanel(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                % v-fixA: stop playback before collapse (prevents hidden playback / currentIndex drift)
                try
                    app.stopFlightPlay(fIdx);
                catch ME_stop
                    try
                        app.logCaught(ME_stop, 'flight-play:collapse-stop');
                    catch
                    end
                end
                if isfield(app.UI(fIdx), 'flightPlayControlPanel') && ~isempty(app.UI(fIdx).flightPlayControlPanel) ...
                        && isvalid(app.UI(fIdx).flightPlayControlPanel)
                    app.setUiVisible(app.UI(fIdx).flightPlayControlPanel, false);
                end
                if isfield(app.UI(fIdx), 'flightPlayHostGrid') && ~isempty(app.UI(fIdx).flightPlayHostGrid) ...
                        && isvalid(app.UI(fIdx).flightPlayHostGrid)
                    app.UI(fIdx).flightPlayHostGrid.RowHeight = {30, 0, '1x'};
                end
                if isfield(app.UI(fIdx), 'btnFlightPlayControl') && ~isempty(app.UI(fIdx).btnFlightPlayControl) ...
                        && isvalid(app.UI(fIdx).btnFlightPlayControl)
                    app.UI(fIdx).btnFlightPlayControl.Text = '재생 제어';
                end
            catch ME
                app.logCaught(ME, 'flight-play:collapse');
            end
        end

        function setNumericControlValue(~, h, limits, value)
            try
                if isempty(h) || ~isvalid(h), return; end
                if isprop(h, 'Limits')
                    h.Limits = limits;
                end
                h.Value = max(limits(1), min(limits(2), double(value)));
            catch
            end
        end

        function moveFlightDataFrame(app, fIdx, delta)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if app.IsDeleting || isempty(app.Models(fIdx).rawData), return; end
                nRows = height(app.Models(fIdx).rawData);
                if nRows < 1, return; end
                curr = max(1, min(nRows, round(app.Models(fIdx).currentIndex)));
                idx = max(1, min(nRows, curr + round(delta)));
                app.applyTimeChange(fIdx, idx);
            catch ME
                app.logCaught(ME, 'flight-play:move-frame');
            end
        end

        function handleFlightPlaySliderChange(app, fIdx, value)
            [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
            if ~okIdx, return; end
            app.moveFlightDataFrameToIndex(fIdx, round(value));
        end

        function handleFlightPlayFrameInputChange(app, fIdx, value)
            [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
            if ~okIdx, return; end
            app.moveFlightDataFrameToIndex(fIdx, round(value));
        end

        function handleFlightPlayTimeInputChange(app, fIdx, value)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if isempty(app.Models(fIdx).rawData) || ~isfield(app.Models(fIdx).mappedCols, 'Time'), return; end
                timeCol = app.Models(fIdx).mappedCols.Time;
                idx = app.findClosestIndexByTime(app.Models(fIdx).rawData.(timeCol), double(value));
                app.moveFlightDataFrameToIndex(fIdx, idx);
            catch ME
                app.logCaught(ME, 'flight-play:time-input');
            end
        end

        function moveFlightDataFrameToIndex(app, fIdx, idx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if isempty(app.Models(fIdx).rawData), return; end
                nRows = height(app.Models(fIdx).rawData);
                if nRows < 1, return; end
                idx = max(1, min(nRows, round(idx)));
                app.applyTimeChange(fIdx, idx);
            catch ME
                app.logCaught(ME, 'flight-play:move-to-index');
            end
        end

        function toggleFlightPlay(app, fIdx)
            [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
            if ~okIdx, return; end
            if app.FlightPlayActive(fIdx)
                app.stopFlightPlay(fIdx);
            else
                app.startFlightPlay(fIdx);
            end
        end

        function startFlightPlay(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if app.IsDeleting || isempty(app.Models(fIdx).rawData), return; end
                app.stopFlightPlay(fIdx);
                app.FlightPlayActive(fIdx) = true;
                % [#8] Period is computed once from FlightPlayFps at start time. Changing
                %      FlightPlayFps during playback does not apply immediately; only a stop->start(restart)
                %      applies the new FPS. (no runtime FPS setter currently - default 20.)
                app.FlightPlayTimer{fIdx} = timer('ExecutionMode', 'fixedSpacing', ...
                    'Period', max(0.01, 1 / max(1, app.FlightPlayFps)), ...
                    'BusyMode', 'drop', ...
                    'Name', sprintf('FlightDataDashboard_FlightPlay_%d', fIdx), ...
                    'Tag', sprintf('FlightDataDashboard:FlightPlay:%d', fIdx), ...
                    'TimerFcn', @(~,~) app.onFlightPlayTimer(fIdx), ...
                    'ErrorFcn', @(~,evt) app.logCaught(evt, 'timer:flightPlay'));
                start(app.FlightPlayTimer{fIdx});
                app.refreshFlightPlayControlPanel(fIdx);
            catch ME
                % v-fixB: clean up the partially created timer on start failure
                try
                    if exist('okIdx', 'var') && okIdx
                        app.FlightPlayActive(fIdx) = false;
                        if numel(app.FlightPlayTimer) >= fIdx && ~isempty(app.FlightPlayTimer{fIdx}) ...
                                && isvalid(app.FlightPlayTimer{fIdx})
                            try
                                stop(app.FlightPlayTimer{fIdx});
                            catch
                            end
                            delete(app.FlightPlayTimer{fIdx});
                        end
                        app.FlightPlayTimer{fIdx} = [];
                    end
                catch
                end
                app.logCaught(ME, 'flight-play:start');
            end
        end

        function stopFlightPlay(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx || fIdx > numel(app.FlightPlayActive), return; end
                app.FlightPlayActive(fIdx) = false;
                if numel(app.FlightPlayTimer) >= fIdx && ~isempty(app.FlightPlayTimer{fIdx}) ...
                        && isvalid(app.FlightPlayTimer{fIdx})
                    try
                        stop(app.FlightPlayTimer{fIdx});
                    catch
                    end
                    delete(app.FlightPlayTimer{fIdx});
                end
                app.FlightPlayTimer{fIdx} = [];
                app.refreshFlightPlayControlPanel(fIdx);
            catch ME
                app.logCaught(ME, 'flight-play:stop');
            end
        end

        function onFlightPlayTimer(app, fIdx)
            try
                [okIdx, fIdx] = app.validateFlightPlayIndex(fIdx);
                if ~okIdx, return; end
                if app.IsDeleting || ~app.FlightPlayActive(fIdx) || isempty(app.Models(fIdx).rawData)
                    app.stopFlightPlay(fIdx);
                    return;
                end
                nRows = height(app.Models(fIdx).rawData);
                idx = max(1, min(nRows, round(app.Models(fIdx).currentIndex)));
                if idx >= nRows
                    app.stopFlightPlay(fIdx);
                    return;
                end
                app.applyTimeChange(fIdx, idx + 1);
                app.updatePath3DAtTime(fIdx, app.getCurrentFlightTime(fIdx));
            catch ME
                if exist('okIdx', 'var') && okIdx
                    app.stopFlightPlay(fIdx);
                end
                app.logCaught(ME, 'flight-play:timer');
            end
        end
    end

    % =========================================================================
    % UI layout creation factory (Create Layout)
    % =========================================================================
    methods (Access = public)
        function pos = getInitialWindowPosition(app)
            screen = app.getActiveScreenArea();
            screenW = max(640, screen(3));
            screenH = max(480, screen(4));

            marginX = 16;
            marginY = 24;
            maxW = max(640, screenW - 2 * marginX);
            maxH = max(480, screenH - 2 * marginY);
            desiredW = 1560;
            desiredH = 858;

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
                app.applyResponsiveControlBar();   % v-fix7: switch the control bar to 2 rows at narrow width
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

        function applyResponsiveControlBar(app)
            % v-fix7: if figure width < 1100, control bar 2 rows (label/value row 1 + toggle row 2)
            try
                figW = app.getFigurePixelWidth();
                narrow = figW < 1100;
                for fIdx = 1:min(2, numel(app.UI))
                    if ~isfield(app.UI(fIdx), 'ctrlGrid') || isempty(app.UI(fIdx).ctrlGrid) ...
                            || ~isvalid(app.UI(fIdx).ctrlGrid)
                        continue;
                    end
                    g = app.UI(fIdx).ctrlGrid;
                    % [3D Path] include btnPath3D so responsive layout keeps the new column aligned
                    btns = {app.UI(fIdx).btnAtt, app.UI(fIdx).btnMap, app.UI(fIdx).btnAlt, app.UI(fIdx).btnPath3D, app.UI(fIdx).btnVid};
                    if narrow
                        g.RowHeight = {'1x', '1x'};
                        g.ColumnWidth = {100, 150, 110, 120, '1x'};
                        cols = [1 2 3 4 5];
                        for b = 1:numel(btns)
                            h = btns{b};
                            if ~isempty(h) && isvalid(h)
                                try
                                    h.Layout.Row = 2; h.Layout.Column = cols(b);
                                catch
                                end
                            end
                        end
                        if isfield(app.UI(fIdx), 'ctrlFGrid') && ~isempty(app.UI(fIdx).ctrlFGrid) ...
                                && isvalid(app.UI(fIdx).ctrlFGrid)
                            app.UI(fIdx).ctrlFGrid.RowHeight = {78, '1x'};
                        end
                    else
                        g.RowHeight = {'1x'};
                        g.ColumnWidth = {100, 150, 110, 120, '1x', 70, 70, 70, 80, 70};
                        cols = [6 7 8 9 10];
                        for b = 1:numel(btns)
                            h = btns{b};
                            if ~isempty(h) && isvalid(h)
                                try
                                    h.Layout.Row = 1; h.Layout.Column = cols(b);
                                catch
                                end
                            end
                        end
                        if isfield(app.UI(fIdx), 'ctrlFGrid') && ~isempty(app.UI(fIdx).ctrlFGrid) ...
                                && isvalid(app.UI(fIdx).ctrlFGrid)
                            app.UI(fIdx).ctrlFGrid.RowHeight = {45, '1x'};
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'responsiveCtrlBar');
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
                        app.styleToolbarButton(app.WindowMaxBtn, '▣', '복원', 'normal');
                    else
                        app.styleToolbarButton(app.WindowMaxBtn, '□', '최대화', 'normal');
                    end
                elseif app.IsWindowManuallyMaximized
                    app.styleToolbarButton(app.WindowMaxBtn, '▣', '복원', 'normal');
                else
                    app.styleToolbarButton(app.WindowMaxBtn, '□', '최대화', 'normal');
                end
            catch ME_silent
                app.logCaught(ME_silent, 'windowLabel');
            end
        end

        function sizePx = getSelectedVideoDisplaySize(app, fIdx)
            sizePx = [720, 512];
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

        function pos = getVideoViewerDialogPosition(app, fIdx)
            sizePx = app.getSelectedVideoDisplaySize(fIdx);
            dlgW = max(520, sizePx(1) + 36);
            dlgH = max(360, sizePx(2) + 92);
            try
                screen = app.getActiveScreenArea();
                dlgW = min(dlgW, max(520, screen(3) - 80));
                dlgH = min(dlgH, max(360, screen(4) - 120));
                x = screen(1) + max(20, round((screen(3) - dlgW) / 2));
                y = screen(2) + max(40, round((screen(4) - dlgH) / 2));
                pos = [x, y, dlgW, dlgH];
            catch
                pos = [120, 120, dlgW, dlgH];
            end
        end

        function pos = getVideoControlDialogPosition(app, fIdx)
            dlgW = 760;
            dlgH = 300;
            try
                if ~isempty(app.UI) && fIdx <= numel(app.UI) && ...
                        isfield(app.UI(fIdx), 'vidControlDialog') && ~isempty(app.UI(fIdx).vidControlDialog) && ...
                        isvalid(app.UI(fIdx).vidControlDialog)
                    oldPos = app.UI(fIdx).vidControlDialog.Position;
                    dlgW = max(dlgW, oldPos(3));
                    dlgH = max(dlgH, oldPos(4));
                end
                screen = app.getActiveScreenArea();
                viewerPos = [];
                if ~isempty(app.UI) && fIdx <= numel(app.UI) && ...
                        isfield(app.UI(fIdx), 'vidViewerDialog') && ~isempty(app.UI(fIdx).vidViewerDialog) && ...
                        isvalid(app.UI(fIdx).vidViewerDialog)
                    viewerPos = app.UI(fIdx).vidViewerDialog.Position;
                end
                if isempty(viewerPos)
                    viewerPos = app.UIFigure.Position;
                end

                gap = 8;
                x = viewerPos(1) + viewerPos(3) + gap;
                y = viewerPos(2) + max(0, viewerPos(4) - dlgH);
                if x + dlgW > screen(1) + screen(3) - 8
                    x = viewerPos(1) - dlgW - gap;
                end
                x = max(screen(1) + 8, min(x, screen(1) + screen(3) - dlgW - 8));
                y = max(screen(2) + 8, min(y, screen(2) + screen(4) - dlgH - 48));
                pos = [x, y, dlgW, dlgH];
            catch
                pos = [120, 120, dlgW, dlgH];
            end
        end

        function startVideoDialogFollowTimer(app)
            try
                if ~isempty(app.VideoDialogFollowTimer) && isvalid(app.VideoDialogFollowTimer)
                    if ~strcmpi(app.VideoDialogFollowTimer.Running, 'on')
                        start(app.VideoDialogFollowTimer);
                    end
                    return;
                end
                app.VideoDialogFollowTimer = timer( ...
                    'ExecutionMode', 'fixedSpacing', ...
                    'Period', app.VIDEO_DIALOG_FOLLOW_S, ...
                    'BusyMode', 'drop', ...
                    'Name', 'FlightDashboardVideoDialogFollow', ...
                    'TimerFcn', @(~,~) app.pollVideoDialogFollower(), ...
                    'ErrorFcn', @(~,evt) app.logCaught(evt, 'timer:videoDialogFollow'));
                start(app.VideoDialogFollowTimer);
            catch ME_silent
                app.logCaught(ME_silent, 'videoDialogFollow:start');
            end
        end

        function stopVideoDialogFollowTimer(app)
            try
                if ~isempty(app.VideoDialogFollowTimer) && isvalid(app.VideoDialogFollowTimer)
                    stop(app.VideoDialogFollowTimer);
                    delete(app.VideoDialogFollowTimer);
                end
            catch
            end
            app.VideoDialogFollowTimer = [];
            app.VideoDialogLastViewerPos = {[], []};
        end

        function updateVideoDialogFollowState(app, fIdx)
            try
                if app.areVideoDialogsVisible(fIdx)
                    app.VideoDialogLastViewerPos{fIdx} = app.UI(fIdx).vidViewerDialog.Position;
                    app.startVideoDialogFollowTimer();
                else
                    app.VideoDialogLastViewerPos{fIdx} = [];
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoDialogFollow:update');
            end
        end

        function tf = areVideoDialogsVisible(app, fIdx)
            tf = false;
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                viewer = app.UI(fIdx).vidViewerDialog;
                control = app.UI(fIdx).vidControlDialog;
                tf = ~isempty(viewer) && isvalid(viewer) && strcmpi(char(viewer.Visible), 'on') && ...
                     ~isempty(control) && isvalid(control) && strcmpi(char(control.Visible), 'on');
            catch
                tf = false;
            end
        end

        function pollVideoDialogFollower(app)
            if app.IsDeleting, return; end
            anyVisible = false;
            try
                for fIdx = 1:2
                    if ~app.areVideoDialogsVisible(fIdx)
                        app.VideoDialogLastViewerPos{fIdx} = [];
                        continue;
                    end
                    anyVisible = true;
                    viewer = app.UI(fIdx).vidViewerDialog;
                    control = app.UI(fIdx).vidControlDialog;
                    pos = viewer.Position;
                    lastPos = app.VideoDialogLastViewerPos{fIdx};
                    if isempty(lastPos) || numel(lastPos) < 4
                        app.VideoDialogLastViewerPos{fIdx} = pos;
                        continue;
                    end
                    delta = pos(1:2) - lastPos(1:2);
                    if any(abs(delta) >= 1)
                        ctrlPos = control.Position;
                        ctrlPos(1:2) = ctrlPos(1:2) + delta;
                        control.Position = ctrlPos;
                    end
                    app.VideoDialogLastViewerPos{fIdx} = pos;
                end
                if ~anyVisible
                    try
                        if ~isempty(app.VideoDialogFollowTimer) && isvalid(app.VideoDialogFollowTimer) && ...
                                strcmpi(app.VideoDialogFollowTimer.Running, 'on')
                            stop(app.VideoDialogFollowTimer);
                        end
                    catch
                    end
                    app.VideoDialogLastViewerPos = {[], []};
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoDialogFollow:poll');
            end
        end

        function setVideoViewerVisible(app, fIdx, tf, doReflow)
            if nargin < 4, doReflow = true; end
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                dlg = app.UI(fIdx).vidViewerDialog;
                if isempty(dlg) || ~isvalid(dlg), return; end
                % v5-A2: forbid external Video Player display during board-off - final defense on all call paths
                if tf && ~isempty(find(app.BoardOffState, 1))
                    try
                        app.hideVideoControlDialog(fIdx);
                    catch ME_control
                        app.logCaught(ME_control, 'videoViewerVisible:boardOffControl');
                    end
                    dlg.Visible = 'off';
                    app.UI(fIdx).PanelVisible.video = true;   % keep only the state for board-on restore
                    if isfield(app.UI(fIdx), 'btnVid') && ~isempty(app.UI(fIdx).btnVid) && isvalid(app.UI(fIdx).btnVid)
                        app.UI(fIdx).btnVid.Text = '비디오 창 예약';
                    end
                    try
                        app.updateVideoDialogFollowState(fIdx);
                    catch ME_follow
                        app.logCaught(ME_follow, 'videoViewerVisible:boardOffFollow');
                    end
                    if doReflow
                        app.reflowBoardColumns(fIdx);
                    end
                    return;
                end
                if tf
                    targetPos = app.getVideoViewerDialogPosition(fIdx);
                    dlgWasHidden = ~strcmpi(char(dlg.Visible), 'on');
                    if dlgWasHidden || dlg.Position(3) < targetPos(3) || dlg.Position(4) < targetPos(4)
                        dlg.Position = targetPos;
                    end
                    dlg.Visible = 'on';
                    app.setVideoDisplaySize(fIdx);
                    app.UI(fIdx).PanelVisible.video = true;
                    if isfield(app.UI(fIdx), 'btnVid') && ~isempty(app.UI(fIdx).btnVid) && isvalid(app.UI(fIdx).btnVid)
                        app.UI(fIdx).btnVid.Text = '비디오 창 닫기';
                    end
                    app.updateVideoDialogFollowState(fIdx);
                else
                    app.hideVideoControlDialog(fIdx);
                    dlg.Visible = 'off';
                    app.UI(fIdx).PanelVisible.video = false;
                    if isfield(app.UI(fIdx), 'btnVid') && ~isempty(app.UI(fIdx).btnVid) && isvalid(app.UI(fIdx).btnVid)
                        app.UI(fIdx).btnVid.Text = '비디오 ▸';
                    end
                    app.updateVideoDialogFollowState(fIdx);
                end
                if doReflow
                    app.reflowBoardColumns(fIdx);
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoViewerVisible');
            end
        end

        function hideVideoViewersForBoardOff(app)
            % v5-A: hide Video Player during board-off - hide only the dialog (keep PanelVisible/button)
            for vIdx = 1:numel(app.UI)
                try
                    dlg = app.UI(vIdx).vidViewerDialog;
                    if ~isempty(dlg) && isvalid(dlg)
                        dlg.Visible = 'off';
                    end
                catch
                end
            end
        end

        function restoreVideoViewersAfterBoardOn(app)
            % v5-A: board-on restore - re-show only boards whose PanelVisible.video is kept
            for vIdx = 1:numel(app.UI)
                try
                    if isfield(app.UI(vIdx), 'PanelVisible') && logical(app.UI(vIdx).PanelVisible.video)
                        app.setVideoViewerVisible(vIdx, true, false);
                    end
                catch
                end
            end
        end

        function btnPath3DPushed(app, fIdx)
            if app.IsDeleting, return; end
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || numel(app.UI) < fIdx
                    return;
                end
                target = true;
                if numel(app.Path3DVisible) >= fIdx
                    target = ~logical(app.Path3DVisible(fIdx));
                end
                app.setPath3DDialogVisible(fIdx, target);
            catch ME
                app.logCaught(ME, 'path3D:button');
            end
        end

        function createPath3DDialog(app, fIdx)
            if app.IsDeleting, return; end
            if isempty(app.UI) || numel(app.UI) < fIdx
                return;
            end
            try
                if isfield(app.UI(fIdx), 'path3DDialog') && ~isempty(app.UI(fIdx).path3DDialog) ...
                        && isvalid(app.UI(fIdx).path3DDialog)
                    return;
                end
            catch
            end

            fig = [];
            try
                t = app.getLightTheme();
                fig = uifigure('Name', sprintf('3D Path - Flight Data %d', fIdx), ...
                    'Visible', 'off', 'Position', [160, 160, 800, 600], ...
                    'Color', t.windowBg, 'CloseRequestFcn', @(~,~) app.closePath3DDialog(fIdx));
                try
                    if isprop(fig, 'Resize')
                        fig.Resize = 'on';
                    end
                    if isprop(fig, 'AutoResizeChildren')
                        fig.AutoResizeChildren = 'off';
                    end
                catch ME_fig
                    app.logCaught(ME_fig, 'path3D:auto-resize');
                end

                root = uigridlayout(fig, [1 2]);
                root.Padding = [6 6 6 6];
                root.ColumnSpacing = 6;
                root.ColumnWidth = {'1x', 220};
                root.BackgroundColor = t.windowBg;

                plotGrid = uigridlayout(root, [2 1]);
                plotGrid.Layout.Column = 1;
                plotGrid.Padding = [0 0 0 0];
                plotGrid.RowSpacing = 4;
                plotGrid.RowHeight = {32, '1x'};
                plotGrid.BackgroundColor = t.windowBg;

                topRow = uigridlayout(plotGrid, [1 2]);
                topRow.Layout.Row = 1;
                topRow.Padding = [0 0 0 0];
                topRow.ColumnWidth = {100, '1x'};
                topRow.BackgroundColor = t.windowBg;
                uibutton(topRow, 'Text', 'Reset View', 'FontSize', 11, ...
                    'BackgroundColor', t.toolbarGrayBg, 'FontColor', t.toolbarGrayFg, ...
                    'ButtonPushedFcn', @(~,~) app.path3DAutoFit(fIdx));
                uilabel(topRow, 'Text', 'X=Lon, Y=Lat, Z=Alt', ...
                    'HorizontalAlignment', 'right', 'FontColor', t.textSecondary);

                ax = uiaxes(plotGrid);
                ax.Layout.Row = 2;
                ax.Color = t.plotAxesBg;
                ax.XColor = t.plotTickFg;
                ax.YColor = t.plotTickFg;
                ax.ZColor = t.plotTickFg;
                ax.GridColor = t.plotGridColor;
                xlabel(ax, 'East (Lon)');
                ylabel(ax, 'North (Lat)');
                zlabel(ax, 'Up (Alt)');
                grid(ax, 'on');
                view(ax, 3);
                try
                    ax.XLimMode = 'manual';
                    ax.YLimMode = 'manual';
                    ax.ZLimMode = 'manual';
                    ax.Clipping = 'on';
                catch ME_axes_props
                    app.logCaught(ME_axes_props, 'path3D:axes-props');
                end
                try
                    disableDefaultInteractivity(ax);
                    ax.Toolbar.Visible = 'off';
                catch ME_axes
                    app.logCaught(ME_axes, 'path3D:axes-interaction');
                end

                sidebar = uipanel(root, 'Title', 'Axis / Display', ...
                    'BackgroundColor', t.surfaceBg, 'ForegroundColor', t.textPrimary, ...
                    'FontSize', 12, 'FontWeight', 'bold');
                sidebar.Layout.Column = 2;
                sg = uigridlayout(sidebar, [9 3]);
                sg.Padding = [6 6 6 6];
                sg.RowSpacing = 5;
                sg.ColumnSpacing = 5;
                sg.RowHeight = {22, 28, 28, 28, 28, 28, 28, 32, '1x'};
                sg.ColumnWidth = {38, '1x', '1x'};
                sg.BackgroundColor = t.surfaceBg;

                uilabel(sg, 'Text', 'Axis', 'FontWeight', 'bold', 'FontColor', t.textPrimary);
                uilabel(sg, 'Text', 'Min', 'FontWeight', 'bold', 'FontColor', t.textPrimary);
                uilabel(sg, 'Text', 'Max', 'FontWeight', 'bold', 'FontColor', t.textPrimary);
                xMin = app.createPath3DAxisInput(sg, 'X', 2, 1);
                xMax = app.createPath3DAxisInput(sg, '', 2, 3);
                yMin = app.createPath3DAxisInput(sg, 'Y', 3, 1);
                yMax = app.createPath3DAxisInput(sg, '', 3, 3);
                zMin = app.createPath3DAxisInput(sg, 'Z', 4, 1);
                zMax = app.createPath3DAxisInput(sg, '', 4, 3);
                app.createPath3DApplyButton(sg, fIdx, 'x', xMin, xMax, 5);
                app.createPath3DApplyButton(sg, fIdx, 'y', yMin, yMax, 6);
                app.createPath3DApplyButton(sg, fIdx, 'z', zMin, zMax, 7);
                fitBtn = uibutton(sg, 'Text', 'Auto / Fit', 'FontWeight', 'bold', ...
                    'BackgroundColor', t.toolbarGreenBg, 'FontColor', t.toolbarGreenFg, ...
                    'ButtonPushedFcn', @(~,~) app.path3DAutoFit(fIdx));
                fitBtn.Layout.Row = 8;
                fitBtn.Layout.Column = [1 3];

                app.UI(fIdx).path3DDialog = fig;
                app.UI(fIdx).path3DAxes = ax;
                app.UI(fIdx).path3DFullTrajectory = gobjects(0);
                app.UI(fIdx).path3DPastTrajectory = gobjects(0);
                app.UI(fIdx).path3DWayPoints = gobjects(0);
                app.UI(fIdx).path3DDroneTransform = gobjects(0);
                app.UI(fIdx).path3DDronePatch = gobjects(0);
                app.UI(fIdx).path3DBodyAxes = gobjects(1, 3);
                app.UI(fIdx).path3DSidebar = sidebar;
                app.UI(fIdx).path3DAxisLimitsCtrl = struct( ...
                    'xMin', xMin, 'xMax', xMax, 'yMin', yMin, 'yMax', yMax, ...
                    'zMin', zMin, 'zMax', zMax, 'fitBtn', fitBtn);
                app.applyLightTheme(fig);
                app.renderPath3DInitial(fIdx);
            catch ME
                try
                    if ~isempty(fig) && isvalid(fig)
                        delete(fig);
                    end
                catch
                end
                try
                    if ~isempty(app.UI) && numel(app.UI) >= fIdx
                        app.UI(fIdx).path3DDialog = [];
                    end
                catch
                end
                app.logCaught(ME, 'dialog:path3D:build');
                rethrow(ME);
            end
        end

        function openPath3DDialog(app, fIdx)
            app.setPath3DDialogVisible(fIdx, true);
        end

        function closePath3DDialog(app, fIdx)
            app.setPath3DDialogVisible(fIdx, false);
        end

        function setPath3DDialogVisible(app, fIdx, tf)
            if app.IsDeleting, return; end
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || numel(app.UI) < fIdx
                    return;
                end
                app.Path3DVisible(fIdx) = logical(tf);
                if tf && ~isempty(find(app.BoardOffState, 1))
                    if isfield(app.UI(fIdx), 'path3DDialog') && ~isempty(app.UI(fIdx).path3DDialog) ...
                            && isvalid(app.UI(fIdx).path3DDialog)
                        app.UI(fIdx).path3DDialog.Visible = 'off';
                    end
                    app.refreshPath3DButton(fIdx);
                    return;
                end
                if tf
                    app.createPath3DDialog(fIdx);
                end
                dlg = [];
                if isfield(app.UI(fIdx), 'path3DDialog')
                    dlg = app.UI(fIdx).path3DDialog;
                end
                if isempty(dlg) || ~isvalid(dlg)
                    app.refreshPath3DButton(fIdx);
                    return;
                end
                if tf
                    dlg.Visible = 'on';
                    app.renderPath3DInitial(fIdx);
                    app.updatePath3DAtTime(fIdx, app.getCurrentFlightTime(fIdx));
                else
                    dlg.Visible = 'off';
                end
                app.refreshPath3DButton(fIdx);
            catch ME
                app.logCaught(ME, 'path3D:setVisible');
            end
        end

        function hidePath3DDialogsForBoardOff(app, ~)
            for vIdx = 1:min(2, numel(app.UI))
                try
                    if isfield(app.UI(vIdx), 'path3DDialog') && ~isempty(app.UI(vIdx).path3DDialog) ...
                            && isvalid(app.UI(vIdx).path3DDialog)
                        app.UI(vIdx).path3DDialog.Visible = 'off';
                    end
                    app.refreshPath3DButton(vIdx);
                catch ME
                    app.logCaught(ME, 'path3D:hideForBoardOff');
                end
            end
        end

        function restorePath3DDialogsAfterBoardOn(app, ~)
            for vIdx = 1:min(2, numel(app.Path3DVisible))
                try
                    if logical(app.Path3DVisible(vIdx))
                        app.setPath3DDialogVisible(vIdx, true);
                    else
                        app.refreshPath3DButton(vIdx);
                    end
                catch ME
                    app.logCaught(ME, 'path3D:restoreAfterBoardOn');
                end
            end
        end

        function refreshPath3DButton(app, fIdx)
            try
                if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'btnPath3D')
                    return;
                end
                btn = app.UI(fIdx).btnPath3D;
                if isempty(btn) || ~isvalid(btn)
                    return;
                end
                if numel(app.Path3DVisible) >= fIdx && app.Path3DVisible(fIdx)
                    if ~isempty(find(app.BoardOffState, 1))
                        btn.Text = '3D 예약';
                    else
                        btn.Text = '3D 닫기';
                    end
                else
                    btn.Text = '3D 경로 ▸';
                end
            catch ME
                app.logCaught(ME, 'path3D:button-refresh');
            end
        end

        function renderPath3DInitial(app, fIdx)
            if app.IsDeleting, return; end
            try
                if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'path3DAxes')
                    return;
                end
                ax = app.UI(fIdx).path3DAxes;
                if isempty(ax) || ~isvalid(ax)
                    return;
                end
                cla(ax);
                [ok, times, x, y, z] = app.getPath3DSeries(fIdx);
                hold(ax, 'on');
                grid(ax, 'on');
                xlabel(ax, 'East (Lon)');
                ylabel(ax, 'North (Lat)');
                zlabel(ax, 'Up (Alt)');
                view(ax, 3);
                if ~ok
                    title(ax, 'No flight data');
                    app.UI(fIdx).path3DFullTrajectory = gobjects(0);
                    app.UI(fIdx).path3DPastTrajectory = gobjects(0);
                    app.UI(fIdx).path3DWayPoints = gobjects(0);
                    app.UI(fIdx).path3DDroneTransform = gobjects(0);
                    app.UI(fIdx).path3DDronePatch = gobjects(0);
                    app.UI(fIdx).path3DBodyAxes = gobjects(1, 3);
                    return;
                end
                fullIdx = app.path3DDecimatedIndices(numel(x), app.PATH3D_FULL_MAX_POINTS);
                app.UI(fIdx).path3DFullTrajectory = plot3(ax, x(fullIdx), y(fullIdx), z(fullIdx), ':', ...
                    'LineWidth', 1.2, 'Color', [0.25 0.35 0.45]);
                app.UI(fIdx).path3DPastTrajectory = plot3(ax, nan, nan, nan, '-', ...
                    'LineWidth', 2.2, 'Color', [0.00 0.45 0.74]);
                wayPoints = app.getPath3DWayPoints(fIdx);
                if ~isempty(wayPoints)
                    app.UI(fIdx).path3DWayPoints = scatter3(ax, [wayPoints.lon], [wayPoints.lat], [wayPoints.alt], ...
                        64, [0.86 0.16 0.12], 'filled', 'MarkerEdgeColor', [0.35 0.05 0.02], 'LineWidth', 1.0);
                else
                    app.UI(fIdx).path3DWayPoints = gobjects(0);
                end
                idx = max(1, min(numel(times), round(app.Models(fIdx).currentIndex)));
                app.createPath3DDroneGlyph(fIdx, ax, x, y, z);
                title(ax, sprintf('Flight Data %d 3D Path', fIdx));
                app.path3DAutoFit(fIdx);
                app.updatePath3DAtTime(fIdx, times(idx));
            catch ME
                app.logCaught(ME, 'path3D:render');
            end
        end

        function updatePath3DAtTime(app, fIdx, t)
            if app.IsDeleting, return; end
            try
                if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'path3DDialog')
                    return;
                end
                dlg = app.UI(fIdx).path3DDialog;
                if isempty(dlg) || ~isvalid(dlg) || ~app.isUiVisible(dlg)
                    return;
                end
                [ok, times, x, y, z] = app.getPath3DSeries(fIdx);
                if ~ok
                    return;
                end
                idx = app.findClosestIndexByTime(times, t);
                idx = max(1, min(numel(times), idx));
                if isempty(app.UI(fIdx).path3DPastTrajectory) || ~isvalid(app.UI(fIdx).path3DPastTrajectory) ...
                        || isempty(app.UI(fIdx).path3DDroneTransform) || ~isvalid(app.UI(fIdx).path3DDroneTransform)
                    app.renderPath3DInitial(fIdx);
                    return;
                end
                pastIdx = app.path3DDecimatedIndices(idx, app.PATH3D_PAST_MAX_POINTS);
                set(app.UI(fIdx).path3DPastTrajectory, 'XData', x(pastIdx), 'YData', y(pastIdx), 'ZData', z(pastIdx));
                app.UI(fIdx).path3DDroneTransform.Matrix = app.path3DDroneTransformMatrix(fIdx, idx, x(idx), y(idx), z(idx), x, y, z);
            catch ME
                app.logCaught(ME, 'path3D:update');
            end
        end

        function createPath3DDroneGlyph(app, fIdx, ax, x, y, z)
            try
                hg = hgtransform('Parent', ax);
                vertices = [ ...
                     1.00,  0.00, 0.00; ...
                     0.00,  0.45, 0.00; ...
                    -1.00,  0.00, 0.00; ...
                     0.00, -0.45, 0.00];
                faces = [1 2 3 4];
                app.UI(fIdx).path3DDroneTransform = hg;
                app.UI(fIdx).path3DDronePatch = patch('Parent', hg, ...
                    'Vertices', vertices, 'Faces', faces, ...
                    'FaceColor', [0.95 0.67 0.10], 'FaceAlpha', 0.88, ...
                    'EdgeColor', [0.10 0.10 0.10], 'LineWidth', 1.0);
                app.UI(fIdx).path3DBodyAxes = gobjects(1, 3);
                app.UI(fIdx).path3DBodyAxes(1) = line('Parent', hg, 'XData', [0 1.35], 'YData', [0 0], ...
                    'ZData', [0 0], 'Color', [0.85 0.10 0.10], 'LineWidth', 2.0);
                app.UI(fIdx).path3DBodyAxes(2) = line('Parent', hg, 'XData', [0 0], 'YData', [0 1.35], ...
                    'ZData', [0 0], 'Color', [0.10 0.65 0.20], 'LineWidth', 2.0);
                app.UI(fIdx).path3DBodyAxes(3) = line('Parent', hg, 'XData', [0 0], 'YData', [0 0], ...
                    'ZData', [0 1.35], 'Color', [0.10 0.25 0.90], 'LineWidth', 2.0);
                idx = max(1, min(numel(x), round(app.Models(fIdx).currentIndex)));
                hg.Matrix = app.path3DDroneTransformMatrix(fIdx, idx, x(idx), y(idx), z(idx), x, y, z);
            catch ME
                app.logCaught(ME, 'path3D:drone-glyph');
                app.UI(fIdx).path3DDroneTransform = gobjects(0);
                app.UI(fIdx).path3DDronePatch = gobjects(0);
                app.UI(fIdx).path3DBodyAxes = gobjects(1, 3);
            end
        end

        function M = path3DDroneTransformMatrix(app, fIdx, idx, x0, y0, z0, x, y, z)
            M = eye(4);
            try
                scales = app.path3DDroneScale(x, y, z);
                R = app.path3DRotationMatrixAtIndex(fIdx, idx);
                M(1:3, 1:3) = R * diag(scales);
                M(1:3, 4) = [double(x0); double(y0); double(z0)];
            catch ME
                app.logCaught(ME, 'path3D:drone-transform');
                M(1:3, 4) = [double(x0); double(y0); double(z0)];
            end
        end

        function scales = path3DDroneScale(~, x, y, z)
            x = x(isfinite(x));
            y = y(isfinite(y));
            z = z(isfinite(z));
            xySpan = 1e-3;
            zSpan = 1;
            if ~isempty(x)
                xySpan = max(xySpan, max(x) - min(x));
            end
            if ~isempty(y)
                xySpan = max(xySpan, max(y) - min(y));
            end
            if ~isempty(z)
                zSpan = max(zSpan, max(z) - min(z));
            end
            scales = [xySpan * 0.035, xySpan * 0.035, zSpan * 0.035];
        end

        function R = path3DRotationMatrixAtIndex(app, fIdx, idx)
            R = eye(3);
            % [#4] attitude gated off by default (identity = position only) until verified
            if ~app.Path3DAttitudeEnabled
                return;
            end
            try
                [bodyAttitude, hasSource] = app.resolvePath3DAttitudeSource(fIdx);
                if ~hasSource || fIdx < 1 || fIdx > numel(app.Models) || isempty(app.Models(fIdx).rawData)
                    return;
                end
                tbl = app.Models(fIdx).rawData;
                idx = max(1, min(height(tbl), round(double(idx))));
                cols = {bodyAttitude.bodyX, bodyAttitude.bodyY, bodyAttitude.bodyZ};
                vals = nan(1, 3);
                for colIdx = 1:3
                    if isempty(cols{colIdx}) || ~ismember(cols{colIdx}, tbl.Properties.VariableNames)
                        return;
                    end
                    vals(colIdx) = double(tbl.(cols{colIdx})(idx));
                end
                if any(~isfinite(vals))
                    return;
                end
                useDegreeFallback = any(abs(vals) > (2 * pi * 1.2));
                roll = app.path3DAngleToRadians(vals(1), cols{1}, useDegreeFallback);
                pitch = app.path3DAngleToRadians(vals(2), cols{2}, useDegreeFallback);
                yaw = app.path3DAngleToRadians(vals(3), cols{3}, useDegreeFallback);
                % [#1] ENU<-NED yaw conversion (pure helper, unit-testable).
                % roll/pitch are body-frame rotations (no ENU/NED difference); kept as-is.
                yaw = app.path3DYawNedToEnu(yaw);
                cr = cos(roll);  sr = sin(roll);
                cp = cos(pitch); sp = sin(pitch);
                cy = cos(yaw);   sy = sin(yaw);
                Rx = [1 0 0; 0 cr -sr; 0 sr cr];
                Ry = [cp 0 sp; 0 1 0; -sp 0 cp];
                Rz = [cy -sy 0; sy cy 0; 0 0 1];
                R = Rz * Ry * Rx;
            catch ME
                app.logCaught(ME, 'path3D:rotation');
                R = eye(3);
            end
        end

        function yawEnu = path3DYawNedToEnu(~, yawNed)
            % [#1] NED heading (clockwise from North) -> ENU yaw (counter-clockwise from East).
            % psi_ENU = pi/2 - psi_NED. So North(0)->pi/2 (+y), East(pi/2)->0 (+x), South(pi)->-pi/2.
            yawEnu = pi/2 - double(yawNed);
        end

        function angleRad = path3DAngleToRadians(~, value, columnName, useDegreeFallback)
            lowerName = lower(char(columnName));
            if contains(lowerName, 'rad')
                angleRad = double(value);
            elseif contains(lowerName, 'deg') || useDegreeFallback
                angleRad = double(value) * pi / 180;
            else
                angleRad = double(value);
            end
        end

        function [bodyAttitude, hasSource] = resolvePath3DAttitudeSource(app, fIdx)
            bodyAttitude = struct('bodyX', '', 'bodyY', '', 'bodyZ', '');
            hasSource = false;
            try
                if fIdx < 1 || fIdx > numel(app.Models) || isempty(app.Models(fIdx).rawData)
                    return;
                end
                tbl = app.Models(fIdx).rawData;
                if isfield(app.Models(fIdx), 'bodyAttitude') && isstruct(app.Models(fIdx).bodyAttitude)
                    configured = app.Models(fIdx).bodyAttitude;
                    keys = {'bodyX', 'bodyY', 'bodyZ'};
                    for keyIdx = 1:numel(keys)
                        key = keys{keyIdx};
                        if isfield(configured, key)
                            bodyAttitude.(key) = char(configured.(key));
                        end
                    end
                    hasSource = all(cellfun(@(key) isfield(bodyAttitude, key) && ...
                        ~isempty(bodyAttitude.(key)) && ismember(bodyAttitude.(key), tbl.Properties.VariableNames), keys));
                    if hasSource
                        return;
                    end
                end
                if isfield(app.Models(fIdx), 'mappedCols')
                    cols = app.Models(fIdx).mappedCols;
                    if isfield(cols, 'Roll') && isfield(cols, 'Pitch') && isfield(cols, 'Heading') ...
                            && ismember(cols.Roll, tbl.Properties.VariableNames) ...
                            && ismember(cols.Pitch, tbl.Properties.VariableNames) ...
                            && ismember(cols.Heading, tbl.Properties.VariableNames)
                        bodyAttitude.bodyX = char(cols.Roll);
                        bodyAttitude.bodyY = char(cols.Pitch);
                        bodyAttitude.bodyZ = char(cols.Heading);
                        hasSource = true;
                    end
                end
            catch ME
                app.logCaught(ME, 'path3D:resolve-attitude');
            end
        end

        function applyPath3DAxisLimits(app, fIdx, axisName, lo, hi)
            try
                if ~isfinite(lo) || ~isfinite(hi) || lo >= hi
                    return;
                end
                ax = app.UI(fIdx).path3DAxes;
                if isempty(ax) || ~isvalid(ax)
                    return;
                end
                switch lower(char(axisName))
                    case 'x'
                        xlim(ax, [lo hi]);
                    case 'y'
                        ylim(ax, [lo hi]);
                    case 'z'
                        zlim(ax, [lo hi]);
                end
            catch ME
                app.logCaught(ME, 'path3D:axis-apply');
            end
        end

        function path3DAutoFit(app, fIdx)
            try
                if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'path3DAxes')
                    return;
                end
                ax = app.UI(fIdx).path3DAxes;
                if isempty(ax) || ~isvalid(ax)
                    return;
                end
                [ok, ~, x, y, z] = app.getPath3DSeries(fIdx);
                if ~ok
                    return;
                end
                wayPoints = app.getPath3DWayPoints(fIdx);
                if ~isempty(wayPoints)
                    x = [x(:); reshape([wayPoints.lon], [], 1)];
                    y = [y(:); reshape([wayPoints.lat], [], 1)];
                    z = [z(:); reshape([wayPoints.alt], [], 1)];
                end
                xLim = app.path3DBounds(x);
                yLim = app.path3DBounds(y);
                zLim = app.path3DBounds(z);
                xlim(ax, xLim);
                ylim(ax, yLim);
                zlim(ax, zLim);
                try
                    ax.XLimMode = 'manual';
                    ax.YLimMode = 'manual';
                    ax.ZLimMode = 'manual';
                    ax.Clipping = 'on';
                catch ME_axes_props
                    app.logCaught(ME_axes_props, 'path3D:auto-fit-axes-props');
                end
                app.setPath3DAxisCtrlValues(fIdx, xLim, yLim, zLim);
            catch ME
                app.logCaught(ME, 'path3D:auto-fit');
            end
        end

        function ctrl = createPath3DAxisInput(~, parent, labelText, rowIdx, colIdx)
            if ~isempty(labelText)
                lbl = uilabel(parent, 'Text', labelText, 'FontWeight', 'bold');
                lbl.Layout.Row = rowIdx;
                lbl.Layout.Column = colIdx;
                editCol = 2;
            else
                editCol = colIdx;
            end
            ctrl = uieditfield(parent, 'numeric', 'Value', 0);
            ctrl.Layout.Row = rowIdx;
            ctrl.Layout.Column = editCol;
        end

        function createPath3DApplyButton(app, parent, fIdx, axisName, loCtrl, hiCtrl, rowIdx)
            btn = uibutton(parent, 'Text', sprintf('%s Apply', upper(char(axisName))), ...
                'ButtonPushedFcn', @(~,~) app.applyPath3DAxisLimits(fIdx, axisName, loCtrl.Value, hiCtrl.Value));
            btn.Layout.Row = rowIdx;
            btn.Layout.Column = [1 3];
        end

        function setPath3DAxisCtrlValues(app, fIdx, xLim, yLim, zLim)
            try
                if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'path3DAxisLimitsCtrl')
                    return;
                end
                c = app.UI(fIdx).path3DAxisLimitsCtrl;
                c.xMin.Value = xLim(1); c.xMax.Value = xLim(2);
                c.yMin.Value = yLim(1); c.yMax.Value = yLim(2);
                c.zMin.Value = zLim(1); c.zMax.Value = zLim(2);
            catch ME
                app.logCaught(ME, 'path3D:axis-field-refresh');
            end
        end

        function lim = path3DBounds(~, values)
            values = values(isfinite(values));
            if isempty(values)
                lim = [0 1];
                return;
            end
            lo = min(values);
            hi = max(values);
            if lo == hi
                pad = max(1, abs(lo) * 0.01);
            else
                pad = (hi - lo) * 0.05;
            end
            lim = [lo - pad, hi + pad];
        end

        function idx = path3DDecimatedIndices(~, stopIdx, maxPoints)
            idx = [];
            try
                stopIdx = floor(double(stopIdx));
                maxPoints = max(1, floor(double(maxPoints)));
                if ~isfinite(stopIdx) || stopIdx < 1
                    return;
                end
                step = max(1, ceil(stopIdx / maxPoints));
                idx = 1:step:stopIdx;
                if isempty(idx) || idx(end) ~= stopIdx
                    idx = [idx, stopIdx];
                end
            catch
                idx = [];
            end
        end

        function [ok, times, x, y, z] = getPath3DSeries(app, fIdx)
            ok = false;
            times = [];
            x = [];
            y = [];
            z = [];
            try
                if fIdx < 1 || fIdx > numel(app.Models) || isempty(app.Models(fIdx).rawData)
                    return;
                end
                tbl = app.Models(fIdx).rawData;
                if height(tbl) == 0 || ~isfield(app.Models(fIdx), 'mappedCols')
                    return;
                end
                cols = app.Models(fIdx).mappedCols;
                needed = {'Time', 'Lon', 'Lat', 'Alt'};
                for nIdx = 1:numel(needed)
                    key = needed{nIdx};
                    if ~isfield(cols, key) || isempty(cols.(key)) ...
                            || ~ismember(cols.(key), tbl.Properties.VariableNames)
                        return;
                    end
                end
                times = double(tbl.(cols.Time)(:));
                x = double(tbl.(cols.Lon)(:));
                y = double(tbl.(cols.Lat)(:));
                z = double(tbl.(cols.Alt)(:));
                n = min([numel(times), numel(x), numel(y), numel(z)]);
                if n < 1
                    return;
                end
                times = times(1:n);
                x = x(1:n);
                y = y(1:n);
                z = z(1:n);
                ok = any(isfinite(x) & isfinite(y) & isfinite(z));
            catch ME
                app.logCaught(ME, 'path3D:series');
            end
        end

        function wayPoints = getPath3DWayPoints(app, fIdx)
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            try
                if fIdx < 1 || fIdx > numel(app.Models)
                    return;
                end
                if isfield(app.Models(fIdx), 'option') && isfield(app.Models(fIdx).option, 'wayPoints')
                    raw = app.Models(fIdx).option.wayPoints;
                elseif isfield(app.Models(fIdx), 'wayPoints')
                    raw = app.Models(fIdx).wayPoints;
                else
                    raw = wayPoints;
                end
                wayPoints = app.normalizeWayPointStruct(raw);
            catch ME
                app.logCaught(ME, 'path3D:waypoints');
            end
        end

        function currentTime = getCurrentFlightTime(app, fIdx)
            currentTime = 0;
            try
                if isempty(app.Models(fIdx).rawData)
                    return;
                end
                idx = max(1, min(height(app.Models(fIdx).rawData), round(app.Models(fIdx).currentIndex)));
                timeCol = app.Models(fIdx).mappedCols.Time;
                currentTime = double(app.Models(fIdx).rawData.(timeCol)(idx));
            catch
            end
        end

        function [wayPoints, bodyAttitude] = normalizePath3DOptionDraft(app, draft, csvHeaders)
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            bodyAttitude = struct('bodyX', '', 'bodyY', '', 'bodyZ', '');
            try
                if isfield(draft, 'wayPoints')
                    wayPoints = app.normalizeWayPointStruct(draft.wayPoints);
                end
                if isfield(draft, 'bodyAttitude') && isstruct(draft.bodyAttitude)
                    keys = {'bodyX', 'bodyY', 'bodyZ'};
                    for keyIdx = 1:numel(keys)
                        key = keys{keyIdx};
                        if isfield(draft.bodyAttitude, key)
                            value = char(draft.bodyAttitude.(key));
                            if ~isempty(value) && ismember(value, csvHeaders)
                                bodyAttitude.(key) = value;
                            end
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'path3D:normalize-option');
            end
        end

        function wayPoints = normalizeWayPointStruct(app, raw)
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            try
                if isempty(raw) || ~isstruct(raw)
                    return;
                end
                for wpIdx = 1:numel(raw)
                    if ~isfield(raw(wpIdx), 'lat') || ~isfield(raw(wpIdx), 'lon') || ~isfield(raw(wpIdx), 'alt')
                        app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                        continue;
                    end
                    lat = double(raw(wpIdx).lat);
                    lon = double(raw(wpIdx).lon);
                    alt = double(raw(wpIdx).alt);
                    if ~(isfinite(lat) && isfinite(lon) && isfinite(alt))
                        app.logCaught(MException('FDD:OptionWayPoint', 'invalid row'), 'option:wayPoint:invalidRow');
                        continue;
                    end
                    label = sprintf('WP%d', wpIdx);
                    if isfield(raw(wpIdx), 'label') && ~isempty(raw(wpIdx).label)
                        label = char(raw(wpIdx).label);
                    end
                    wayPoints(end+1) = struct('label', label, 'lat', lat, 'lon', lon, 'alt', alt); %#ok<AGROW>
                end
            catch ME
                app.logCaught(ME, 'path3D:normalize-waypoints');
            end
        end

        function wayPoints = parseOptionWayPoints(app, linesOrText)
            wayPoints = struct('label', {}, 'lat', {}, 'lon', {}, 'alt', {});
            try
                lines = splitlines(string(linesOrText));
                for lineIdx = 1:numel(lines)
                    lineStr = strtrim(lines(lineIdx));
                    if lineStr == "" || startsWith(lineStr, "#")
                        continue;
                    end
                    kv = split(char(lineStr), '=');
                    if numel(kv) < 2
                        continue;
                    end
                    nm = strtrim(kv{1});
                    vals = split(strtrim(strjoin(kv(2:end), '=')), ',');
                    if numel(vals) < 3
                        continue;
                    end
                    lat = str2double(strtrim(vals{1}));
                    lon = str2double(strtrim(vals{2}));
                    alt = str2double(strtrim(vals{3}));
                    label = nm;
                    if numel(vals) >= 4 && ~isempty(strtrim(vals{4}))
                        label = strtrim(vals{4});
                    end
                    if isfinite(lat) && isfinite(lon) && isfinite(alt)
                        wayPoints(end+1) = struct('label', char(label), 'lat', lat, 'lon', lon, 'alt', alt); %#ok<AGROW>
                    end
                end
            catch ME
                app.logCaught(ME, 'option:wayPoint:parse');
            end
        end

        function bodyAttitude = parseOptionBodyAttitude(app, linesOrText, csvHeaders)
            bodyAttitude = struct('bodyX', '', 'bodyY', '', 'bodyZ', '');
            try
                lines = splitlines(string(linesOrText));
                for lineIdx = 1:numel(lines)
                    kv = split(char(strtrim(lines(lineIdx))), '=');
                    if numel(kv) < 2
                        continue;
                    end
                    bk = strtrim(kv{1});
                    bv = strtrim(strjoin(kv(2:end), '='));
                    if any(strcmpi(bk, {'bodyX', 'bodyY', 'bodyZ'})) && ismember(bv, csvHeaders)
                        bodyAttitude.(['body' upper(bk(end))]) = bv;
                    end
                end
            catch ME
                app.logCaught(ME, 'option:bodyAttitude:parse');
            end
        end

        function editDialogApplyPath3DDraft(app, ~)
            try
                app.editDialogApplyOptionDraft();
                for fIdx = 1:2
                    if app.Path3DVisible(fIdx)
                        app.renderPath3DInitial(fIdx);
                        app.updatePath3DAtTime(fIdx, app.getCurrentFlightTime(fIdx));
                    end
                end
            catch ME
                app.logCaught(ME, 'editDialog:path3DApply');
            end
        end

        function state = getPath3DStateForTest(app)
            state = struct('visible', false(1, 2), 'desiredVisible', logical(app.Path3DVisible), ...
                'hasAxes', false(1, 2), 'hasDroneTransform', false(1, 2), ...
                'hasBodyAxes', false(1, 2), 'pastPointCount', zeros(1, 2));
            for vIdx = 1:min(2, numel(app.UI))
                try
                    if isfield(app.UI(vIdx), 'path3DDialog') && ~isempty(app.UI(vIdx).path3DDialog) ...
                            && isvalid(app.UI(vIdx).path3DDialog)
                        state.visible(vIdx) = app.isUiVisible(app.UI(vIdx).path3DDialog);
                    end
                    if isfield(app.UI(vIdx), 'path3DAxes') && ~isempty(app.UI(vIdx).path3DAxes) ...
                            && isvalid(app.UI(vIdx).path3DAxes)
                        state.hasAxes(vIdx) = true;
                    end
                    if isfield(app.UI(vIdx), 'path3DPastTrajectory') && ~isempty(app.UI(vIdx).path3DPastTrajectory) ...
                            && isvalid(app.UI(vIdx).path3DPastTrajectory)
                        state.pastPointCount(vIdx) = numel(app.UI(vIdx).path3DPastTrajectory.XData);
                    end
                    if isfield(app.UI(vIdx), 'path3DDroneTransform') && ~isempty(app.UI(vIdx).path3DDroneTransform) ...
                            && isvalid(app.UI(vIdx).path3DDroneTransform)
                        state.hasDroneTransform(vIdx) = true;
                    end
                    if isfield(app.UI(vIdx), 'path3DBodyAxes') && ~isempty(app.UI(vIdx).path3DBodyAxes)
                        state.hasBodyAxes(vIdx) = all(isvalid(app.UI(vIdx).path3DBodyAxes));
                    end
                catch ME
                    app.logCaught(ME, 'test:path3D-state');
                end
            end
        end

        function onVideoResolutionChanged(app, fIdx)
            % v4-R2: removed dialog auto-show on resolution change. update frame/display only.
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
                pad = 0;
                if isfield(app.UI(fIdx), 'vidContainer') && ~isempty(app.UI(fIdx).vidContainer) && ...
                        isvalid(app.UI(fIdx).vidContainer)
                    app.UI(fIdx).vidContainer.BackgroundColor = app.getLightTheme().videoPanelBg;   % v3-D: external container light
                end
                app.UI(fIdx).vidAxes.Units = 'pixels';
                app.UI(fIdx).vidAxes.Position = [pad, pad, sizePx(1), sizePx(2)];
                app.UI(fIdx).vidAxes.Color = app.getLightTheme().videoAxesBg;   % v3-sample: remove black
                app.UI(fIdx).vidAxes.XColor = 'none';
                app.UI(fIdx).vidAxes.YColor = 'none';
                try
                    app.UI(fIdx).vidAxes.ActivePositionProperty = 'position';
                catch
                end
                try
                    app.UI(fIdx).vidAxes.InnerPosition = [pad, pad, sizePx(1), sizePx(2)];
                catch
                end
                try
                    app.UI(fIdx).vidAxes.LooseInset = [0 0 0 0];
                catch
                end
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
                if strcmpi(char(dlg.Visible), 'on')
                    app.hideVideoControlDialog(fIdx);
                else
                    try
                        dlg.Position = app.getVideoControlDialogPosition(fIdx);
                    catch ME_inner
                        app.logCaught(ME_inner, 'openVideoControlDialog:position');
                    end
                    dlg.Visible = 'on';
                    drawnow limitrate;
                    if isfield(app.UI(fIdx), 'vidControlBtn') && ~isempty(app.UI(fIdx).vidControlBtn) && isvalid(app.UI(fIdx).vidControlBtn)
                        app.UI(fIdx).vidControlBtn.Text = '제어창 닫기';
                    end
                    app.updateVideoDialogFollowState(fIdx);
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
                app.updateVideoDialogFollowState(fIdx);
            catch ME_silent
                app.logCaught(ME_silent, 'videoControlHide');
            end
        end

        function ctrl = createVideoControlDialog(app, fIdx)
            ctrl = struct();
            ctrlFont = 14;
            ctrlSmallFont = 13;
            % [step1] protect the entire new video-control-dialog build - on failure clean the partial figure then rethrow
            try
            dlg = uifigure('Name', sprintf('AVI 제어 - Flight Data %d', fIdx), ...
                'Visible', 'off', 'Position', [120, 120, 760, 380], ...
                'Color', [0.94 0.94 0.96], ...
                'CloseRequestFcn', @(~,~) app.hideVideoControlDialog(fIdx));
            % v-fix5: resize stabilization - set AutoResizeChildren off first (required) before SizeChangedFcn
            try
                if isprop(dlg, 'AutoResizeChildren')
                    dlg.AutoResizeChildren = 'off';
                end
            catch ME_silent
                app.logCaught(ME_silent, 'videoControlDialog:auto-resize-children');
            end
            try
                dlg.SizeChangedFcn = @(src,~) app.clampVideoControlDialogSize(src);
            catch ME_silent
                app.logCaught(ME_silent, 'videoControlDialog:size-changed-fcn');
            end
            root = uigridlayout(dlg, [3 1]);
            root.RowHeight = {64, '1x', 56};   % v-fix5: Navigator row flex + secure min height
            root.Padding = [6 6 6 6];
            root.RowSpacing = 5;

            tT = app.getLightTheme();   % v-style
            syncPnl = uipanel(root, 'Title', '동기 설정', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary, 'FontSize', ctrlSmallFont);
            glSync = uigridlayout(syncPnl, [1 6], ...
                'ColumnWidth', {70, 105, 74, 120, '1x', 100}, ...
                'Padding', [6 4 6 4], 'ColumnSpacing', 6);
            uilabel(glSync, 'Text', 'Frame:', 'FontSize', ctrlFont, 'FontWeight', 'bold');
            ctrl.vidSyncFrameInput = uispinner(glSync, 'Value', 1, 'Step', 1, ...
                'Limits', [1 1e9], 'ValueDisplayFormat', '%d', 'FontSize', ctrlFont);
            uilabel(glSync, 'Text', 'Time(s):', 'FontSize', ctrlFont, 'FontWeight', 'bold');
            ctrl.vidSyncTimeInput = uispinner(glSync, 'Value', 0, 'Step', 0.1, ...
                'ValueDisplayFormat', '%.3f', 'FontSize', ctrlFont);
            uilabel(glSync, 'Text', '');
            ctrl.vidSyncBtn = uibutton(glSync, 'Text', '동기', ...
                'BackgroundColor', tT.toolbarGreenBg, 'FontColor', tT.toolbarGreenFg, ...
                'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.applyVideoSync(fIdx));

            vdubGroupPnl = uipanel(root, 'Title', 'Frame Navigator', ...
                'FontSize', ctrlSmallFont, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.94 0.96 0.98], ...
                'BorderType', 'line', 'ForegroundColor', tT.textPrimary);
            vdubGrid = uigridlayout(vdubGroupPnl, [3 1]);
            vdubGrid.RowHeight = {32, 50, 40};   % v2-F2: increase label/slider/button row height (prevents clipping)
            vdubGrid.Padding = [8 3 8 2];
            vdubGrid.RowSpacing = 2;
            ctrl.vidVdubLabel = uilabel(vdubGrid, ...
                'Text', 'Frame 1 / 1  (00:00:00.000)', ...
                'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'FontName', 'Consolas', 'FontColor', tT.accentBlueText, ...
                'HorizontalAlignment', 'center');
            ctrl.vidVdubSlider = uislider(vdubGrid, ...
                'Limits', [1 100], 'Value', 1, ...
                'MajorTicks', [1 25 50 75 100], ...
                'MinorTicks', [], ...
                'ValueChangingFcn', @(~,evt) app.onVdubSliderChanging(fIdx, evt.Value), ...
                'ValueChangedFcn',  @(src,~) app.onVdubSliderChanged(fIdx, src));
            navPnl = uipanel(vdubGrid, 'BorderType', 'none', 'BackgroundColor', [0.94 0.96 0.98]);
            glNav = uigridlayout(navPnl, [1 6], ...
                'ColumnWidth', {'1x', '1x', '1x', '1x', '1x', '1x'}, ...
                'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            uibutton(glNav, 'Text', '◄◄◄', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '20 프레임 뒤로 (-20)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'back20'));
            uibutton(glNav, 'Text', '◄◄', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '10 프레임 뒤로 (-10)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'back10'));
            uibutton(glNav, 'Text', '◄', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '이전 frame (-1)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'prev'));
            uibutton(glNav, 'Text', '►', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '다음 frame (+1)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'next'));
            uibutton(glNav, 'Text', '►►', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '10 프레임 앞으로 (+10)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'fwd10'));
            uibutton(glNav, 'Text', '►►►', 'FontSize', ctrlFont, 'FontWeight', 'bold', ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'Tooltip', '20 프레임 앞으로 (+20)', ...
                'ButtonPushedFcn', @(~,~) app.onVdubNav(fIdx, 'fwd20'));

            hzPnl = uipanel(root, 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary, 'BorderType', 'line');
            glHz = uigridlayout(hzPnl, [1 12], ...
                'ColumnWidth', {80, 30, 56, 30, 12, 68, 30, 56, 30, 12, 60, 100}, ...
                'Padding', [6 4 6 4], 'ColumnSpacing', 4);
            uilabel(glHz, 'Text', 'Video FPS:', 'FontSize', ctrlSmallFont, 'FontWeight', 'bold');
            uibutton(glHz, 'Text', '◄', 'FontSize', ctrlSmallFont, ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'video', -1));
            ctrl.vidVideoFpsInput = uispinner(glHz, 'Value', 15, 'Step', 1, ...
                'Limits', [1 1000], 'ValueDisplayFormat', '%d', 'FontSize', ctrlSmallFont, ...
                'ValueChangedFcn', @(src,~) app.onHzInputChanged(fIdx, 'video', src.Value));
            uibutton(glHz, 'Text', '►', 'FontSize', ctrlSmallFont, ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'video', 1));
            uilabel(glHz, 'Text', '');
            uilabel(glHz, 'Text', 'Data Hz:', 'FontSize', ctrlSmallFont, 'FontWeight', 'bold');
            uibutton(glHz, 'Text', '◄', 'FontSize', ctrlSmallFont, ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'data', -1));
            ctrl.vidDataFpsInput = uispinner(glHz, 'Value', 50, 'Step', 1, ...
                'Limits', [1 1000], 'ValueDisplayFormat', '%d', 'FontSize', ctrlSmallFont, ...
                'ValueChangedFcn', @(src,~) app.onHzInputChanged(fIdx, 'data', src.Value));
            uibutton(glHz, 'Text', '►', 'FontSize', ctrlSmallFont, ...
                'BackgroundColor', tT.toolbarGrayBg, 'FontColor', tT.toolbarGrayFg, ...
                'ButtonPushedFcn', @(~,~) app.adjustHzValue(fIdx, 'data', 1));
            uilabel(glHz, 'Text', '');
            uilabel(glHz, 'Text', 'Cache:', 'FontSize', ctrlSmallFont, 'FontWeight', 'bold');
            ctrl.vidCacheBudget = uidropdown(glHz, ...
                'Items', {'30 MB', '50 MB', '100 MB'}, ...
                'ItemsData', [30, 50, 100], ...
                'Value', 100, 'FontSize', ctrlSmallFont, ...   % v-fix6: default 100MB
                'ValueChangedFcn', @(src,~) app.setCacheBudget(src.Value));

            ctrl.vidControlDialog = dlg;
            ctrl.vidFrameAxes = gobjects(0);
            ctrl.vidFrameXLine = gobjects(0);
            ctrl.vidFrameMarker = gobjects(0);
            app.applyLightTheme(dlg);  % v4-Theme
            catch ME
                try
                    if exist('dlg', 'var') && ~isempty(dlg) && isvalid(dlg)
                        delete(dlg);
                    end
                catch
                end
                % [#3] description-implementation alignment - on build failure, explicitly invalidate the slot too (existence/range guard)
                try
                    if fIdx >= 1 && fIdx <= numel(app.UI) && isfield(app.UI(fIdx), 'vidControlDialog')
                        app.UI(fIdx).vidControlDialog = [];
                    end
                catch
                end
                app.logCaught(ME, 'dialog:videoControl:build');
                rethrow(ME);
            end
        end

        function toggleBoardVisibility(app, fIdx)
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || fIdx > numel(app.UI)
                    return;
                end
                % [bug#4] on fast consecutive toggles, the trailing drawnow's queue drain can re-enter, so
                % block via an instance flag. onCleanup guarantees release including exception/early-return.
                if app.InBoardToggle, return; end
                app.InBoardToggle = true;
                cleanupBoardToggle = onCleanup(@() app.restoreInBoardToggle()); %#ok<NASGU>
                app.CurrentLayoutPreset = 'custom';
                app.updateLayoutPresetButtons();
                sourceIdx = app.getBoardOffSourceIdx(fIdx);

                if app.BoardOffState(fIdx)
                    app.BoardOffState(fIdx) = false;
                    if isfield(app.UI(fIdx), 'boardOffPanel')
                        app.setUiVisible(app.UI(fIdx).boardOffPanel, false);
                    end
                    app.restoreBoardPanelState(fIdx);
                    app.restoreBoardPanelState(sourceIdx);
                    app.restoreVideoViewersAfterBoardOn();   % v5-A
                    app.restorePath3DDialogsAfterBoardOn(fIdx);
                    if isfield(app.UI(fIdx), 'boardOffSignature')
                        app.UI(fIdx).boardOffSignature = '';
                    end
                else
                    otherIdx = 3 - fIdx;
                    if otherIdx >= 1 && otherIdx <= numel(app.BoardOffState) && app.BoardOffState(otherIdx)
                        app.updateBoardToggleButtons();
                        return;
                    end
                    app.captureBoardPanelState(fIdx);
                    app.captureBoardPanelState(sourceIdx);
                    app.BoardOffState(fIdx) = true;
                    app.hideVideoViewersForBoardOff();   % v5-A: policy - do not show Video Player during board-off
                    app.hidePath3DDialogsForBoardOff(fIdx);
                    app.setUiVisible(app.UI(fIdx).panel, false);
                    if isfield(app.UI(fIdx), 'boardOffPanel')
                        app.setUiVisible(app.UI(fIdx).boardOffPanel, true);
                    end
                    % Policy B: board-off uses the summary plot area; keep the
                    % normal flight-play row collapsed to avoid hidden blank space.
                    app.collapseFlightPlayControlPanel(fIdx);
                    app.collapseFlightPlayControlPanel(sourceIdx);
                    app.reflowBoardColumns(sourceIdx);
                    app.refreshBoardOffSummaryPanel(fIdx, true);
                end

                % [Bug fix B1] Always reflow BOTH boards after any toggle so that
                % collapsed/expanded panel widths render correctly. drawnow forces an
                % immediate layout pass — without it the source board can keep stale
                % 0-width columns visible as blank space.
                app.reflowBoardColumns(fIdx);
                app.reflowBoardColumns(sourceIdx);
                % [L1 C-1] dynamic BodyGrid RowHeight change: use separate source/summary rows when off.
                app.applyBodyGridRowHeights();
                app.updateBoardToggleButtons();
                drawnow;
            catch ME
                app.logCaught(ME, 'boardToggle');
            end
        end

        function applyBodyGridRowHeights(app)
            % [L1 C-1/L4] 4-row bodyGrid including row splitter/off-summary.
            try
                if isempty(app.BodyGrid) || ~isvalid(app.BodyGrid), return; end
                activeOff = find(app.BoardOffState, 1);
                if isempty(activeOff)
                    app.setUiVisible(app.BodyRowSplitter, true);
                    topW = max(0.2, min(0.8, double(app.BodyRowSplitRatio)));
                    botW = 1 - topW;
                    app.BodyGrid.RowHeight = {sprintf('%dx', round(topW * 100)), ...
                        app.LAYOUT_SPLITTER_THICKNESS, sprintf('%dx', round(botW * 100)), 0};
                    return;
                end
                % v-fix1: show the splitter even during board-off - BoardOffSourceRatio drag-adjustable
                app.setUiVisible(app.BodyRowSplitter, true);
                srcW = max(0.5, min(1.0, double(app.BoardOffSourceRatio)));
                summaryW = max(0, 1 - srcW);
                srcStr = sprintf('%dx', max(1, round(srcW * 100)));
                if summaryW <= eps
                    summarySpec = 0;
                else
                    summarySpec = sprintf('%dx', max(1, round(summaryW * 100)));
                end
                thk = app.LAYOUT_SPLITTER_THICKNESS;
                if activeOff == 1
                    app.BodyGrid.RowHeight = {0, thk, srcStr, summarySpec};
                else
                    app.BodyGrid.RowHeight = {srcStr, thk, summarySpec, 0};
                end
            catch ME
                app.logCaught(ME, 'bodyGridRowHeights');
            end
        end

        function sourceIdx = getBoardOffSourceIdx(~, offIdx)
            sourceIdx = 3 - offIdx;
        end

        function row = getBodyGridRowForFlight(~, fIdx)
            row = 1;
            if fIdx == 2
                row = 3;
            end
        end

        function row = getBoardOffSummaryGridRow(~, fIdx)
            row = 4;
            if fIdx == 2
                row = 2;
            end
        end

        function startBodyRowSplitterDrag(app)
            try
                if app.IsDraggingMarker || app.IsDraggingSplitter || ...
                        app.IsDraggingRowSplitter || app.IsDraggingColumnSplitter
                    return;
                end
                app.IsDraggingRowSplitter = true;
                app.RowSplitterStartPoint = app.UIFigure.CurrentPoint;
                % v-fix1: use BoardOffSourceRatio as the drag target during board-off
                if any(app.BoardOffState)
                    app.RowSplitterStartRatio = app.BoardOffSourceRatio;
                else
                    app.RowSplitterStartRatio = app.BodyRowSplitRatio;
                end
                app.UIFigure.WindowButtonMotionFcn = @(~,~) app.bodyRowSplitterMotion();
                app.UIFigure.WindowButtonUpFcn = @(~,~) app.stopBodyRowSplitterDrag();
            catch ME
                app.logCaught(ME, 'rowSplitter:start');
            end
        end

        function bodyRowSplitterMotion(app)
            try
                if ~app.IsDraggingRowSplitter || isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                    return;
                end
                pt = app.UIFigure.CurrentPoint;
                figH = max(1, app.UIFigure.Position(4));
                dy = double(pt(2) - app.RowSplitterStartPoint(2));
                if any(app.BoardOffState)
                    % v-fix1: off state - drag-adjust source ratio (direction reversed if the upper board is off)
                    activeOff = find(app.BoardOffState, 1);
                    delta = dy / figH;
                    if activeOff == 1, delta = -delta; end
                    newRatio = max(0.5, min(1.0, app.RowSplitterStartRatio + delta));
                    app.BoardOffSourceRatio = newRatio;
                    app.applyBodyGridRowHeights();
                    drawnow limitrate;
                else
                    app.setBodyRowSplitRatio(app.RowSplitterStartRatio - dy / figH);
                end
            catch ME
                app.logCaught(ME, 'rowSplitter:motion');
            end
        end

        function stopBodyRowSplitterDrag(app)
            try
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                end
                app.IsDraggingRowSplitter = false;
            catch ME
                app.logCaught(ME, 'rowSplitter:stop');
            end
        end

        function setBodyRowSplitRatio(app, ratio)
            try
                app.CurrentLayoutPreset = 'custom';
                app.updateLayoutPresetButtons();
                app.BodyRowSplitRatio = max(0.2, min(0.8, double(ratio)));
                app.applyBodyGridRowHeights();
                drawnow limitrate;
            catch ME
                app.logCaught(ME, 'rowSplitter:setRatio');
            end
        end

        function updateColumnSplitterVisibility(app, fIdx, widths)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ~isfield(app.UI(fIdx), 'colSplitters')
                    return;
                end
                splitCols = [2, 4, 6];
                for sIdx = 1:min(numel(splitCols), numel(app.UI(fIdx).colSplitters))
                    sp = app.UI(fIdx).colSplitters(sIdx);
                    if isempty(sp) || ~isvalid(sp), continue; end
                    app.setUiVisible(sp, ~app.isTestWidthZero(widths{splitCols(sIdx)}));
                end
            catch ME
                app.logCaught(ME, 'columnSplitter:visibility');
            end
        end

        function startColumnSplitterDrag(app, fIdx, splitterIdx, ~)
            try
                try
                    if isprop(app.UIFigure, 'SelectionType') && strcmpi(char(app.UIFigure.SelectionType), 'open')
                        app.resetUserColumnWidths(fIdx);
                        app.reflowBoardColumns(fIdx);
                        app.refreshBoardOffSummaryPanel(fIdx, true);
                        return;
                    end
                catch
                end
                if app.IsDraggingMarker || app.IsDraggingSplitter || app.IsDraggingRowSplitter || app.IsDraggingColumnSplitter
                    return;
                end
                pairs = [1 3; 3 5; 5 7];
                if fIdx < 1 || fIdx > 2 || splitterIdx < 1 || splitterIdx > size(pairs, 1)
                    return;
                end
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg), return; end
                cw = dg.ColumnWidth;
                leftCol = pairs(splitterIdx, 1);
                rightCol = pairs(splitterIdx, 2);
                if numel(cw) < rightCol || app.isTestWidthZero(cw{leftCol}) || app.isTestWidthZero(cw{rightCol})
                    return;
                end
                app.CurrentLayoutPreset = 'custom';
                app.updateLayoutPresetButtons();
                app.IsDraggingColumnSplitter = true;
                app.DraggedColumnSplitterInfo = struct('fIdx', fIdx, 'leftCol', leftCol, 'rightCol', rightCol);
                app.ColumnSplitterStartPoint = app.UIFigure.CurrentPoint;
                app.ColumnSplitterStartWidths = cw;
                app.UIFigure.WindowButtonMotionFcn = @(~,~) app.columnSplitterMotion();
                app.UIFigure.WindowButtonUpFcn = @(~,~) app.stopColumnSplitterDrag();
                if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'left-right'; end
            catch ME
                app.logCaught(ME, 'columnSplitter:start');
            end
        end

        function columnSplitterMotion(app)
            try
                if ~app.IsDraggingColumnSplitter, return; end
                info = app.DraggedColumnSplitterInfo;
                fIdx = info.fIdx;
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg), return; end
                dx = double(app.UIFigure.CurrentPoint(1) - app.ColumnSplitterStartPoint(1));
                cw = app.ColumnSplitterStartWidths;
                leftCol = info.leftCol;
                rightCol = info.rightCol;
                leftW = app.widthSpecToPixels(cw{leftCol}, dg);
                rightW = app.widthSpecToPixels(cw{rightCol}, dg);
                minW = 80;
                newLeft = max(minW, leftW + dx);
                newRight = max(minW, rightW - dx);
                total = max(minW * 2, leftW + rightW);
                if newLeft + newRight > total
                    over = newLeft + newRight - total;
                    newLeft = max(minW, newLeft - over / 2);
                    newRight = max(minW, total - newLeft);
                end
                live = dg.ColumnWidth;
                % v4 P2: do not change plot/dataView columns to fixed pixels - always '1x'
                if leftCol == 7
                    live{leftCol} = '1x';
                else
                    live{leftCol} = round(newLeft);
                end
                if rightCol == 7
                    live{rightCol} = '1x';
                else
                    live{rightCol} = round(newRight);
                end
                dg.ColumnWidth = live;
                app.rememberUserColumnWidths(fIdx, live);
                app.refreshAfterColumnWidthChange(fIdx, false);
            catch ME
                app.logCaught(ME, 'columnSplitter:motion');
            end
        end

        function stopColumnSplitterDrag(app)
            try
                fIdx = 0;
                try
                    fIdx = app.DraggedColumnSplitterInfo.fIdx;
                catch
                end
                if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                    app.UIFigure.WindowButtonMotionFcn = '';
                    app.UIFigure.WindowButtonUpFcn = '';
                    if isprop(app.UIFigure, 'Pointer'), app.UIFigure.Pointer = 'arrow'; end
                end
                app.refreshAfterColumnWidthChange(fIdx, true);
                app.IsDraggingColumnSplitter = false;
                app.ColumnSplitterStartWidths = {};
            catch ME
                app.logCaught(ME, 'columnSplitter:stop');
            end
        end

        function simulateColumnSplitterDrag(app, fIdx, splitterIdx, dx)
            try
                pairs = [1 3; 3 5; 5 7];
                if fIdx < 1 || fIdx > 2 || splitterIdx < 1 || splitterIdx > size(pairs, 1)
                    return;
                end
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg), return; end
                cw = dg.ColumnWidth;
                leftCol = pairs(splitterIdx, 1);
                rightCol = pairs(splitterIdx, 2);
                if numel(cw) < rightCol || app.isTestWidthZero(cw{leftCol}) || app.isTestWidthZero(cw{rightCol})
                    return;
                end
                app.CurrentLayoutPreset = 'custom';
                app.updateLayoutPresetButtons();
                leftW = app.widthSpecToPixels(cw{leftCol}, dg);
                rightW = app.widthSpecToPixels(cw{rightCol}, dg);
                minW = 80;
                newLeft = max(minW, leftW + double(dx));
                newRight = max(minW, rightW - double(dx));
                total = max(minW * 2, leftW + rightW);
                if newLeft + newRight > total
                    newLeft = max(minW, min(total - minW, newLeft));
                    newRight = max(minW, total - newLeft);
                end
                % v4 P2: do not change plot/dataView columns to fixed pixels - always '1x'
                if leftCol == 7
                    cw{leftCol} = '1x';
                else
                    cw{leftCol} = round(newLeft);
                end
                if rightCol == 7
                    cw{rightCol} = '1x';
                else
                    cw{rightCol} = round(newRight);
                end
                dg.ColumnWidth = cw;
                app.rememberUserColumnWidths(fIdx, cw);
                app.updateColumnSplitterVisibility(fIdx, cw);
                app.refreshAfterColumnWidthChange(fIdx, true);
            catch ME
                app.logCaught(ME, 'columnSplitter:testDelta');
            end
        end

        function refreshAfterColumnWidthChange(app, fIdx, forceSummary)
            if nargin < 3, forceSummary = false; end
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || fIdx > numel(app.UI) || ...
                        ~isfield(app.UI(fIdx), 'dataGrid') || isempty(app.UI(fIdx).dataGrid) || ...
                        ~isvalid(app.UI(fIdx).dataGrid)
                    return;
                end
                widths = app.UI(fIdx).dataGrid.ColumnWidth;
                % v-fix2: in side-analysis(hsplit) mode col5=mapAlt - save the drag result as mapAltWidth
                isHsplitMode = isfield(app.UI(fIdx), 'arrangementMode') ...
                    && strcmp(app.UI(fIdx).arrangementMode, 'hsplit');
                if isHsplitMode
                    try
                        if numel(widths) >= 5 && isnumeric(widths{5}) && widths{5} > 0
                            s = app.UserColumnWidths{fIdx};
                            if ~isstruct(s), s = app.getEmptyUserColumnWidthsStruct(); end
                            s.mapAltWidth = max(120, double(widths{5}));
                            app.UserColumnWidths{fIdx} = s;
                        end
                    catch
                    end
                else
                    % v-final P3: normalize only in normal mode (hsplit column mapping differs)
                    if isfield(app.UI(fIdx), 'PanelVisible')
                        widths = app.normalizeColumnWidthsForVisiblePanels(app.UI(fIdx).PanelVisible, widths);
                        app.UI(fIdx).dataGrid.ColumnWidth = widths;
                    end
                end
                app.updateColumnSplitterVisibility(fIdx, widths);
                app.reflowAttitudePanel(fIdx);
                activeOff = find(app.BoardOffState, 1);
                if forceSummary && ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff)
                    app.refreshBoardOffSummaryPanel(activeOff, true);
                end
                drawnow limitrate;
            catch ME
                app.logCaught(ME, 'columnSplitter:postReflow');
            end
        end

        function rememberUserColumnWidths(app, fIdx, widths)
            % v4-R3: extract-save only adjustable fixed-width fields(att/mapAlt/info).
            % never save plot/splitter/hidden/legacy video columns.
            try
                if fIdx < 1 || fIdx > 2, return; end
                widths = app.normalizeDataGridColumnWidth(widths);
                if isempty(widths), return; end
                s = app.getEmptyUserColumnWidthsStruct();
                if numel(widths) >= 5
                    if isnumeric(widths{1}) && isscalar(widths{1}) && widths{1} > 0
                        s.attitudeWidth = max(80, double(widths{1}));   % v4 28.2 clamp
                    end
                    if isnumeric(widths{3}) && isscalar(widths{3}) && widths{3} > 0
                        s.mapAltWidth = max(120, double(widths{3}));
                    end
                    if isnumeric(widths{5}) && isscalar(widths{5}) && widths{5} > 0
                        s.infoWidth = max(100, double(widths{5}));
                    end
                end
                app.UserColumnWidths{fIdx} = s;
            catch ME
                app.logCaught(ME, 'columnWidth:remember');
            end
        end

        function s = getEmptyUserColumnWidthsStruct(~)
            s = struct('attitudeWidth', [], 'mapAltWidth', [], 'infoWidth', []);
        end

        function resetUserColumnWidths(app, fIdx)
            try
                if fIdx < 1 || fIdx > numel(app.UserColumnWidths), return; end
                app.UserColumnWidths{fIdx} = app.getEmptyUserColumnWidthsStruct();
            catch ME
                app.logCaught(ME, 'columnWidth:reset');
            end
        end

        function widths = getRememberedColumnWidths(app, fIdx)
            % v4-R3: struct -> 8-cell reconstruction. plot=`1x`, splitter=0 auto.
            widths = {};
            try
                if fIdx < 1 || fIdx > numel(app.UserColumnWidths), return; end
                s = app.UserColumnWidths{fIdx};
                % legacy upgrade: previous cell cache -> one-time struct conversion
                if iscell(s) && ~isempty(s)
                    legacy = app.normalizeDataGridColumnWidth(s);
                    migrated = app.getEmptyUserColumnWidthsStruct();
                    if numel(legacy) >= 5
                        if isnumeric(legacy{1}) && isscalar(legacy{1}) && legacy{1} > 0
                            migrated.attitudeWidth = max(80, double(legacy{1}));
                        end
                        if isnumeric(legacy{3}) && isscalar(legacy{3}) && legacy{3} > 0
                            migrated.mapAltWidth = max(120, double(legacy{3}));
                        end
                        if isnumeric(legacy{5}) && isscalar(legacy{5}) && legacy{5} > 0
                            migrated.infoWidth = max(100, double(legacy{5}));
                        end
                    end
                    s = migrated;
                    app.UserColumnWidths{fIdx} = s;
                end
                if ~isstruct(s), return; end
                aW = []; mW = []; iW = [];
                if isfield(s, 'attitudeWidth'), aW = s.attitudeWidth; end
                if isfield(s, 'mapAltWidth'), mW = s.mapAltWidth; end
                if isfield(s, 'infoWidth'), iW = s.infoWidth; end
                if isempty(aW) && isempty(mW) && isempty(iW), return; end
                pw = app.getResponsivePanelWidths();
                if isempty(aW), aW = pw(1); end
                if isempty(mW), mW = pw(2); end
                if isempty(iW), iW = pw(3); end
                widths = {aW, 0, mW, 0, iW, 0, '1x', 0};
            catch
                widths = {};
            end
        end

        function widths = getDefaultDataGridColumnWidths(app)
            panelWidths = app.getResponsivePanelWidths();
            widths = {panelWidths(1), 0, panelWidths(2), 0, panelWidths(3), 0, '1x', 0};
        end

        function px = widthSpecToPixels(~, spec, gridHandle)
            px = 120;
            try
                if isnumeric(spec)
                    px = max(0, double(spec(1)));
                elseif ischar(spec) || isstring(spec)
                    txt = strtrim(char(spec));
                    if endsWith(txt, 'x')
                        gp = getpixelposition(gridHandle, true);
                        px = max(80, gp(3) * 0.35);
                    else
                        v = str2double(txt);
                        if isfinite(v), px = max(0, v); end
                    end
                end
            catch
                px = 120;
            end
        end

        function captureBoardPanelState(app, fIdx)
            try
                if fIdx < 1 || fIdx > 2 || isempty(app.UI) || fIdx > numel(app.UI)
                    return;
                end
                snap = struct('PanelVisible', [], 'ColumnWidth', []);
                if isfield(app.UI(fIdx), 'PanelVisible')
                    snap.PanelVisible = app.normalizePanelVisibleState(app.UI(fIdx).PanelVisible);
                end
                if isfield(app.UI(fIdx), 'dataGrid') && ~isempty(app.UI(fIdx).dataGrid) ...
                        && isvalid(app.UI(fIdx).dataGrid)
                    snap.ColumnWidth = app.UI(fIdx).dataGrid.ColumnWidth;
                end
                app.BoardPanelVisibleSnapshot{fIdx} = snap;
            catch ME
                app.logCaught(ME, 'boardCapture');
            end
        end

        function snap = getBoardPanelSnapshot(app, fIdx)
            snap = struct('PanelVisible', [], 'ColumnWidth', []);
            try
                if fIdx >= 1 && fIdx <= numel(app.BoardPanelVisibleSnapshot) ...
                        && isstruct(app.BoardPanelVisibleSnapshot{fIdx})
                    snap = app.BoardPanelVisibleSnapshot{fIdx};
                end
            catch
            end
        end

        function restoreBoardPanelState(app, fIdx)
            try
                % Make sure the board panel itself is visible again (off-board case).
                app.setUiVisible(app.UI(fIdx).panel, true);
                snap = app.getBoardPanelSnapshot(fIdx);
                if ~isempty(snap.PanelVisible)
                    app.UI(fIdx).PanelVisible = app.normalizePanelVisibleState(snap.PanelVisible);
                end
                if ~isempty(snap.ColumnWidth)
                    snap.ColumnWidth = app.normalizeColumnWidthsForVisiblePanels(app.UI(fIdx).PanelVisible, snap.ColumnWidth);
                    app.rememberUserColumnWidths(fIdx, snap.ColumnWidth);
                    if isfield(app.UI(fIdx), 'dataGrid') && ~isempty(app.UI(fIdx).dataGrid) ...
                            && isvalid(app.UI(fIdx).dataGrid)
                        app.UI(fIdx).dataGrid.ColumnWidth = snap.ColumnWidth;
                    end
                end
                app.ensureBoardCorePanelsVisible(fIdx);
                app.reflowBoardColumns(fIdx);
            catch ME
                app.setUiVisible(app.UI(fIdx).panel, true);
                app.logCaught(ME, 'boardRestore');
            end
        end

        function ensureBoardCorePanelsVisible(app, fIdx)
            % [Bug fix B2] Force data view / current flight info to be visible. These have
            % no togglePanel button but can be zero-width inside the off-mode source board.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'PanelVisible'), return; end
                app.UI(fIdx).PanelVisible.info = true;
                app.UI(fIdx).PanelVisible.dataView = true;
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
                if numel(widths) >= 7
                    widths{4} = 0;  % map/info splitter
                    widths{5} = 0;  % current flight info
                    widths{6} = 0;  % info/plot splitter
                    widths{7} = 0;  % plot data panel
                    if isfield(app.UI(fIdx), 'PanelVisible')
                        st = app.UI(fIdx).PanelVisible;
                        mapOn = (isfield(st, 'mapOnly') && st.mapOnly) || ...
                                (isfield(st, 'altOnly') && st.altOnly) || ...
                                (~isfield(st, 'mapOnly') && isfield(st, 'map') && st.map);
                        if mapOn
                            widths{3} = '1x';
                        elseif isfield(st, 'attitude') && st.attitude
                            widths{1} = '1x';
                        end
                    end
                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                    app.updateColumnSplitterVisibility(fIdx, widths);
                elseif numel(widths) >= 4
                    widths{3} = 0;  % legacy current flight info
                    widths{4} = 0;  % legacy plot data panel
                    app.UI(fIdx).dataGrid.ColumnWidth = widths;
                    normWidths = app.normalizeDataGridColumnWidth(widths);
                    if ~isempty(normWidths)
                        app.updateColumnSplitterVisibility(fIdx, normWidths);
                    end
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
                % [L1 B-1] panelMapAlt visibility is the union mapOnly || altOnly.
                % recognize the legacy 'map' key for backward-compat too.
                hasMapOnly = isfield(st, 'mapOnly') && st.mapOnly;
                hasAltOnly = isfield(st, 'altOnly') && st.altOnly;
                if ~isfield(st, 'mapOnly') && isfield(st, 'map')
                    % when loading an old project, migrate the legacy 'map' key -> turn both on
                    hasMapOnly = st.map; hasAltOnly = st.map;
                end
                if isfield(app.UI(fIdx), 'panelMapAlt')
                    app.setUiVisible(app.UI(fIdx).panelMapAlt, hasMapOnly || hasAltOnly);
                end
                if isfield(app.UI(fIdx), 'panelMap') && ~isempty(app.UI(fIdx).panelMap) && isvalid(app.UI(fIdx).panelMap)
                    app.UI(fIdx).panelMap.Visible = hasMapOnly;
                end
                if isfield(app.UI(fIdx), 'panelAlt') && ~isempty(app.UI(fIdx).panelAlt) && isvalid(app.UI(fIdx).panelAlt)
                    app.UI(fIdx).panelAlt.Visible = hasAltOnly;
                end
                % v4-R2: removed video dialog auto-sync. dialog visibility changes only via user toggle.
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
                % v4-L1: board-off active source board -> always hsplit (upper info+plot / lower remaining)
                activeOff = find(app.BoardOffState, 1);
                if ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff)
                    app.applyBoardHsplit(fIdx);
                    return;
                end
                % if it was hsplit before, return to normal
                if isfield(app.UI(fIdx), 'arrangementMode') && strcmp(app.UI(fIdx).arrangementMode, 'hsplit')
                    if strcmp(app.CurrentLayoutPreset, 'layout-hsplit')
                        % user has the hsplit preset selected - keep hsplit even when both boards are visible
                        app.applyBoardHsplit(fIdx);
                        return;
                    end
                    app.applyBoardNormal(fIdx);
                end
                app.syncBoardPanelHandles(fIdx);
                panelWidths = app.getResponsivePanelWidths();
                widths = app.getRememberedColumnWidths(fIdx);
                if isempty(widths)
                    widths = app.getDefaultDataGridColumnWidths();
                end
                infoOn = true;
                dataViewOn = true;
                if isfield(app.UI(fIdx), 'PanelVisible')
                    st = app.normalizePanelVisibleState(app.UI(fIdx).PanelVisible);
                    app.UI(fIdx).PanelVisible = st;
                else
                    st = app.normalizePanelVisibleState(struct());
                end
                if isfield(app.UI(fIdx), 'PanelVisible')
                    if isfield(st, 'attitude') && ~st.attitude
                        widths{1} = 0;
                    elseif isfield(st, 'attitude') && st.attitude && app.isTestWidthZero(widths{1})
                        widths{1} = panelWidths(1);
                    end
                    % [L1 B-1] hide the column only when both mapOnly + altOnly are false
                    mapColOn = (isfield(st, 'mapOnly') && st.mapOnly) || ...
                               (isfield(st, 'altOnly') && st.altOnly) || ...
                               (~isfield(st, 'mapOnly') && isfield(st, 'map') && st.map);
                    if ~mapColOn
                        widths{3} = 0;
                    elseif app.isTestWidthZero(widths{3})
                        widths{3} = panelWidths(2);
                    end
                    if isfield(st, 'info')
                        infoOn = logical(st.info);
                    end
                    if isfield(st, 'dataView')
                        dataViewOn = logical(st.dataView);
                    end
                    if ~infoOn
                        widths{5} = 0;
                    elseif app.isTestWidthZero(widths{5})
                        widths{5} = panelWidths(3);
                    end
                    if ~dataViewOn
                        widths{7} = 0;
                    else
                        % v4 P2: always '1x' when plot/dataView visible (prevents fixed-pixel drift)
                        widths{7} = '1x';
                    end
                    widths{2} = 0; widths{4} = 0; widths{6} = 0;
                    if ~app.isTestWidthZero(widths{1}) && ~app.isTestWidthZero(widths{3}), widths{2} = app.LAYOUT_SPLITTER_THICKNESS; end
                    if ~app.isTestWidthZero(widths{3}) && ~app.isTestWidthZero(widths{5}), widths{4} = app.LAYOUT_SPLITTER_THICKNESS; end
                    if ~app.isTestWidthZero(widths{5}) && ~app.isTestWidthZero(widths{7}), widths{6} = app.LAYOUT_SPLITTER_THICKNESS; end
                    if ~infoOn && ~dataViewOn
                        attOn = isfield(st, 'attitude') && st.attitude;
                        if attOn && mapColOn
                            widths{1} = '1x';
                            widths{3} = '1x';
                        elseif attOn
                            widths{1} = '1x';
                        elseif mapColOn
                            widths{3} = '1x';
                        end
                    end
                end
                % v4-R1: removed board-off source override. the source shows its own PanelVisible as-is.
                % v4-R4: a single normalize helper guarantees final consistency (idempotent).
                widths = app.normalizeColumnWidthsForVisiblePanels(st, widths);
                app.UI(fIdx).dataGrid.ColumnWidth = widths;
                app.UI(fIdx).dataGrid.Scrollable = 'on';
                app.updateColumnSplitterVisibility(fIdx, widths);
                if isfield(app.UI(fIdx), 'hiSplitter') && ~isempty(app.UI(fIdx).hiSplitter) && isvalid(app.UI(fIdx).hiSplitter)
                    app.setUiVisible(app.UI(fIdx).hiSplitter, numel(widths) >= 8 && ~app.isTestWidthZero(widths{8}));
                end
                app.refreshPanelToggleButtons(fIdx);
                app.reflowAttitudePanel(fIdx);
                app.setVideoDisplaySize(fIdx);
            catch ME
                app.logCaught(ME, 'boardReflowColumns');
            end
        end

        function reflowAttitudePanel(app, fIdx)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ...
                        ~isfield(app.UI(fIdx), 'panelAttitudeGrid') || isempty(app.UI(fIdx).panelAttitudeGrid) || ...
                        ~isvalid(app.UI(fIdx).panelAttitudeGrid) || ...
                        ~isfield(app.UI(fIdx), 'PanelVisible') || ~app.UI(fIdx).PanelVisible.attitude
                    return;
                end
                grids = {app.UI(fIdx).pitchGaugeGrid, app.UI(fIdx).rollGaugeGrid, app.UI(fIdx).hdgGaugeGrid};
                if any(cellfun(@(h) isempty(h) || ~isvalid(h), grids))
                    return;
                end

                w = app.getAttitudePanelPixelWidth(fIdx);
                g = app.UI(fIdx).panelAttitudeGrid;
                if w >= 440
                    g.RowHeight = {'1x'};
                    g.ColumnWidth = {'1x', '1x', '1x'};
                    layoutRC = [1 1; 1 2; 1 3];
                    fontSz = 16;
                elseif w >= 220
                    g.RowHeight = {'1x', '1x'};
                    g.ColumnWidth = {'1x', '1x'};
                    layoutRC = [1 1; 1 2; 2 1];
                    fontSz = 14;
                else
                    g.RowHeight = {'1x', '1x', '1x'};
                    g.ColumnWidth = {'1x'};
                    layoutRC = [1 1; 2 1; 3 1];
                    fontSz = 12;
                end

                for k = 1:3
                    grids{k}.Layout.Row = layoutRC(k, 1);
                    grids{k}.Layout.Column = layoutRC(k, 2);
                end
                app.setAttitudeLabelFont(fIdx, fontSz);
            catch ME
                app.logCaught(ME, 'attitudeReflow');
            end
        end

        function w = getAttitudePanelPixelWidth(app, fIdx)
            w = 0;
            try
                if app.IsDraggingColumnSplitter && app.DraggedColumnSplitterInfo.fIdx == fIdx
                    widths = app.UI(fIdx).dataGrid.ColumnWidth;
                    if ~isempty(widths) && isnumeric(widths{1}) && isscalar(widths{1})
                        w = double(widths{1});
                        return;
                    end
                end
            catch
                w = 0;
            end
            try
                if isfield(app.UI(fIdx), 'panelAttitude') && ~isempty(app.UI(fIdx).panelAttitude) && ...
                        isvalid(app.UI(fIdx).panelAttitude)
                    w = double(app.UI(fIdx).panelAttitude.Position(3));
                end
            catch
                w = 0;
            end
            if w > 1
                return;
            end
            try
                widths = app.UI(fIdx).dataGrid.ColumnWidth;
                if ~isempty(widths)
                    v = widths{1};
                    if isnumeric(v) && isscalar(v)
                        w = double(v);
                    elseif ischar(v) || isstring(v)
                        w = max(440, app.getFigurePixelWidth() - sum(app.getResponsivePanelWidths()) - 40);
                    end
                end
            catch
                w = 160;
            end
            if w <= 1
                w = 160;
            end
        end

        function setAttitudeLabelFont(app, fIdx, fontSz)
            labels = {'pitchLabel', 'rollLabel', 'hdgLabel'};
            for i = 1:numel(labels)
                try
                    h = app.UI(fIdx).(labels{i});
                    if ~isempty(h) && isvalid(h)
                        h.FontSize = fontSz;
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'attitudeReflow:label');
                end
            end
            valueTexts = {'pitchValueText', 'rollValueText', 'hdgValueText'};
            valueFontSz = max(12, fontSz + 1);
            for i = 1:numel(valueTexts)
                try
                    if isfield(app.UI(fIdx), valueTexts{i})
                        h = app.UI(fIdx).(valueTexts{i});
                        if ~isempty(h) && isvalid(h)
                            h.FontSize = valueFontSz;
                        end
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'attitudeReflow:valueText');
                end
            end
        end

        function setAttitudeValueText(app, fIdx, pitch, roll, hdg)
            fields = {'pitchValueText', 'rollValueText', 'hdgValueText'};
            values = {sprintf('P %+.2f°', pitch), sprintf('R %+.2f°', roll), sprintf('H %+.2f°', hdg)};
            for i = 1:numel(fields)
                try
                    if isfield(app.UI(fIdx), fields{i})
                        h = app.UI(fIdx).(fields{i});
                        if ~isempty(h) && isvalid(h)
                            h.String = values{i};
                        end
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'attitudeValueText');
                end
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
                        btn.Enable = 'on';
                        app.styleToolbarButton(btn, '▦', labelsOn{k}, 'active');
                    else
                        if isempty(activeOff)
                            btn.Enable = 'on';
                            app.styleToolbarButton(btn, '▦', labelsOff{k}, 'normal');
                        else
                            btn.Enable = 'off';
                            app.styleToolbarButton(btn, '▦', labelsOff{k}, 'disabled');
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'boardButtons');
            end
        end

        function applyLayoutPreset(app, presetName)
            % v4: arrangement-only. PanelVisible / BoardOffState / BodyGrid.RowHeight /
            % do not change BodyRowSplitRatio / Video Player. adjust only the in-board column layout.
            try
                presetName = char(presetName);
                validNames = app.getLayoutPresetNames();
                if ~any(strcmp(presetName, validNames))
                    % Legacy preset names (single-top/data-focus/video-focus etc.) -> safe-map to reset
                    presetName = 'layout-reset';
                end
                app.CurrentLayoutPreset = presetName;

                if strcmp(presetName, 'layout-reset')
                    for k = 1:2
                        app.resetUserColumnWidths(k);
                        % v4-L1: keep hsplit if a board-off active board, else return to normal
                        if any(app.BoardOffState) && k == app.getBoardOffSourceIdx(find(app.BoardOffState, 1))
                            app.applyBoardHsplit(k);
                        else
                            app.applyBoardNormal(k);
                            app.reflowBoardColumns(k);
                        end
                        app.refreshBoardOffSummaryPanel(k, true);
                    end
                else
                    for k = 1:2
                        app.applyBoardInternalArrangement(k, presetName);
                        app.refreshBoardOffSummaryPanel(k, true);
                    end
                end
                app.updateBoardToggleButtons();
                app.updateLayoutPresetButtons();
                drawnow limitrate;
            catch ME
                app.logCaught(ME, 'layoutPreset');
            end
        end

        function applyBoardInternalArrangement(app, fIdx, presetName)
            % v4: adjust in-board layout. PanelVisible/BoardOff/BodyGrid.RowHeight unchanged.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                if ~isfield(app.UI(fIdx), 'dataGrid') || isempty(app.UI(fIdx).dataGrid) || ~isvalid(app.UI(fIdx).dataGrid)
                    return;
                end
                if ~isfield(app.UI(fIdx), 'PanelVisible'), return; end

                % v4-L1: board-off active source board is always hsplit (single-board analysis)
                activeOff = find(app.BoardOffState, 1);
                if ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff)
                    app.applyBoardHsplit(fIdx);
                    return;
                end
                if strcmp(presetName, 'layout-hsplit')
                    app.applyBoardHsplit(fIdx);  % v4-L1: a real 2-row even when both boards are visible
                    return;
                end
                % other presets are 1-row normal arrangement
                app.applyBoardNormal(fIdx);

                st = app.UI(fIdx).PanelVisible;
                pw = app.getResponsivePanelWidths();
                widths = {pw(1), 0, pw(2), 0, pw(3), 0, '1x', 0};
                switch presetName
                    case 'layout-grid'
                        % default balanced widths
                    case 'layout-vsplit'
                        figW = max(800, app.getFigurePixelWidth());
                        widths{5} = max(180, round(figW * 0.30));
                    case 'layout-compact'
                        widths{1} = max(120, round(pw(1) * 0.8));
                        widths{3} = max(140, round(pw(2) * 0.8));
                        widths{5} = max(140, round(pw(3) * 0.7));
                    case 'layout-reset'
                        % keep default
                end
                widths = app.normalizeColumnWidthsForVisiblePanels(st, widths);
                app.UI(fIdx).dataGrid.ColumnWidth = widths;
                app.UI(fIdx).dataGrid.Scrollable = 'on';
                app.rememberUserColumnWidths(fIdx, widths);
                app.updateColumnSplitterVisibility(fIdx, widths);
                app.refreshPanelToggleButtons(fIdx);
                app.reflowAttitudePanel(fIdx);
            catch ME
                app.logCaught(ME, 'boardArrangement');
            end
        end

        function applyBoardNormal(app, fIdx)
            % v4-L1: return dataGrid to the 1-row 8-col default mode.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg), return; end
                if isfield(app.UI(fIdx), 'arrangementMode') && strcmp(app.UI(fIdx).arrangementMode, 'normal')
                    return;  % idempotent
                end
                dg.RowHeight = {'1x'};
                % child panel Layout.Row=1 + restore original Column
                placements = {{'panelAttitude', 1}, {'panelMapAlt', 3}, {'panelInfo', 5}, {'panelDataView', 7}};
                for k = 1:numel(placements)
                    nm = placements{k}{1}; col = placements{k}{2};
                    app.setPanelLayoutCell(fIdx, nm, 1, col);
                end
                % v3-audit M: release the attitude col span on normal return
                if isfield(app.UI(fIdx), 'panelAttitude') && ~isempty(app.UI(fIdx).panelAttitude) ...
                        && isvalid(app.UI(fIdx).panelAttitude)
                    try
                        app.UI(fIdx).panelAttitude.Layout.Column = 1;
                    catch
                    end
                end
                % splitters (col 2/4/6) - restore Layout + visibility (recover what was hidden in hsplit mode)
                if isfield(app.UI(fIdx), 'colSplitters')
                    sp = app.UI(fIdx).colSplitters;
                    splitCols = [2, 4, 6];
                    for s = 1:min(numel(sp), 3)
                        if ~isempty(sp(s)) && isvalid(sp(s))
                            sp(s).Layout.Row = 1;
                            sp(s).Layout.Column = splitCols(s);
                            try
                                sp(s).Visible = 'on';
                            catch
                            end
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'hiSplitter') && ~isempty(app.UI(fIdx).hiSplitter) && isvalid(app.UI(fIdx).hiSplitter)
                    try
                        app.UI(fIdx).hiSplitter.Layout.Row = 1;
                    catch
                    end
                    try
                        app.UI(fIdx).hiSplitter.Visible = 'on';
                    catch
                    end
                end
                app.UI(fIdx).arrangementMode = 'normal';
                app.syncBoardPanelHandles(fIdx);
                widths = app.getRememberedColumnWidths(fIdx);
                if isempty(widths)
                    widths = app.getDefaultDataGridColumnWidths();
                end
                widths = app.normalizeColumnWidthsForVisiblePanels(app.UI(fIdx).PanelVisible, widths);
                dg.ColumnWidth = widths;
                dg.Scrollable = 'on';
                app.updateColumnSplitterVisibility(fIdx, widths);
                app.refreshPanelToggleButtons(fIdx);
            catch ME
                app.logCaught(ME, 'boardArrangement:normal');
            end
        end

        function applyBoardHsplit(app, fIdx)
            % v4-L1: switch dataGrid to 3-row (upper / splitter / lower) mode.
            %   Row 1: info(col 1) + plot(col 3)
            %   Row 2: splitter (LAYOUT_SPLITTER_THICKNESS)
            %   Row 3: attitude(col 1) + map/alt(col 3)
            % Columns 5/7 unused (width 0).
            % PanelVisible unchanged - hidden panels hidden via width 0.
            try
                if isempty(app.UI) || fIdx > numel(app.UI), return; end
                dg = app.UI(fIdx).dataGrid;
                if isempty(dg) || ~isvalid(dg), return; end
                if ~isfield(app.UI(fIdx), 'PanelVisible'), return; end
                st = app.UI(fIdx).PanelVisible;
                thk = app.LAYOUT_SPLITTER_THICKNESS;

                % v3-audit B: board-off active means single-board analysis - force info+plot visible
                activeOff = find(app.BoardOffState, 1);
                isBoardOffSource = ~isempty(activeOff) && fIdx == app.getBoardOffSourceIdx(activeOff);
                if isBoardOffSource
                    if isfield(st, 'info')
                        st.info = true;
                        app.UI(fIdx).PanelVisible.info = true;
                    end
                    if isfield(st, 'dataView')
                        st.dataView = true;
                        app.UI(fIdx).PanelVisible.dataView = true;
                    end
                end
                upperOn = (isfield(st,'info') && st.info) || (isfield(st,'dataView') && st.dataView);
                lowerOn = (isfield(st,'attitude') && st.attitude) || ...
                          (isfield(st,'mapOnly') && st.mapOnly) || ...
                          (isfield(st,'altOnly') && st.altOnly);
                if upperOn && lowerOn
                    dg.RowHeight = {'1x', thk, '1x'};
                elseif upperOn
                    dg.RowHeight = {'1x', 0, 0};
                elseif lowerOn
                    dg.RowHeight = {0, 0, '1x'};
                else
                    dg.RowHeight = {'1x'};
                    app.UI(fIdx).arrangementMode = 'hsplit';
                    return;
                end

                figW = max(800, app.getFigurePixelWidth());
                leftFixed = max(160, round(figW * 0.22));
                infoOn = isfield(st,'info') && st.info;
                dataViewOn = isfield(st,'dataView') && st.dataView;
                attitudeOn = isfield(st,'attitude') && st.attitude;
                mapColOn = (isfield(st,'mapOnly') && st.mapOnly) || (isfield(st,'altOnly') && st.altOnly);
                sideAnalysisMode = isBoardOffSource && ~attitudeOn && mapColOn && infoOn && dataViewOn;

                if sideAnalysisMode
                    % v-fix2: prefer user-adjusted width (UserColumnWidths.mapAltWidth), else default computation
                    mapW = max(220, round(figW * 0.24));
                    try
                        s = app.UserColumnWidths{fIdx};
                        if isstruct(s) && isfield(s, 'mapAltWidth') && ~isempty(s.mapAltWidth) ...
                                && isnumeric(s.mapAltWidth) && s.mapAltWidth > 0
                            mapW = max(120, double(s.mapAltWidth));
                        end
                    catch
                    end
                    dg.RowHeight = {'1x'};
                    dg.ColumnWidth = {leftFixed, thk, '1x', thk, mapW, 0, 0, 0};
                    dg.Scrollable = 'on';

                    app.setPanelLayoutCell(fIdx, 'panelInfo',     1, 1);
                    app.setPanelLayoutCell(fIdx, 'panelDataView', 1, 3);
                    app.setPanelLayoutCell(fIdx, 'panelMapAlt',   1, 5);
                    app.setPanelLayoutCell(fIdx, 'panelAttitude', 1, 1);
                    try
                        app.setUiVisible(app.UI(fIdx).panelInfo, true);
                    catch
                    end
                    try
                        app.setUiVisible(app.UI(fIdx).panelDataView, true);
                    catch
                    end
                    try
                        app.setUiVisible(app.UI(fIdx).panelMapAlt, true);
                    catch
                    end
                    try
                        app.setUiVisible(app.UI(fIdx).panelAttitude, false);
                    catch
                    end
                    try
                        app.setMapAltArrangement(fIdx, 'vertical');
                    catch
                    end

                    if isfield(app.UI(fIdx), 'colSplitters')
                        sp = app.UI(fIdx).colSplitters;
                        for s = 1:numel(sp)
                            if ~isempty(sp(s)) && isvalid(sp(s))
                                try
                                    sp(s).Visible = ternary(s <= 2, 'on', 'off');
                                catch
                                end
                            end
                        end
                    end
                    if isfield(app.UI(fIdx), 'hiSplitter') && ~isempty(app.UI(fIdx).hiSplitter) && isvalid(app.UI(fIdx).hiSplitter)
                        try
                            app.UI(fIdx).hiSplitter.Visible = 'off';
                        catch
                        end
                    end
                    app.UI(fIdx).arrangementMode = 'hsplit';
                    app.refreshPanelToggleButtons(fIdx);
                    app.reflowAttitudePanel(fIdx);
                    return;
                end

                % most cases have both areas visible - left fixed, right flex.
                % when only one area is visible, expand the left side via flex.
                widths = {leftFixed, thk, '1x', 0, 0, 0, 0, 0};
                upperLeftOn  = infoOn;
                upperRightOn = dataViewOn;
                lowerLeftOn  = attitudeOn;
                lowerRightOn = mapColOn;
                anyLeft  = upperLeftOn  || lowerLeftOn;
                anyRight = upperRightOn || lowerRightOn;
                if anyLeft && ~anyRight
                    widths = {'1x', 0, 0, 0, 0, 0, 0, 0};
                elseif anyRight && ~anyLeft
                    widths = {0, 0, '1x', 0, 0, 0, 0, 0};
                end
                % if plot/dataView is visible, Col 3 is always '1x' (already set that way).
                dg.ColumnWidth = widths;
                dg.Scrollable = 'on';

                % v2-C3: child panel layout - remove blank lower-left
                % Case C3-2/C3-3: attitudeOff + mapColOn -> panelMapAlt fills lower-left
                % Case C3-1: attitudeOff + mapColOn (both) -> normal horizontal Map/Alt
                % Case C3-5: attitudeOn + mapColOn -> default left/right split
                % Case M: attitudeOn + !mapColOn → attitude col [1 3] span
                app.setPanelLayoutCell(fIdx, 'panelInfo',     1, 1);
                app.setPanelLayoutCell(fIdx, 'panelDataView', 1, 3);
                if attitudeOn && ~mapColOn
                    % attitude alone lower - col [1 3] span (secures 1x3 horizontal reflow)
                    if isfield(app.UI(fIdx), 'panelAttitude') ...
                            && ~isempty(app.UI(fIdx).panelAttitude) && isvalid(app.UI(fIdx).panelAttitude)
                        try
                            app.UI(fIdx).panelAttitude.Layout.Row = 3;
                        catch
                        end
                        try
                            app.UI(fIdx).panelAttitude.Layout.Column = [1 3];
                        catch
                        end
                    end
                    app.setPanelLayoutCell(fIdx, 'panelMapAlt',   3, 3);
                elseif ~attitudeOn && mapColOn
                    % v2-C3-2/C3-3: attitude hidden - move panelMapAlt to lower-left to remove blank
                    if isfield(app.UI(fIdx), 'panelMapAlt') ...
                            && ~isempty(app.UI(fIdx).panelMapAlt) && isvalid(app.UI(fIdx).panelMapAlt)
                        try
                            app.UI(fIdx).panelMapAlt.Layout.Row = 3;
                        catch
                        end
                        try
                            app.UI(fIdx).panelMapAlt.Layout.Column = [1 3];
                        catch
                        end
                    end
                    app.setPanelLayoutCell(fIdx, 'panelAttitude', 3, 1);
                else
                    app.setPanelLayoutCell(fIdx, 'panelAttitude', 3, 1);
                    app.setPanelLayoutCell(fIdx, 'panelMapAlt',   3, 3);
                end

                % v3-fix: hsplit is a shared column model - panel width alone is insufficient for hidden handling.
                % explicitly sync each panel's Visible to PanelVisible state.
                try
                    app.setUiVisible(app.UI(fIdx).panelInfo, infoOn);
                catch
                end
                try
                    app.setUiVisible(app.UI(fIdx).panelDataView, dataViewOn);
                catch
                end
                try
                    app.setUiVisible(app.UI(fIdx).panelAttitude, attitudeOn);
                catch
                end
                try
                    app.setUiVisible(app.UI(fIdx).panelMapAlt, mapColOn);
                catch
                end

                % splitters: hide the external column splitter in hsplit mode
                if isfield(app.UI(fIdx), 'colSplitters')
                    sp = app.UI(fIdx).colSplitters;
                    for s = 1:numel(sp)
                        if ~isempty(sp(s)) && isvalid(sp(s))
                            try
                                sp(s).Visible = 'off';
                            catch
                            end
                        end
                    end
                end
                if isfield(app.UI(fIdx), 'hiSplitter') && ~isempty(app.UI(fIdx).hiSplitter) && isvalid(app.UI(fIdx).hiSplitter)
                    try
                        app.UI(fIdx).hiSplitter.Visible = 'off';
                    catch
                    end
                end

                app.UI(fIdx).arrangementMode = 'hsplit';
                app.refreshPanelToggleButtons(fIdx);
                app.reflowAttitudePanel(fIdx);
            catch ME
                app.logCaught(ME, 'boardArrangement:hsplit');
            end
        end

        function setPanelLayoutCell(app, fIdx, fieldName, rowIdx, colIdx)
            % v4-L1: reassign child panel Layout.Row/.Column. Visible is managed by the caller/syncBoardPanelHandles.
            try
                if ~isfield(app.UI(fIdx), fieldName), return; end
                h = app.UI(fIdx).(fieldName);
                if isempty(h) || ~isvalid(h), return; end
                try
                    h.Layout.Row = rowIdx;
                catch
                end
                try
                    h.Layout.Column = colIdx;
                catch
                end
            catch ME
                app.logCaught(ME, 'setPanelLayoutCell');
            end
        end

        function setBoardOffDirect(app, offIdx)
            % v4-R1/L1: summary dropped. hsplit on the active source board (upper info+plot / lower remaining).
            try
                app.BoardOffState = [false, false];
                for k = 1:min(2, numel(app.UI))
                    if isfield(app.UI(k), 'panel')
                        app.setUiVisible(app.UI(k).panel, true);
                    end
                    if isfield(app.UI(k), 'boardOffPanel') && ~isempty(app.UI(k).boardOffPanel) ...
                            && isvalid(app.UI(k).boardOffPanel)
                        app.setUiVisible(app.UI(k).boardOffPanel, false);
                    end
                    if isfield(app.UI(k), 'boardOffSignature')
                        app.UI(k).boardOffSignature = '';
                    end
                end
                if offIdx >= 1 && offIdx <= 2
                    app.BoardOffState(offIdx) = true;
                    app.hidePath3DDialogsForBoardOff(offIdx);
                    app.setUiVisible(app.UI(offIdx).panel, false);
                    sourceIdx = app.getBoardOffSourceIdx(offIdx);
                    if sourceIdx >= 1 && sourceIdx <= numel(app.UI)
                        app.applyBoardNormal(offIdx);   % the off board stays in normal mode (hidden anyway)
                        app.applyBoardHsplit(sourceIdx);  % v4-L1: active source board = upper/lower
                    end
                else
                    % board-on return: both boards in normal mode
                    for k = 1:min(2, numel(app.UI))
                        app.applyBoardNormal(k);
                    end
                    app.restorePath3DDialogsAfterBoardOn(0);
                end
            catch ME
                app.logCaught(ME, 'layoutPreset:boardOff');
            end
        end

        function clampVideoControlDialogSize(~, dlg)
            % v-fix5: correct the AVI control dialog min size (prevents UI clipping)
            try
                if isempty(dlg) || ~isvalid(dlg), return; end
                minW = 620; minH = 320;
                pos = dlg.Position;
                if pos(3) < minW || pos(4) < minH
                    dlg.Position = [pos(1), pos(2), max(pos(3), minW), max(pos(4), minH)];
                end
            catch
            end
        end

        function setBodyGridRowsDirect(app, rows)
            try
                if ~isempty(app.BodyGrid) && isvalid(app.BodyGrid)
                    app.BodyGrid.RowHeight = app.normalizeBodyRowHeight(rows);
                    if isempty(find(app.BoardOffState, 1))
                        app.setUiVisible(app.BodyRowSplitter, true);
                    end
                end
            catch ME
                app.logCaught(ME, 'layoutPreset:rows');
            end
        end

        function setFlightPanelVisiblePreset(app, fIdx, attitude, mapOnly, altOnly, video, info, dataView)
            try
                if isempty(app.UI) || fIdx > numel(app.UI) || ~isfield(app.UI(fIdx), 'PanelVisible')
                    return;
                end
                app.UI(fIdx).PanelVisible.attitude = logical(attitude);
                app.UI(fIdx).PanelVisible.mapOnly = logical(mapOnly);
                app.UI(fIdx).PanelVisible.altOnly = logical(altOnly);
                app.UI(fIdx).PanelVisible.video = logical(video);
                app.UI(fIdx).PanelVisible.info = logical(info);
                app.UI(fIdx).PanelVisible.dataView = logical(dataView);
            catch ME
                app.logCaught(ME, 'layoutPreset:panelVisible');
            end
        end

        function updateLayoutPresetButtons(app)
            try
                names = app.getLayoutPresetNames();
                icons = app.getLayoutPresetIcons();
                if ~isempty(app.LayoutPresetButtons)
                    t = app.getLightTheme();  % v4-Theme
                    for k = 1:min(numel(app.LayoutPresetButtons), numel(names))
                        btn = app.LayoutPresetButtons(k);
                        if isempty(btn) || ~isvalid(btn), continue; end
                        if strcmp(app.CurrentLayoutPreset, names{k})
                            btn.BackgroundColor = t.toolbarYellowBg;
                            btn.FontColor = t.toolbarYellowFg;
                        else
                            btn.BackgroundColor = t.toolbarGrayBg;
                            btn.FontColor = t.toolbarGrayFg;
                        end
                        btn.Text = icons{k};
                    end
                end
                app.refreshHeaderLayoutPresetDropdown();
            catch ME
                app.logCaught(ME, 'layoutPresetButtons');
            end
        end

        function names = getLayoutPresetNames(~)
            % v4: arrangement-only presets (removed V/focus-style)
            names = {'layout-grid', 'layout-vsplit', 'layout-hsplit', 'layout-compact', 'layout-reset'};
        end

        function icons = getLayoutPresetIcons(~)
            icons = {'⊞', '▥', '▤', '▦', '↺'};
        end

        function refreshBoardOffSummaryPanel(app, fIdx, forceRebuild)
            if nargin < 3, forceRebuild = false; end
            try
                if isempty(app.UI) || fIdx < 1 || fIdx > numel(app.UI), return; end
                if isfield(app.UI(fIdx), 'boardOffPanel') && ~isempty(app.UI(fIdx).boardOffPanel) ...
                        && isvalid(app.UI(fIdx).boardOffPanel)
                    if ~app.BoardOffState(fIdx) || app.BoardOffSourceRatio >= 1.0
                        app.setUiVisible(app.UI(fIdx).boardOffPanel, false);
                        return;
                    end
                    app.setUiVisible(app.UI(fIdx).boardOffPanel, true);
                else
                    return;
                end
                sourceIdx = app.getBoardOffSourceIdx(fIdx);
                if sourceIdx < 1 || sourceIdx > numel(app.UI), return; end
                if isfield(app.UI(fIdx), 'boardOffTable') && ~isempty(app.UI(fIdx).boardOffTable) ...
                        && isvalid(app.UI(fIdx).boardOffTable) ...
                        && isfield(app.UI(sourceIdx), 'dataTable') && ~isempty(app.UI(sourceIdx).dataTable) ...
                        && isvalid(app.UI(sourceIdx).dataTable)
                    app.UI(fIdx).boardOffTable.Data = app.UI(sourceIdx).dataTable.Data;
                end
                sig = app.getBoardOffPlotSignature(sourceIdx);
                if forceRebuild || ~isfield(app.UI(fIdx), 'boardOffSignature') ...
                        || ~strcmp(char(app.UI(fIdx).boardOffSignature), sig)
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
                    app.disableAxesInteractionsBeforeDelete(tg, 'boardOff:clear-tabs-axes');
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
                    currIdx = app.clampedCurrentIndex(sourceIdx);
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
                    newTab = uitab(tg, 'Title', tabTitle, 'BackgroundColor', [1 1 1]);
                    app.UI(fIdx).boardOffPlotTabs(end+1) = newTab;
                    plotLayout = uigridlayout(newTab, 'ColumnWidth', {'1x'}, 'RowHeight', {}, ...
                        'Padding', [5 5 5 5], 'RowSpacing', 5, 'Scrollable', 'on', ...
                        'BackgroundColor', [1 1 1]);
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
                currIdx = app.clampedCurrentIndex(sourceIdx);
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
                if sourceIdx >= 1 && sourceIdx <= numel(app.LastInfoTableSelectionValid)
                    app.LastInfoTableSelectionValid(sourceIdx) = true;
                end
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
            % v-style: light bg → dark title, dark/blue bg → white title.
            try
                t = app.getLightTheme();
                panels = findall(root, 'Type', 'uipanel');
            catch
                panels = []; t = struct();
            end
            for k = 1:numel(panels)
                p = panels(k);
                try
                    if isempty(p) || ~isvalid(p) || ~isprop(p, 'Title') ...
                            || isempty(char(p.Title)) || ~isprop(p, 'ForegroundColor')
                        continue;
                    end
                    if isprop(p, 'BackgroundColor')
                        bg = p.BackgroundColor;
                        bgIsLight = false;
                        if isnumeric(bg) && numel(bg) == 3
                            bgIsLight = mean(double(bg)) >= 0.70;
                        elseif ischar(bg) || isstring(bg)
                            bgIsLight = any(strcmpi(char(bg), {'w', 'white'}));
                        end
                        if bgIsLight
                            p.ForegroundColor = t.textPrimary;
                        else
                            p.ForegroundColor = t.panelBlueFg;
                        end
                    end
                catch ME
                    app.logCaught(ME, 'enforceReadablePanelTitles');
                end
            end
        end

        function t = getLightTheme(~)
            % v3-style: light/calm palette based on sample.png. saturated blue is accent-only.
            t = struct();
            t.windowBg       = [0.94 0.96 0.98];
            t.appShellBg     = [0.94 0.96 0.98];
            t.surfaceBg      = [1.00 1.00 1.00];
            t.surfaceAltBg   = [0.97 0.98 1.00];
            t.headerBg       = [0.93 0.95 0.97];   % sample style: ribbon surface, not dark chrome
            t.dividerColor   = [0.78 0.83 0.88];
            t.borderColor    = [0.62 0.72 0.82];
            t.gridLine       = [0.74 0.84 0.92];
            t.textPrimary    = [0.03 0.05 0.07];
            t.textSecondary  = [0.10 0.18 0.25];
            t.textMuted      = [0.35 0.42 0.48];
            t.textInverse    = [0.03 0.05 0.07];
            t.accentBlue     = [0.00 0.45 0.74];
            t.accentBlueLite = [0.82 0.93 1.00];
            t.accentBlueText = [0.00 0.18 0.32];
            t.accentGreen    = [0.00 0.58 0.22];
            t.warningRed     = [0.86 0.32 0.18];
            t.successGreen   = [0.00 0.48 0.20];
            t.disabledBg     = [0.82 0.85 0.88];
            t.disabledFg     = [0.32 0.36 0.40];
            t.tableHeaderBg  = [0.88 0.94 0.99];
            t.tableRowBgA    = [1.00 1.00 1.00];
            t.tableRowBgB    = [0.94 0.97 1.00];
            t.axesBg         = [0.99 1.00 1.00];
            t.plotPanelBg    = [1.00 1.00 1.00];
            t.plotAxesBg     = [0.99 1.00 1.00];
            t.tabBg          = [1.00 1.00 1.00];
            t.tabFg          = [0.03 0.05 0.07];
            t.gaugePitchBg   = [0.74 0.88 1.00];
            t.gaugeRollBg    = [1.00 0.86 0.82];
            t.gaugeHeadingBg = [0.82 0.94 0.84];
            t.gaugeTickFg    = [0.03 0.05 0.07];
            t.gaugeNeedleFg  = [0.95 0.67 0.10];
            t.videoPlaceholderBg = [0.94 0.96 0.98];
            t.videoAxesBg        = [0 0 0];   % v-sync: keep the video axes black (requirement #2)
            t.panelBg            = [1.00 1.00 1.00];
            t.panelAltBg         = [0.97 0.98 1.00];
            t.panelTitleBg       = [0.86 0.92 0.97];
            t.panelTitleFg       = [0.05 0.12 0.20];
            t.tabActiveBg        = [1.00 1.00 1.00];
            t.tabActiveFg        = [0.05 0.12 0.20];
            t.tabInactiveBg      = [0.88 0.92 0.96];
            t.tabInactiveFg      = [0.18 0.24 0.30];
            t.buttonBg           = [0.93 0.95 0.97];
            t.buttonFg           = [0.05 0.10 0.18];
            t.buttonActiveBg     = [0.82 0.89 0.96];
            t.buttonActiveFg     = [0.00 0.18 0.32];
            t.buttonDisabledBg   = [0.86 0.88 0.90];
            t.buttonDisabledFg   = [0.45 0.50 0.55];
            t.fieldBg            = [1.00 1.00 1.00];
            t.fieldFg            = [0.05 0.10 0.18];
            t.tableHeaderFg      = [0.05 0.12 0.20];
            t.mapAxesBg          = [1.00 1.00 1.00];
            t.altAxesBg          = [1.00 1.00 1.00];
            t.gaugePanelBg       = [1.00 1.00 1.00];
            t.gaugeAxesBg        = [1.00 1.00 1.00];
            t.gaugeTextFg        = [0.05 0.10 0.18];
            t.videoPanelBg       = [0 0 0];   % v-sync: keep the video container black
            t.dialogBg           = [0.95 0.97 0.99];
            t.dialogHeaderBg     = [0.86 0.92 0.97];
            t.dialogTabBg        = [0.88 0.92 0.96];
            t.dialogTabSelectedBg= [1.00 1.00 1.00];
            t.treeBg             = [1.00 1.00 1.00];
            t.treeFg             = [0.05 0.10 0.18];
            t.plotTitleFg        = [0.05 0.10 0.18];
            t.plotLabelFg        = [0.18 0.24 0.30];
            t.plotTickFg         = [0.30 0.36 0.42];
            t.plotGridColor      = [0.78 0.84 0.92];
            t.fontFamily     = 'Segoe UI';
            t.fontFamilyMono = 'Consolas';
            t.fontSizeSmall  = 11;
            t.fontSizeBase   = 12;
            t.fontSizeLarge  = 14;
            % v3-sample: button bg = panel bg (harmonized). distinguish function via fg color only.
            t.btnActiveBg    = [0.86 0.92 0.97];   % selection highlight is a light blue tint
            t.btnActiveFg    = [0.00 0.18 0.32];
            t.btnAccentBg    = [1.00 1.00 1.00];
            t.btnAccentFg    = [0.78 0.55 0.05];   % accent yellow text
            t.btnNormalBg    = [1.00 1.00 1.00];   % same as panel(white)
            t.btnNormalFg    = [0.05 0.10 0.18];
            t.btnDisabledBg  = [0.94 0.95 0.96];
            t.btnDisabledFg  = [0.55 0.60 0.65];
            t.btnWarningBg   = [1.00 1.00 1.00];
            t.btnWarningFg   = [0.78 0.16 0.12];   % warning red text on white
            % v3-sample: panel header -> light blue strip (sample-consistent)
            t.panelBlueBg    = [0.95 0.97 0.99];
            t.panelBlueBg2   = [0.93 0.96 0.98];
            t.panelBlueFg    = [0.05 0.12 0.20];
            % v3-sample: all toolbar bg = panel(white). distinguish function via fg color only.
            t.toolbarYellowBg = [1.00 1.00 1.00];
            t.toolbarYellowFg = [0.78 0.55 0.05];   % deep yellow (file/import)
            t.toolbarGreenBg  = [1.00 1.00 1.00];
            t.toolbarGreenFg  = [0.00 0.50 0.20];   % deep green (sync/apply)
            t.toolbarBlueBg   = [1.00 1.00 1.00];
            t.toolbarBlueFg   = [0.00 0.32 0.62];   % deep blue (board/action)
            t.toolbarGrayBg   = [1.00 1.00 1.00];
            t.toolbarGrayFg   = [0.18 0.24 0.30];   % dark gray (default)
            t.toolbarDarkBg   = [1.00 1.00 1.00];
            t.toolbarDarkFg   = [0.30 0.16 0.50];   % deep purple (settings/edit)
            % extra accent text color (fg over panel only)
            t.accentOrangeFg = [0.85 0.42 0.10];
            t.accentRedFg    = [0.78 0.16 0.12];
            t.accentPurpleFg = [0.45 0.18 0.62];
        end

        function tf = isNearBlackColor(~, c)
            tf = false;
            try
                if isnumeric(c) && numel(c) == 3
                    tf = mean(double(c)) < 0.20 && max(double(c)) < 0.30;
                end
            catch
            end
        end

        function tf = isBlueThemeColor(app, c, t)
            tf = false;
            if nargin < 3 || isempty(t), t = app.getLightTheme(); end
            try
                if isnumeric(c) && numel(c) == 3
                    refs = [t.headerBg; t.panelBlueBg; t.panelBlueBg2; t.toolbarBlueBg; t.toolbarDarkBg];
                    for k = 1:size(refs, 1)
                        if all(abs(double(c) - refs(k, :)) < 0.05), tf = true; return; end
                    end
                end
            catch
            end
        end

        function tf = isVideoAxes(app, ax)
            tf = false;
            try
                if isempty(ax) || ~isvalid(ax), return; end
                if isprop(ax, 'Tag') && ~isempty(char(ax.Tag)) && contains(lower(char(ax.Tag)), 'video')
                    tf = true; return;
                end
                if ~isempty(app.UI)
                    for k = 1:numel(app.UI)
                        if isfield(app.UI(k), 'vidAxes') && ~isempty(app.UI(k).vidAxes) ...
                                && isvalid(app.UI(k).vidAxes) && app.UI(k).vidAxes == ax
                            tf = true; return;
                        end
                    end
                end
            catch
            end
        end

        function safeSetFontColor(~, h, color)
            try
                if isempty(h) || ~isvalid(h), return; end
                if isprop(h, 'FontColor'), h.FontColor = color; end
            catch
            end
        end

        function safeSetBackground(~, h, color)
            try
                if isempty(h) || ~isvalid(h), return; end
                if isprop(h, 'BackgroundColor'), h.BackgroundColor = color; end
            catch
            end
        end

        function applyLightTheme(app, root)
            % v4-L2: role-based light theme. dispatcher.
            try
                if nargin < 2 || isempty(root) || ~isvalid(root)
                    root = app.UIFigure;
                end
                if isempty(root) || ~isvalid(root), return; end
                t = app.getLightTheme();
                try
                    if isprop(root, 'Color'), root.Color = t.windowBg; end
                    if isprop(root, 'BackgroundColor'), root.BackgroundColor = t.windowBg; end
                catch
                end
                app.applyThemeToPanels(root, t);
                app.applyThemeToButtons(root, t);
                app.applyThemeToLabels(root, t);
                app.applyThemeToTables(root, t);
                app.applyThemeToAxes(root, t);
                app.applyThemeToInputs(root, t);
                app.applyThemeToTabs(root, t);
                app.applyThemeToTrees(root, t);
                app.applyLightPanelTitleContrast(root);
            catch ME
                app.logCaught(ME, 'applyLightTheme');
            end
        end

        function applyThemeToPanels(app, root, t)
            % v2-style: preserve blue intent + normalize near-black non-video to surfaceAltBg.
            try
                panels = findall(root, 'Type', 'uipanel');
                for k = 1:numel(panels)
                    p = panels(k);
                    if isempty(p) || ~isvalid(p), continue; end
                    try
                        if isprop(p, 'BorderColor') && isprop(p, 'BorderType') && ~strcmp(char(p.BorderType), 'none')
                            p.BorderColor = t.borderColor;
                        end
                        if isprop(p, 'BackgroundColor')
                            bg = p.BackgroundColor;
                            if app.isBlueThemeColor(bg, t)
                                % sample style: pale blue panels still use dark text.
                                if isprop(p, 'ForegroundColor'), p.ForegroundColor = t.textPrimary; end
                            elseif app.isNearBlackColor(bg)
                                % near-black non-video -> light-normalize to surfaceAltBg
                                p.BackgroundColor = t.surfaceAltBg;
                                if isprop(p, 'ForegroundColor'), p.ForegroundColor = t.textPrimary; end
                            else
                                % light bg: correct white text -> dark
                                if isprop(p, 'ForegroundColor')
                                    fg = p.ForegroundColor;
                                    if isnumeric(fg) && numel(fg)==3 && mean(double(fg))>=0.85 ...
                                            && isnumeric(bg) && numel(bg)==3 && mean(double(bg))>=0.85
                                        p.ForegroundColor = t.textPrimary;
                                    end
                                end
                            end
                        end
                    catch
                    end
                end
                grids = findall(root, 'Type', 'uigridlayout');
                for k = 1:numel(grids)
                    g = grids(k);
                    if isempty(g) || ~isvalid(g), continue; end
                    try
                        if isprop(g, 'BackgroundColor')
                            bg = g.BackgroundColor;
                            if app.isNearBlackColor(bg) && ~app.isBlueThemeColor(bg, t)
                                g.BackgroundColor = t.surfaceAltBg;
                            end
                        end
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:panels');
            end
        end

        function applyThemeToButtons(app, root, t)
            % v-sync: skip role-colored buttons when Tag='FDD:RoleButton' or role palette matches.
            try
                btns = findall(root, 'Type', 'uibutton');
                rolePalette = [t.toolbarYellowBg; t.toolbarGreenBg; t.toolbarBlueBg; ...
                               t.toolbarDarkBg; t.toolbarGrayBg; t.btnWarningBg];
                for k = 1:numel(btns)
                    b = btns(k);
                    if isempty(b) || ~isvalid(b), continue; end
                    try
                        % v-sync: Tag-based whitelist
                        if isprop(b, 'Tag') && strcmp(string(b.Tag), "FDD:RoleButton")
                            continue;
                        end
                        if isprop(b, 'BackgroundColor')
                            bg = b.BackgroundColor;
                            isRoleBg = false;
                            if isnumeric(bg) && numel(bg) == 3
                                for ri = 1:size(rolePalette, 1)
                                    if all(abs(double(bg) - rolePalette(ri, :)) < 0.02)
                                        isRoleBg = true; break;
                                    end
                                end
                            end
                            if ~isRoleBg && isnumeric(bg) && numel(bg) == 3 && all(double(bg) < 0.55)
                                b.BackgroundColor = t.btnNormalBg;
                            end
                        end
                        if isprop(b, 'FontName'), b.FontName = t.fontFamily; end   % v-sync
                        if isprop(b, 'FontColor')
                            fc = b.FontColor;
                            if isnumeric(fc) && numel(fc) == 3 && all(double(fc) >= 0.95)
                                parentBg = [];
                                try
                                    parentBg = b.BackgroundColor;
                                catch
                                end
                                if isnumeric(parentBg) && numel(parentBg) == 3 && all(double(parentBg) >= 0.80)
                                    b.FontColor = t.btnNormalFg;
                                end
                            end
                        end
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:buttons');
            end
        end

        function applyThemeToLabels(app, root, t)
            % v4-L2: uilabel - normalize only white text over a light bg to dark.
            try
                labels = findall(root, 'Type', 'uilabel');
                for k = 1:numel(labels)
                    lb = labels(k);
                    if isempty(lb) || ~isvalid(lb), continue; end
                    try
                        if isprop(lb, 'FontColor')
                            fc = lb.FontColor;
                            if isnumeric(fc) && numel(fc) == 3 && all(double(fc) >= 0.95)
                                parentBg = [];
                                try
                                    parentBg = lb.Parent.BackgroundColor;
                                catch
                                end
                                if isnumeric(parentBg) && numel(parentBg) == 3 && all(double(parentBg) >= 0.85)
                                    lb.FontColor = t.textPrimary;
                                end
                            end
                        end
                        if isprop(lb, 'FontName'), lb.FontName = t.fontFamily; end   % v-sync
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:labels');
            end
        end

        function applyThemeToTables(app, root, t)
            % v-final P11: role-based - force white bg + dark text on dashboard-owned uitable.
            % replace all high-saturation (mean<0.85) bg with white. flight identity uses a separate accent strip.
            try
                tbls = findall(root, 'Type', 'uitable');
                for k = 1:numel(tbls)
                    tb = tbls(k);
                    if isempty(tb) || ~isvalid(tb), continue; end
                    try
                        if isprop(tb, 'BackgroundColor')
                            bg = tb.BackgroundColor;
                            if isnumeric(bg) && size(bg, 2) == 3 && mean(bg(1, :)) < 0.85
                                tb.BackgroundColor = t.tableRowBgA;
                            end
                        end
                        if isprop(tb, 'ForegroundColor')
                            fg = tb.ForegroundColor;
                            if isnumeric(fg) && numel(fg) == 3 && mean(double(fg)) >= 0.80
                                tb.ForegroundColor = t.textPrimary;
                            end
                        end
                        if isprop(tb, 'FontName'), tb.FontName = t.fontFamilyMono; end   % v-sync
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:tables');
            end
        end

        function applyThemeToAxes(app, root, t)
            % v2-style: always force non-video axes light + consistent tick/grid/font.
            try
                axesAll = findall(root, 'Type', 'axes');
                for k = 1:numel(axesAll)
                    ax = axesAll(k);
                    if isempty(ax) || ~isvalid(ax), continue; end
                    if app.isVideoAxes(ax), continue; end
                    try
                        if isprop(ax, 'Color'), ax.Color = t.plotAxesBg; end
                        if isprop(ax, 'XColor'), ax.XColor = t.textSecondary; end
                        if isprop(ax, 'YColor'), ax.YColor = t.textSecondary; end
                        if isprop(ax, 'GridColor'), ax.GridColor = t.gridLine; end
                        if isprop(ax, 'FontSize') && ax.FontSize < 11, ax.FontSize = 11; end
                        if isprop(ax, 'FontName'), ax.FontName = t.fontFamily; end   % v-sync
                        try
                            if ~isempty(ax.Title)
                                ax.Title.Color = t.textPrimary;
                                if ax.Title.FontSize < 12
                                    ax.Title.FontSize = 12;
                                end
                            end
                            if ~isempty(ax.XLabel)
                                ax.XLabel.Color = t.textPrimary;
                                if ax.XLabel.FontSize < 12
                                    ax.XLabel.FontSize = 12;
                                end
                            end
                            if ~isempty(ax.YLabel)
                                ax.YLabel.Color = t.textPrimary;
                                if ax.YLabel.FontSize < 12
                                    ax.YLabel.FontSize = 12;
                                end
                            end
                        catch
                        end
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:axes');
            end
        end

        function applyThemeToInputs(app, root, t)
            % v4-L2: uidropdown / uieditfield / uispinner / uitextarea / uicheckbox light bg.
            try
                inputTypes = {'uidropdown', 'uieditfield', 'uinumericeditfield', 'uispinner', 'uitextarea', 'uicheckbox'};
                for ti = 1:numel(inputTypes)
                    try
                        ctrls = findall(root, 'Type', inputTypes{ti});
                    catch
                        ctrls = [];
                    end
                    for k = 1:numel(ctrls)
                        c = ctrls(k);
                        if isempty(c) || ~isvalid(c), continue; end
                        try
                            if isprop(c, 'BackgroundColor')
                                bg = c.BackgroundColor;
                                if isnumeric(bg) && numel(bg) == 3 && all(double(bg) < 0.55)
                                    c.BackgroundColor = t.surfaceBg;
                                end
                            end
                            if isprop(c, 'FontColor')
                                fc = c.FontColor;
                                if isnumeric(fc) && numel(fc) == 3 && all(double(fc) >= 0.95)
                                    c.FontColor = t.textPrimary;
                                end
                            end
                            if isprop(c, 'FontName'), c.FontName = t.fontFamily; end   % v-sync
                        catch
                        end
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:inputs');
            end
        end

        function applyThemeToTabs(app, root, t)
            % v4-L2: uitabgroup/uitab - light-normalize the background.
            try
                tgs = findall(root, 'Type', 'uitabgroup');
                for k = 1:numel(tgs)
                    tg = tgs(k);
                    if isempty(tg) || ~isvalid(tg), continue; end
                    % uitabgroup itself has no BackgroundColor. process only the tabs.
                    try
                        tabs = tg.Children;
                        for s = 1:numel(tabs)
                            tb = tabs(s);
                            if isempty(tb) || ~isvalid(tb), continue; end
                            try
                                if isprop(tb, 'BackgroundColor')
                                    bg = tb.BackgroundColor;
                                    if isnumeric(bg) && numel(bg) == 3 && all(double(bg) < 0.55)
                                        tb.BackgroundColor = t.surfaceBg;
                                    end
                                end
                                if isprop(tb, 'ForegroundColor')
                                    fg = tb.ForegroundColor;
                                    if isnumeric(fg) && numel(fg) == 3 && all(double(fg) >= 0.95)
                                        tb.ForegroundColor = t.textPrimary;
                                    end
                                end
                            catch
                            end
                        end
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'theme:tabs');
            end
        end

        function applyThemeToTrees(app, root, t) %#ok<INUSL>
            % v3-B7: uitree light bg + readable text.
            try
                trees = findall(root, 'Type', 'uitree');
            catch
                trees = [];
            end
            for k = 1:numel(trees)
                tr = trees(k);
                if isempty(tr) || ~isvalid(tr), continue; end
                try
                    if isprop(tr, 'BackgroundColor'), tr.BackgroundColor = t.treeBg; end
                catch
                end
                try
                    if isprop(tr, 'FontColor'), tr.FontColor = t.treeFg; end
                catch
                end
            end
        end

        function offUi = createBoardOffSummaryPanel(app, parentGrid, fIdx)
            themeT = app.getLightTheme();   % v-style
            pnl = uipanel(parentGrid, 'Title', sprintf('Flight Data %d - Board Off Summary', fIdx), ...
                'FontWeight', 'bold', 'FontSize', 14, ...
                'BackgroundColor', themeT.panelBlueBg, 'ForegroundColor', themeT.panelBlueFg, ...
                'Visible', 'off');
            pnl.Layout.Row = app.getBoardOffSummaryGridRow(fIdx);
            pnl.Layout.Column = 1;

            root = uigridlayout(pnl, [1 2]);
            root.BackgroundColor = themeT.panelBlueBg;
            root.ColumnWidth = {300, '1x'};
            root.RowHeight = {'1x'};
            root.Padding = [4 4 4 4];
            root.ColumnSpacing = 6;

            infoPanel = uipanel(root, 'Title', '현재 비행 정보', ...
                'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', themeT.textPrimary, 'Scrollable', 'on');
            infoPanel.Layout.Column = 1;
            infoGrid = uigridlayout(infoPanel, [1 1], 'Padding', [0 0 0 0]);
            tbl = uitable(infoGrid, 'BackgroundColor', [1.00 1.00 1.00; 0.96 0.98 1.00], 'ForegroundColor', [0 0 0], ...
                'FontWeight', 'bold', 'RowStriping', 'on', 'ColumnName', {'항목', '값'}, ...
                'RowName', [], 'ColumnWidth', {'26x', '24x'}, 'FontSize', 12, 'FontName', 'Consolas');
            cm = uicontextmenu(app.UIFigure);
            uimenu(cm, 'Text', 'H 영역에 Plot 추가 (현재 행)', ...
                'MenuSelectedFcn', @(~,~) app.boardOffPlotSelectedVariable(fIdx));
            uimenu(cm, 'Text', '동기시간 찾기...', ...
                'MenuSelectedFcn', @(~,~) app.searchFlightDataValue(app.getBoardOffSourceIdx(fIdx)));
            tbl.ContextMenu = cm;
            tbl.CellSelectionCallback = @(~, event) app.boardOffTableSelection(fIdx, event);

            plotPanel = uipanel(root, 'Title', 'plot 데이터', ...
                'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', themeT.textPrimary);
            plotPanel.Layout.Column = 2;
            plotGrid = uigridlayout(plotPanel, [2 1], 'Padding', [2 2 2 2]);
            plotGrid.RowHeight = {28, '1x'};
            plotGrid.RowSpacing = 4;
            btnRow = uigridlayout(plotGrid, [1 3], 'Padding', [2 2 2 2], 'ColumnSpacing', 4, 'BackgroundColor', [0.94 0.96 0.98]);
            btnRow.Layout.Row = 1;
            btnRow.ColumnWidth = {110, 120, '1x'};
            uibutton(btnRow, 'Text', '+ 빈 탭 추가', ...
                'BackgroundColor', themeT.toolbarGreenBg, 'FontColor', themeT.toolbarGreenFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.boardOffAddPlotTab(fIdx));
            uibutton(btnRow, 'Text', '현재 탭 지우기', ...
                'BackgroundColor', themeT.toolbarYellowBg, 'FontColor', themeT.toolbarYellowFg, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) app.boardOffClearCurrentTab(fIdx));
            uilabel(btnRow, 'Text', '');  % spacer

            tg = uitabgroup(plotGrid);
            tg.Layout.Row = 2;
            tg.SelectionChangedFcn = @(~,~) app.syncBoardOffSelectedTab(fIdx);
            blankTab = uitab(tg, 'Title', 'Tab 1', 'BackgroundColor', [1 1 1]);
            blankGrid = uigridlayout(blankTab, [1 1], 'Padding', [8 8 8 8]);
            uilabel(blankGrid, 'Text', '표시할 plot 없음', ...
                'HorizontalAlignment', 'center', 'FontColor', themeT.textSecondary, 'FontWeight', 'bold');

            % [R-10] Off-summary panels are late-created, so apply title contrast here.
            app.applyLightPanelTitleContrast(pnl);
            offUi = struct('panel', pnl, 'table', tbl, 'tabGroup', tg);
        end

        function createLayout(app)
            % [V3.22 #7] main layout skeleton + header delegated to buildHeaderBar
            % per-flight-path build keeps the existing in-place code (risk management)
            mainLayout = uigridlayout(app.UIFigure, [2 1]);
            mainLayout.RowHeight = {66, '1x'};
            mainLayout.Padding = [2 2 2 2];
            mainLayout.RowSpacing = 2;

            % --- Header bar ---
            app.buildHeaderBar(mainLayout);

            % --- Body (2 flight-paths vertical stack) ---
            tT = app.getLightTheme();   % v-style
            scrollBody = uipanel(mainLayout, 'Scrollable', 'on', 'BorderType', 'none', 'BackgroundColor', tT.windowBg);
            bodyGrid = uigridlayout(scrollBody, [4 1]);
            bodyGrid.BackgroundColor = tT.windowBg;
            bodyGrid.ColumnWidth = {'1x'};
            bodyGrid.RowHeight = {'1x', app.LAYOUT_SPLITTER_THICKNESS, '1x', 0};
            bodyGrid.Padding = [2 2 2 2];
            bodyGrid.RowSpacing = 2;
            app.BodyGrid = bodyGrid;   % [L1 C-1] retain for runtime RowHeight reflow
            app.BodyRowSplitter = uipanel(bodyGrid, 'BackgroundColor', tT.borderColor, ...
                'BorderType', 'none');
            app.BodyRowSplitter.Layout.Row = 2;
            app.BodyRowSplitter.Layout.Column = 1;
            app.BodyRowSplitter.ButtonDownFcn = @(~,~) app.startBodyRowSplitterDrag();

            titleStrs = {'Flight Data 1', 'Flight Data 2'};
            panelColors = {tT.panelBlueBg, tT.panelBlueBg2};   % v-style: blue panel
            panelWidths = app.getResponsivePanelWidths();

            UI_temp = struct('panel', {}, 'dataTable', {}, 'spinner', {}, 'currentTimeLabel', {}, 'fileNameLabel', {}, ...
                        'mapAxes', {}, 'altAxes', {}, 'pitchAxes', {}, 'rollAxes', {}, 'hdgAxes', {}, ...
                        'pitchLabel', {}, 'rollLabel', {}, 'hdgLabel', {}, ...
                        'pitchValueText', {}, 'rollValueText', {}, 'hdgValueText', {}, ...
                        'hMapPath', {}, 'hgMapPlane', {}, 'hAltPath', {}, 'hAltMarker', {}, 'timeLine', {}, ...
                        'hgPitch', {}, 'hgRoll', {}, 'hgHdg', {}, ...
                        'tabGroup', {}, 'plotTabs', {}, 'plotLayouts', {}, 'plotAxes', {}, ...
                        'timeLines', {}, 'timeMarkers', {}, 'plotData', {}, 'xLimListeners', {}, 'altXLimListener', {}, 'vidAxes', {}, 'vidImageHandle', {}, ...
                        'dataGrid', {}, 'panelAttitude', {}, 'panelAttitudeGrid', {}, ...
                        'pitchGaugeGrid', {}, 'rollGaugeGrid', {}, 'hdgGaugeGrid', {}, ...
                        'panelMapAlt', {}, 'panelInfo', {}, 'panelDataView', {}, 'panelVideo', {}, 'colSplitters', {}, ...
                        'arrangementMode', {}, 'ctrlGrid', {}, 'ctrlRowPanel', {}, 'ctrlFGrid', {}, ...
                        'btnAtt', {}, 'btnMap', {}, 'btnAlt', {}, 'btnPath3D', {}, 'btnInfo', {}, 'btnDataView', {}, 'btnVid', {}, 'PanelVisible', {}, ...
                        'btnFlightPlayControl', {}, 'flightPlayHostGrid', {}, 'flightPlayControlPanel', {}, 'flightPlayGrid', {}, ...
                        'flightPlayStatusLabel', {}, 'flightPlaySlider', {}, 'flightPlayFrameInput', {}, 'flightPlayTimeInput', {}, ...
                        'flightPlayBtnBack20', {}, 'flightPlayBtnBack10', {}, 'flightPlayBtnPrev', {}, 'flightPlayBtnNext', {}, ...
                        'flightPlayBtnFwd10', {}, 'flightPlayBtnFwd20', {}, 'flightPlayBtnPlayPause', {}, ...
                        'vidViewerDialog', {}, 'vidContainer', {}, 'vidResolutionDropdown', {}, 'vidControlBtn', {}, 'vidControlDialog', {}, ...
                        'vidSyncFrameInput', {}, 'vidSyncTimeInput', {}, 'vidSyncBtn', {}, 'vidSyncStatus', {}, ...
                        'vidVideoFpsInput', {}, 'vidDataFpsInput', {}, ...
                        'vidFrameAxes', {}, 'vidFrameXLine', {}, 'vidFrameMarker', {}, ...
                        'path3DDialog', {}, 'path3DAxes', {}, 'path3DFullTrajectory', {}, 'path3DPastTrajectory', {}, ...
                        'path3DWayPoints', {}, 'path3DDroneTransform', {}, 'path3DDronePatch', {}, 'path3DBodyAxes', {}, ...
                        'path3DSidebar', {}, 'path3DAxisLimitsCtrl', {}, ...
                        'vidCacheBudget', {}, 'vidVdubSlider', {}, 'vidVdubLabel', {}, ...
                        'boardOffPanel', {}, 'boardOffTable', {}, 'boardOffTabGroup', {}, ...
                        'boardOffPlotTabs', {}, 'boardOffPlotLayouts', {}, 'boardOffPlotAxes', {}, ...
                        'boardOffTimeLines', {}, 'boardOffTimeMarkers', {}, 'boardOffPlotData', {}, ...
                        'boardOffSignature', {});

            for fIdx = 1:2
                % [V3.22 #7] flight-path fIdx build - section guide (top->bottom build order):
                %   (a) main panel + control bar
                %   (b) Col 1: flight attitude (3 gauges)
                %   (c) Col 2: map + altitude (vertical split)
                %   (d) Col 3: data table (info panel)
                %   (e) Col 4: plot area(H) - tabGroup
                %   (f) Col 5: H<->I splitter (draggable)
                %   (g) Col 6: video + Frame Navigator

                % --- (a) main panel + control bar ---
                UI_temp(fIdx).panel = uipanel(bodyGrid, 'Title', titleStrs{fIdx}, 'FontWeight', 'bold', 'FontSize', 14, ...
                    'BackgroundColor', panelColors{fIdx}, 'ForegroundColor', tT.panelBlueFg);
                UI_temp(fIdx).panel.Layout.Row = app.getBodyGridRowForFlight(fIdx);
                UI_temp(fIdx).panel.Layout.Column = 1;
                fGrid = uigridlayout(UI_temp(fIdx).panel, [2 1]);
                fGrid.BackgroundColor = panelColors{fIdx};
                fGrid.ColumnWidth = {'1x'};
                fGrid.RowHeight = {45, '1x'};
                fGrid.Padding = [2 2 2 2];
                fGrid.RowSpacing = 2;

                controlPanel = uipanel(fGrid, 'BackgroundColor', tT.headerBg, 'ForegroundColor', tT.textInverse, 'BorderType', 'line');
                % [L1 B-1/L2] independent map/altitude/info/plot/video toggles.
                % v2-B: removed the visible info/plot buttons in the header; 3D Path adds one control button.
                glCtrl = uigridlayout(controlPanel, [1 10]);
                glCtrl.BackgroundColor = tT.headerBg;
                glCtrl.ColumnWidth = {100, 150, 110, 120, '1x', 70, 70, 70, 80, 70};
                glCtrl.RowHeight = {'1x'};
                glCtrl.Padding = [2 2 2 2];
                UI_temp(fIdx).ctrlGrid = glCtrl;            % v-fix7: for responsive 2-row switching
                UI_temp(fIdx).ctrlRowPanel = controlPanel;
                UI_temp(fIdx).ctrlFGrid = fGrid;

                uilabel(glCtrl, 'Text', '입력 시간(s):', 'FontWeight', 'bold', 'FontSize', 12, 'FontColor', tT.panelTitleFg);
                UI_temp(fIdx).spinner = uispinner(glCtrl, 'Enable', 'off', 'FontSize', 13, 'ValueDisplayFormat', '%.3f', ...
                                             'BackgroundColor', [1 1 1], 'FontColor', tT.textPrimary, ...
                                             'ValueChangedFcn', @(~, event) app.handleSpinnerChange(fIdx, event.Value));
                uilabel(glCtrl, 'Text', '실시간 현재값:', 'FontWeight', 'bold', 'FontSize', 12, 'FontColor', tT.panelTitleFg);
                UI_temp(fIdx).currentTimeLabel = uilabel(glCtrl, 'Text', '0.000 s', 'FontWeight', 'bold', 'FontSize', 13, 'FontColor', tT.warningRed);
                UI_temp(fIdx).fileNameLabel = uilabel(glCtrl, 'Text', '파일 없음', 'FontColor', tT.textSecondary, 'FontSize', 11, 'FontWeight', 'bold');

                % v-style: panel toggle button role colors (Att=blue, Map=green, Alt=blue, Info=yellow, Plot=purple, Vid=dark)
                UI_temp(fIdx).btnAtt = uibutton(glCtrl, 'Text', '자세 ▸', 'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarBlueBg, 'FontColor', tT.toolbarBlueFg, ...
                    'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'attitude'));
                UI_temp(fIdx).btnAtt.Layout.Column = 6;
                UI_temp(fIdx).btnMap = uibutton(glCtrl, 'Text', '지도 ▸', 'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarGreenBg, 'FontColor', tT.toolbarGreenFg, ...
                    'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'mapOnly'));
                UI_temp(fIdx).btnMap.Layout.Column = 7;
                UI_temp(fIdx).btnAlt = uibutton(glCtrl, 'Text', '고도 ▸', 'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarBlueBg, 'FontColor', tT.toolbarBlueFg, ...
                    'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'altOnly'));
                UI_temp(fIdx).btnAlt.Layout.Column = 8;
                UI_temp(fIdx).btnPath3D = uibutton(glCtrl, 'Text', '3D 경로 ▸', 'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarGreenBg, 'FontColor', tT.toolbarGreenFg, ...
                    'ButtonPushedFcn', @(~,~) app.btnPath3DPushed(fIdx));
                UI_temp(fIdx).btnPath3D.Layout.Column = 9;
                % v2-B: removed btnInfo/btnDataView (PanelVisible.info/dataView kept true internally)
                UI_temp(fIdx).btnInfo = gobjects(0);
                UI_temp(fIdx).btnDataView = gobjects(0);
                UI_temp(fIdx).btnVid = uibutton(glCtrl, 'Text', '비디오 ▸', 'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarDarkBg, 'FontColor', tT.toolbarDarkFg, ...
                    'ButtonPushedFcn', @(~,~) app.togglePanel(fIdx, 'video'));
                UI_temp(fIdx).btnVid.Layout.Column = 10;
                UI_temp(fIdx).PanelVisible = struct( ...
                    'attitude', false, 'mapOnly', false, 'altOnly', false, 'video', false, ...
                    'info', true, 'dataView', true);

                % [Layout dataGrid columns]
                % 1 attitude | 2 splitter | 3 map/alt | 4 splitter |
                % 5 info table | 6 splitter | 7 plot data | 8 reserved legacy H/I
                UI_temp(fIdx).dataGrid = uigridlayout(fGrid, [1 8]);
                UI_temp(fIdx).dataGrid.BackgroundColor = panelColors{fIdx};   % v-style
                UI_temp(fIdx).dataGrid.ColumnWidth = {0, 0, 0, 0, panelWidths(3), 4, '1x', 0};
                UI_temp(fIdx).dataGrid.RowHeight = {'1x'};
                UI_temp(fIdx).dataGrid.Padding = [0 0 0 0];
                UI_temp(fIdx).dataGrid.ColumnSpacing = 3;   % splitter visibility
                UI_temp(fIdx).dataGrid.Scrollable = 'on';

                UI_temp(fIdx).colSplitters = gobjects(1, 3);
                splitCols = [2, 4, 6];
                for sIdx = 1:numel(splitCols)
                    sp = uipanel(UI_temp(fIdx).dataGrid, 'BackgroundColor', tT.borderColor, 'BorderType', 'none');
                    sp.Layout.Column = splitCols(sIdx);
                    sp.ButtonDownFcn = @(~,event) app.startColumnSplitterDrag(fIdx, sIdx, event);
                    UI_temp(fIdx).colSplitters(sIdx) = sp;
                end

                % --- (b) Col 1: flight attitude (Pitch / Roll / Heading gauges) ---
                UI_temp(fIdx).panelAttitude = uipanel(UI_temp(fIdx).dataGrid, 'Title', '비행 자세', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary);
                UI_temp(fIdx).panelAttitude.Layout.Column = 1;
                UI_temp(fIdx).panelAttitude.Visible = 'off';
                gGrid = uigridlayout(UI_temp(fIdx).panelAttitude, [3 1]);
                gGrid.RowHeight = {'1x', '1x', '1x'};
                gGrid.Padding = [2 2 2 2];
                gGrid.RowSpacing = 2;
                UI_temp(fIdx).panelAttitudeGrid = gGrid;

                [UI_temp(fIdx).pitchAxes, UI_temp(fIdx).pitchLabel, UI_temp(fIdx).pitchGaugeGrid] = app.createGaugePanel(gGrid, 'Pitch');
                [UI_temp(fIdx).rollAxes, UI_temp(fIdx).rollLabel, UI_temp(fIdx).rollGaugeGrid]   = app.createGaugePanel(gGrid, 'Roll');
                [UI_temp(fIdx).hdgAxes, UI_temp(fIdx).hdgLabel, UI_temp(fIdx).hdgGaugeGrid]     = app.createGaugePanel(gGrid, 'Heading');

                % --- (c) Col 2: Map (top) + Altitude (bottom) ---
                UI_temp(fIdx).panelMapAlt = uipanel(UI_temp(fIdx).dataGrid, 'BorderType', 'none', 'BackgroundColor', panelColors{fIdx});
                UI_temp(fIdx).panelMapAlt.Layout.Column = 3;
                UI_temp(fIdx).panelMapAlt.Visible = 'off';
                pGrid = uigridlayout(UI_temp(fIdx).panelMapAlt, [2 1]);
                pGrid.RowHeight = {'1.5x', '1x'};
                pGrid.Padding = [0 0 0 0];
                UI_temp(fIdx).panelMapAltGrid = pGrid;   % [L1 B-1] for dynamic sub-row change

                mapPnl = uipanel(pGrid, 'Title', 'Map', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary);
                mapGrid = uigridlayout(mapPnl, [1 1], 'Padding', [5 5 5 5]);
                UI_temp(fIdx).mapAxes = uiaxes(mapGrid);
                hold(UI_temp(fIdx).mapAxes, 'on');
                xlabel(UI_temp(fIdx).mapAxes, 'Lon', 'FontWeight', 'bold', 'FontSize', 10);
                ylabel(UI_temp(fIdx).mapAxes, 'Lat', 'FontWeight', 'bold', 'FontSize', 10);
                set(UI_temp(fIdx).mapAxes, 'XGrid', 'on', 'YGrid', 'on', 'XMinorGrid', 'on', 'YMinorGrid', 'on', 'XMinorTick', 'on', 'YMinorTick', 'on', 'TickDir', 'out');

                % [V3.10] Map axes hide the toolbar (use wheel-zoom/drag-pan only)
                disableDefaultInteractivity(UI_temp(fIdx).mapAxes);
                UI_temp(fIdx).mapAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).mapAxes.Interactions = [panInteraction, zoomInteraction];

                altPnl = uipanel(pGrid, 'Title', 'Altitude', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary);
                UI_temp(fIdx).panelMap = mapPnl;          % [L1 B-1] handle for independent toggle
                UI_temp(fIdx).panelAlt = altPnl;
                altGrid = uigridlayout(altPnl, [1 1], 'Padding', [5 5 5 5]);
                UI_temp(fIdx).altAxes = uiaxes(altGrid);
                hold(UI_temp(fIdx).altAxes, 'on');
                xlabel(UI_temp(fIdx).altAxes, 'Time(s)', 'FontWeight', 'bold', 'FontSize', 11);
                ylabel(UI_temp(fIdx).altAxes, 'Alt', 'FontWeight', 'bold', 'FontSize', 10);
                xtickformat(UI_temp(fIdx).altAxes, '%.0f');
                set(UI_temp(fIdx).altAxes, 'XGrid', 'on', 'YGrid', 'on', 'XMinorGrid', 'on', 'YMinorGrid', 'on', 'XMinorTick', 'on', 'YMinorTick', 'on', 'TickDir', 'out');

                % [V3.10] Altitude axes hide the toolbar (use wheel-zoom/drag-pan only)
                disableDefaultInteractivity(UI_temp(fIdx).altAxes);
                UI_temp(fIdx).altAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).altAxes.Interactions = [panInteraction, zoomInteraction];

                % --- (d) Col 3: current flight info (data table) ---
                infoPanel = uipanel(UI_temp(fIdx).dataGrid, 'Title', '현재 비행 정보', 'FontSize', 13, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary, 'Scrollable', 'on');
                infoPanel.Layout.Column = 5;
                UI_temp(fIdx).panelInfo = infoPanel;        % [v4-L1] handle for hsplit reparent
                glInfo = uigridlayout(infoPanel, [1 1], 'Padding', [0 0 0 0]);
                UI_temp(fIdx).dataTable = uitable(glInfo, 'BackgroundColor', [1.00 1.00 1.00; 0.96 0.98 1.00], 'ForegroundColor', [0 0 0], 'FontWeight', 'bold', ...
                                             'RowStriping', 'on', 'ColumnName', {'항목', '값'}, 'RowName', [], ...
                                             'ColumnWidth', {'29x', '20x'}, 'FontSize', 12, 'FontName', 'Consolas');
                cm = uicontextmenu(app.UIFigure);
                uimenu(cm, 'Text', 'H 영역에 Plot 추가 (현재 탭)', 'MenuSelectedFcn', @(~,~) app.plotSelectedVariable(fIdx));
                uimenu(cm, 'Text', '동기시간 찾기...', 'MenuSelectedFcn', @(~,~) app.searchFlightDataValue(fIdx));
                UI_temp(fIdx).dataTable.ContextMenu = cm;
                UI_temp(fIdx).dataTable.CellSelectionCallback = @(~, event) app.handleTableSelection(fIdx, event);

                % --- (e) Col 4: H panel (plot tabGroup) ---
                hPnl = uipanel(UI_temp(fIdx).dataGrid, 'Title', 'plot 데이터', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary);
                hPnl.Layout.Column = 7;
                UI_temp(fIdx).panelDataView = hPnl;         % [v4-L1] handle for hsplit reparent
                hGrid2 = uigridlayout(hPnl, [3 1]);
                hGrid2.RowHeight = {30, 0, '1x'};
                hGrid2.Padding = [2 2 2 2];
                UI_temp(fIdx).flightPlayHostGrid = hGrid2;

                btnPnl = uipanel(hGrid2, 'BorderType', 'none', 'BackgroundColor', [0.94 0.96 0.98]);
                btnGrid = uigridlayout(btnPnl, [1 4]);
                btnGrid.RowHeight = {'1x'};
                btnGrid.ColumnWidth = {100, 115, 100, '1x'};
                btnGrid.Padding = [4 4 4 4];
                btnGrid.ColumnSpacing = 5;
                uibutton(btnGrid, 'Text', '+ 빈 탭 추가', ...
                    'BackgroundColor', tT.toolbarGreenBg, 'FontColor', tT.toolbarGreenFg, 'FontWeight', 'bold', ...
                    'ButtonPushedFcn', @(~,~) app.addPlotTab(fIdx));
                uibutton(btnGrid, 'Text', '현재 탭 지우기', ...
                    'BackgroundColor', tT.toolbarYellowBg, 'FontColor', tT.toolbarYellowFg, 'FontWeight', 'bold', ...
                    'ButtonPushedFcn', @(~,~) app.clearCurrentTab(fIdx));
                UI_temp(fIdx).btnFlightPlayControl = uibutton(btnGrid, 'Text', '재생 제어', ...
                    'BackgroundColor', tT.toolbarBlueBg, 'FontColor', tT.toolbarBlueFg, 'FontWeight', 'bold', ...
                    'ButtonPushedFcn', @(~,~) app.toggleFlightPlayControlPanel(fIdx));
                uilabel(btnGrid, 'Text', '');

                playUi = app.createFlightPlayControlPanel(hGrid2, fIdx, tT);
                playUi.panel.Layout.Row = 2;
                UI_temp(fIdx).flightPlayControlPanel = playUi.panel;
                UI_temp(fIdx).flightPlayGrid = playUi.grid;
                UI_temp(fIdx).flightPlayStatusLabel = playUi.statusLabel;
                UI_temp(fIdx).flightPlaySlider = playUi.slider;
                UI_temp(fIdx).flightPlayFrameInput = playUi.frameInput;
                UI_temp(fIdx).flightPlayTimeInput = playUi.timeInput;
                UI_temp(fIdx).flightPlayBtnBack20 = playUi.btnBack20;
                UI_temp(fIdx).flightPlayBtnBack10 = playUi.btnBack10;
                UI_temp(fIdx).flightPlayBtnPrev = playUi.btnPrev;
                UI_temp(fIdx).flightPlayBtnNext = playUi.btnNext;
                UI_temp(fIdx).flightPlayBtnFwd10 = playUi.btnFwd10;
                UI_temp(fIdx).flightPlayBtnFwd20 = playUi.btnFwd20;
                UI_temp(fIdx).flightPlayBtnPlayPause = playUi.btnPlayPause;

                UI_temp(fIdx).tabGroup = uitabgroup(hGrid2);
                UI_temp(fIdx).tabGroup.Layout.Row = 3;
                UI_temp(fIdx).tabGroup.SelectionChangedFcn = @(~,~) app.updateTabTimeLines(fIdx);
                UI_temp(fIdx).plotTabs = [];
                UI_temp(fIdx).plotLayouts = {};

                UI_temp(fIdx).plotAxes = cell(1, app.MAX_TABS);
                UI_temp(fIdx).timeLines = cell(1, app.MAX_TABS);
                UI_temp(fIdx).timeMarkers = cell(1, app.MAX_TABS);
                UI_temp(fIdx).plotData = cell(1, app.MAX_TABS);
                UI_temp(fIdx).xLimListeners = cell(1, app.MAX_TABS);

                % --- (f)(g) Col 5: H<->I splitter, Col 6: Video panel [V3.15 6-row layout + VirtualDub group cohesion] ---
                %   Row 1 (32px) : AVI open button + sync status label
                %   Row 2 (32px) : Frame No input <-> Time input + sync button (simplified)
                %   Row 3 (1x)   : video display area
                %   Row 4 (~120px) : Frame Navigator group panel (label+slider+button+star axes)
                %   Row 5 (32px) : Video Hz / Data Hz input + Cache dropdown
                % [PATCH UX-3] H<->I boundary splitter (Col 5)
                UI_temp(fIdx).hiSplitter = uipanel(UI_temp(fIdx).dataGrid, ...
                    'BackgroundColor', tT.borderColor, 'BorderType', 'line', ...
                    'BorderColor', tT.dividerColor, ...
                    'Tooltip', '드래그하여 비디오 패널 너비 조절 (H ↔ I)', ...
                    'HitTest', 'on');
                UI_temp(fIdx).hiSplitter.Layout.Column = 8;
                UI_temp(fIdx).hiSplitter.ButtonDownFcn = @(~,~) app.startHISplitterDrag(fIdx);

                UI_temp(fIdx).vidViewerDialog = uifigure('Name', sprintf('Video Player - Flight Data %d', fIdx), ...
                    'Visible', 'off', 'Position', [120, 120, 780, 620], ...
                    'Color', tT.windowBg, ...
                    'CloseRequestFcn', @(~,~) app.setVideoViewerVisible(fIdx, false, true));
                try
                    if isprop(UI_temp(fIdx).vidViewerDialog, 'AutoResizeChildren')
                        UI_temp(fIdx).vidViewerDialog.AutoResizeChildren = 'off';
                    end
                catch ME_silent
                    app.logCaught(ME_silent, 'videoViewer:auto-resize');
                end
                viewerRoot = uigridlayout(UI_temp(fIdx).vidViewerDialog, [1 1], ...
                    'Padding', [2 2 2 2], 'RowHeight', {'1x'}, 'ColumnWidth', {'1x'});
                UI_temp(fIdx).panelVideo = uipanel(viewerRoot, 'Title', 'Video Player', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], 'ForegroundColor', tT.textPrimary);
                UI_temp(fIdx).panelVideo.Layout.Row = 1;
                UI_temp(fIdx).panelVideo.Layout.Column = 1;
                % video display priority: control functions split into a separate dialog
                iGrid2 = uigridlayout(UI_temp(fIdx).panelVideo, [2 1]);
                iGrid2.RowHeight = {34, '1x'};
                iGrid2.Padding = [0 0 0 0];
                iGrid2.RowSpacing = 2;

                % Row 1: AVI open + display resolution + control-window button + sync status
                vBtnPnl = uipanel(iGrid2, 'BorderType', 'none', 'BackgroundColor', [0.94 0.96 0.98]);
                vBtnPnl.Layout.Row = 1;
                glVB = uigridlayout(vBtnPnl, [1 5], ...
                    'ColumnWidth', {110, 42, 95, 80, '1x'}, ...
                    'Padding', [3 3 3 3], 'ColumnSpacing', 5);
                uibutton(glVB, 'Text', 'AVI 파일 열기', 'FontSize', 11, 'ButtonPushedFcn', @(~,~) app.loadAviFile(fIdx));
                uilabel(glVB, 'Text', '크기:', 'FontSize', 11, 'FontWeight', 'bold');
                UI_temp(fIdx).vidResolutionDropdown = uidropdown(glVB, ...
                    'Items', {'320x240', '640x480', '720x512'}, ...
                    'Value', '720x512', 'FontSize', 11, ...
                    'BackgroundColor', [1 1 1], 'FontColor', tT.textPrimary, ...
                    'ValueChangedFcn', @(~,~) app.onVideoResolutionChanged(fIdx));
                UI_temp(fIdx).vidControlBtn = uibutton(glVB, 'Text', '제어창', ...
                    'FontSize', 11, 'FontWeight', 'bold', ...
                    'BackgroundColor', tT.toolbarDarkBg, 'FontColor', tT.toolbarDarkFg, ...
                    'ButtonPushedFcn', @(~,~) app.toggleVideoControlDialog(fIdx));
                UI_temp(fIdx).vidSyncStatus = uilabel(glVB, 'Text', '동기 미설정', 'FontSize', 11, ...
                    'FontColor', tT.textSecondary, 'HorizontalAlignment', 'right');
                UI_temp(fIdx).vidSyncStatus.Layout.Column = 5;

                % Row 2: fixed-resolution video area (container scrollable)
                UI_temp(fIdx).vidContainer = uipanel(iGrid2, 'BorderType', 'none', ...
                    'Scrollable', 'on', 'BackgroundColor', tT.videoPanelBg);   % v3-D: external container light, vidAxes only black
                UI_temp(fIdx).vidContainer.Layout.Row = 2;
                UI_temp(fIdx).vidAxes = uiaxes(UI_temp(fIdx).vidContainer, ...
                    'Units', 'pixels', 'Position', [0 0 720 512]);
                UI_temp(fIdx).vidAxes.Color = tT.videoAxesBg;   % v3-sample: remove black (image shows pixels)
                UI_temp(fIdx).vidAxes.XColor = 'none';
                UI_temp(fIdx).vidAxes.YColor = 'none';
                try
                    UI_temp(fIdx).vidAxes.ActivePositionProperty = 'position';
                catch
                end
                axis(UI_temp(fIdx).vidAxes, 'image');
                axis(UI_temp(fIdx).vidAxes, 'off');
                disableDefaultInteractivity(UI_temp(fIdx).vidAxes);
                UI_temp(fIdx).vidAxes.Toolbar.Visible = 'off';
                UI_temp(fIdx).vidImageHandle = image(UI_temp(fIdx).vidAxes, zeros(512,720,3,'uint8'), ...
                    'XData', [1 720], 'YData', [1 512]);
                app.applyLightPanelTitleContrast(UI_temp(fIdx).vidViewerDialog);
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

            % [V3.22 #5] alias the flat UI struct to a grouped view - new code uses the group path
            % existing flat fields (app.UI(fIdx).mapAxes etc.) are also kept -> 100% compatible
            app.buildUIGroups();
        end

        % [V3.22 #5] bundle the flat UI struct into a grouped view(struct) stored in a separate property
        % - app.UIGroup(fIdx).attitude.rollAxes = app.UI(fIdx).rollAxes  (alias)
        % - new code prefers the app.UIGroup(...) path; existing code keeps app.UI(...)
        % - handle objects, so the alias points to the same object and both sync on change
        function buildUIGroups(app)
            % [V3.22 #5] bundle the flat UI struct into a grouped view(struct array, 1x2)
            % - handle objects, so the alias points to the same object and both sync on change
            UIGroup_temp = struct([]);
            for fIdx = 1:2
                u = app.UI(fIdx);
                grp = struct();

                % Attitude group
                grp.attitude = struct( ...
                    'panel',      u.panelAttitude, ...
                    'pitchAxes',  u.pitchAxes,  'pitchLabel', u.pitchLabel, 'pitchValueText', u.pitchValueText, 'hgPitch', u.hgPitch, ...
                    'rollAxes',   u.rollAxes,   'rollLabel',  u.rollLabel,  'rollValueText',  u.rollValueText,  'hgRoll',  u.hgRoll, ...
                    'hdgAxes',    u.hdgAxes,    'hdgLabel',   u.hdgLabel,   'hdgValueText',   u.hdgValueText,   'hgHdg',   u.hgHdg);

                % Map/Altitude(MapAlt) group
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

                % video + Frame Navigator group
                grp.video = struct( ...
                    'viewerDialog',    u.vidViewerDialog, ...
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

                % Plot(H area) group - cell array avoids the struct() ctor
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

                % control header group
                grp.controls = struct( ...
                    'spinner',          u.spinner, ...
                    'currentTimeLabel', u.currentTimeLabel, ...
                    'fileNameLabel',    u.fileNameLabel, ...
                    'btnAtt',           u.btnAtt, ...
                    'btnMap',           u.btnMap, ...
                    'btnAlt',           u.btnAlt, ...
                    'btnPath3D',        u.btnPath3D, ...
                    'btnInfo',          u.btnInfo, ...
                    'btnDataView',      u.btnDataView, ...
                    'btnVid',           u.btnVid);

                % data table + container
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

        function txt = toolbarButtonText(~, iconText, labelText)
            txt = sprintf('%s\n%s', iconText, labelText);
        end

        function btn = createToolbarButton(app, parent, iconText, labelText, callbackFcn, stateName)
            if nargin < 6 || isempty(stateName)
                stateName = 'normal';
            end
            btn = uibutton(parent, 'Text', app.toolbarButtonText(iconText, labelText), ...
                'ButtonPushedFcn', callbackFcn, 'FontSize', 10, 'FontWeight', 'bold');
            try
                btn.WordWrap = 'on';
            catch
            end
            try
                btn.Tooltip = labelText;
            catch
            end
            app.styleToolbarButton(btn, iconText, labelText, stateName);
        end

        function styleToolbarButton(app, btn, iconText, labelText, stateName)
            % v-style: keyword-based role color mapping (flight-path=yellow, board=blue, coastline/win=gray, settings/edit=dark).
            try
                if isempty(btn) || ~isvalid(btn), return; end
                t = app.getLightTheme();
                btn.Text = app.toolbarButtonText(iconText, labelText);
                btn.FontSize = 11;
                btn.FontWeight = 'bold';
                try
                    btn.WordWrap = 'on';
                catch
                end
                lbl = char(labelText);
                switch lower(char(stateName))
                    case 'active'
                        % v3-sample: active = light blue tint bg + role fg (background changes only on pressed)
                        btn.BackgroundColor = t.btnActiveBg;
                        if contains(lbl, '보드')
                            btn.FontColor = t.toolbarBlueFg;
                        else
                            btn.FontColor = t.toolbarGreenFg;
                        end
                    case 'accent'
                        btn.BackgroundColor = t.btnActiveBg;
                        btn.FontColor = t.toolbarGreenFg;
                    case 'disabled'
                        btn.BackgroundColor = t.btnDisabledBg;
                        btn.FontColor = t.btnDisabledFg;
                    otherwise
                        if contains(lbl, '비행경로')
                            btn.BackgroundColor = t.toolbarYellowBg;
                            btn.FontColor = t.toolbarYellowFg;
                        elseif contains(lbl, '해안선')
                            btn.BackgroundColor = t.toolbarGrayBg;
                            btn.FontColor = t.toolbarGrayFg;
                        elseif contains(lbl, '보드')
                            btn.BackgroundColor = t.toolbarBlueBg;
                            btn.FontColor = t.toolbarBlueFg;
                        elseif contains(lbl, '설정') || contains(lbl, '편집')
                            btn.BackgroundColor = t.toolbarDarkBg;
                            btn.FontColor = t.toolbarDarkFg;
                        else
                            btn.BackgroundColor = t.toolbarGrayBg;
                            btn.FontColor = t.toolbarGrayFg;
                        end
                end
            catch ME_silent
                app.logCaught(ME_silent, 'toolbarButtonStyle');
            end
        end

        % [V3.22 #7] main window top header bar (file select / Sync input)
        % - split out from createLayout so header-area changes do not affect the main builder
        function buildHeaderBar(app, mainLayout)
            t = app.getLightTheme();   % v-style
            hHeaderPanel = uipanel(mainLayout, 'BackgroundColor', t.headerBg, 'ForegroundColor', t.textPrimary, 'BorderType', 'line');
            glHeader = uigridlayout(hHeaderPanel, [1 12]);
            glHeader.BackgroundColor = t.headerBg;
            glHeader.ColumnWidth = {110, 110, 100, 104, 104, 430, '1x', 150, 120, 72, 72, 104};
            glHeader.RowHeight = {'1x'};
            glHeader.Padding = [4 3 4 3];
            glHeader.ColumnSpacing = 4;

            app.createToolbarButton(glHeader, '+', '비행경로 1 선택', @(~, ~) app.handleFlightFile(1), 'normal');
            app.createToolbarButton(glHeader, '+', '비행경로 2 선택', @(~, ~) app.handleFlightFile(2), 'normal');
            app.createToolbarButton(glHeader, '≋', '해안선 정보', @(~, ~) app.handleCoastFile(), 'normal');
            app.BoardToggleButtons = gobjects(1, 2);
            app.BoardToggleButtons(1) = app.createToolbarButton(glHeader, '▦', '상단 보드 off', @(~, ~) app.toggleBoardVisibility(1), 'normal');
            app.BoardToggleButtons(2) = app.createToolbarButton(glHeader, '▦', '하단 보드 off', @(~, ~) app.toggleBoardVisibility(2), 'normal');
            app.buildLayoutPresetPicker(glHeader);
            uilabel(glHeader, 'Text', '');

            app.SyncInput = uieditfield(glHeader, 'text', 'Value', '', 'Enable', 'off', ...
                'Tooltip', 'ex: 23.4, 34.4', 'FontSize', 13);
            app.SyncBtn = app.createToolbarButton(glHeader, '↔', '비행시간 동기', @(~, ~) app.toggleSync(), 'disabled');
            app.SyncBtn.Enable = 'off';
            app.WindowMinBtn = app.createToolbarButton(glHeader, '-', '최소화', @(~, ~) app.minimizeWindow(), 'normal');
            app.WindowMaxBtn = app.createToolbarButton(glHeader, '□', '최대화', @(~, ~) app.toggleMaximizeWindow(), 'normal');

            % [Audit fix #1] Entry point to the modeless settings/edit dialog.
            try
                app.createToolbarButton(glHeader, '⚙', '설정/편집', @(~,~) app.openEditDialog(), 'normal');
            catch ME_silent
                app.logCaught(ME_silent, 'buildHeaderBar:edit-button');
            end
            app.updateBoardToggleButtons();
            app.updateLayoutPresetButtons();
            app.refreshGlobalSyncControls();
        end

        function buildLayoutPresetPicker(app, parent)
            try
                t = app.getLightTheme();   % v-style
                names = app.getLayoutPresetNames();
                icons = app.getLayoutPresetIcons();
                pnl = uipanel(parent, 'Title', 'Layout', ...
                    'BackgroundColor', t.headerBg, 'ForegroundColor', t.textInverse, ...
                    'FontSize', 9, 'FontWeight', 'bold');
                gl = uigridlayout(pnl, [1 numel(names) + 1], ...
                    'ColumnWidth', [repmat({32}, 1, numel(names)), {110}], ...
                    'RowHeight', {'1x'}, ...
                    'Padding', [2 1 2 1], 'ColumnSpacing', 2);
                tips = {'Grid (균형)', 'V-Split (좌우 분할)', 'H-Split (수평 배치)', ...
                        'Compact (작은 화면)', 'Reset (폭 초기화)'};
                app.LayoutPresetButtons = gobjects(1, numel(names));
                for k = 1:numel(names)
                    presetName = names{k};
                    btn = uibutton(gl, 'Text', icons{k}, 'FontSize', 13, 'FontWeight', 'bold', ...
                        'ButtonPushedFcn', @(~,~) app.applyLayoutPreset(presetName));
                    try
                        btn.Tooltip = tips{k};
                    catch
                    end
                    app.LayoutPresetButtons(k) = btn;
                end
                app.HeaderLayoutPresetDD = uidropdown(gl, ...
                    'Items', {'사용자 프리셋'}, 'Value', '사용자 프리셋', ...
                    'BackgroundColor', [1 1 1], 'FontColor', t.textPrimary, ...
                    'FontSize', 10, 'ValueChangedFcn', @(~,~) app.applyHeaderLayoutPreset());
                app.HeaderLayoutPresetDD.Layout.Column = numel(names) + 1;
                app.refreshHeaderLayoutPresetDropdown();
            catch ME
                app.logCaught(ME, 'layoutPresetPicker');
            end
        end

        function refreshHeaderLayoutPresetDropdown(app)
            try
                dd = app.HeaderLayoutPresetDD;
                if isempty(dd) || ~isvalid(dd), return; end
                items = {'사용자 프리셋'};
                if ~isempty(app.UserLayoutPresets) && isstruct(app.UserLayoutPresets)
                    names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                    items = [items, names];
                end
                dd.Value = '사용자 프리셋';
                dd.Items = items;
                cur = char(app.CurrentLayoutPreset);
                if any(strcmp(cur, items))
                    dd.Value = cur;
                elseif ~any(strcmp(char(dd.Value), items))
                    dd.Value = items{1};
                end
            catch ME
                app.logCaught(ME, 'layoutPresetHeaderDropdown');
            end
        end

        function applyHeaderLayoutPreset(app)
            try
                dd = app.HeaderLayoutPresetDD;
                if isempty(dd) || ~isvalid(dd), return; end
                presetName = char(dd.Value);
                if strcmp(presetName, '사용자 프리셋'), return; end
                names = arrayfun(@(p) char(p.Name), app.UserLayoutPresets, 'UniformOutput', false);
                hit = find(strcmp(names, presetName), 1);
                if isempty(hit), return; end
                app.applyLayoutUiState(app.UserLayoutPresets(hit).Layout);
                app.CurrentLayoutPreset = presetName;
                app.updateLayoutPresetButtons();
                app.markProjectDirtyAndScheduleRefresh('layout-preset-header-apply');
            catch ME
                app.logCaught(ME, 'layoutPresetHeaderApply');
            end
        end

        function [ax, lbl, grid] = createGaugePanel(app, parentPnl, titleStr)
            t = app.getLightTheme();   % v2-D1: strengthen external label readability
            grid = uigridlayout(parentPnl, [2 1]);
            grid.RowHeight = {28, '1x'};
            grid.Padding = [0 0 0 0];
            grid.RowSpacing = 0;
            try
                grid.BackgroundColor = t.surfaceBg;
            catch
            end

            lbl = uilabel(grid, 'Text', [titleStr ' +0.000'], 'FontWeight', 'bold', 'FontSize', 15, ...
                'FontColor', t.textPrimary, 'HorizontalAlignment', 'center');
            axPnl = uipanel(grid, 'BorderType', 'none', 'BackgroundColor', t.surfaceBg);

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
                'UiState',     struct('WindowPosition', [], 'EditDialogPosition', [], ...
                                      'ActiveTab', 'Project', 'Layout', app.createDefaultLayoutUiState()), ...
                'AuxFiles',    {{}});
            for i = 1:2
                st.Flights(i).Name = sprintf('Flight %d', i);
            end
        end

        function layout = createDefaultLayoutUiState(app)
            panel = app.createDefaultPanelVisibleState();
            layout = struct( ...
                'CurrentLayoutPreset', 'custom', ...
                'BoardOffState', [false, false], ...
                'BoardOffSourceRatio', 1.0, ...
                'BodyRowSplitRatio', 0.5, ...
                'BodyRowHeight', {{'1x', app.LAYOUT_SPLITTER_THICKNESS, '1x', 0}}, ...
                'Path3DVisible', [false, false], ...
                'PanelVisible', [panel, panel]);
            layout.ColumnWidth = cell(1, 2);
            layout.LayoutPresets = struct('Name', {}, 'SavedAt', {}, 'Layout', {});
        end

        function panel = createDefaultPanelVisibleState(~)
            panel = struct('attitude', false, 'mapOnly', false, 'altOnly', false, ...
                'video', false, 'info', true, 'dataView', true);
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
            try
                st.UiState.Layout = app.collectLayoutUiState();
            catch ME
                app.logCaught(ME, 'collectCurrentProjectState:layout');
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
                try
                    if isfield(st.UiState, 'Layout') && ~isempty(st.UiState.Layout)
                        if isfield(st.UiState.Layout, 'LayoutPresets')
                            app.UserLayoutPresets = st.UiState.Layout.LayoutPresets;
                        end
                        app.applyLayoutUiState(st.UiState.Layout);
                    end
                catch ME
                    app.logCaught(ME, 'applyProjectStateToApp:layout');
                end
            end
            if isfield(st, 'PlotConfig')
                app.PlotConfigState = st.PlotConfig;
            end
            app.ProjectState = st;
            % [Medium 1] dirty=false is meaningful only after the caller has completed the file load.
            % autoLoadProjectFromFile re-decides later via the loadCompletedCleanly flag.
            % on a direct call (e.g., external import) the caller must make the follow-up decision too.
            app.ProjectDirty = false;
            % [Review High #3] if the Edit Dialog is open, immediately re-sync all tab display values to the
            % new project state - so Sync / Plot / Files / Options labels do not remain stale.
            try
                if ~isempty(app.EditDialog) && isvalid(app.EditDialog)
                    app.refreshEditDialog();
                end
            catch ME
                app.logCaught(ME, 'applyProjectState:refresh');
            end
        end

        function layout = collectLayoutUiState(app)
            layout = app.createDefaultLayoutUiState();
            layout.CurrentLayoutPreset = char(app.CurrentLayoutPreset);
            layout.BoardOffState = logical(app.BoardOffState);
            layout.BoardOffSourceRatio = double(app.BoardOffSourceRatio);
            layout.BodyRowSplitRatio = double(app.BodyRowSplitRatio);
            layout.Path3DVisible = logical(app.Path3DVisible);
            try
                if ~isempty(app.BodyGrid) && isvalid(app.BodyGrid)
                    layout.BodyRowHeight = app.BodyGrid.RowHeight;
                end
            catch ME
                app.logCaught(ME, 'collectLayoutUiState:rows');
            end
            for fIdx = 1:2
                try
                    if ~isempty(app.UI) && numel(app.UI) >= fIdx && isfield(app.UI(fIdx), 'PanelVisible')
                        layout.PanelVisible(fIdx) = app.normalizePanelVisibleState(app.UI(fIdx).PanelVisible);
                    end
                    if ~isempty(app.UI) && numel(app.UI) >= fIdx && isfield(app.UI(fIdx), 'dataGrid') ...
                            && ~isempty(app.UI(fIdx).dataGrid) && isvalid(app.UI(fIdx).dataGrid)
                        cachedWidths = app.getRememberedColumnWidths(fIdx);
                        if isempty(cachedWidths)
                            layout.ColumnWidth{fIdx} = app.enforcePanelVisibilityOnColumnWidths( ...
                                layout.PanelVisible(fIdx), app.UI(fIdx).dataGrid.ColumnWidth);
                        else
                            layout.ColumnWidth{fIdx} = app.enforcePanelVisibilityOnColumnWidths( ...
                                layout.PanelVisible(fIdx), cachedWidths);
                        end
                    end
                catch ME
                    app.logCaught(ME, 'collectLayoutUiState:panel');
                end
            end
            layout.LayoutPresets = app.UserLayoutPresets;
        end

        function applyLayoutUiState(app, layout)
            try
                layout = app.mergeLayoutUiState(layout);
                app.CurrentLayoutPreset = char(layout.CurrentLayoutPreset);
                if isfield(layout, 'LayoutPresets') && ~isempty(layout.LayoutPresets)
                    app.UserLayoutPresets = layout.LayoutPresets;
                end
                app.BoardOffSourceRatio = max(0.5, min(1.0, double(layout.BoardOffSourceRatio)));
                app.BodyRowSplitRatio = max(0.2, min(0.8, double(layout.BodyRowSplitRatio)));
                for fIdx = 1:2
                    if isempty(app.UI) || numel(app.UI) < fIdx || ~isfield(app.UI(fIdx), 'PanelVisible')
                        continue;
                    end
                    app.UI(fIdx).PanelVisible = app.normalizePanelVisibleState(layout.PanelVisible(fIdx));
                    app.applyMapAltVisibility(fIdx);
                    savedWidths = app.getLayoutColumnWidth(layout, fIdx);
                    if ~isempty(savedWidths)
                        savedWidths = app.enforcePanelVisibilityOnColumnWidths(layout.PanelVisible(fIdx), savedWidths);
                        app.rememberUserColumnWidths(fIdx, savedWidths);
                    end
                end

                offIdx = find(logical(layout.BoardOffState), 1);
                if isempty(offIdx)
                    app.setBoardOffDirect(0);
                else
                    app.setBoardOffDirect(offIdx);
                end
                for fIdx = 1:2
                    app.applyMapAltVisibility(fIdx);
                    app.reflowBoardColumns(fIdx);
                    app.refreshBoardOffSummaryPanel(fIdx, true);
                end
                if isempty(offIdx)
                    for fIdx = 1:2
                        savedWidths = app.getLayoutColumnWidth(layout, fIdx);
                        if ~isempty(savedWidths) && ~isempty(app.UI) && numel(app.UI) >= fIdx ...
                                && isfield(app.UI(fIdx), 'dataGrid') && ~isempty(app.UI(fIdx).dataGrid) ...
                                && isvalid(app.UI(fIdx).dataGrid)
                            savedWidths = app.enforcePanelVisibilityOnColumnWidths(layout.PanelVisible(fIdx), savedWidths);
                            app.UI(fIdx).dataGrid.ColumnWidth = savedWidths;
                            app.rememberUserColumnWidths(fIdx, savedWidths);
                            app.updateColumnSplitterVisibility(fIdx, savedWidths);
                        end
                    end
                end
                if isempty(offIdx)
                    app.setBodyGridRowsDirect(app.normalizeBodyRowHeight(layout.BodyRowHeight));
                else
                    app.applyBodyGridRowHeights();
                end
                % [#2] backward-compatible: old .fdproj without Path3DVisible -> default false
                if isfield(layout, 'Path3DVisible') && numel(layout.Path3DVisible) >= 2
                    app.Path3DVisible = logical(layout.Path3DVisible);
                else
                    app.Path3DVisible = [false, false];
                end
                for fIdx = 1:2
                    app.setPath3DDialogVisible(fIdx, app.Path3DVisible(fIdx));
                end
                app.updateBoardToggleButtons();
                app.updateLayoutPresetButtons();
                drawnow limitrate;
            catch ME
                app.logCaught(ME, 'applyLayoutUiState');
            end
        end

        function layout = mergeLayoutUiState(app, layout)
            def = app.createDefaultLayoutUiState();
            if nargin < 2 || isempty(layout) || ~isstruct(layout)
                layout = def;
                return;
            end
            names = fieldnames(def);
            for i = 1:numel(names)
                nm = names{i};
                if ~isfield(layout, nm) || isempty(layout.(nm))
                    layout.(nm) = def.(nm);
                end
            end
            layout.CurrentLayoutPreset = char(layout.CurrentLayoutPreset);
            bos = logical(layout.BoardOffState);
            if numel(bos) < 2, bos = def.BoardOffState; end
            bos = [bos(1), bos(2)];
            if all(bos)
                bos(2) = false;
            end
            layout.BoardOffState = bos;
            layout.BoardOffSourceRatio = max(0.5, min(1.0, double(layout.BoardOffSourceRatio)));
            layout.BodyRowSplitRatio = max(0.2, min(0.8, double(layout.BodyRowSplitRatio)));
            layout.BodyRowHeight = app.normalizeBodyRowHeight(layout.BodyRowHeight);
            p3 = logical(layout.Path3DVisible);
            if numel(p3) < 2
                p3 = def.Path3DVisible;
            end
            layout.Path3DVisible = [p3(1), p3(2)];
            layout.ColumnWidth = app.normalizeLayoutColumnWidth(layout.ColumnWidth);
            panels = def.PanelVisible;
            if isfield(layout, 'PanelVisible') && isstruct(layout.PanelVisible)
                for fIdx = 1:min(2, numel(layout.PanelVisible))
                    panels(fIdx) = app.normalizePanelVisibleState(layout.PanelVisible(fIdx));
                end
            end
            layout.PanelVisible = panels;
            if ~isstruct(layout.LayoutPresets) || isempty(layout.LayoutPresets)
                layout.LayoutPresets = def.LayoutPresets;
            else
                presetDef = struct('Name', '', 'SavedAt', '', 'Layout', def);
                presets = layout.LayoutPresets;
                for p = 1:numel(presets)
                    if ~isfield(presets(p), 'Name'), presets(p).Name = presetDef.Name; end
                    if ~isfield(presets(p), 'SavedAt'), presets(p).SavedAt = presetDef.SavedAt; end
                    if ~isfield(presets(p), 'Layout') || isempty(presets(p).Layout)
                        presets(p).Layout = def;
                    else
                        presets(p).Layout = app.mergeLayoutUiState(presets(p).Layout);
                        presets(p).Layout.LayoutPresets = def.LayoutPresets;
                    end
                end
                layout.LayoutPresets = presets;
            end
        end

        function panel = normalizePanelVisibleState(app, panel)
            def = app.createDefaultPanelVisibleState();
            if nargin < 2 || isempty(panel) || ~isstruct(panel)
                panel = def;
                return;
            end
            names = fieldnames(def);
            for i = 1:numel(names)
                nm = names{i};
                if ~isfield(panel, nm) || isempty(panel.(nm))
                    if strcmp(nm, 'mapOnly') && isfield(panel, 'map')
                        panel.(nm) = logical(panel.map);
                    elseif strcmp(nm, 'altOnly') && isfield(panel, 'map')
                        panel.(nm) = logical(panel.map);
                    else
                        panel.(nm) = def.(nm);
                    end
                else
                    panel.(nm) = logical(panel.(nm));
                end
            end
            orderedPanel = def;
            for i = 1:numel(names)
                nm = names{i};
                orderedPanel.(nm) = panel.(nm);
            end
            panel = orderedPanel;
        end

        function rows = normalizeBodyRowHeight(app, rows)
            defaultRows = {'1x', app.LAYOUT_SPLITTER_THICKNESS, '1x', 0};
            if nargin < 2 || isempty(rows)
                rows = defaultRows;
                return;
            end
            if isstring(rows)
                rows = cellstr(rows);
            elseif ischar(rows)
                rows = {rows};
            elseif isnumeric(rows)
                rows = num2cell(rows);
            end
            if ~iscell(rows)
                rows = defaultRows;
                return;
            end
            if numel(rows) == 2
                rows = {rows{1}, app.LAYOUT_SPLITTER_THICKNESS, rows{2}, 0};
            elseif numel(rows) == 3
                rows = {rows{1}, app.LAYOUT_SPLITTER_THICKNESS, rows{3}, 0};
            elseif numel(rows) ~= 4
                rows = defaultRows;
                return;
            end
            rows = reshape(rows, 1, 4);
        end

        function allWidths = normalizeLayoutColumnWidth(app, allWidths)
            normalized = cell(1, 2);
            if nargin >= 2 && iscell(allWidths)
                for fIdx = 1:min(2, numel(allWidths))
                    normalized{fIdx} = app.normalizeDataGridColumnWidth(allWidths{fIdx});
                end
            elseif nargin >= 2 && isstruct(allWidths)
                keys = {'Flight1', 'Flight2'};
                for fIdx = 1:2
                    if isfield(allWidths, keys{fIdx})
                        normalized{fIdx} = app.normalizeDataGridColumnWidth(allWidths.(keys{fIdx}));
                    end
                end
            end
            allWidths = normalized;
        end

        function widths = getLayoutColumnWidth(app, layout, fIdx)
            widths = {};
            try
                if isfield(layout, 'ColumnWidth') && iscell(layout.ColumnWidth) && numel(layout.ColumnWidth) >= fIdx
                    widths = app.normalizeDataGridColumnWidth(layout.ColumnWidth{fIdx});
                end
            catch
                widths = {};
            end
        end

        function widths = normalizeDataGridColumnWidth(~, widths)
            if isempty(widths)
                widths = {};
                return;
            end
            if isstring(widths)
                widths = cellstr(widths);
            elseif ischar(widths)
                widths = {widths};
            elseif isnumeric(widths)
                widths = num2cell(widths);
            end
            if ~iscell(widths)
                widths = {};
                return;
            end
            widths = reshape(widths, 1, []);
            if numel(widths) == 6
                % Legacy grid: attitude/map/info/plot/splitter/video.
                widths = {widths{1}, 0, widths{2}, 0, widths{3}, widths{5}, widths{4}, 0};
            elseif numel(widths) ~= 8
                widths = {};
            end
        end

        function widths = enforcePanelVisibilityOnColumnWidths(app, panelState, widths)
            % v4-R4: alias to single canonical normalizer.
            widths = app.normalizeColumnWidthsForVisiblePanels(panelState, widths);
        end

        function widths = normalizeColumnWidthsForVisiblePanels(app, panelState, widths)
            % v4-R4: single idempotent normalizer.
            % - plot/dataView visible -> column 7 always '1x'
            % - hidden panel column -> 0; adjacent splitter -> 0
            % - both neighbors visible -> splitter = LAYOUT_SPLITTER_THICKNESS
            % - widths{8} (legacy video column) always 0
            % - repeated calls with same panelState + same adjustable widths -> identical result
            widths = app.normalizeDataGridColumnWidth(widths);
            if isempty(widths)
                widths = app.getDefaultDataGridColumnWidths();
            end
            panelState = app.normalizePanelVisibleState(panelState);
            panelWidths = app.getResponsivePanelWidths();
            if ~panelState.attitude
                widths{1} = 0;
            elseif app.isTestWidthZero(widths{1})
                widths{1} = panelWidths(1);
            end
            if ~(panelState.mapOnly || panelState.altOnly)
                widths{3} = 0;
            elseif app.isTestWidthZero(widths{3})
                widths{3} = panelWidths(2);
            end
            if ~panelState.info
                widths{5} = 0;
            elseif app.isTestWidthZero(widths{5})
                widths{5} = panelWidths(3);
            end
            if ~panelState.dataView
                widths{7} = 0;
            else
                % v4 P2: always force flex '1x' when plot/dataView visible (do not store fixed pixels)
                widths{7} = '1x';
            end
            widths{2} = 0; widths{4} = 0; widths{6} = 0; widths{8} = 0;
            thk = app.LAYOUT_SPLITTER_THICKNESS;
            if ~app.isTestWidthZero(widths{1}) && ~app.isTestWidthZero(widths{3}), widths{2} = thk; end
            if ~app.isTestWidthZero(widths{3}) && ~app.isTestWidthZero(widths{5}), widths{4} = thk; end
            if ~app.isTestWidthZero(widths{5}) && ~app.isTestWidthZero(widths{7}), widths{6} = thk; end
        end

        function st = migrateProjectState(app, st)
            % [D7] in-memory migration entry point. v1->v1 passthrough; future versions extend switch.
            if isempty(st), return; end
            if ~isfield(st, 'Version') || isempty(st.Version)
                st.Version = 1;
            end
            defaultState = app.createDefaultProjectState();
            if ~isfield(st, 'UiState') || isempty(st.UiState) || ~isstruct(st.UiState)
                st.UiState = defaultState.UiState;
            else
                uiNames = fieldnames(defaultState.UiState);
                for iName = 1:numel(uiNames)
                    nm = uiNames{iName};
                    if ~isfield(st.UiState, nm)
                        st.UiState.(nm) = defaultState.UiState.(nm);
                    end
                end
                st.UiState.Layout = app.mergeLayoutUiState(st.UiState.Layout);
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
                % v-crit3: state consistency on safe-failure - revert partially updated meta
                try
                    app.ProjectLastSaveText = '';
                    app.ProjectDirty = false;
                catch
                end
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
            if app.IsDeleting, return; end   % [bug#1] block the timer firing in the teardown window
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
            app.setEditDialogStatus('변경됨');   % [step2] edit started -> changed (best-effort)
            try
                if isempty(app.EditApplyTimer) || ~isvalid(app.EditApplyTimer)
                    app.EditApplyTimer = timer( ...
                        'ExecutionMode', 'singleShot', ...
                        'StartDelay', app.EditApplyDelaySec, ...
                        'TimerFcn', @(~,~) app.applyPendingDialogChanges(), ...
                        'ErrorFcn', @(~,evt) app.logCaught(evt, 'timer:editApply'));
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
                        'TimerFcn', @(~,~) app.saveProjectAutosave(), ...
                        'ErrorFcn', @(~,evt) app.logCaught(evt, 'timer:autosave'));
                    start(app.AutosaveTimer);
                end
            catch ME
                app.logCaught(ME, 'project-dirty:autosave-timer');
            end
        end

        function applyPendingDialogChanges(app)
            % Default applier: refresh data UI for any flights with loaded data.
            % Phases 2-4 extend this with option/sync/plot specific re-applies.
            if app.IsDeleting, return; end   % [bug#2] block the EditApplyTimer singleShot teardown window
            try
                for fIdx = 1:2
                    try
                        if ~isempty(app.Models(fIdx).rawData) && height(app.Models(fIdx).rawData) > 0
                            app.setupDataUI(fIdx, false);
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
                app.setEditDialogStatus('적용됨');   % [step2] apply finished ok -> applied
            catch ME
                app.logCaught(ME, 'apply-pending-dialog');
                app.setEditDialogStatus('오류');     % [step2] apply failed -> error
            end
        end

        % =================================================================
        % [Phase 3] Programmatic sync setters (consumed by future Sync tab).
        % These reuse the existing UI refresh paths so the main window stays
        % consistent regardless of who initiated the change.
        % =================================================================
        function ok = searchFlightDataValue(app, fIdx)
            % [Sync Search] search the selected item value -> candidate time list -> set sync basis(T1/T2).
            % returns: whether the dialog opened (for observing guard silent-return)
            ok = false;
            try
                if fIdx < 1 || fIdx > numel(app.Models), return; end
                % v-fix: if there was never an actual row selection, prevent a default row1 search
                if fIdx <= numel(app.LastInfoTableSelectionValid) && ~app.LastInfoTableSelectionValid(fIdx)
                    uialert(app.UIFigure, '먼저 왼쪽 클릭으로 항목 행을 선택한 뒤 우클릭 메뉴를 사용하세요.', '동기시간 찾기');
                    return;
                end
                selRow = app.Models(fIdx).selectedRow;
                if isempty(selRow) || ~isfinite(selRow) || selRow < 1 ...
                        || selRow > numel(app.Models(fIdx).displayMeta)
                    uialert(app.UIFigure, '먼저 "현재 비행 정보"에서 항목(행)을 선택하세요.', '동기시간 찾기');
                    return;
                end
                if isempty(app.Models(fIdx).rawData) || height(app.Models(fIdx).rawData) < 1
                    uialert(app.UIFigure, '비행데이터가 로드되지 않았습니다.', '동기시간 찾기');
                    return;
                end
                meta = app.Models(fIdx).displayMeta(selRow);
                yCol = meta.header;
                % v-fix5: validate Time column mapping
                if ~isfield(app.Models(fIdx).mappedCols, 'Time') || isempty(app.Models(fIdx).mappedCols.Time) ...
                        || ~ismember(app.Models(fIdx).mappedCols.Time, app.Models(fIdx).rawData.Properties.VariableNames)
                    uialert(app.UIFigure, 'Time 컬럼 매핑이 유효하지 않습니다.', '동기시간 찾기');
                    return;
                end
                timeCol = app.Models(fIdx).mappedCols.Time;
                if ~ismember(yCol, app.Models(fIdx).rawData.Properties.VariableNames)
                    uialert(app.UIFigure, sprintf('컬럼 "%s" 을(를) 찾을 수 없습니다.', yCol), '동기시간 찾기');
                    return;
                end
                yData = app.Models(fIdx).rawData.(yCol);
                if ~isnumeric(yData)
                    uialert(app.UIFigure, '숫자형 항목만 검색할 수 있습니다.', '동기시간 찾기');
                    return;
                end
                app.openSyncSearchDialog(fIdx, yCol, timeCol);
                ok = true;
            catch ME
                app.logCaught(ME, 'sync-search');
            end
        end

        function openSyncSearchDialog(app, fIdx, yCol, timeCol)
            t = app.getLightTheme();
            % v-fix3: close the existing dialog and store the handle (lifecycle tracking)
            try
                if numel(app.SyncSearchDialogs) >= fIdx && ~isempty(app.SyncSearchDialogs{fIdx}) ...
                        && isvalid(app.SyncSearchDialogs{fIdx})
                    delete(app.SyncSearchDialogs{fIdx});
                end
            catch
            end
            dlg = uifigure('Name', sprintf('동기시간 찾기 - Flight Data %d (%s)', fIdx, yCol), ...
                'Position', [200 200 560 460], 'Color', t.dialogBg);
            app.SyncSearchDialogs{fIdx} = dlg;
            try
                dlg.AutoResizeChildren = 'off';
            catch
            end
            gl = uigridlayout(dlg, [4 4], 'RowHeight', {32, '1x', 32, 36}, ...
                'ColumnWidth', {'1x', 90, 90, 90}, 'Padding', [8 8 8 8], ...
                'RowSpacing', 6, 'ColumnSpacing', 6, 'BackgroundColor', t.dialogBg);
            uilabel(gl, 'Text', sprintf('검색 값 (%s):', yCol), 'FontColor', t.textPrimary, 'FontWeight', 'bold');
            valField = uieditfield(gl, 'numeric', 'Value', 0, 'BackgroundColor', [1 1 1], 'FontColor', t.textPrimary);
            valField.Layout.Row = 1; valField.Layout.Column = [2 3];
            searchBtn = uibutton(gl, 'Text', '검색', 'BackgroundColor', t.toolbarBlueBg, 'FontColor', t.toolbarBlueFg, 'FontWeight', 'bold');
            searchBtn.Layout.Row = 1; searchBtn.Layout.Column = 4;
            resTable = uitable(gl, 'ColumnName', {'Rank', 'Index', 'Time(s)', 'Value', 'Diff'}, ...
                'BackgroundColor', [1 1 1; 0.96 0.98 1.00], 'ForegroundColor', [0 0 0], ...
                'RowName', [], 'FontName', 'Consolas');
            resTable.Layout.Row = 2; resTable.Layout.Column = [1 4];
            infoLbl = uilabel(gl, 'Text', '값을 입력하고 검색하세요.', 'FontColor', t.textSecondary);
            infoLbl.Layout.Row = 3; infoLbl.Layout.Column = [1 4];
            gotoBtn = uibutton(gl, 'Text', '선택 위치로 이동', 'BackgroundColor', t.toolbarGrayBg, 'FontColor', t.toolbarGrayFg, 'FontWeight', 'bold');
            gotoBtn.Layout.Row = 4; gotoBtn.Layout.Column = 1;
            setBtn = uibutton(gl, 'Text', sprintf('T%d 지정', fIdx), 'BackgroundColor', t.toolbarGreenBg, 'FontColor', t.toolbarGreenFg, 'FontWeight', 'bold');
            setBtn.Layout.Row = 4; setBtn.Layout.Column = 2;
            applyBtn = uibutton(gl, 'Text', '동기 적용', 'BackgroundColor', t.toolbarYellowBg, 'FontColor', t.toolbarYellowFg, 'FontWeight', 'bold');
            applyBtn.Layout.Row = 4; applyBtn.Layout.Column = 3;
            clearBtn = uibutton(gl, 'Text', '동기 해제', 'BackgroundColor', t.btnWarningBg, 'FontColor', t.btnWarningFg, 'FontWeight', 'bold');
            clearBtn.Layout.Row = 4; clearBtn.Layout.Column = 4;

            searchBtn.ButtonPushedFcn = @(~,~) app.runSyncSearch(fIdx, yCol, timeCol, valField.Value, resTable, infoLbl);
            gotoBtn.ButtonPushedFcn   = @(~,~) app.syncSearchGoto(fIdx, resTable);
            setBtn.ButtonPushedFcn    = @(~,~) app.syncSearchSetAnchor(fIdx, yCol, resTable, infoLbl);
            applyBtn.ButtonPushedFcn  = @(~,~) app.syncSearchApply(infoLbl);
            clearBtn.ButtonPushedFcn  = @(~,~) app.clearPendingSyncAnchor(infoLbl);
        end

        function clearPendingSyncAnchor(app, infoLbl)
            % v-fix4: on sync release, reset both SyncState + PendingFlightSyncAnchor
            try
                app.PendingFlightSyncAnchor = struct('T1', NaN, 'T2', NaN, ...
                    'Source1', '', 'Source2', '', 'Index1', NaN, 'Index2', NaN, 'Value1', NaN, 'Value2', NaN);
                app.setFlightDataSync(NaN, NaN, false);
                if nargin >= 2 && ~isempty(infoLbl) && isvalid(infoLbl)
                    infoLbl.Text = '동기 해제 및 T1/T2 후보 초기화 완료.';
                end
            catch ME
                app.logCaught(ME, 'sync-search:clear-anchor');
            end
        end

        function invalidateInfoTableSelection(app, fIdx)
            % invalidate stale selection on displayMeta rebuild (the same row may mean a different item)
            try
                if fIdx >= 1 && fIdx <= numel(app.LastInfoTableSelectionValid)
                    app.LastInfoTableSelectionValid(fIdx) = false;
                end
            catch
            end
        end

        function dlgs = getOpenDialogHandlesForTest(app)
            % v-fix1: the runner collects visible dialogs {handle, tag} without direct private-property access
            dlgs = cell(0, 2);
            try
                cand = {};
                if ~isempty(app.EditDialog), cand(end+1,:) = {app.EditDialog, 'editdialog'}; end
                for fk = 1:numel(app.UI)
                    try
                        cand(end+1,:) = {app.UI(fk).vidControlDialog, sprintf('vidctrl_f%d', fk)}; %#ok<AGROW>
                    catch
                    end
                    try
                        cand(end+1,:) = {app.UI(fk).vidViewerDialog,  sprintf('vidview_f%d', fk)}; %#ok<AGROW>
                    catch
                    end
                end
                for fk = 1:numel(app.SyncSearchDialogs)
                    cand(end+1,:) = {app.SyncSearchDialogs{fk}, sprintf('syncsearch_f%d', fk)}; %#ok<AGROW>
                end
                for k = 1:size(cand, 1)
                    d = cand{k, 1};
                    if ~isempty(d) && isa(d,'matlab.ui.Figure') && isvalid(d) ...
                            && strcmpi(char(d.Visible), 'on')
                        dlgs(end+1, :) = {d, cand{k, 2}}; %#ok<AGROW>
                    end
                end
            catch ME
                app.logCaught(ME, 'test:open-dialog-handles');
            end
        end

        function rows = computeSyncSearchRows(~, yData, tData, target)
            % prefer exact match (>500 limit), else value-sorted closest-centered +-7 max 15.
            % columns: [Rank, Index, Time, Value, Diff]. nearest keeps closest in the middle row (no re-sort).
            rows = zeros(0, 5);
            % v-fix1: defend against empty data / non-finite target
            if isempty(yData) || isempty(tData) || ~isfinite(target), return; end
            finiteMask = isfinite(yData) & isfinite(tData);
            idxAll = find(finiteMask);
            if isempty(idxAll), return; end
            vals = yData(idxAll); times = tData(idxAll);
            exact = find(vals == target);
            if ~isempty(exact)
                sel = exact;
                if numel(sel) > 500, sel = sel(1:500); end
                rowsIdx = idxAll(sel);
                rk = (1:numel(sel))';
                rows = [rk, double(rowsIdx(:)), double(times(sel)), double(vals(sel)), double(vals(sel) - target)];
                return;
            end
            [sortedVals, order] = sort(vals);
            [~, nearestPos] = min(abs(sortedVals - target));
            lo = max(1, nearestPos - 7); hi = min(numel(sortedVals), nearestPos + 7);
            sel = order(lo:hi);
            rowsIdx = idxAll(sel);
            % v-fix2: keep value-sorted order so closest stays in the middle row (removed index re-sort)
            rk = (1:numel(sel))';
            rows = [rk, double(rowsIdx(:)), double(times(sel)), double(vals(sel)), double(vals(sel) - target)];
        end

        function r = syncSearchClosestDisplayRow(~, rows)
            % min |Diff| display row from the nearest result (for Rank-based selection)
            r = 1;
            try
                if isempty(rows), return; end
                [~, r] = min(abs(rows(:, 5)));   % Diff column = 5
            catch
                r = 1;
            end
        end

        function runSyncSearch(app, fIdx, yCol, timeCol, target, resTable, infoLbl)
            try
                yData = app.Models(fIdx).rawData.(yCol);
                tData = app.Models(fIdx).rawData.(timeCol);
                rows = app.computeSyncSearchRows(yData, tData, target);
                resTable.Data = rows;
                if isempty(rows)
                    infoLbl.Text = '검색 결과 없음 (유효 숫자값 없음).';
                elseif any(rows(:,4) == target)   % Value column = 4
                    infoLbl.Text = sprintf('일치 %d개 표시.', size(rows,1));
                    try
                        resTable.Selection = [1 1];
                    catch
                    end
                else
                    infoLbl.Text = sprintf('일치값 없음 → 가장 가까운 %d개 표시.', size(rows,1));
                    try
                        resTable.Selection = [app.syncSearchClosestDisplayRow(rows), 1];
                    catch
                    end
                end
            catch ME
                app.logCaught(ME, 'sync-search:run');
            end
        end

        function r = syncSearchSelectedRow(~, resTable)
            r = [];
            try
                if isempty(resTable.Data), return; end
                sel = resTable.Selection;
                if isempty(sel), r = resTable.Data(1, :); else, r = resTable.Data(sel(1), :); end
            catch
                r = [];
            end
        end

        function syncSearchGoto(app, fIdx, resTable)
            try
                r = app.syncSearchSelectedRow(resTable);
                if isempty(r), return; end
                app.applyTimeChange(fIdx, max(1, min(height(app.Models(fIdx).rawData), round(r(2)))));   % Index column = 2
            catch ME
                app.logCaught(ME, 'sync-search:goto');
            end
        end

        function syncSearchSetAnchor(app, fIdx, yCol, resTable, infoLbl)
            try
                r = app.syncSearchSelectedRow(resTable);
                if isempty(r), return; end
                % columns: [Rank, Index, Time, Value, Diff]
                if fIdx == 1
                    app.PendingFlightSyncAnchor.T1 = r(3);
                    app.PendingFlightSyncAnchor.Source1 = yCol;
                    app.PendingFlightSyncAnchor.Index1 = r(2); app.PendingFlightSyncAnchor.Value1 = r(4);
                else
                    app.PendingFlightSyncAnchor.T2 = r(3);
                    app.PendingFlightSyncAnchor.Source2 = yCol;
                    app.PendingFlightSyncAnchor.Index2 = r(2); app.PendingFlightSyncAnchor.Value2 = r(4);
                end
                infoLbl.Text = sprintf('T1=%s, T2=%s', ...
                    app.fmtAnchor(app.PendingFlightSyncAnchor.T1), app.fmtAnchor(app.PendingFlightSyncAnchor.T2));
            catch ME
                app.logCaught(ME, 'sync-search:set-anchor');
            end
        end

        function s = fmtAnchor(~, v)
            if isfinite(v), s = sprintf('%.3f', v); else, s = '(미지정)'; end
        end

        function syncSearchApply(app, infoLbl)
            try
                t1 = app.PendingFlightSyncAnchor.T1; t2 = app.PendingFlightSyncAnchor.T2;
                if ~isfinite(t1) || ~isfinite(t2)
                    if ~isempty(infoLbl) && isvalid(infoLbl)
                        infoLbl.Text = 'T1, T2 를 모두 지정해야 동기 적용 가능.';
                    end
                    return;
                end
                app.setFlightDataSync(t1, t2, true);
                if ~isempty(infoLbl) && isvalid(infoLbl)
                    infoLbl.Text = sprintf('동기 적용 완료 (T1=%.3f, T2=%.3f).', t1, t2);
                end
            catch ME
                app.logCaught(ME, 'sync-search:apply');
            end
        end

        function setFlightDataSync(app, syncT1, syncT2, enabled)
            if nargin < 4, enabled = true; end
            if ~enabled
                app.SyncState.IsSynced = false;
                try
                    app.refreshGlobalSyncControls();
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
                app.refreshGlobalSyncControls();
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
                    app.SyncBtn.Enable = 'on';
                    app.styleToolbarButton(app.SyncBtn, '⟲', '동기 해제', 'active');
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
            app.refreshGlobalSyncControls();
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
    % [V3.22 #6] Static wrapper - abstract external function calls through the class
    % - on a future +flightdash package split, only this wrapper needs a one-line change
    % - currently delegates to file-level external functions (parfeval accepts both forms)
    % - recommended usage: parfeval(pool, @FlightDataDashboard.workerDecodeFrame, ...)
    % =========================================================================
    methods (Static, Access = public)
        function img = workerDecodeFrame(filePath, frameNo, fps, maxSlots)
            % future migration: replace with flightdash.asyncDecodeFramePersistent
            if nargin < 4
                img = asyncDecodeFramePersistent(filePath, frameNo, fps);
            else
                img = asyncDecodeFramePersistent(filePath, frameNo, fps, maxSlots);
            end
        end

        function workerCleanupCache()
            % future migration: replace with flightdash.cleanupAsyncDecodeCache
            cleanupAsyncDecodeCache();
        end
    end

    % =========================================================================
    % v-fixH1/H2: moved the onCleanup restore helpers to private methods.
    %   a local function outside classdef fails to directly set private properties (IsUpdating /
    %   DraggedFromVideo), where try/catch silently swallowed the problem - this closes it.
    %   every cleanup body is wrapped in its own try/catch + logCaught so no exception
    %   leaks outside the onCleanup callback.
    % =========================================================================
    methods (Access = private)
        function restoreVideoSyncFlags(app, fIdx, prevDraggedFromVideo, prevUpdating)
            try
                if isempty(app) || ~isvalid(app), return; end
                if app.IsDeleting, return; end
                app.DraggedFromVideo = logical(prevDraggedFromVideo);
                if fIdx >= 1 && fIdx <= numel(app.IsUpdating)
                    app.IsUpdating(fIdx) = logical(prevUpdating);
                end
            catch ME
                try
                    app.logCaught(ME, 'restoreVideoSyncFlags');
                catch
                end
            end
        end

        function restoreIsUpdating(app, fIdx, prevValue)
            try
                if isempty(app) || ~isvalid(app), return; end
                if app.IsDeleting, return; end
                if fIdx >= 1 && fIdx <= numel(app.IsUpdating)
                    app.IsUpdating(fIdx) = logical(prevValue);
                end
            catch ME
                try
                    app.logCaught(ME, 'restoreIsUpdating');
                catch
                end
            end
        end
    end
end

% =========================================================================
% [V3.19 (1)] external function: async decoding for the parfeval worker
% parfeval cannot take a class method directly, so define a file-level function
% the worker creates its own VideoReader, decodes, and returns the frame
% =========================================================================
% =========================================================================
% [V3.21 #2-A / V3.22 #4] persistent VideoReader worker function
% - recreate VR every call(50ms) -> reuse via persistent(3ms)
% - recreate VR only when the file path changes
% - maxSlots: passed by the caller (default 4) - per-channel independent VR
% =========================================================================
function out = ternary(cond, ifTrue, ifFalse)
    % Simple ternary helper for UI Enable / mode string toggles.
    if cond, out = ifTrue; else, out = ifFalse; end
end

function img = asyncDecodeFramePersistent(filePath, frameNo, fps, maxSlots)
    % [PATCH] multi-slot LRU cache (per-channel independent VR, prevents file lock/memory leak)
    persistent cache   % struct array: .path, .sig, .vr, .lastUse
    img = [];
    if nargin < 4 || isempty(maxSlots) || maxSlots < 1
        maxSlots = 4;
    end
    maxSlots = max(1, round(double(maxSlots)));

    % [PATCH] cleanup branch: delete all slot VRs then fully reset the cache
    if ischar(filePath) && strcmp(filePath, '__CLEANUP__')
        asyncClearDecodeCache(cache);
        cache = [];   % v-crit1: full persistent reset (prevents leftover stale VR struct)
        return;
    end

    try
        fileSig = asyncDecodeFileSignature(filePath);
        if isempty(fileSig), return; end
        if isempty(cache), cache = struct('path',{},'sig',{},'vr',{},'lastUse',{}); end
        if ~isempty(cache) && ~isfield(cache, 'sig')
            asyncClearDecodeCache(cache);
            cache = struct('path',{},'sig',{},'vr',{},'lastUse',{});
        end

        % Same path can point to a replaced AVI. Drop stale readers before
        % the normal lookup so workers never decode from an old file handle.
        for k = numel(cache):-1:1
            if strcmp(cache(k).path, filePath) && ~strcmp(cache(k).sig, fileSig)
                asyncDeleteVideoReaderQuietly(cache(k).vr);
                cache(k) = [];
            end
        end

        % slot search
        idx = 0;
        for k = 1:numel(cache)
            if strcmp(cache(k).path, filePath) && strcmp(cache(k).sig, fileSig) && ...
                    ~isempty(cache(k).vr) && isvalid(cache(k).vr)
                idx = k; break;
            end
        end

        if idx == 0
            % LRU eviction (delete the oldest slot when full)
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
                asyncDeleteVideoReaderQuietly(cache(victim).vr);
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

function asyncClearDecodeCache(cache)
    if isempty(cache), return; end
    for k = 1:numel(cache)
        if isfield(cache, 'vr')
            asyncDeleteVideoReaderQuietly(cache(k).vr);
        end
    end
end

function asyncDeleteVideoReaderQuietly(vr)
    try
        if ~isempty(vr) && isvalid(vr)
            delete(vr);
        end
    catch
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

% [PATCH] worker persistent cache cleanup function
% - calls the cleanup branch of asyncDecodeFramePersistent to delete all VRs + persistent clear
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
