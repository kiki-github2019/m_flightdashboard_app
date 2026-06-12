function auto_test_runner(varargin)
%AUTO_TEST_RUNNER  FlightDataDashboard 보드 off/on + 패널 토글 50 케이스 회귀.
%
%   결과 저장 경로 (자동 탐지):
%       ~/MATLAB Drive/cowork_auto_test
%       %USERPROFILE%/MATLAB Drive/cowork_auto_test
%       /MATLAB Drive/cowork_auto_test
%       <pwd>/cowork_auto_test (최종 폴백)
%
%   생성 파일:
%       index.md, caseNN.md, caseNN_stepMM.png
%
%   사전 조건:
%       FlightDataDashboard.m, flight_data1.dat, flight_data2.dat 가 현재 폴더에 있을 것.
%       AVI 파일은 LoadAvi='lazy' 일 때 E04 같은 sync 케이스만 사용함.
%
%   옵션 (MATLAB Online OOM 회피용):
%       'Start' (default 1)    : 시작 케이스 번호
%       'End'   (default Inf)  : 종료 케이스 번호 (양 끝 포함)
%       'Order' (default 'asc'): 'asc' | 'desc' — 실행 순서
%       'Skip'  (default [])   : 스킵할 케이스 번호 벡터
%       'CaseList' (default []): 명시적 실행 순서 벡터 (지정 시 Start/End/Order 무시)
%       'LoadAvi' (default 'lazy') : 'lazy' | 'always' | 'never'
%       'CaptureMode' (default 'baseline') : 'all' | 'baseline' | 'fail' | 'none'
%       'CaptureScale' (default 0.60) : PNG 축소 비율, 0 < value <= 1
%
%   사용:
%       >> auto_test_runner                                       % 전체, asc
%       >> auto_test_runner('Start',1,'End',10)                   % 1~10 만 실행
%       >> auto_test_runner('Order','desc','Skip',2)              % 전체 desc, case 2 skip
%       >> auto_test_runner('Start',65,'End',3,'Order','desc')    % 65→3 역순
%       >> auto_test_runner('CaseList',[65:-1:3 1])               % 명시적 순서
%       >> auto_test_runner('CaseList',2,'CaptureMode','none','LoadAvi','never')  % case 2 단독 빠른 실행
%       >> auto_test_runner('LoadAvi','never')                    % AVI 일체 미로드
%       >> auto_test_runner('CaptureMode','all','CaptureScale',1) % 원본 캡처
%       2026-06-06 1700 claude code recommandation
%       >> auto_test_runner('OutputDir','D:\flightdashboard\1. 최초-MVC 전\cowork auto test', ...
%                 'LoadAvi','never','CaptureMode','fail','CaptureScale',0.6, ...
%                 'OnlineSafeMode',true,'Order','desc','Skip',[2 5 6 37 48])
    p = inputParser;
    p.addParameter('Start',   1,      @(x) isnumeric(x) && isscalar(x) && x >= 1);
    p.addParameter('End',     Inf,    @(x) isnumeric(x) && isscalar(x));
    p.addParameter('Order',   'asc',  @(s) ischar(s) || isstring(s));
    p.addParameter('Skip',    [],     @(x) isempty(x) || (isnumeric(x) && isvector(x)));
    p.addParameter('CaseList',[],     @(x) isempty(x) || (isnumeric(x) && isvector(x)));
    p.addParameter('LoadAvi', 'lazy', @(s) ischar(s) || isstring(s));
    p.addParameter('CaptureMode', 'baseline', @(s) ischar(s) || isstring(s));
    p.addParameter('CaptureScale', 0.60, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0 && x <= 1);
    p.addParameter('OnlineSafeMode', false, @(x) islogical(x) || (isnumeric(x) && isscalar(x)));
    p.addParameter('OutputDir', '', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    opts = p.Results;
    loadAviMode = lower(char(opts.LoadAvi));
    if ~ismember(loadAviMode, {'lazy', 'always', 'never'})
        error('auto_test_runner:BadLoadAvi', 'LoadAvi must be lazy, always, or never.');
    end
    captureMode = lower(char(opts.CaptureMode));
    if ~ismember(captureMode, {'all', 'baseline', 'fail', 'none'})
        error('auto_test_runner:BadCaptureMode', 'CaptureMode must be all, baseline, fail, or none.');
    end
    orderMode = lower(char(opts.Order));
    if ~ismember(orderMode, {'asc', 'desc'})
        error('auto_test_runner:BadOrder', 'Order must be ''asc'' or ''desc''.');
    end
    captureScale = double(opts.CaptureScale);
    safeWarnings = {};
    % v3 P9-strengthened: OnlineSafeMode — 실질 보호 (clamp + 강한 경고)
    if logical(opts.OnlineSafeMode)
        if captureScale > 0.6
            safeWarnings{end + 1} = sprintf('OnlineSafeMode: CaptureScale %.2f → 0.6 자동 클램프', captureScale);
            captureScale = 0.6;
        end
        if strcmp(captureMode, 'all') && strcmp(loadAviMode, 'always')
            safeWarnings{end + 1} = ['OnlineSafeMode: CaptureMode=all + LoadAvi=always 광범위 실행은 ' ...
                'MATLAB Online hard-crash 위험. 권장: LoadAvi=never/lazy, CaptureMode=fail/none.'];
        end
        if strcmp(loadAviMode, 'always')
            safeWarnings{end + 1} = 'OnlineSafeMode: LoadAvi=always 는 video-specific 케이스에만 권장 (CaseList 명시).';
        end
        for sw = 1:numel(safeWarnings)
            warning('auto_test_runner:OnlineSafeMode', '%s', safeWarnings{sw});
        end
    end
    captureOpts = struct('mode', captureMode, 'scale', captureScale);

    % v3-audit G: OutputDir 명시 시 그대로 사용, 아니면 자동 탐지
    if ~isempty(char(opts.OutputDir))
        outDir = char(opts.OutputDir);
    else
        outDir = i_resolveOutputDir();
    end
    if ~isfolder(outDir), mkdir(outDir); end
    fprintf('[auto_test_runner] output dir: %s\n', outDir);

    cases   = i_buildCaseMatrix();
    nCases  = numel(cases);
    iStart  = max(1, round(opts.Start));
    iEnd    = min(nCases, round(opts.End));
    caseOrder = i_buildCaseOrder(nCases, iStart, iEnd, orderMode, opts.Skip, opts.CaseList);
    % v-chunk: 10 케이스 단위 progress/index 분할. 파일명에 시작~끝 케이스 번호 포함.
    chunkSize = 10;
    chunkStartIdx = 1;          % 현 chunk 의 caseOrder 시작 인덱스
    progressFile = '';          % 현 chunk 의 progress 파일
    indexFile = '';             % 현 chunk 의 index 파일
    pendingSafeWarnings = safeWarnings;

    results = repmat(struct('id', 0, 'group', '', 'title', '', ...
                            'status', 'SKIPPED', 'steps', 0, 'error', ''), nCases, 1);
    for i = 1:nCases
        results(i).id    = i;
        results(i).group = cases(i).group;
        results(i).title = cases(i).title;
    end

    for ii = 1:numel(caseOrder)
        i = caseOrder(ii);
        tc = cases(i);
        % v-chunk: 새 chunk 시작 시 progress/index 파일 신규 생성
        if ii == chunkStartIdx
            chunkEndIdx = min(ii + chunkSize - 1, numel(caseOrder));
            firstCase = caseOrder(ii);
            lastCase  = caseOrder(chunkEndIdx);
            lo = min(firstCase, lastCase); hi = max(firstCase, lastCase);
            progressFile = fullfile(outDir, sprintf('progress_%03d-%03d.md', lo, hi));
            indexFile    = fullfile(outDir, sprintf('index_%03d-%03d.md',    lo, hi));
            i_initProgressMd(progressFile, opts, nCases, caseOrder(ii:chunkEndIdx));
            for sw = 1:numel(pendingSafeWarnings)
                i_appendProgressMd(progressFile, 0, 0, 'ONLINE_SAFE_WARN', pendingSafeWarnings{sw});
            end
            pendingSafeWarnings = {};   % 첫 chunk 에만 기록
        end
        fprintf('\n[%02d/%02d] %s | %s\n', i, nCases, tc.group, tc.title);
        i_appendProgressMd(progressFile, i, 0, 'START', sprintf('%s | %s', tc.group, tc.title));

        if tc.requireAvi && strcmp(loadAviMode, 'never')
            r = struct('id', i, 'group', tc.group, 'title', tc.title, ...
                       'status', 'SKIPPED', 'steps', 0, ...
                       'error', 'LoadAvi=never: AVI-required case skipped');
            results(i) = r;
            i_writeCaseMd(outDir, i, tc, r);
            i_appendProgressMd(progressFile, i, 0, 'SKIPPED', r.error);
            fprintf('  SKIPPED: %s\n', r.error);
            continue;
        end

        i_appendProgressMd(progressFile, i, 0, 'CLEANUP_BEFORE', 'closing leftover dashboard figures');
        cleanupStats = i_aggressiveCleanup();   % kill any leftover figures/timers/dialogs
        i_appendProgressMd(progressFile, i, 0, 'CLEANUP_BEFORE_DONE', i_cleanupSummary(cleanupStats));

        app = [];
        try
            needAvi = strcmp(loadAviMode, 'always') || ...
                      (strcmp(loadAviMode, 'lazy') && tc.requireAvi);
            i_appendProgressMd(progressFile, i, 0, 'SETUP_START', sprintf('needAvi=%d', needAvi));
            app = i_setupFreshApp(needAvi);
            i_appendProgressMd(progressFile, i, 0, 'SETUP_DONE', 'fresh app ready');
            r   = i_runCase(app, tc, i, outDir, progressFile, captureOpts);
        catch ME
            r = struct('id', i, 'group', tc.group, 'title', tc.title, ...
                       'status', 'SETUP_FAIL', 'steps', 0, 'error', i_errorReport(ME));
            i_appendProgressMd(progressFile, i, 0, 'SETUP_FAIL', r.error);
            fprintf('  SETUP_FAIL: %s\n', ME.message);
        end

        try
            if ~isempty(app) && isvalid(app)
                i_appendProgressMd(progressFile, i, r.steps, 'CLEANUP_APP_START', 'closing app dialogs and main figure');
                i_closeAppDialogs(app);
                i_settleUi(1);
                delete(app);
                i_appendProgressMd(progressFile, i, r.steps, 'CLEANUP_APP_DONE', 'app deleted');
            end
        catch ME
            i_appendProgressMd(progressFile, i, r.steps, 'CLEANUP_WARN', ME.message);
            fprintf('  CLEANUP_WARN: %s\n', ME.message);
        end
        i_appendProgressMd(progressFile, i, r.steps, 'CLEANUP_AFTER_START', 'aggressive cleanup after case');
        cleanupStats = i_aggressiveCleanup();
        i_settleUi(2);            % let MATLAB GC/layout settle before next case
        i_appendProgressMd(progressFile, i, r.steps, 'CLEANUP_AFTER_DONE', i_cleanupSummary(cleanupStats));

        results(i) = r;
        i_writeCaseMd(outDir, i, tc, r);
        i_appendProgressMd(progressFile, i, r.steps, r.status, r.error);
        % v-chunk: 현 chunk 의 index 즉시 갱신 (중간 crash 대비)
        chunkCases = caseOrder(chunkStartIdx:chunkEndIdx);
        try
            i_writeIndexMd(outDir, results(chunkCases), indexFile, progressFile);
        catch
        end
        % v-chunk: chunk 끝 도달 시 finalize + 다음 chunk 준비
        if ii == chunkEndIdx
            chunkSubset = results(chunkCases);
            i_appendProgressMd(progressFile, 0, 0, 'CHUNK_FINISHED', sprintf('PASS=%d FAIL=%d', ...
                sum(strcmp({chunkSubset.status}, 'PASS')), sum(strcmp({chunkSubset.status}, 'FAIL'))));
            chunkStartIdx = ii + 1;
        end
    end

    nPass = sum(strcmp({results.status}, 'PASS'));
    nFail = sum(strcmp({results.status}, 'FAIL'));
    nExc  = sum(strcmp({results.status}, 'EXCEPTION'));
    nCap  = sum(strcmp({results.status}, 'CAPTURE_FAIL'));
    nSF   = sum(strcmp({results.status}, 'SETUP_FAIL'));
    nSkip = sum(strcmp({results.status}, 'SKIPPED'));
    fprintf('\nDone. %d cases. PASS=%d FAIL=%d EXCEPTION=%d CAPTURE_FAIL=%d SETUP_FAIL=%d SKIPPED=%d\n', ...
        nCases, nPass, nFail, nExc, nCap, nSF, nSkip);
    fprintf('See: %s\\index_*.md (chunked by 10)\n', outDir);
end

% =========================================================================
% Output dir resolution
% =========================================================================
function outDir = i_resolveOutputDir()
    % v-local: 로컬 MATLAB 환경 전용. 프로젝트 내 cowork auto test 폴더 우선.
    candidates = {};
    candidates{end + 1} = fullfile(pwd, 'cowork auto test');
    candidates{end + 1} = fullfile(pwd, 'cowork_auto_test');
    try
        candidates{end + 1} = fullfile(userpath, 'cowork_auto_test');
    catch
    end
    for k = 1:numel(candidates)
        parent = fileparts(candidates{k});
        if isfolder(parent)
            outDir = candidates{k};
            return;
        end
    end
    outDir = fullfile(pwd, 'cowork_auto_test');
end

% =========================================================================
% Aggressive cleanup (MATLAB Online OOM mitigation)
% =========================================================================
function stats = i_aggressiveCleanup()
    stats = struct('figuresBefore', 0, 'figuresDeleted', 0, 'figuresAfter', 0, ...
                   'timersBefore', 0, 'timersDeleted', 0, 'timersAfter', 0);
    stats.figuresBefore = i_countDashboardFigures();
    stats.timersBefore = i_countDashboardTimers();
    % Close dashboard-owned figures left by a failed case. Use delete, not
    % close, so modal close confirmation cannot block the next test.
    try
        figs = findall(groot, 'Type', 'figure');
        for k = 1:numel(figs)
            try
                if i_isDashboardRelatedFigure(figs(k))
                    delete(figs(k));
                    stats.figuresDeleted = stats.figuresDeleted + 1;
                end
            catch
            end
        end
    catch
    end
    stats.timersDeleted = i_cleanupDashboardTimers();
    i_settleUi(1);
    stats.figuresAfter = i_countDashboardFigures();
    stats.timersAfter = i_countDashboardTimers();
end

function i_closeAppDialogs(app)
    % Best-effort cleanup for modeless edit/video control dialogs.
    if isempty(app), return; end
    try
        if ~isvalid(app), return; end
    catch
        return;
    end

    try
        for fIdx = 1:min(2, numel(app.UI))
            if isfield(app.UI(fIdx), 'vidControlDialog')
                i_safeDeleteHandle(app.UI(fIdx).vidControlDialog);
            end
        end
    catch
    end

    mainFig = [];
    try
        mainFig = app.UIFigure;
    catch
    end

    try
        figs = findall(groot, 'Type', 'figure');
        for k = 1:numel(figs)
            try
                if ~isempty(mainFig) && isvalid(mainFig) && isequal(figs(k), mainFig)
                    continue;
                end
                if i_isDashboardRelatedFigure(figs(k))
                    delete(figs(k));
                end
            catch
            end
        end
    catch
    end
end

function i_safeDeleteHandle(h)
    try
        if ~isempty(h) && isvalid(h)
            delete(h);
        end
    catch
    end
end

function tf = i_isDashboardRelatedFigure(fig)
    tf = false;
    try
        if isempty(fig) || ~isvalid(fig), return; end
        keys = {'FlightDataDashboard', 'Flight Data', '비행 데이터', ...
                '비행경로', '해안선 정보', '설정/프로젝트', ...
                'AVI 제어', 'AVI 파일 열기', '비행시간 동기'};
        if isprop(fig, 'Name') && i_containsAny(char(fig.Name), keys)
            tf = true;
            return;
        end
        kids = findall(fig);
        for iKid = 1:numel(kids)
            try
                if isprop(kids(iKid), 'Text') && i_containsAny(char(kids(iKid).Text), keys)
                    tf = true;
                    return;
                end
            catch
            end
        end
    catch
        tf = false;
    end
end

function nDeleted = i_cleanupDashboardTimers()
    % Never delete every MATLAB timer: MATLAB Online may have unrelated
    % timers from other apps. Limit cleanup to dashboard-owned callbacks.
    nDeleted = 0;
    try
        timers = timerfindall;
    catch
        return;
    end

    for k = 1:numel(timers)
        try
            t = timers(k);
            if isempty(t) || ~isvalid(t), continue; end
            if i_isDashboardRelatedTimer(t)
                try
                    stop(t);
                catch
                end
                delete(t);
                nDeleted = nDeleted + 1;
            end
        catch
        end
    end
end

function n = i_countDashboardFigures()
    n = 0;
    try
        figs = findall(groot, 'Type', 'figure');
        for k = 1:numel(figs)
            try
                if i_isDashboardRelatedFigure(figs(k))
                    n = n + 1;
                end
            catch
            end
        end
    catch
        n = 0;
    end
end

function n = i_countDashboardTimers()
    n = 0;
    try
        timers = timerfindall;
        for k = 1:numel(timers)
            try
                t = timers(k);
                if ~isempty(t) && isvalid(t) && i_isDashboardRelatedTimer(t)
                    n = n + 1;
                end
            catch
            end
        end
    catch
        n = 0;
    end
end

function txt = i_cleanupSummary(stats)
    try
        txt = sprintf('figures %d->%d deleted=%d; timers %d->%d deleted=%d', ...
            stats.figuresBefore, stats.figuresAfter, stats.figuresDeleted, ...
            stats.timersBefore, stats.timersAfter, stats.timersDeleted);
        if stats.figuresAfter > 0 || stats.timersAfter > 0
            txt = sprintf('%s; residual dashboard resources remain', txt);
        end
    catch
        txt = 'cleanup summary unavailable';
    end
end

function tf = i_isDashboardRelatedTimer(t)
    try
        keys = {'FlightDataDashboard', 'applyPendingDialogChanges', 'saveProjectAutosave', ...
            'FlightPlay', 'FlightDataDashboard:FlightPlay', 'FlightDataDashboard_FlightPlay', 'onFlightPlayTimer'};
        tf = i_containsAny(i_timerDescriptor(t), keys);
    catch
        tf = false;
    end
end

function txt = i_timerDescriptor(t)
    props = {'Name', 'Tag', 'TimerFcn', 'StopFcn', 'ErrorFcn'};
    parts = cell(1, numel(props));
    n = 0;
    for p = 1:numel(props)
        try
            if isprop(t, props{p})
                n = n + 1;
                parts{n} = i_valueToText(t.(props{p}));
            end
        catch
        end
    end
    if n == 0
        txt = '';
    else
        txt = strjoin(parts(1:n), ' ');
    end
end

function txt = i_valueToText(v)
    txt = '';
    try
        if isempty(v)
            return;
        elseif isa(v, 'function_handle')
            txt = func2str(v);
        elseif iscell(v)
            parts = cell(1, numel(v));
            for k = 1:numel(v)
                parts{k} = i_valueToText(v{k});
            end
            txt = strjoin(parts, ' ');
        elseif ischar(v) || isstring(v)
            txt = char(v);
        else
            txt = class(v);
        end
    catch
        txt = '';
    end
end

function tf = i_containsAny(txt, keys)
    tf = false;
    for k = 1:numel(keys)
        if contains(txt, keys{k}, 'IgnoreCase', true)
            tf = true;
            return;
        end
    end
end

function i_settleUi(n)
    if nargin < 1 || isempty(n), n = 1; end
    for k = 1:max(1, n)
        try
            drawnow limitrate;
        catch
            drawnow;
        end
        pause(0.08);
    end
end

function txt = i_errorReport(ME)
    try
        txt = getReport(ME, 'extended', 'hyperlinks', 'off');
    catch
        try
            txt = sprintf('%s: %s', ME.identifier, ME.message);
            for k = 1:numel(ME.stack)
                txt = sprintf('%s\n  at %s:%d', txt, ME.stack(k).name, ME.stack(k).line);
            end
        catch
            txt = ME.message;
        end
    end
end

% =========================================================================
% Fresh app bootstrap (no file pickers)
% =========================================================================
function app = i_setupFreshApp(needAvi)
    if nargin < 1, needAvi = false; end

    app = FlightDataDashboard();
    i_settleUi(1);

    dataFiles = {1, 'flight_data1.dat'; 2, 'flight_data2.dat'};
    for k = 1:size(dataFiles, 1)
        fIdx  = dataFiles{k, 1};
        fpath = dataFiles{k, 2};
        if ~isfile(fpath)
            error('AutoTest:MissingDataFile', 'Missing required data file: %s', fpath);
        end
        try
            app.testHook('parseFlightData', fIdx, fpath);
            app.testHook('setupDataUI', fIdx);
            app.testHook('calculateBounds', fIdx);
            app.testHook('initPlots', fIdx);
            app.testHook('updateDashboard', fIdx, 1);
        catch ME
            error('AutoTest:DataLoadFailed', 'Data load failed for flight %d: %s', fIdx, ME.message);
        end
    end

    if needAvi
        aviFiles = {1, 'flight_data1_fps35.avi'; 2, 'flight_data2_fps7.avi'};
        for k = 1:size(aviFiles, 1)
            fIdx  = aviFiles{k, 1};
            fpath = aviFiles{k, 2};
            if ~isfile(fpath)
                error('AutoTest:MissingAviFile', 'Missing required AVI file: %s', fpath);
            end
            try
                ok = app.testHook('loadAviFileFromPath', fIdx, fpath, struct('promptOnSync', false));
                if isempty(ok) || ~ok
                    error('loadAviFileFromPath returned false');
                end
            catch ME
                error('AutoTest:AviLoadFailed', 'AVI load failed for flight %d: %s', fIdx, ME.message);
            end
        end
    end
    i_settleUi(2);
end

% =========================================================================
% Per-case runner
% =========================================================================
function r = i_runCase(app, tc, caseIdx, outDir, progressFile, captureOpts)
    r = struct('id', caseIdx, 'group', tc.group, 'title', tc.title, ...
               'status', 'PASS', 'steps', 0, 'error', '');

    i_settleUi(1);
    try
        i_appendProgressMd(progressFile, caseIdx, 1, 'BASELINE_CAPTURE_START', 'capture initial dashboard');
        if i_capture(app, outDir, caseIdx, 1, captureOpts, 'baseline')
            i_appendProgressMd(progressFile, caseIdx, 1, 'BASELINE_CAPTURE_DONE', 'baseline image saved');
        else
            i_appendProgressMd(progressFile, caseIdx, 1, 'BASELINE_CAPTURE_SKIPPED', captureOpts.mode);
        end
    catch ME
        r.status = 'CAPTURE_FAIL';
        r.error = sprintf('baseline capture: %s\n%s', ME.message, i_errorReport(ME));
        i_appendProgressMd(progressFile, caseIdx, 1, r.status, r.error);
        fprintf('  CAPTURE_FAIL: %s\n', ME.message);
        return;
    end
    r.steps = 1;

    st = app.testHook('getTestState');
    exp = i_expectedFromState(st);
    [ok, msg] = i_validateState(st, exp);
    if ~ok
        r.status = 'FAIL';
        r.error = sprintf('baseline validation: %s', msg);
        try
            if i_capture(app, outDir, caseIdx, r.steps, captureOpts, 'fail')
                i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_DONE', 'baseline validation');
            else
                i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_SKIPPED', captureOpts.mode);
            end
        catch ME
            i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_WARN', ME.message);
        end
        i_appendProgressMd(progressFile, caseIdx, r.steps, r.status, r.error);
        fprintf('  FAIL: %s\n', r.error);
        return;
    end

    for j = 1:numel(tc.actions)
        act = tc.actions{j};
        try
            beforeState = app.testHook('getTestState');
            i_appendProgressMd(progressFile, caseIdx, j + 1, 'ACTION_START', act.label);
            i_applyAction(app, act, beforeState, outDir, caseIdx, j + 1, captureOpts);
            exp = i_updateExpectedState(exp, act, beforeState);
            i_appendProgressMd(progressFile, caseIdx, j + 1, 'ACTION_DONE', act.label);
        catch ME
            r.status = 'EXCEPTION';
            r.error  = sprintf('step %d (%s): %s\n%s', j + 1, act.label, ME.message, i_errorReport(ME));
            i_appendProgressMd(progressFile, caseIdx, j + 1, r.status, r.error);
            fprintf('  EXCEPTION at step %d: %s\n', j + 1, ME.message);
        end
        i_settleUi(1);
        r.steps = r.steps + 1;
        try
            i_appendProgressMd(progressFile, caseIdx, r.steps, 'CAPTURE_START', act.label);
            captureReason = 'step';
            if strcmp(r.status, 'EXCEPTION')
                captureReason = 'fail';
            end
            if i_capture(app, outDir, caseIdx, r.steps, captureOpts, captureReason)
                i_appendProgressMd(progressFile, caseIdx, r.steps, 'CAPTURE_DONE', act.label);
            else
                i_appendProgressMd(progressFile, caseIdx, r.steps, 'CAPTURE_SKIPPED', captureOpts.mode);
            end
        catch ME
            r.status = 'CAPTURE_FAIL';
            r.error  = sprintf('step %d (%s): %s\n%s', j + 1, act.label, ME.message, i_errorReport(ME));
            i_appendProgressMd(progressFile, caseIdx, r.steps, r.status, r.error);
            fprintf('  CAPTURE_FAIL at step %d: %s\n', j + 1, ME.message);
        end
        if strcmp(r.status, 'EXCEPTION'), break; end
        if strcmp(r.status, 'CAPTURE_FAIL'), break; end

        st = app.testHook('getTestState');
        [ok, msg] = i_validateState(st, exp);
        if ~ok
            r.status = 'FAIL';
            r.error = sprintf('step %d (%s): %s', j + 1, act.label, msg);
            try
                if i_capture(app, outDir, caseIdx, r.steps, captureOpts, 'fail')
                    i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_DONE', act.label);
                else
                    i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_SKIPPED', captureOpts.mode);
                end
            catch ME
                i_appendProgressMd(progressFile, caseIdx, r.steps, 'FAIL_CAPTURE_WARN', ME.message);
            end
            i_appendProgressMd(progressFile, caseIdx, r.steps, r.status, r.error);
            fprintf('  FAIL at step %d: %s\n', j + 1, msg);
            break;
        end
        i_appendProgressMd(progressFile, caseIdx, r.steps, 'VALIDATION_PASS', act.label);
    end
end

function i_applyAction(app, act, beforeState, outDir, caseIdx, stepIdx, captureOpts)
    switch act.fn
        case 'togglePanel'
            fIdx = act.args{1};
            if beforeState.BoardOffState(fIdx)
                return;
            end
            app.testHook('pushPanelToggleButton', act.args{:});
        case 'toggleBoardVisibility'
            fIdx = act.args{1};
            activeOff = find(beforeState.BoardOffState, 1);
            if ~isempty(activeOff) && activeOff ~= fIdx
                return;
            end
            app.testHook('pushBoardToggleButton', act.args{:});
        case 'ensureNoBoardOff'
            activeOff = find(beforeState.BoardOffState, 1);
            if ~isempty(activeOff)
                app.testHook('pushBoardToggleButton', activeOff);
            end
        case 'boardOffAddPlotTab'
            offIdx = act.args{1};
            if ~beforeState.BoardOffState(offIdx), return; end
            app.testHook('boardOffAddPlotTab', act.args{:});
        case 'boardOffClearCurrentTab'
            offIdx = act.args{1};
            if ~beforeState.BoardOffState(offIdx), return; end
            app.testHook('boardOffClearCurrentTab', act.args{:});
        case 'boardOffPlotSelectedVariable'
            offIdx    = act.args{1};
            sourceIdx = 3 - offIdx;
            if ~beforeState.BoardOffState(offIdx), return; end
            if ~isnan(act.row)
                app.testHook('setSelectedRow', sourceIdx, act.row);
            end
            app.testHook('boardOffPlotSelectedVariable', offIdx);
        case 'applyTimeChange'
            app.testHook('applyTimeChange', act.args{:});
        case {'toggleFlightPlayControlPanel','moveFlightDataFrame','refreshFlightPlayControlPanel', ...
              'handleFlightPlaySliderChange','handleFlightPlayFrameInputChange','handleFlightPlayTimeInputChange', ...
              'startFlightPlay','stopFlightPlay'}
            app.testHook(act.fn, act.args{:});
        case 'setFlightDataSync'
            app.testHook('setFlightDataSync', act.args{:});
        case 'applyLayoutPreset'
            app.testHook('applyLayoutPreset', act.args{:});
        case 'setBodyRowSplitRatio'
            app.testHook('setBodyRowSplitRatio', act.args{:});
        case 'simulateColumnSplitterDrag'
            app.testHook('simulateColumnSplitterDrag', act.args{:});
        case 'saveCurrentLayoutPreset'
            app.testHook('saveCurrentLayoutPreset', act.args{:});
        case 'applySavedLayoutPreset'
            app.testHook('applySavedLayoutPreset', act.args{:});
        case 'deleteSavedLayoutPreset'
            app.testHook('deleteSavedLayoutPreset', act.args{:});
        case 'roundTripProjectLayoutState'
            app.testHook('roundTripProjectLayoutState');
        case 'setVideoSync'
            app.testHook('setVideoSync', act.args{:});
        case 'loadProjectFixture'
            projectPath = i_createProjectFixture(app, char(act.args{1}), outDir);
            app.testHook('autoLoadProjectFromFile', projectPath);
        case 'loadProjectFixtureSafeFailure'
            projectPath = i_createProjectFixture(app, char(act.args{1}), outDir);
            app.testHook('loadProjectFile', projectPath);
        case 'openProjectFixtureInEditDialog'
            projectPath = i_createProjectFixture(app, char(act.args{1}), outDir);
            app.testHook('openEditDialog');
            app.testHook('editDialogOpenProjectFromPath', projectPath);
        case 'toggleVideoControlDialog'
            app.testHook('toggleVideoControlDialog', act.args{:});
        case 'goToFrame'
            app.testHook('goToFrame', act.args{:});
        case 'captureRequiredPanel'
            i_captureRequiredPanel(app, outDir, caseIdx, stepIdx, captureOpts, act.args{:});
        % v-runner: EditDialog dispatch (모든 boardOff 상태에서 허용)
        case {'openEditDialog','closeEditDialog','applyPendingDialogChanges', ...
              'editDialogSaveProject','editDialogSaveProjectAs','editDialogApplyOptionDraft', ...
              'capturePlotConfigAndRefresh','editDialogRebuildPlots','editDialogApplyPlotProps', ...
              'editDialogSyncTabXLimAll','editDialogSyncSelectedPlotXLimAll'}
            app.testHook(act.fn);
        case {'editDialogToggleXAuto','editDialogToggleYAuto','switchEditDialogTab'}
            app.testHook(act.fn, act.args{:});
        otherwise
            error('AutoTest:UnknownAction', 'Unknown action: %s', act.fn);
    end
end

function exp = i_expectedFromState(st)
    side = struct('attitude', true, 'map', true, 'mapOnly', true, 'altOnly', true, ...
        'video', true, 'info', true, 'dataView', true);
    exp = struct();
    exp.boardOff = logical(st.BoardOffState);
    exp.panel = repmat(side, 1, 2);
    exp.currentIndex = NaN(1, 2);
    exp.plotTabCount = zeros(1, 2);
    exp.totalPlotCount = zeros(1, 2);
    exp.selectedTabPlotCount = zeros(1, 2);
    exp.minPlotTabCount = zeros(1, 2);
    exp.minTotalPlotCount = zeros(1, 2);
    exp.expectSelectedTabClear = false(1, 2);
    exp.videoSynced = false(1, 2);
    exp.requireVideoFrameMove = false(1, 2);
    exp.videoFrameBeforeMove = NaN(1, 2);
    exp.summaryVisible = false(1, 2);
    exp.sourceColumnsHidden = false(1, 2);
    exp.currentLayoutPreset = char(st.CurrentLayoutPreset);
    exp.bodyRowSplitRatio = st.BodyRowSplitRatio;
    exp.minUserLayoutPresetCount = st.UserLayoutPresetCount;
    exp.requireColumnWidthChange = false(1, 2);
    exp.columnWidthBefore = cell(1, 2);
    exp.flightPlayVisible = false(1, 2);
    exp.requireFlightPlay = false(1, 2);
    exp.flightPlayActive = false(1, 2);
    exp.projectRestoreRequired = false;
    exp.projectRestoreKind = '';
    exp.projectSafeFailureRequired = false;
    exp.projectSafeFailureKind = '';
    exp.editDialogExpectedVisible = false;
    exp.requireVideoControl = false(1, 2);
    exp.videoControlVisible = false(1, 2);
    exp.videoFrameExpected = NaN(1, 2);
    exp.minRequiredPanelCaptures = 0;
    exp.savedPresetState = struct();
    for fIdx = 1:2
        b = st.boards(fIdx);
        exp.panel(fIdx) = b.PanelVisible;
        exp.currentIndex(fIdx) = b.currentIndex;
        exp.plotTabCount(fIdx) = b.plotTabCount;
        exp.totalPlotCount(fIdx) = b.totalPlotCount;
        exp.selectedTabPlotCount(fIdx) = b.selectedTabPlotCount;
        exp.minPlotTabCount(fIdx) = b.plotTabCount;
        exp.minTotalPlotCount(fIdx) = b.totalPlotCount;
        exp.videoSynced(fIdx) = b.videoSync.IsSynced;
        exp.summaryVisible(fIdx) = b.boardOffPanelVisible;
        exp.sourceColumnsHidden(fIdx) = b.infoColumnHidden && b.plotColumnHidden && b.splitterColumnHidden;
        if isfield(b, 'flightPlay')
            exp.flightPlayVisible(fIdx) = logical(b.flightPlay.panelVisible);
            exp.flightPlayActive(fIdx) = logical(b.flightPlay.playActive);
        end
        if isfield(st, 'vidControlDialogVisible')
            exp.videoControlVisible(fIdx) = logical(st.vidControlDialogVisible(fIdx));
        end
    end
end

function exp = i_updateExpectedState(exp, act, beforeState)
    switch act.fn
        case 'togglePanel'
            fIdx = act.args{1};
            if beforeState.BoardOffState(fIdx)
                return;
            end
            exp.currentLayoutPreset = 'custom';
            name = char(act.args{2});
            if strcmp(name, 'map')
                % v3 P1: 앱 btnMap 콜백은 togglePanel('mapOnly') — mapOnly 만 토글.
                % 'map' alias 도 mapOnly 만 토글하도록 일치시킴. altOnly 는 불변.
                exp.panel(fIdx).mapOnly = ~exp.panel(fIdx).mapOnly;
                exp.panel(fIdx).map = exp.panel(fIdx).mapOnly || exp.panel(fIdx).altOnly;
            else
                exp.panel(fIdx).(name) = ~exp.panel(fIdx).(name);
                if strcmp(name, 'mapOnly') || strcmp(name, 'altOnly')
                    exp.panel(fIdx).map = exp.panel(fIdx).mapOnly || exp.panel(fIdx).altOnly;
                end
            end
        case 'toggleBoardVisibility'
            exp.currentLayoutPreset = 'custom';
            fIdx = act.args{1};
            if exp.boardOff(fIdx)
                exp.boardOff(fIdx) = false;
                exp.summaryVisible(fIdx) = false;
                exp.sourceColumnsHidden(3 - fIdx) = false;
            elseif ~any(exp.boardOff)
                exp.boardOff(fIdx) = true;
                exp.summaryVisible(fIdx) = true;
                exp.sourceColumnsHidden(3 - fIdx) = true;
            end
        case 'ensureNoBoardOff'
            exp.boardOff(:) = false;
            exp.summaryVisible(:) = false;
            exp.sourceColumnsHidden(:) = false;
        case 'boardOffAddPlotTab'
            offIdx = act.args{1};
            if ~beforeState.BoardOffState(offIdx), return; end
            sourceIdx = 3 - offIdx;
            exp.plotTabCount(sourceIdx) = exp.plotTabCount(sourceIdx) + 1;
            exp.selectedTabPlotCount(sourceIdx) = 0;
            exp.minPlotTabCount(sourceIdx) = exp.minPlotTabCount(sourceIdx) + 1;
            exp.expectSelectedTabClear(sourceIdx) = false;
        case 'boardOffClearCurrentTab'
            offIdx = act.args{1};
            if ~beforeState.BoardOffState(offIdx), return; end
            sourceIdx = 3 - offIdx;
            clearedCount = max(0, beforeState.boards(sourceIdx).selectedTabPlotCount);
            exp.totalPlotCount(sourceIdx) = max(0, exp.totalPlotCount(sourceIdx) - clearedCount);
            exp.selectedTabPlotCount(sourceIdx) = 0;
            exp.minTotalPlotCount(sourceIdx) = max(0, exp.minTotalPlotCount(sourceIdx) - clearedCount);
            exp.expectSelectedTabClear(sourceIdx) = true;
        case 'boardOffPlotSelectedVariable'
            offIdx = act.args{1};
            if ~beforeState.BoardOffState(offIdx), return; end
            sourceIdx = 3 - offIdx;
            exp.totalPlotCount(sourceIdx) = exp.totalPlotCount(sourceIdx) + 1;
            exp.selectedTabPlotCount(sourceIdx) = exp.selectedTabPlotCount(sourceIdx) + 1;
            exp.minTotalPlotCount(sourceIdx) = exp.minTotalPlotCount(sourceIdx) + 1;
            exp.expectSelectedTabClear(sourceIdx) = false;
        case 'applyTimeChange'
            fIdx = act.args{1};
            exp.currentIndex(fIdx) = act.args{2};
            if exp.videoSynced(fIdx)
                exp.requireVideoFrameMove(fIdx) = true;
                exp.videoFrameBeforeMove(fIdx) = beforeState.boards(fIdx).videoSync.CurrentFrame;
            end
        case 'toggleFlightPlayControlPanel'
            fIdx = act.args{1};
            exp.flightPlayVisible(fIdx) = ~exp.flightPlayVisible(fIdx);
            exp.requireFlightPlay(fIdx) = true;
        case 'moveFlightDataFrame'
            fIdx = act.args{1};
            delta = act.args{2};
            exp.currentIndex(fIdx) = i_clampIndex(beforeState, fIdx, beforeState.boards(fIdx).currentIndex + delta);
            exp.requireFlightPlay(fIdx) = true;
        case {'handleFlightPlaySliderChange','handleFlightPlayFrameInputChange'}
            fIdx = act.args{1};
            exp.currentIndex(fIdx) = i_clampIndex(beforeState, fIdx, act.args{2});
            exp.requireFlightPlay(fIdx) = true;
        case 'handleFlightPlayTimeInputChange'
            fIdx = act.args{1};
            exp.currentIndex(fIdx) = 1;
            exp.requireFlightPlay(fIdx) = true;
        case 'refreshFlightPlayControlPanel'
            fIdx = act.args{1};
            exp.requireFlightPlay(fIdx) = true;
        case 'startFlightPlay'
            fIdx = act.args{1};
            exp.flightPlayActive(fIdx) = true;
            exp.currentIndex(fIdx) = NaN;
            exp.requireFlightPlay(fIdx) = true;
        case 'stopFlightPlay'
            fIdx = act.args{1};
            exp.flightPlayActive(fIdx) = false;
            exp.requireFlightPlay(fIdx) = true;
        case 'setFlightDataSync'
            exp.currentIndex(1) = 1;
            exp.currentIndex(2) = NaN;
        case 'applyLayoutPreset'
            exp = i_updateExpectedLayoutPreset(exp, char(act.args{1}));
        case 'setBodyRowSplitRatio'
            exp.currentLayoutPreset = 'custom';
            exp.bodyRowSplitRatio = max(0.2, min(0.8, double(act.args{1})));
        case 'simulateColumnSplitterDrag'
            exp.currentLayoutPreset = 'custom';
            fIdx = act.args{1};
            exp.requireColumnWidthChange(fIdx) = true;
            exp.columnWidthBefore{fIdx} = beforeState.boards(fIdx).dataGridColumnWidth;
        case 'saveCurrentLayoutPreset'
            presetName = char(act.args{1});
            key = matlab.lang.makeValidName(presetName);
            exp.savedPresetState.(key) = struct( ...
                'panel', exp.panel, ...
                'boardOff', exp.boardOff, ...
                'summaryVisible', exp.summaryVisible, ...
                'sourceColumnsHidden', exp.sourceColumnsHidden, ...
                'currentLayoutPreset', exp.currentLayoutPreset, ...
                'bodyRowSplitRatio', exp.bodyRowSplitRatio);
            if ~any(strcmp(beforeState.UserLayoutPresetNames, presetName))
                exp.minUserLayoutPresetCount = max(exp.minUserLayoutPresetCount, beforeState.UserLayoutPresetCount + 1);
            end
        case 'applySavedLayoutPreset'
            key = matlab.lang.makeValidName(char(act.args{1}));
            if isfield(exp.savedPresetState, key)
                saved = exp.savedPresetState.(key);
                exp.panel = saved.panel;
                exp.boardOff = saved.boardOff;
                exp.summaryVisible = saved.summaryVisible;
                exp.sourceColumnsHidden = saved.sourceColumnsHidden;
                exp.currentLayoutPreset = char(act.args{1});
                exp.bodyRowSplitRatio = saved.bodyRowSplitRatio;
            end
        case 'deleteSavedLayoutPreset'
            exp.minUserLayoutPresetCount = max(0, exp.minUserLayoutPresetCount - 1);
        case 'roundTripProjectLayoutState'
            % Expected state should remain unchanged after an in-memory project round-trip.
        case 'setVideoSync'
            fIdx = act.args{1};
            exp.videoSynced(fIdx) = true;
            exp.requireVideoFrameMove(fIdx) = false;
            exp.videoFrameBeforeMove(fIdx) = NaN;
        case 'loadProjectFixture'
            exp.projectRestoreRequired = true;
            exp.projectRestoreKind = char(act.args{1});
            exp.projectSafeFailureRequired = false;
        case 'loadProjectFixtureSafeFailure'
            exp.projectSafeFailureRequired = true;
            exp.projectSafeFailureKind = char(act.args{1});
        case 'openProjectFixtureInEditDialog'
            exp.projectRestoreRequired = true;
            exp.projectRestoreKind = char(act.args{1});
            exp.editDialogExpectedVisible = true;
        case 'toggleVideoControlDialog'
            fIdx = act.args{1};
            exp.videoControlVisible(fIdx) = ~exp.videoControlVisible(fIdx);
            exp.requireVideoControl(fIdx) = true;
        case 'goToFrame'
            fIdx = act.args{1};
            exp.videoFrameExpected(fIdx) = act.args{2};
        case 'captureRequiredPanel'
            exp.minRequiredPanelCaptures = exp.minRequiredPanelCaptures + 1;
            panelName = lower(char(act.args{1}));
            fIdx = act.args{2};
            if any(strcmp(panelName, {'flightplay', 'flightplaycontrol'}))
                exp.flightPlayVisible(fIdx) = true;
                exp.requireFlightPlay(fIdx) = true;
            elseif any(strcmp(panelName, {'videocontrol', 'avicontrol'}))
                exp.videoControlVisible(fIdx) = true;
                exp.requireVideoControl(fIdx) = true;
            elseif any(strcmp(panelName, {'editdialog', 'projecteditor'}))
                exp.editDialogExpectedVisible = true;
            end
    end
end

function exp = i_updateExpectedLayoutPreset(exp, presetName)
    % v4: arrangement-only. PanelVisible / BoardOff / SummaryVisible / RowHeight 불변.
    validNames = {'layout-grid', 'layout-vsplit', 'layout-hsplit', 'layout-compact', 'layout-reset'};
    if ~any(strcmp(presetName, validNames))
        presetName = 'layout-reset';
    end
    exp.currentLayoutPreset = presetName;
    % v4: exp.panel, exp.boardOff, exp.summaryVisible, exp.sourceColumnsHidden 변경 금지
end

function idx = i_clampIndex(st, fIdx, value)
    idx = round(double(value));
    try
        nRows = max(1, double(st.boards(fIdx).rawDataRows));
    catch
        nRows = max(1, idx);
    end
    idx = max(1, min(nRows, idx));
end

function [ok, msg] = i_validateState(st, exp) %#ok<*AGROW>
    % v3-lint: i_makePanelState / i_hasButtonText 제거 — board-off 새 policy 에서 미사용.
    issues = {};
    if sum(st.BoardOffState) > 1
        issues{end + 1} = 'both boards are off';
    end
    if isfield(st, 'CurrentLayoutPreset') && ~strcmp(char(st.CurrentLayoutPreset), exp.currentLayoutPreset)
        issues{end + 1} = sprintf('layout preset expected=%s actual=%s', ...
            exp.currentLayoutPreset, char(st.CurrentLayoutPreset));
    end
    if isfield(st, 'UserLayoutPresetCount') && st.UserLayoutPresetCount < exp.minUserLayoutPresetCount
        issues{end + 1} = sprintf('user layout preset count below expected minimum expected>=%d actual=%d', ...
            exp.minUserLayoutPresetCount, st.UserLayoutPresetCount);
    end
    issues = i_validateBodyRows(st, exp, issues);
    if any(logical(st.BoardOffState) ~= logical(exp.boardOff))
        issues{end + 1} = sprintf('board-off state mismatch expected=%s actual=%s', ...
            i_boolVecString(exp.boardOff), i_boolVecString(st.BoardOffState));
    end

    % v3 P2/P3/P4: 새 board-off policy = active source hsplit, summary panel 폐기.
    % 무거운 hidden boardOffPanel findall/marker/xline scan 제거 (case 48 hard-crash 방지).
    % 라이트한 검증만: source visible + off hidden + Video Player 비표시.
    activeOff = find(st.BoardOffState, 1);
    if isempty(activeOff)
        for fIdx = 1:2
            if ~st.boards(fIdx).panelVisible
                issues{end + 1} = sprintf('board %d panel hidden while no board-off active', fIdx);
            end
            if st.boards(fIdx).infoColumnHidden || st.boards(fIdx).plotColumnHidden
                issues{end + 1} = sprintf('board %d info/plot column hidden after board-on restore', fIdx);
            end
        end
    else
        offIdx = activeOff;
        srcIdx = 3 - offIdx;
        if st.boards(offIdx).panelVisible
            issues{end + 1} = sprintf('off board %d original panel still visible', offIdx);
        end
        if ~st.boards(srcIdx).panelVisible
            issues{end + 1} = sprintf('source board %d panel hidden', srcIdx);
        end
        % source 보드 arrangementMode = 'hsplit' (있을 때)
        if isfield(st.boards(srcIdx), 'arrangementMode') && ...
                ~strcmp(char(st.boards(srcIdx).arrangementMode), 'hsplit')
            issues{end + 1} = sprintf('source board %d arrangementMode expected=hsplit actual=%s', ...
                srcIdx, char(st.boards(srcIdx).arrangementMode));
        end
        % Video Player 자동 팝업 금지 (있을 때만 체크)
        if isfield(st, 'vidViewerDialogVisible') && any(logical(st.vidViewerDialogVisible))
            issues{end + 1} = 'Video Player auto-opened during board-off';
        end
    end

    for fIdx = 1:2
        if ~st.boards(fIdx).exists
            issues{end + 1} = sprintf('board %d state missing', fIdx);
            continue;
        end
        names = {'attitude', 'map', 'mapOnly', 'altOnly', 'video', 'info', 'dataView'};
        for iName = 1:numel(names)
            nm = names{iName};
            if st.boards(fIdx).PanelVisible.(nm) ~= exp.panel(fIdx).(nm)
                issues{end + 1} = sprintf('board %d %s PanelVisible expected=%d actual=%d', ...
                    fIdx, nm, exp.panel(fIdx).(nm), st.boards(fIdx).PanelVisible.(nm));
            end
            if any(strcmp(nm, {'attitude', 'map', 'video'})) && ...
                    ~st.BoardOffState(fIdx) && st.boards(fIdx).sideHandleVisible.(nm) ~= st.boards(fIdx).PanelVisible.(nm)
                issues{end + 1} = sprintf('board %d %s handle visibility mismatch', fIdx, nm);
            end
        end
        issues = i_validateBoardColumnWidths(st, fIdx, activeOff, issues);
        if exp.requireColumnWidthChange(fIdx) && i_widthCellsEqual(st.boards(fIdx).dataGridColumnWidth, exp.columnWidthBefore{fIdx})
            issues{end + 1} = sprintf('board %d column splitter did not change ColumnWidth', fIdx);
        end
        if st.boards(fIdx).PanelVisible.attitude
            if st.boards(fIdx).attitudeGridRows < 1 || st.boards(fIdx).attitudeGridColumns < 1
                issues{end + 1} = sprintf('board %d attitude grid dimensions missing', fIdx);
            end
            if isfinite(st.boards(fIdx).attitudeLabelFontSize) && st.boards(fIdx).attitudeLabelFontSize < 9
                issues{end + 1} = sprintf('board %d attitude label font too small', fIdx);
            end
        end
        if st.boards(fIdx).dataLoaded
            if st.boards(fIdx).dataTableRows < 1
                issues{end + 1} = sprintf('board %d data table empty', fIdx);
            end
            if isfinite(st.boards(fIdx).currentTime) && isfinite(st.boards(fIdx).spinnerValue) && ...
                    abs(st.boards(fIdx).currentTime - st.boards(fIdx).spinnerValue) > 0.01
                issues{end + 1} = sprintf('board %d spinner/current time mismatch', fIdx);
            end
            if isfinite(exp.currentIndex(fIdx)) && st.boards(fIdx).currentIndex ~= exp.currentIndex(fIdx)
                issues{end + 1} = sprintf('board %d currentIndex expected=%d actual=%d', ...
                    fIdx, exp.currentIndex(fIdx), st.boards(fIdx).currentIndex);
            end
            if ~st.boards(fIdx).altMarkerInteractive || ~st.boards(fIdx).altLineInteractive
                issues{end + 1} = sprintf('board %d altitude marker/xline callback missing', fIdx);
            end
            issues = i_validateFlightPlayState(st, exp, fIdx, issues);
        end
        if st.boards(fIdx).plotTabCount < exp.minPlotTabCount(fIdx)
            issues{end + 1} = sprintf('board %d plot tab count below expected minimum', fIdx);
        end
        if st.boards(fIdx).plotTabCount ~= exp.plotTabCount(fIdx)
            issues{end + 1} = sprintf('board %d plot tab count expected=%d actual=%d', ...
                fIdx, exp.plotTabCount(fIdx), st.boards(fIdx).plotTabCount);
        end
        if st.boards(fIdx).totalPlotCount < exp.minTotalPlotCount(fIdx)
            issues{end + 1} = sprintf('board %d plot count below expected minimum', fIdx);
        end
        if st.boards(fIdx).totalPlotCount ~= exp.totalPlotCount(fIdx)
            issues{end + 1} = sprintf('board %d total plot count expected=%d actual=%d', ...
                fIdx, exp.totalPlotCount(fIdx), st.boards(fIdx).totalPlotCount);
        end
        if st.boards(fIdx).selectedTabPlotCount ~= exp.selectedTabPlotCount(fIdx)
            issues{end + 1} = sprintf('board %d selected tab plot count expected=%d actual=%d', ...
                fIdx, exp.selectedTabPlotCount(fIdx), st.boards(fIdx).selectedTabPlotCount);
        end
        if exp.expectSelectedTabClear(fIdx) && st.boards(fIdx).selectedTabPlotCount ~= 0
            issues{end + 1} = sprintf('board %d selected tab not cleared', fIdx);
        end
        if exp.videoSynced(fIdx)
            vss = st.boards(fIdx).videoSync;
            if ~vss.IsSynced
                issues{end + 1} = sprintf('board %d video sync not enabled', fIdx);
            end
            if ~st.boards(fIdx).aviLoaded
                issues{end + 1} = sprintf('board %d video sync expected but AVI not loaded', fIdx);
            end
            if vss.TotalFrames <= 0 || vss.VideoFps <= 0 || vss.DataFps <= 0
                issues{end + 1} = sprintf('board %d video sync metadata invalid', fIdx);
            end
            if vss.TotalFrames > 0 && (vss.CurrentFrame < 1 || vss.CurrentFrame > vss.TotalFrames)
                issues{end + 1} = sprintf('board %d video frame out of range', fIdx);
            end
            if exp.requireVideoFrameMove(fIdx) && isfinite(exp.videoFrameBeforeMove(fIdx)) && ...
                    vss.CurrentFrame == exp.videoFrameBeforeMove(fIdx)
                issues{end + 1} = sprintf('board %d video frame did not move after time change', fIdx);
            end
            if isfinite(exp.videoFrameExpected(fIdx)) && abs(vss.CurrentFrame - exp.videoFrameExpected(fIdx)) > 1
                issues{end + 1} = sprintf('board %d video frame expected=%d actual=%d', ...
                    fIdx, exp.videoFrameExpected(fIdx), vss.CurrentFrame);
            end
        end
        if st.boards(fIdx).videoSync.IsSynced && st.boards(fIdx).videoSync.TotalFrames > 0 && ...
                st.boards(fIdx).dataLoaded && isfinite(st.boards(fIdx).currentTime)
            vss = st.boards(fIdx).videoSync;
            expectedFrame = round(vss.AnchorFrame + (st.boards(fIdx).currentTime - vss.AnchorTime) * vss.VideoFps);
            expectedFrame = max(1, min(expectedFrame, vss.TotalFrames));
            if abs(vss.CurrentFrame - expectedFrame) > 0
                issues{end + 1} = sprintf('board %d video frame mismatch expected=%d actual=%d', ...
                    fIdx, expectedFrame, vss.CurrentFrame);
            end
        end
    end

    if isempty(activeOff)
        if ~i_buttonStateOk(st.toggleButtons(1), 'off', 'on') || ~i_buttonStateOk(st.toggleButtons(2), 'off', 'on')
            issues{end + 1} = 'board toggle buttons not restored to off/on-enabled labels';
        end
    else
        otherIdx = 3 - activeOff;
        if ~i_buttonStateOk(st.toggleButtons(activeOff), 'on', 'on') || ...
                ~i_buttonStateOk(st.toggleButtons(otherIdx), 'off', 'off')
            issues{end + 1} = 'board toggle mutual-exclusion button state mismatch';
        end
    end

    if exp.projectRestoreRequired
        issues = i_validateProjectRestore(st, exp, issues);
    end
    if exp.projectSafeFailureRequired
        issues = i_validateProjectSafeFailure(st, exp, issues);
    end
    if exp.editDialogExpectedVisible && (~isfield(st, 'EditDialogVisible') || ~st.EditDialogVisible)
        issues{end + 1} = 'EditDialog not visible after project-open action';
    end
    if isfield(st, 'vidControlDialogVisible')
        for fIdx = 1:2
            if exp.requireVideoControl(fIdx) && logical(st.vidControlDialogVisible(fIdx)) ~= logical(exp.videoControlVisible(fIdx))
                issues{end + 1} = sprintf('board %d video control visible expected=%d actual=%d', ...
                    fIdx, exp.videoControlVisible(fIdx), st.vidControlDialogVisible(fIdx));
            end
        end
    end
    if exp.minRequiredPanelCaptures > 0 && ~isfield(st, 'RequiredPanelCaptureCount')
        % Capture existence is asserted synchronously by i_captureRequiredPanel.
    end

    ok = isempty(issues);
    if ok
        msg = '';
    else
        msg = sprintf('%s\nState snapshot: %s', strjoin(issues, '; '), i_stateSnapshot(st, exp));
    end
end

function s = i_boolVecString(v)
    try
        s = mat2str(logical(v));
    catch
        s = '(unavailable)';
    end
end

function txt = i_stateSnapshot(st, exp)
    try
        parts = cell(1, 2);
        for fIdx = 1:2
            b = st.boards(fIdx);
            parts{fIdx} = sprintf(['F%d{off=%d,panel=%d,idx=%g,time=%.3f,spin=%.3f,' ...
                'tabs=%d/%d,plots=%d/%d,selPlots=%d/%d,colsHidden=[%d %d %d],' ...
                'summary=%d,boPlots=%d,boMarkers=%d,video=[sync=%d frame=%d/%d]}'], ...
                fIdx, st.BoardOffState(fIdx), b.panelVisible, b.currentIndex, ...
                b.currentTime, b.spinnerValue, b.plotTabCount, exp.plotTabCount(fIdx), ...
                b.totalPlotCount, exp.totalPlotCount(fIdx), ...
                b.selectedTabPlotCount, exp.selectedTabPlotCount(fIdx), ...
                b.infoColumnHidden, b.plotColumnHidden, b.splitterColumnHidden, ...
                b.boardOffPanelVisible, b.boardOff.totalPlotCount, b.boardOff.markerCount, ...
                b.videoSync.IsSynced, b.videoSync.CurrentFrame, b.videoSync.TotalFrames);
        end
        txt = sprintf('BoardOff actual=%s expected=%s; %s; %s', ...
            i_boolVecString(st.BoardOffState), i_boolVecString(exp.boardOff), parts{1}, parts{2});
    catch ME
        txt = sprintf('snapshot unavailable: %s', ME.message);
    end
end

function tf = i_buttonStateOk(btn, labelNeedle, enableValue)
    try
        tf = contains(btn.Text, labelNeedle) && strcmpi(btn.Enable, enableValue);
    catch
        tf = false;
    end
end

function issues = i_validateBodyRows(st, exp, issues) %#ok<*AGROW>
    % v3-new: board-off = active source hsplit + summary 폐기.
    % row4 (summary row) 는 collapsed (0) 이 정상. row2 (splitter row) 도 board-off 시 0 허용.
    if ~isfield(st, 'BodyRowHeight') || numel(st.BodyRowHeight) ~= 4
        issues{end + 1} = 'BodyGrid RowHeight is not a 4-row board/summary layout';
        return;
    end
    activeOff = find(st.BoardOffState, 1);
    if isempty(activeOff)
        if isfield(st, 'BodyRowSplitterVisible') && ~st.BodyRowSplitterVisible
            issues{end + 1} = 'row splitter hidden while both boards are visible';
        end
        if isfield(st, 'BodyRowSplitRatio') && abs(double(st.BodyRowSplitRatio) - double(exp.bodyRowSplitRatio)) > 0.03
            issues{end + 1} = sprintf('row split ratio expected=%.3f actual=%.3f', ...
                double(exp.bodyRowSplitRatio), double(st.BodyRowSplitRatio));
        end
        midRow = i_rowWeight(st.BodyRowHeight{2});
        if midRow <= 0
            issues{end + 1} = 'row splitter row is collapsed while both boards are visible';
        elseif abs(midRow - 4) > 0.1
            issues{end + 1} = sprintf('row splitter height expected=4 actual=%.3f', midRow);
        end
        summaryRow = i_rowWeight(st.BodyRowHeight{4});
        if summaryRow ~= 0
            issues{end + 1} = 'hidden summary row consumes height while both boards are visible';
        end
        return;
    end
    if isfield(st, 'BodyRowSplitterVisible') && ~st.BodyRowSplitterVisible
        issues{end + 1} = 'row splitter hidden while one board is off';
    end
    row1 = i_rowWeight(st.BodyRowHeight{1});
    row2 = i_rowWeight(st.BodyRowHeight{2});
    row3 = i_rowWeight(st.BodyRowHeight{3});
    row4 = i_rowWeight(st.BodyRowHeight{4});
    if row2 <= 0
        issues{end + 1} = 'row splitter row is collapsed while one board is off';
    elseif abs(row2 - 4) > 0.1
        issues{end + 1} = sprintf('board-off row splitter height expected=4 actual=%.3f', row2);
    end
    if activeOff == 1
        % upper off: row1/row2=0, row3>0 (source 100%), row4 may be 0 (summary 폐기)
        if row1 ~= 0 || row3 <= 0 || row4 < 0
            issues{end + 1} = sprintf('upper-off rows invalid: row1=%g row3=%g row4=%g', row1, row3, row4);
        end
    elseif activeOff == 2
        % lower off: row1>0 (source 100%), row3/row4=0, row2 may be 0
        if row1 <= 0 || row3 < 0 || row4 ~= 0
            issues{end + 1} = sprintf('lower-off rows invalid: row1=%g row3=%g row4=%g', row1, row3, row4);
        end
    end
end

function w = i_rowWeight(spec)
    w = 0;
    try
        if isnumeric(spec)
            w = double(spec(1));
            return;
        end
        txt = strtrim(char(spec));
        if ~isempty(txt) && strcmpi(txt(end), 'x')
            txt = txt(1:end-1);
        end
        v = str2double(txt);
        if isfinite(v), w = v; end
    catch
        w = 0;
    end
end

function issues = i_validateBoardColumnWidths(st, fIdx, activeOff, issues) %#ok<*AGROW>
    if ~st.boards(fIdx).exists || isempty(st.boards(fIdx).dataGridColumnWidth)
        return;
    end
    widths = st.boards(fIdx).dataGridColumnWidth;
    if numel(widths) < 7
        issues{end + 1} = sprintf('board %d dataGrid ColumnWidth has fewer than 7 columns', fIdx);
        return;
    end

    % The original panel of the off board is intentionally hidden; its old
    % grid widths are not meaningful until the board is restored.
    if st.BoardOffState(fIdx)
        return;
    end

    isSourceDuringBoardOff = ~isempty(activeOff) && fIdx == 3 - activeOff;
    if isSourceDuringBoardOff
        if numel(widths) >= 8
            movedStillVisible = ~i_widthSpecIsZero(widths{4}) || ~i_widthSpecIsZero(widths{5}) || ...
                ~i_widthSpecIsZero(widths{6}) || ~i_widthSpecIsZero(widths{7});
        else
            movedStillVisible = ~i_widthSpecIsZero(widths{3}) || ~i_widthSpecIsZero(widths{4}) || ...
                ~i_widthSpecIsZero(widths{5});
        end
        if movedStillVisible
            issues{end + 1} = sprintf('board %d moved info/plot columns still occupy width', fIdx);
        end
        return;
    end

    if numel(widths) >= 8
        panelMap = struct('name', {'attitude', 'map', 'info', 'dataView'}, 'col', {1, 3, 5, 7});
    else
        panelMap = struct('name', {'attitude', 'map', 'info', 'dataView'}, 'col', {1, 2, 3, 4});
    end
    for k = 1:numel(panelMap)
        name = panelMap(k).name;
        col = panelMap(k).col;
        isZero = i_widthSpecIsZero(widths{col});
        if st.boards(fIdx).PanelVisible.(name) && isZero
            issues{end + 1} = sprintf('board %d %s column collapsed while panel visible', fIdx, name);
        elseif ~st.boards(fIdx).PanelVisible.(name) && ~isZero
            issues{end + 1} = sprintf('board %d %s column left blank while panel hidden', fIdx, name);
        end
    end

    if numel(widths) >= 8 && ~isempty(st.boards(fIdx).columnSplitterVisible)
        expectedSplitters = [ ...
            ~i_widthSpecIsZero(widths{1}) && ~i_widthSpecIsZero(widths{3}), ...
            ~i_widthSpecIsZero(widths{3}) && ~i_widthSpecIsZero(widths{5}), ...
            ~i_widthSpecIsZero(widths{5}) && ~i_widthSpecIsZero(widths{7})];
        actualSplitters = logical(st.boards(fIdx).columnSplitterVisible);
        n = min(numel(expectedSplitters), numel(actualSplitters));
        if any(actualSplitters(1:n) ~= expectedSplitters(1:n))
            issues{end + 1} = sprintf('board %d column splitter visibility mismatch', fIdx);
        end
    end
end

function issues = i_validateFlightPlayState(st, exp, fIdx, issues) %#ok<*AGROW>
    % v-fix-A: hidden+inactive 패널은 control 내부 검증 skip (baseline 전역 false FAIL 방지).
    % control 검증은 panel visible / playActive / requireFlightPlay / expected visible|active 일 때만.
    try
        fp = st.boards(fIdx).flightPlay;
        requireFP = exp.requireFlightPlay(fIdx);
        expVisible = logical(exp.flightPlayVisible(fIdx));
        expActive  = logical(exp.flightPlayActive(fIdx));
        validateControls = logical(fp.panelVisible) || logical(fp.playActive) || ...
                           requireFP || expVisible || expActive;

        % 가시/활성 expected 상태는 항상 검증 (구조 안전성)
        if logical(fp.panelVisible) ~= expVisible
            issues{end + 1} = sprintf('board %d flight play panel visible expected=%d actual=%d', ...
                fIdx, expVisible, fp.panelVisible);
        end
        if logical(fp.playActive) ~= expActive
            issues{end + 1} = sprintf('board %d flight play active expected=%d actual=%d', ...
                fIdx, expActive, fp.playActive);
        end

        if ~validateControls
            return;   % hidden+inactive 무관 case → control 내부 검증 skip
        end

        if requireFP
            required = {'buttonValid','panelValid','sliderValid','frameInputValid','timeInputValid'};
            for k = 1:numel(required)
                if ~isfield(fp, required{k}) || ~fp.(required{k})
                    issues{end + 1} = sprintf('board %d flight play %s missing/invalid', fIdx, required{k});
                end
            end
        end
        if fp.sliderValid && st.boards(fIdx).rawDataRows > 0
            if fp.sliderLimits(1) > 1 || fp.sliderLimits(2) < st.boards(fIdx).rawDataRows
                issues{end + 1} = sprintf('board %d flight play slider limits invalid', fIdx);
            end
            if abs(fp.sliderValue - st.boards(fIdx).currentIndex) > 0.5
                issues{end + 1} = sprintf('board %d flight play slider/index mismatch', fIdx);
            end
        end
        if fp.frameInputValid && abs(fp.frameValue - st.boards(fIdx).currentIndex) > 0.5
            issues{end + 1} = sprintf('board %d flight play frame input/index mismatch', fIdx);
        end
        if fp.timeInputValid && isfinite(st.boards(fIdx).currentTime) && abs(fp.timeValue - st.boards(fIdx).currentTime) > 0.02
            issues{end + 1} = sprintf('board %d flight play time input/current time mismatch', fIdx);
        end
    catch ME
        issues{end + 1} = sprintf('board %d flight play validation error: %s', fIdx, ME.message);
    end
end

function tf = i_widthCellsEqual(a, b)
    tf = false;
    try
        if numel(a) ~= numel(b), return; end
        tf = true;
        for k = 1:numel(a)
            if ~strcmp(i_widthSpecKey(a{k}), i_widthSpecKey(b{k}))
                tf = false;
                return;
            end
        end
    catch
        tf = false;
    end
end

function key = i_widthSpecKey(spec)
    try
        if isnumeric(spec)
            key = sprintf('n:%.6g', double(spec(1)));
        else
            key = sprintf('s:%s', strtrim(char(spec)));
        end
    catch
        key = 'bad';
    end
end

function tf = i_widthSpecIsZero(widthSpec)
    try
        if isnumeric(widthSpec)
            tf = all(double(widthSpec) == 0);
            return;
        end
        s = strtrim(char(widthSpec));
        tf = any(strcmpi(s, {'0', '0x', '0px'}));
    catch
        tf = false;
    end
end

function projectPath = i_createProjectFixture(app, kind, outDir)
    fixtureDir = fullfile(outDir, 'project_fixtures');
    if ~exist(fixtureDir, 'dir')
        mkdir(fixtureDir);
    end
    safeKind = regexprep(char(kind), '[^\w\-]', '_');
    projectPath = fullfile(fixtureDir, sprintf('fixture_%03d_%s.fdproj', randi(999), safeKind));
    if strcmp(kind, 'corrupt_json')
        i_writeText(projectPath, '{ "Version": 1, "Flights": [');
        return;
    end
    ok = app.testHook('saveProjectFile', projectPath);
    if ~ok || ~isfile(projectPath)
        error('AutoTest:ProjectFixtureSaveFailed', 'Could not save project fixture: %s', projectPath);
    end
    try
        st = jsondecode(fileread(projectPath));
    catch ME
        error('AutoTest:ProjectFixtureDecodeFailed', '%s', ME.message);
    end
    st = i_mutateProjectFixtureStruct(st, kind, fixtureDir);
    i_writeText(projectPath, jsonencode(st, 'PrettyPrint', true));
end

function st = i_mutateProjectFixtureStruct(st, kind, fixtureDir)
    switch char(kind)
        case 'full'
        case 'data_only'
            if isfield(st, 'PlotConfig'), st = rmfield(st, 'PlotConfig'); end
            if isfield(st, 'UiState') && isfield(st.UiState, 'Layout')
                st.UiState = rmfield(st.UiState, 'Layout');
            end
        case 'data_plot_single'
            st = i_trimProjectPlotConfig(st, 1, 1);
        case 'data_plot_multi'
            st = i_trimProjectPlotConfig(st, 2, 2);
        case 'manual_axis_limits'
            st = i_setProjectAxisLimits(st, [0 10], [-1 1]);
        case 'layout_normal_custom_widths'
            st = i_setProjectColumnWidths(st, {120, 4, '1x', 4, 220, 4, '2x', 0});
        case 'layout_lower_board_off'
            st = i_setProjectBoardOff(st, [false true]);
        case 'layout_upper_board_off'
            st = i_setProjectBoardOff(st, [true false]);
        case 'layout_hsplit_grid'
            st = i_setProjectPreset(st, 'layout-hsplit');
        case 'hidden_panel_columns'
            st = i_setProjectHiddenPanels(st);
        case 'flight_sync'
            st.FlightSync = struct('IsSynced', true, 'SyncT1', 0, 'SyncT2', 0);
        case 'video_sync_with_avi'
            if isfield(st, 'Flights')
                for fIdx = 1:min(2, numel(st.Flights))
                    st.Flights(fIdx).VideoSync = struct('IsSynced', true, ...
                        'AnchorFrame', 1, 'AnchorTime', 0, 'VideoFps', 30, 'DataFps', 50);
                end
            end
        case 'missing_plotconfig'
            if isfield(st, 'PlotConfig'), st = rmfield(st, 'PlotConfig'); end
        case 'missing_layout'
            if isfield(st, 'UiState') && isfield(st.UiState, 'Layout')
                st.UiState = rmfield(st.UiState, 'Layout');
            end
        case 'missing_projectsettings'
            if isfield(st, 'ProjectSettings'), st = rmfield(st, 'ProjectSettings'); end
        case 'flight1_only'
            if isfield(st, 'Flights') && numel(st.Flights) >= 1
                st.Flights = st.Flights(1);
            end
        case 'invalid_data_path'
            st = i_setProjectBrokenPath(st, 'DataFile', fixtureDir);
        case 'invalid_avi_path'
            st = i_setProjectBrokenPath(st, 'AviFile', fixtureDir);
        case 'old_schema'
            if isfield(st, 'Schema'), st.Schema = 'FlightDataDashboardProject'; end
            if isfield(st, 'Version'), st.Version = 1; end
        case 'extra_unknown_fields'
            st.UnknownFutureField = struct('Value', 42, 'Text', 'ignored by restore');
        otherwise
            error('AutoTest:UnknownProjectFixtureKind', 'Unknown project fixture kind: %s', char(kind));
    end
end

function st = i_trimProjectPlotConfig(st, maxTabs, maxPlots)
    if ~isfield(st, 'PlotConfig') || isempty(st.PlotConfig), return; end
    try
        for fIdx = 1:min(2, numel(st.PlotConfig.Flights))
            tabs = st.PlotConfig.Flights(fIdx).Tabs;
            if numel(tabs) > maxTabs, tabs = tabs(1:maxTabs); end
            for tIdx = 1:numel(tabs)
                if isfield(tabs(tIdx), 'Plots') && numel(tabs(tIdx).Plots) > maxPlots
                    tabs(tIdx).Plots = tabs(tIdx).Plots(1:maxPlots);
                end
            end
            st.PlotConfig.Flights(fIdx).Tabs = tabs;
        end
    catch
    end
end

function st = i_setProjectAxisLimits(st, xlimv, ylimv)
    if ~isfield(st, 'PlotConfig') || isempty(st.PlotConfig), return; end
    try
        for fIdx = 1:min(2, numel(st.PlotConfig.Flights))
            tabs = st.PlotConfig.Flights(fIdx).Tabs;
            for tIdx = 1:numel(tabs)
                for pIdx = 1:numel(tabs(tIdx).Plots)
                    tabs(tIdx).Plots(pIdx).XLimMode = 'manual';
                    tabs(tIdx).Plots(pIdx).XLim = xlimv;
                    tabs(tIdx).Plots(pIdx).YLimMode = 'manual';
                    tabs(tIdx).Plots(pIdx).YLim = ylimv;
                end
            end
            st.PlotConfig.Flights(fIdx).Tabs = tabs;
        end
    catch
    end
end

function st = i_setProjectColumnWidths(st, widths)
    try
        if ~isfield(st, 'UiState'), st.UiState = struct(); end
        if ~isfield(st.UiState, 'Layout') || isempty(st.UiState.Layout)
            st.UiState.Layout = struct();
        end
        st.UiState.Layout.ColumnWidth = {widths, widths};
    catch
    end
end

function st = i_setProjectBoardOff(st, offState)
    try
        if ~isfield(st, 'UiState'), st.UiState = struct(); end
        if ~isfield(st.UiState, 'Layout') || isempty(st.UiState.Layout)
            st.UiState.Layout = struct();
        end
        st.UiState.Layout.BoardOffState = logical(offState);
    catch
    end
end

function st = i_setProjectPreset(st, presetName)
    try
        if ~isfield(st, 'UiState'), st.UiState = struct(); end
        if ~isfield(st.UiState, 'Layout') || isempty(st.UiState.Layout)
            st.UiState.Layout = struct();
        end
        st.UiState.Layout.CurrentLayoutPreset = char(presetName);
    catch
    end
end

function st = i_setProjectHiddenPanels(st)
    try
        if ~isfield(st, 'UiState'), st.UiState = struct(); end
        if ~isfield(st.UiState, 'Layout') || isempty(st.UiState.Layout)
            st.UiState.Layout = struct();
        end
        pv = st.UiState.Layout.PanelVisible;
        for fIdx = 1:min(2, numel(pv))
            pv(fIdx).info = false;
            pv(fIdx).dataView = false;
        end
        st.UiState.Layout.PanelVisible = pv;
    catch
    end
end

function st = i_setProjectBrokenPath(st, fieldName, fixtureDir)
    try
        brokenPath = fullfile(fixtureDir, ['missing_' lower(fieldName) '.dat']);
        if strcmp(fieldName, 'AviFile')
            brokenPath = fullfile(fixtureDir, 'missing_video.avi');
        end
        if isfield(st, 'Flights') && ~isempty(st.Flights)
            st.Flights(1).(fieldName) = brokenPath;
        end
    catch
    end
end

function issues = i_validateProjectRestore(st, exp, issues) %#ok<INUSD>
    snap = i_projectSnapshot(st);
    if ~isfield(st, 'ProjectFilePath') || isempty(st.ProjectFilePath) || ~isfile(st.ProjectFilePath)
        issues{end + 1} = 'project restore did not bind ProjectFilePath to an existing file';
    end
    if ~isfield(st, 'ProjectDirty') || st.ProjectDirty
        issues{end + 1} = 'project restore left ProjectDirty=true for a clean fixture';
    end
    if numel(st.boards) < 2 || ~st.boards(1).exists || ~st.boards(2).exists
        issues{end + 1} = 'project restore lost board test state';
    end
    if ~isfield(st, 'BodyRowHeight') || isempty(st.BodyRowHeight)
        issues{end + 1} = 'project restore did not restore layout row state';
    end
    if ~any(snap.dataLoaded) && ~strcmp(exp.projectRestoreKind, 'flight1_only')
        issues{end + 1} = 'project restore did not leave any flight data loaded';
    end
    if strcmp(exp.projectRestoreKind, 'flight_sync') && ...
            (~isfield(st, 'SyncState') || ~isfield(st.SyncState, 'IsSynced') || ~st.SyncState.IsSynced)
        issues{end + 1} = 'flight sync fixture did not restore SyncState.IsSynced';
    end
    if any(strcmp(exp.projectRestoreKind, {'layout_lower_board_off', 'layout_upper_board_off'})) && ~any(st.BoardOffState)
        issues{end + 1} = 'board-off fixture did not restore BoardOffState';
    end
end

function issues = i_validateProjectSafeFailure(st, exp, issues) %#ok<INUSD>
    snap = i_projectSnapshot(st);
    if numel(st.boards) < 2 || ~st.boards(1).exists || ~st.boards(2).exists
        issues{end + 1} = sprintf('safe-failure fixture %s invalidated board handles', exp.projectSafeFailureKind);
    end
    if ~isfield(st, 'BodyRowHeight') || isempty(st.BodyRowHeight)
        issues{end + 1} = sprintf('safe-failure fixture %s lost layout state', exp.projectSafeFailureKind);
    end
    if isempty(snap.boardOff) || numel(snap.rowCounts) < 2
        issues{end + 1} = sprintf('safe-failure fixture %s produced an incomplete project snapshot', exp.projectSafeFailureKind);
    end
end

function snap = i_projectSnapshot(st)
    snap = struct('dataLoaded', false(1, 2), 'rowCounts', zeros(1, 2), ...
        'currentIndex', NaN(1, 2), 'boardOff', [], 'panelVisible', [], ...
        'syncEnabled', false, 'videoSyncEnabled', false(1, 2), ...
        'plotTabCounts', zeros(1, 2), 'columnWidths', {cell(1, 2)});
    try
        snap.boardOff = logical(st.BoardOffState);
        if isfield(st, 'SyncState') && isfield(st.SyncState, 'IsSynced')
            snap.syncEnabled = logical(st.SyncState.IsSynced);
        end
        for fIdx = 1:min(2, numel(st.boards))
            b = st.boards(fIdx);
            snap.dataLoaded(fIdx) = logical(b.dataLoaded);
            snap.rowCounts(fIdx) = double(b.rawDataRows);
            snap.currentIndex(fIdx) = double(b.currentIndex);
            snap.plotTabCounts(fIdx) = double(b.plotTabCount);
            snap.videoSyncEnabled(fIdx) = logical(b.videoSync.IsSynced);
            snap.columnWidths{fIdx} = b.dataGridColumnWidth;
            snap.panelVisible = [snap.panelVisible; ...
                logical([b.PanelVisible.attitude, b.PanelVisible.mapOnly, b.PanelVisible.altOnly, ...
                b.PanelVisible.info, b.PanelVisible.dataView, b.PanelVisible.video])]; %#ok<AGROW>
        end
    catch
    end
end

function i_captureRequiredPanel(app, outDir, caseIdx, stepIdx, captureOpts, panelName, fIdx)
    if nargin < 8 || isempty(fIdx), fIdx = 1; end
    label = regexprep(char(panelName), '[^\w\-]', '_');
    file = fullfile(outDir, sprintf('case%02d_step%02d_%s.png', caseIdx, stepIdx, label));
    target = i_findPanelCaptureTarget(app, char(panelName), fIdx);
    if isempty(target) || ~isvalid(target)
        error('AutoTest:PanelCaptureTargetMissing', 'Panel capture target missing: %s', char(panelName));
    end
    try
        exportapp(target, file);
    catch
        frame = getframe(target);
        img = frame.cdata;
        if captureOpts.scale < 1
            img = i_resizeImageNearest(img, captureOpts.scale);
        end
        imwrite(img, file);
    end
    info = dir(file);
    if isempty(info) || info(1).bytes <= 0
        error('AutoTest:PanelCaptureEmpty', 'Panel capture file is empty: %s', file);
    end
end

function target = i_findPanelCaptureTarget(app, panelName, fIdx)
    target = [];
    switch lower(char(panelName))
        case {'main', 'dashboard'}
            target = app.UIFigure;
        case {'editdialog', 'projecteditor'}
            app.testHook('openEditDialog');
            target = app.EditDialog;
        case {'videocontrol', 'avicontrol'}
            target = app.UI(fIdx).vidControlDialog;
            if isempty(target) || ~isvalid(target) || ~i_isHandleVisible(target)
                app.testHook('toggleVideoControlDialog', fIdx);
                target = app.UI(fIdx).vidControlDialog;
            end
        case {'videoviewer', 'videoplayer'}
            target = app.UI(fIdx).vidViewerDialog;
        case {'flightplay', 'flightplaycontrol'}
            try
                target = app.UI(fIdx).flightPlayControlPanel;
            catch
                target = [];
            end
            if isempty(target) || ~isvalid(target) || ~i_isHandleVisible(target)
                app.testHook('toggleFlightPlayControlPanel', fIdx);
            end
            target = app.UIFigure;
        otherwise
            error('AutoTest:UnknownPanelCaptureTarget', 'Unknown panel capture target: %s', char(panelName));
    end
end

function tf = i_isHandleVisible(h)
    tf = false;
    try
        tf = ~isempty(h) && isvalid(h) && strcmpi(char(h.Visible), 'on');
    catch
        tf = false;
    end
end

function i_writeText(filePath, txt)
    fid = fopen(filePath, 'w', 'n', 'UTF-8');
    if fid < 0
        error('AutoTest:WriteFailed', 'Could not write %s', filePath);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, txt, 'char');
    clear cleaner;
end

% =========================================================================
% Capture helpers
% =========================================================================
function captured = i_capture(app, outDir, caseIdx, stepIdx, captureOpts, reason)
    captured = false;
    if nargin < 6 || isempty(reason), reason = 'step'; end
    if ~i_shouldCapture(captureOpts, reason)
        return;
    end
    % main figure (suffix 없음 — legacy 파일명 호환)
    mainFile = fullfile(outDir, sprintf('case%02d_step%02d.png', caseIdx, stepIdx));
    captured = i_captureFigure(app.UIFigure, mainFile, captureOpts);
    % v-fix3: 열린 외부 dashboard dialog 도 함께 캡처 (figure type suffix)
    extras = i_collectOpenDialogs(app);
    for e = 1:size(extras, 1)
        f2 = fullfile(outDir, sprintf('case%02d_step%02d_%s.png', caseIdx, stepIdx, extras{e, 2}));
        try, i_captureFigure(extras{e, 1}, f2, captureOpts); catch; end
    end
    if ~captured
        error('AutoTest:CaptureFailed', 'Failed to capture %s', mainFile);
    end
end

function ok = i_captureFigure(figh, file, captureOpts)
    ok = false;
    if isempty(figh) || ~isvalid(figh), return; end
    try
        f = getframe(figh);
        img = f.cdata;
        if captureOpts.scale < 1
            img = i_resizeImageNearest(img, captureOpts.scale);
        end
        imwrite(img, file);
        clear f img;
        try, drawnow limitrate; catch; end
        ok = isfile(file);
        if ok, return; end
    catch
    end
    try
        exportapp(figh, file);
        try, drawnow limitrate; catch; end
        ok = isfile(file);
    catch
    end
end

function dlgs = i_collectOpenDialogs(app)
    % v-fix3: visible 한 EditDialog / vidControlDialog / vidViewerDialog 수집 {handle, typeTag}
    dlgs = cell(0, 2);
    try
        if isprop(app, 'EditDialog') && ~isempty(app.EditDialog) && isvalid(app.EditDialog) ...
                && strcmpi(char(app.EditDialog.Visible), 'on')
            dlgs(end+1, :) = {app.EditDialog, 'editdialog'};
        end
    catch
    end
    try
        for fIdx = 1:numel(app.UI)
            u = app.UI(fIdx);
            pairs = {{'vidControlDialog', sprintf('vidctrl_f%d', fIdx)}, ...
                     {'vidViewerDialog',  sprintf('vidview_f%d', fIdx)}};
            for p = 1:numel(pairs)
                fld = pairs{p}{1};
                if isfield(u, fld) && ~isempty(u.(fld)) && isvalid(u.(fld)) ...
                        && strcmpi(char(u.(fld).Visible), 'on')
                    dlgs(end+1, :) = {u.(fld), pairs{p}{2}}; %#ok<AGROW>
                end
            end
        end
    catch
    end
end

function tf = i_shouldCapture(captureOpts, reason)
    mode = 'baseline';
    if nargin >= 1 && isstruct(captureOpts) && isfield(captureOpts, 'mode')
        mode = char(captureOpts.mode);
    end
    switch lower(mode)
        case 'all'
            tf = true;
        case 'baseline'
            tf = any(strcmpi(reason, {'baseline', 'fail'}));
        case 'fail'
            tf = strcmpi(reason, 'fail');
        case 'none'
            tf = false;
        otherwise
            tf = false;
    end
end

function imgOut = i_resizeImageNearest(imgIn, scale)
    if scale >= 1
        imgOut = imgIn;
        return;
    end
    h = size(imgIn, 1);
    w = size(imgIn, 2);
    newH = max(1, round(h * scale));
    newW = max(1, round(w * scale));
    rowIdx = max(1, min(h, round(linspace(1, h, newH))));
    colIdx = max(1, min(w, round(linspace(1, w, newW))));
    imgOut = imgIn(rowIdx, colIdx, :);
end

% =========================================================================
% Crash-resilient progress writer
% =========================================================================
function i_initProgressMd(progressFile, opts, nCases, caseOrder)
    if nargin < 4, caseOrder = []; end
    fid = fopen(progressFile, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    try
        fprintf(fid, '# Auto Test Progress\n\n');
        fprintf(fid, '- Started: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
        fprintf(fid, '- Start option: %g\n', opts.Start);
        fprintf(fid, '- End option: %g\n', opts.End);
        fprintf(fid, '- Order: %s\n', char(opts.Order));
        fprintf(fid, '- Skip: %s\n', i_vecToStr(opts.Skip));
        fprintf(fid, '- CaseList: %s\n', i_vecToStr(opts.CaseList));
        fprintf(fid, '- LoadAvi: %s\n', char(opts.LoadAvi));
        fprintf(fid, '- CaptureMode: %s\n', char(opts.CaptureMode));
        fprintf(fid, '- CaptureScale: %.3g\n', opts.CaptureScale);
        fprintf(fid, '- OnlineSafeMode: %d\n', logical(opts.OnlineSafeMode));
        fprintf(fid, '- Total cases: %d\n', nCases);
        fprintf(fid, '- Actual caseOrder (%d): %s\n\n', numel(caseOrder), i_vecToStr(caseOrder));
        fprintf(fid, '| Time | Case | Step | Status | Detail |\n');
        fprintf(fid, '|---|---:|---:|---|---|\n');
    catch
    end
    fclose(fid);
end

function s = i_vecToStr(v)
    if isempty(v), s = '[]'; return; end
    s = ['[' strjoin(arrayfun(@(x) sprintf('%g', x), v(:)', 'UniformOutput', false), ' ') ']'];
end

function order = i_buildCaseOrder(nCases, iStart, iEnd, orderMode, skipList, caseList)
    % 실행 순서 벡터 구축. CaseList 지정 시 우선, 아니면 Start/End/Order.
    % Skip 적용 + 중복 제거 (순서 유지) + 1..nCases 범위 clamp.
    if ~isempty(caseList)
        order = round(caseList(:)');
    else
        s = max(1, min(nCases, round(iStart)));
        e = max(1, min(nCases, round(iEnd)));
        if strcmp(orderMode, 'desc')
            if e > s
                tmp = s; s = e; e = tmp;
            end
            order = s:-1:e;
        else
            if e < s
                tmp = s; s = e; e = tmp;
            end
            order = s:e;
        end
    end
    % clamp + valid range
    order = order(order >= 1 & order <= nCases);
    % Skip
    if ~isempty(skipList)
        order = order(~ismember(order, round(skipList(:)')));
    end
    % 중복 제거 (순서 보존)
    [~, ui] = unique(order, 'stable');
    order = order(ui);
end

function i_appendProgressMd(progressFile, caseIdx, stepIdx, status, detail)
    if nargin < 5 || isempty(detail), detail = ''; end
    fid = fopen(progressFile, 'a', 'n', 'UTF-8');
    if fid < 0, return; end
    try
        fprintf(fid, '| %s | %d | %d | `%s` | %s |\n', ...
            char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
            caseIdx, stepIdx, i_mdEscape(status), i_mdEscape(detail));
    catch
    end
    fclose(fid);
end

function out = i_mdEscape(in)
    try
        out = char(string(in));
    catch
        out = char(in);
    end
    out = strrep(out, newline, '<br>');
    out = strrep(out, sprintf('\r'), '<br>');
    out = strrep(out, '|', '\|');
    if isempty(out), out = '&nbsp;'; end
end

% =========================================================================
% Markdown writers
% =========================================================================
function i_writeCaseMd(outDir, idx, tc, r)
    fname = fullfile(outDir, sprintf('case%02d.md', idx));
    fid = fopen(fname, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    closeFid = onCleanup(@() fclose(fid));

    fprintf(fid, '# Case %02d: %s\n\n', idx, tc.title);
    fprintf(fid, '- **그룹**: %s\n', tc.group);
    if ~isempty(tc.target)
        fprintf(fid, '- **검증 대상**: %s\n', tc.target);
    end
    fprintf(fid, '- **기대 결과**: %s\n', tc.expected);
    fprintf(fid, '- **관측 결과**: `%s`\n\n', r.status);

    fprintf(fid, '## 액션 시퀀스\n\n');
    fprintf(fid, '| Step | 액션 | 캡처 |\n');
    fprintf(fid, '|------|------|------|\n');
    if r.steps >= 1
        fprintf(fid, '| 01 | baseline (data loaded) | %s |\n', i_captureMarkdown(outDir, idx, 1));
    else
        fprintf(fid, '| - | not executed | - |\n');
    end
    maxActionRows = min(numel(tc.actions), max(0, r.steps - 1));
    for j = 1:maxActionRows
        fprintf(fid, '| %02d | %s | %s |\n', ...
            j + 1, tc.actions{j}.label, i_captureMarkdown(outDir, idx, j + 1));
    end

    if ~isempty(r.error)
        fprintf(fid, '\n## Failure Detail\n```\n%s\n```\n', r.error);
    end
    clear closeFid;
end

function txt = i_captureMarkdown(outDir, caseIdx, stepIdx)
    name = sprintf('case%02d_step%02d.png', caseIdx, stepIdx);
    if isfile(fullfile(outDir, name))
        txt = sprintf('![](%s)', name);
    else
        txt = '(not captured)';
    end
end

function i_writeIndexMd(outDir, results, indexFile, progressFile)
    % v-chunk: chunk 별 index 파일. indexFile/progressFile 미지정 시 legacy 'index.md'/'progress.md'.
    if nargin < 3 || isempty(indexFile)
        fname = fullfile(outDir, 'index.md');
    else
        fname = indexFile;
    end
    if nargin < 4 || isempty(progressFile)
        progressLinkName = 'progress.md';
    else
        [~, baseName, ext] = fileparts(progressFile);
        progressLinkName = [baseName, ext];
    end
    fid = fopen(fname, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    closeFid = onCleanup(@() fclose(fid));

    fprintf(fid, '# Cowork Auto Test — 결과 인덱스\n\n');
    fprintf(fid, '- 실행 시각: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    fprintf(fid, '- 이 chunk 케이스 수: %d\n', numel(results));
    fprintf(fid, '- PASS: %d\n', sum(strcmp({results.status}, 'PASS')));
    fprintf(fid, '- FAIL: %d\n', sum(strcmp({results.status}, 'FAIL')));
    fprintf(fid, '- EXCEPTION: %d\n', sum(strcmp({results.status}, 'EXCEPTION')));
    fprintf(fid, '- CAPTURE_FAIL: %d\n', sum(strcmp({results.status}, 'CAPTURE_FAIL')));
    fprintf(fid, '- SETUP_FAIL: %d\n', sum(strcmp({results.status}, 'SETUP_FAIL')));
    fprintf(fid, '- SKIPPED: %d\n\n', sum(strcmp({results.status}, 'SKIPPED')));
    fprintf(fid, '- Progress log: [%s](%s)\n\n', progressLinkName, progressLinkName);

    fprintf(fid, '## 그룹 요약\n\n');
    fprintf(fid, '| Group | Total | PASS | FAIL | SKIPPED |\n|---|---|---|---|---|\n');
    groups = unique({results.group}, 'stable');
    for g = 1:numel(groups)
        sel    = strcmp({results.group}, groups{g});
        pass   = sum(strcmp({results(sel).status}, 'PASS'));
        skipd  = sum(strcmp({results(sel).status}, 'SKIPPED'));
        total  = sum(sel);
        fail   = total - pass - skipd;
        fprintf(fid, '| %s | %d | %d | %d | %d |\n', groups{g}, total, pass, fail, skipd);
    end

    fprintf(fid, '\n## 케이스 목록\n\n');
    fprintf(fid, '| # | Group | Title | Status | Steps |\n');
    fprintf(fid, '|---|---|---|---|---|\n');
    for i = 1:numel(results)
        r = results(i);
        fprintf(fid, '| %02d | %s | [%s](case%02d.md) | `%s` | %d |\n', ...
            r.id, r.group, r.title, r.id, r.status, r.steps);
    end
    clear closeFid;
end

% =========================================================================
% 50-case matrix
% =========================================================================
function cases = i_buildCaseMatrix()
    % action builders
    P   = @(fIdx, name, lbl)   struct('fn','togglePanel',                 'args',{{fIdx, name}}, 'label',lbl, 'row',NaN);
    BV  = @(fIdx, lbl)         struct('fn','toggleBoardVisibility',       'args',{{fIdx}},       'label',lbl, 'row',NaN);
    BVR = @(lbl)               struct('fn','ensureNoBoardOff',            'args',{{}},           'label',lbl, 'row',NaN);
    BOA = @(offIdx, lbl)       struct('fn','boardOffAddPlotTab',          'args',{{offIdx}},     'label',lbl, 'row',NaN);
    BOC = @(offIdx, lbl)       struct('fn','boardOffClearCurrentTab',     'args',{{offIdx}},     'label',lbl, 'row',NaN);
    BOP = @(offIdx, row, lbl)  struct('fn','boardOffPlotSelectedVariable','args',{{offIdx}},     'label',lbl, 'row',row);
    ATC = @(fIdx, idx, lbl)    struct('fn','applyTimeChange',             'args',{{fIdx, idx}},  'label',lbl, 'row',NaN);
    LP  = @(name, lbl)         struct('fn','applyLayoutPreset',           'args',{{name}},      'label',lbl, 'row',NaN);
    SRS = @(ratio, lbl)        struct('fn','setBodyRowSplitRatio',        'args',{{ratio}},     'label',lbl, 'row',NaN);
    CDS = @(fIdx, sIdx, dx, lbl) struct('fn','simulateColumnSplitterDrag', 'args',{{fIdx, sIdx, dx}}, 'label',lbl, 'row',NaN);
    SLP = @(name, lbl)         struct('fn','saveCurrentLayoutPreset',      'args',{{name}},      'label',lbl, 'row',NaN);
    ASP = @(name, lbl)         struct('fn','applySavedLayoutPreset',       'args',{{name}},      'label',lbl, 'row',NaN);
    DSP = @(name, lbl)         struct('fn','deleteSavedLayoutPreset',      'args',{{name}},      'label',lbl, 'row',NaN);
    RTL = @(lbl)               struct('fn','roundTripProjectLayoutState',  'args',{{}},          'label',lbl, 'row',NaN);
    SVS = @(fIdx, fr, t, vf, df, lbl) struct('fn','setVideoSync', ...
                                              'args',{{fIdx, fr, t, vf, df, true}}, 'label',lbl, 'row',NaN);
    % v-runner: EditDialog dispatch macros
    OED = @(lbl)               struct('fn','openEditDialog',                'args',{{}},          'label',lbl, 'row',NaN);
    CED = @(lbl)               struct('fn','closeEditDialog',               'args',{{}},          'label',lbl, 'row',NaN);
    APD = @(lbl)               struct('fn','applyPendingDialogChanges',     'args',{{}},          'label',lbl, 'row',NaN);
    EDS = @(lbl)               struct('fn','editDialogSaveProject',         'args',{{}},          'label',lbl, 'row',NaN);
    EAO = @(lbl)               struct('fn','editDialogApplyOptionDraft',    'args',{{}},          'label',lbl, 'row',NaN);
    CPC = @(lbl)               struct('fn','capturePlotConfigAndRefresh',   'args',{{}},          'label',lbl, 'row',NaN);
    EDR = @(lbl)               struct('fn','editDialogRebuildPlots',        'args',{{}},          'label',lbl, 'row',NaN);
    EXA = @(v, lbl)            struct('fn','editDialogToggleXAuto',         'args',{{v}},         'label',lbl, 'row',NaN);
    EYA = @(v, lbl)            struct('fn','editDialogToggleYAuto',         'args',{{v}},         'label',lbl, 'row',NaN);
    EAP = @(lbl)               struct('fn','editDialogApplyPlotProps',      'args',{{}},          'label',lbl, 'row',NaN);
    ESA = @(lbl)               struct('fn','editDialogSyncTabXLimAll',      'args',{{}},          'label',lbl, 'row',NaN);
    ESP = @(lbl)               struct('fn','editDialogSyncSelectedPlotXLimAll', 'args',{{}},      'label',lbl, 'row',NaN);
    SET = @(tabName, lbl)      struct('fn','switchEditDialogTab',           'args',{{tabName}},   'label',lbl, 'row',NaN);
    FPT = @(fIdx, lbl)         struct('fn','toggleFlightPlayControlPanel',  'args',{{fIdx}},      'label',lbl, 'row',NaN);
    FPM = @(fIdx, d, lbl)      struct('fn','moveFlightDataFrame',           'args',{{fIdx, d}},   'label',lbl, 'row',NaN);
    FPS = @(fIdx, v, lbl)      struct('fn','handleFlightPlaySliderChange',  'args',{{fIdx, v}},   'label',lbl, 'row',NaN);
    FPF = @(fIdx, v, lbl)      struct('fn','handleFlightPlayFrameInputChange', 'args',{{fIdx, v}}, 'label',lbl, 'row',NaN);
    FPTM = @(fIdx, v, lbl)     struct('fn','handleFlightPlayTimeInputChange', 'args',{{fIdx, v}}, 'label',lbl, 'row',NaN);
    FPR = @(fIdx, lbl)         struct('fn','refreshFlightPlayControlPanel', 'args',{{fIdx}},      'label',lbl, 'row',NaN);
    FPSY = @(t1, t2, en, lbl)  struct('fn','setFlightDataSync',             'args',{{t1, t2, en}}, 'label',lbl, 'row',NaN);
    FPLAY = @(fIdx, lbl)       struct('fn','startFlightPlay',               'args',{{fIdx}},      'label',lbl, 'row',NaN);
    FSTOP = @(fIdx, lbl)       struct('fn','stopFlightPlay',                'args',{{fIdx}},      'label',lbl, 'row',NaN);
    PR  = @(kind, lbl)         struct('fn','loadProjectFixture',            'args',{{kind}},      'label',lbl, 'row',NaN);
    PRF = @(kind, lbl)         struct('fn','loadProjectFixtureSafeFailure', 'args',{{kind}},      'label',lbl, 'row',NaN);
    PRE = @(kind, lbl)         struct('fn','openProjectFixtureInEditDialog','args',{{kind}},      'label',lbl, 'row',NaN);
    VCD = @(fIdx, lbl)         struct('fn','toggleVideoControlDialog',       'args',{{fIdx}},     'label',lbl, 'row',NaN);
    GTF = @(fIdx, fr, lbl)     struct('fn','goToFrame',                     'args',{{fIdx, fr}}, 'label',lbl, 'row',NaN);
    CAP = @(name, fIdx, lbl)   struct('fn','captureRequiredPanel',          'args',{{name, fIdx}}, 'label',lbl, 'row',NaN);

    mk = @(g, t, tgt, exp, acts) struct('group', g, 'title', t, ...
        'target', tgt, 'expected', exp, 'actions', {acts}, 'requireAvi', false);

    cases = struct('group',{}, 'title',{}, 'target',{}, 'expected',{}, 'actions',{}, 'requireAvi',{});

    %% Group A — 보드 off 없음 (5)
    cases(end + 1) = mk('A','A01 기본 로드','','baseline 캡처', {});
    cases(end + 1) = mk('A','A02 보드1 자세 off','','보드1 자세 숨김', ...
        {P(1,'attitude','보드1 자세 off')});
    cases(end + 1) = mk('A','A03 보드1 지도/고도 off','','보드1 map 숨김', ...
        {P(1,'mapOnly','보드1 지도/고도 off')});
    cases(end + 1) = mk('A','A04 보드1 비디오 off','','보드1 비디오 숨김', ...
        {P(1,'video','보드1 비디오 off')});
    cases(end + 1) = mk('A','A05 보드1 자세+지도+비디오 모두 off','','3개 동시 숨김, H 1x 흡수', ...
        {P(1,'attitude','자세 off'), P(1,'mapOnly','지도/고도 off'), P(1,'video','비디오 off')});

    %% Group B — 보드1 off 시나리오 (15)
    cases(end + 1) = mk('B','B01 보드1 off→on','','왕복 정상', ...
        {BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B02 보드1 off + 보드2 자세 off → on','mid-off 영속성','보드2 자세 off 유지', ...
        {BV(1,'보드1 off'), P(2,'attitude','보드2 자세 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B03 보드1 off + 보드2 지도 off → on','mid-off 영속성','보드2 지도 off 유지', ...
        {BV(1,'보드1 off'), P(2,'mapOnly','보드2 지도/고도 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B04 보드1 off + 보드2 비디오 off → on','mid-off 영속성','보드2 비디오 off 유지', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B05 보드1 off + 비디오 off→on 토글 → 보드1 on','비정상#2 회귀','보드2 비디오 visible', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), P(2,'video','보드2 비디오 on'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B06 보드1 off + 보드2 자세+지도 off → on','','복합 mid-off 영속성', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'mapOnly','지도 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B07 보드1 off + off-summary +빈 탭 추가','off-summary 버튼 가시성','새 탭 추가', ...
        {BV(1,'보드1 off'), BOA(1,'off-summary +빈 탭 추가')});
    cases(end + 1) = mk('B','B08 보드1 off + off-summary 현재 탭 지우기','','현재 탭 클리어', ...
        {BV(1,'보드1 off'), BOA(1,'+빈 탭 추가'), BOC(1,'현재 탭 지우기')});
    cases(end + 1) = mk('B','B09 보드1 off + off-summary plot 추가','비정상#1 회귀','X축 데이터 전체 범위', ...
        {BV(1,'보드1 off'), BOP(1, 4, 'off-summary plot 추가 (row=4)')});
    cases(end + 1) = mk('B','B10 B09 + 보드1 on','비정상#1 회귀','X축 ≥ 데이터 전체 유지', ...
        {BV(1,'보드1 off'), BOP(1, 4, 'off-summary plot 추가'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B11 보드2 비디오 off → 보드1 off → on','snapshot 영속성','보드2 비디오 off 유지', ...
        {P(2,'video','보드2 비디오 off'), BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B12 보드2 지도 off → 보드1 off → on','','보드2 지도 off 유지', ...
        {P(2,'mapOnly','보드2 지도 off'), BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B13 보드1 off + 보드2 자세 off→on','','즉시 토글 반응', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'attitude','자세 on')});
    cases(end + 1) = mk('B','B14 보드1 off + 보드2 3개 모두 off','source 1x flex','widths 폴백 작동', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'mapOnly','지도 off'), P(2,'video','비디오 off')});
    cases(end + 1) = mk('B','B15 보드1 off + applyTimeChange','드래그 결과 동기','source 시간 + off-summary 추종', ...
        {BV(1,'보드1 off'), ATC(2, 50, 'applyTimeChange(2,50)'), ATC(2, 200, 'applyTimeChange(2,200)')});

    %% Group C — 보드2 off (B 대칭) (15)
    cases(end + 1) = mk('C','C01 보드2 off→on','','왕복 정상', ...
        {BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C02 보드2 off + 보드1 자세 off → on','mid-off 영속성','보드1 자세 off 유지', ...
        {BV(2,'보드2 off'), P(1,'attitude','보드1 자세 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C03 보드2 off + 보드1 지도 off → on','mid-off 영속성','보드1 지도 off 유지', ...
        {BV(2,'보드2 off'), P(1,'mapOnly','보드1 지도/고도 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C04 보드2 off + 보드1 비디오 off → on','mid-off 영속성','보드1 비디오 off 유지', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C05 보드2 off + 비디오 off→on 토글 → 보드2 on','비정상#2 회귀','보드1 비디오 visible', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), P(1,'video','보드1 비디오 on'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C06 보드2 off + 보드1 자세+지도 off → on','','복합 mid-off', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'mapOnly','지도 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C07 보드2 off + off-summary +빈 탭 추가','','새 탭 추가', ...
        {BV(2,'보드2 off'), BOA(2,'+빈 탭 추가')});
    cases(end + 1) = mk('C','C08 보드2 off + off-summary 현재 탭 지우기','','현재 탭 클리어', ...
        {BV(2,'보드2 off'), BOA(2,'+빈 탭 추가'), BOC(2,'현재 탭 지우기')});
    cases(end + 1) = mk('C','C09 보드2 off + off-summary plot 추가','비정상#1 회귀','X축 데이터 전체 범위', ...
        {BV(2,'보드2 off'), BOP(2, 4, 'off-summary plot 추가 (row=4)')});
    cases(end + 1) = mk('C','C10 C09 + 보드2 on','비정상#1 회귀','X축 유지', ...
        {BV(2,'보드2 off'), BOP(2, 4, 'off-summary plot 추가'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C11 보드1 비디오 off → 보드2 off → on','','보드1 비디오 off 유지', ...
        {P(1,'video','보드1 비디오 off'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C12 보드1 지도 off → 보드2 off → on','','보드1 지도 off 유지', ...
        {P(1,'mapOnly','보드1 지도 off'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C13 보드2 off + 보드1 자세 off→on','','즉시 토글 반응', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'attitude','자세 on')});
    cases(end + 1) = mk('C','C14 보드2 off + 보드1 3개 모두 off','source 1x flex','widths 폴백', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'mapOnly','지도 off'), P(1,'video','비디오 off')});
    cases(end + 1) = mk('C','C15 보드2 off + applyTimeChange','드래그 결과 동기','source 시간 변화', ...
        {BV(2,'보드2 off'), ATC(1, 50, 'applyTimeChange(1,50)'), ATC(1, 200, 'applyTimeChange(1,200)')});

    %% Group D — 전이 / mutual exclusion (10)
    cases(end + 1) = mk('D','D01 보드1 off/on → 보드2 off/on','','순차 토글', ...
        {BV(1,'보드1 off'), BV(1,'보드1 on'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('D','D02 보드1 off 중 보드2 off 호출','mutual exclusion','no-op', ...
        {BV(1,'보드1 off'), BV(2,'보드2 off 시도 (무시되어야 함)')});
    cases(end + 1) = mk('D','D03 보드1 off + 자세 off → on → 자세 on','','잔여 상태 회귀 없음', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), BV(1,'보드1 on'), P(2,'attitude','자세 on')});
    cases(end + 1) = mk('D','D04 복합 전이','','전체 시퀀스 회귀', ...
        {BV(1,'보드1 off'), P(2,'video','비디오 off'), BV(1,'보드1 on'), BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), P(1,'video','보드1 비디오 on'), BV(2,'보드2 on')});
    cases(end + 1) = mk('D','D05 빠른 보드1 off/on 5회','timer/drawnow 회귀','크래시 없음', ...
        {BV(1,'off1'), BV(1,'on1'), BV(1,'off2'), BV(1,'on2'), BV(1,'off3'), BV(1,'on3'), BV(1,'off4'), BV(1,'on4'), BV(1,'off5'), BV(1,'on5')});
    cases(end + 1) = mk('D','D06 보드1 off 중 보드1 자세 off 시도','','hidden 이므로 무영향', ...
        {BV(1,'보드1 off'), P(1,'attitude','보드1 자세 off (off 상태)')});
    cases(end + 1) = mk('D','D07 보드1 off + source 3개 순차 off','단일 1x flex','widths 정확 수렴', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'mapOnly','지도 off'), P(2,'video','비디오 off')});
    cases(end + 1) = mk('D','D08 보드1 off + source 2단계 hide','','폭 흡수', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'mapOnly','지도 off')});
    cases(end + 1) = mk('D','D09 보드2 off + 보드1 비디오 on→off→on','반대 보드 회귀','마지막 on 유지', ...
        {BV(2,'보드2 off'), P(1,'video','비디오 off'), P(1,'video','비디오 on')});
    cases(end + 1) = mk('D','D10 보드1 off 후 off-summary 버튼 가시성','4014bf9 회귀','+빈 탭 추가 보임', ...
        {BV(1,'보드1 off'), BOA(1,'+빈 탭 추가 (보여야 함)')});

    %% Group E — 별표 드래그 결과 (5)
    cases(end + 1) = mk('E','E01 일반 모드 보드1 시간 변화','별표 드래그 결과','marker/spinner 동기', ...
        {ATC(1, 30, 'applyTimeChange(1,30)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end + 1) = mk('E','E02 보드1 off + applyTimeChange','off-summary 동기','marker 추종', ...
        {BV(1,'보드1 off'), ATC(2, 30, 'applyTimeChange(2,30)'), ATC(2, 100, 'applyTimeChange(2,100)')});
    cases(end + 1) = mk('E','E03 보드2 off + applyTimeChange','off-summary 동기','marker 추종', ...
        {BV(2,'보드2 off'), ATC(1, 30, 'applyTimeChange(1,30)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end + 1) = mk('E','E04 AVI 동기 + applyTimeChange','동기 후 frame 추종','video frame 변화', ...
        {SVS(1, 1, 0, 35, 50, 'setVideoSync(1,1,0,35,50)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end + 1) = mk('E','E05 보드1 비디오 off + applyTimeChange','비디오 hidden 회귀','크래시 없음', ...
        {P(1,'video','보드1 비디오 off'), ATC(1, 100, 'applyTimeChange(1,100)')});

    %% Group G - layout regression coverage (10)
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-01 map/altitude independent toggle', ...
        'mapOnly/altOnly', 'independent PanelVisible and width state', ...
        {P(1,'mapOnly','Flight 1 mapOnly toggle'), P(1,'altOnly','Flight 1 altOnly toggle'), P(1,'mapOnly','Flight 1 mapOnly restore')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-02 board-off active board expansion', ...
        'BodyGrid row splitter', 'source board expands, splitter hides', ...
        {BV(1,'upper board off'), BV(1,'upper board on'), BV(2,'lower board off'), BV(2,'lower board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-03 layout-grid arrangement only', ...
        'layout-grid', 'arrangement preset preserves PanelVisible', ...
        {LP('layout-grid','apply layout-grid preset')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-04 layout-vsplit + layout-compact built-in', ...
        'built-in presets', 'two arrangement presets apply cleanly', ...
        {LP('layout-vsplit','apply layout-vsplit preset'), LP('layout-compact','apply layout-compact preset')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-05 custom preset save/apply/delete', ...
        'custom presets', 'arrangement preset save/apply/delete plumbing', ...
        {LP('layout-vsplit','apply layout-vsplit before save'), SLP('auto_test_vsplit','save custom preset'), ...
         LP('layout-compact','change arrangement after save'), ASP('auto_test_vsplit','apply saved custom preset'), ...
         DSP('auto_test_vsplit','delete saved custom preset')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-06 info/dataView toggle', ...
        'info/dataView toggles', 'user-facing buttons drive PanelVisible', ...
        {P(1,'info','Flight 1 info off'), P(1,'dataView','Flight 1 plot off'), ...
         P(1,'info','Flight 1 info on'), P(1,'dataView','Flight 1 plot on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-07 row splitter drag state', ...
        'row splitter', 'row split ratio changes deterministically', ...
        {SRS(0.65,'set row split ratio to 0.65')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-08 column splitter drag state', ...
        'column splitter', 'ColumnWidth changes deterministically, plot=1x preserved', ...
        {LP('layout-vsplit','show info/plot columns'), CDS(1,3,80,'drag Flight 1 info/plot splitter')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-09 marker drag still works after splitter drag', ...
        'drag conflict guard', 'marker/time update survives splitter change', ...
        {LP('layout-vsplit','show info/plot columns'), CDS(1,3,60,'drag Flight 1 info/plot splitter'), ...
         ATC(1, 50, 'applyTimeChange(1,50)')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-10 project layout round-trip', ...
        'project UiState.Layout', 'in-memory project save/load preserves layout state', ...
        {LP('layout-vsplit','apply layout-vsplit preset'), SRS(0.62,'set row split ratio to 0.62'), ...
         RTL('collect/apply project layout state')});
    % v4 P4 (G-LAYOUT-11~15): arrangement-only / plot=1x flex / preset preserves PanelVisible+BoardOff
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-11 layout preset preserves PanelVisible', ...
        'arrangement only', 'preset does not toggle panels', ...
        {LP('layout-vsplit','apply layout-vsplit'), LP('layout-compact','apply layout-compact'), ...
         LP('layout-grid','back to grid')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-12 layout preset preserves BoardOffState', ...
        'arrangement only', 'preset does not change board-off', ...
        {BV(1,'upper board off'), LP('layout-vsplit','apply preset while board off'), ...
         LP('layout-compact','apply another preset'), BV(1,'upper board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-13 splitter drag keeps plot = 1x', ...
        'plot flex guard', 'info/plot splitter does not freeze plot to numeric', ...
        {LP('layout-grid','baseline grid'), CDS(1,3,120,'drag info/plot splitter'), ...
         CDS(1,3,-60,'drag back'), LP('layout-vsplit','reapply preset')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-14 layout-reset preserves PanelVisible+BoardOff', ...
        'reset narrow', 'reset clears widths only, not visibility', ...
        {P(1,'mapOnly','hide map'), LP('layout-reset','reset widths'), ...
         P(1,'mapOnly','restore map')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-15 repeated cycle no drift', ...
        'repeated apply', 'preset+drag cycle stable, no progressive drift', ...
        {LP('layout-vsplit','vsplit'), CDS(1,3,40,'drag1'), LP('layout-grid','grid'), ...
         CDS(1,3,-40,'drag2'), LP('layout-vsplit','vsplit again'), CDS(1,3,30,'drag3')});
    % v3-audit F: G-LAYOUT-16~25 — 5 panel-hide × 2 board-off × 2 layout-preset 조합
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-16 attitude hide + upper board off', ...
        'combo: attitude off + upper off', 'arrangement valid in board-off with hidden attitude', ...
        {P(2,'attitude','flight2 attitude off'), BV(1,'upper board off'), BV(1,'upper board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-17 mapOnly hide + lower board off', ...
        'combo: mapOnly off + lower off', 'arrangement valid', ...
        {P(1,'mapOnly','flight1 mapOnly off'), BV(2,'lower board off'), BV(2,'lower board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-18 altOnly hide + upper board off', ...
        'combo: altOnly off + upper off', 'arrangement valid', ...
        {P(2,'altOnly','flight2 altOnly off'), BV(1,'upper board off'), BV(1,'upper board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-19 attitude+mapOnly hide + board off', ...
        'combo: multi hide + off', 'lower region empty handled', ...
        {P(2,'attitude','off'), P(2,'mapOnly','off'), BV(1,'upper off'), BV(1,'upper on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-20 info hide before board off → forced visible', ...
        'combo: info hide + board off forces info', 'v3-audit B: source single-board analysis', ...
        {P(1,'info','flight1 info off'), BV(2,'lower board off'), BV(2,'lower board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-21 dataView hide before board off → forced visible', ...
        'combo: dataView hide + board off forces dataView', 'v3-audit B', ...
        {P(2,'dataView','flight2 dataView off'), BV(1,'upper board off'), BV(1,'upper board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-22 hsplit + attitude only', ...
        'combo: hsplit + lower attitude-only', 'attitude col span [1 3] horizontal layout', ...
        {P(1,'mapOnly','off'), P(1,'altOnly','off'), LP('layout-hsplit','hsplit')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-23 hsplit + mapOnly only', ...
        'combo: hsplit + lower mapOnly-only', 'map dominant in lower region', ...
        {P(1,'attitude','off'), P(1,'altOnly','off'), LP('layout-hsplit','hsplit')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-24 hsplit + no lower panels', ...
        'combo: hsplit + only info/plot', 'upper region expands fully', ...
        {P(1,'attitude','off'), P(1,'mapOnly','off'), P(1,'altOnly','off'), LP('layout-hsplit','hsplit')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-25 hsplit → grid restoration cycle', ...
        'combo: hsplit/grid round trip', 'normal restoration preserves visibility', ...
        {LP('layout-hsplit','hsplit'), LP('layout-grid','grid'), LP('layout-hsplit','hsplit again'), ...
         LP('layout-reset','reset to default')});
    % v-final P8: board-off 활성 시 source 보드 패널 토글이 정상 작동하고 board-on 복귀 후 보존되는지
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-26 source-board attitude toggle during board-off', ...
        'panel toggle during board-off persists after board-on', 'v-final P8', ...
        {BV(1,'upper board off'), P(2,'attitude','source flight2 attitude toggle'), ...
         BV(1,'upper board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-27 source-board mapOnly toggle during board-off', ...
        'panel toggle during board-off persists after board-on', 'v-final P8', ...
        {BV(2,'lower board off'), P(1,'mapOnly','source flight1 mapOnly toggle'), ...
         BV(2,'lower board on')});
    cases(end + 1) = mk('G-LAYOUT','G-LAYOUT-28 source-board altOnly toggle during board-off', ...
        'panel toggle during board-off persists after board-on', 'v-final P8', ...
        {BV(1,'upper board off'), P(2,'altOnly','source flight2 altOnly toggle'), ...
         BV(1,'upper board on')});

    % v-runner: G-EDIT — EditDialog 6 탭 자동 회귀
    cases(end + 1) = mk('G-EDIT','G-EDIT-01 open + close EditDialog', ...
        'dialog lifecycle', 'open/close 정상', ...
        {OED('open EditDialog'), CED('close EditDialog')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-02 switch all 6 tabs', ...
        '6 tab traversal', 'Project/Files/Sync/Options/Plot Manager/Export 탐색', ...
        {OED('open'), SET('Project','tab=Project'), SET('Files','tab=Files'), ...
         SET('Sync','tab=Sync'), SET('Options','tab=Options'), ...
         SET('Plot Manager','tab=Plot Manager'), SET('Export','tab=Export'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-03 Plot Manager capture + rebuild', ...
        'Plot Manager apply path', 'capture/rebuild 정상', ...
        {OED('open'), SET('Plot Manager','tab=Plot Manager'), ...
         CPC('capturePlotConfig'), EDR('rebuildPlots'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-04 Plot Manager X/Y auto toggle', ...
        'XLimMode/YLimMode auto', 'X/Y auto on/off cycle', ...
        {OED('open'), SET('Plot Manager','tab=Plot Manager'), ...
         EXA(true,'X auto on'), EXA(false,'X auto off'), ...
         EYA(false,'Y auto off'), EYA(true,'Y auto on'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-05 Plot Manager Apply plot props', ...
        'EDPlotApply', 'apply preserves selection', ...
        {OED('open'), SET('Plot Manager','tab=Plot Manager'), EAP('apply props'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-06 Sync X→All Tabs / X→Plot', ...
        'sync helpers', 'all-tabs + selected-plot sync', ...
        {OED('open'), SET('Plot Manager','tab=Plot Manager'), ...
         ESA('Sync X→All Tabs'), ESP('Sync X→Plot'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-07 Options apply draft', ...
        'option apply', 'editDialogApplyOptionDraft 호출', ...
        {OED('open'), SET('Options','tab=Options'), EAO('apply option draft'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-08 Apply pending dialog changes', ...
        'apply pending', 'applyPendingDialogChanges 호출', ...
        {OED('open'), APD('apply pending'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-09 project save through EditDialog', ...
        'project save', 'editDialogSaveProject 호출', ...
        {OED('open'), SET('Project','tab=Project'), EDS('save project'), CED('close')});
    cases(end + 1) = mk('G-EDIT','G-EDIT-10 close auto-applies pending changes', ...
        'close finalize', 'close 시 pending apply', ...
        {OED('open'), SET('Plot Manager','tab=Plot Manager'), EAP('apply'), CED('close')});

    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-01 Flight 1 play control panel toggle', ...
        'flight play panel', 'Flight 1 panel toggles without blank row', ...
        {FPT(1,'Flight 1 play panel open'), FPR(1,'Flight 1 play panel refresh'), FPT(1,'Flight 1 play panel close')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-02 Flight 2 play control panel toggle', ...
        'flight play panel', 'Flight 2 panel toggles without blank row', ...
        {FPT(2,'Flight 2 play panel open'), FPR(2,'Flight 2 play panel refresh'), FPT(2,'Flight 2 play panel close')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-03 Flight 1 manual row navigation', ...
        'row navigation', 'Flight 1 row buttons clamp and sync controls', ...
        {ATC(1,100,'Flight 1 index=100'), FPT(1,'open'), FPM(1,1,'+1'), FPM(1,-1,'-1'), ...
         FPM(1,10,'+10'), FPM(1,-10,'-10'), FPM(1,20,'+20'), FPM(1,-20,'-20')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-04 Flight 2 manual row navigation', ...
        'row navigation', 'Flight 2 row buttons clamp and sync controls', ...
        {ATC(2,100,'Flight 2 index=100'), FPT(2,'open'), FPM(2,1,'+1'), FPM(2,-1,'-1'), ...
         FPM(2,10,'+10'), FPM(2,-10,'-10'), FPM(2,20,'+20'), FPM(2,-20,'-20')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-05 Slider and frame input', ...
        'slider/frame input', 'slider and frame input move to requested rows', ...
        {FPT(1,'open'), FPS(1,80,'slider row 80'), FPF(1,120,'frame row 120')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-06 Time input nearest-row move', ...
        'time input', 'time input moves to nearest row', ...
        {FPT(1,'open'), FPTM(1,0,'time 0 nearest row')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-07 Flight 1 play control with sync enabled', ...
        'flight sync', 'applyTimeChange path handles synced Flight 2', ...
        {FPSY(0,0,true,'enable flight sync at zero'), FPT(1,'open'), FPM(1,10,'Flight 1 +10 through sync')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-08 Board-off safety while play control visible', ...
        'board-off safety', 'visible play panel survives board-off cycle', ...
        {FPT(1,'open Flight 1 play panel'), BV(2,'lower board off'), BV(2,'lower board on'), ...
         FPT(2,'open Flight 2 play panel'), BV(1,'upper board off'), BV(1,'upper board on')});
    cases(end + 1) = mk('H-FLIGHT-PLAY','H-FLIGHT-PLAY-09 Play/Pause timer start-stop cleanup', ...
        'play timer', 'timer can start and stop without leaking active state', ...
        {FPT(1,'open'), FPLAY(1,'start play'), FSTOP(1,'stop play')});

    % I-PROJECT-RESTORE: project fixture restore and safe failure coverage.
    projectKinds = {'full', 'data_only', 'data_plot_single', 'data_plot_multi', ...
        'manual_axis_limits', 'layout_normal_custom_widths', 'layout_lower_board_off', ...
        'layout_upper_board_off', 'layout_hsplit_grid', 'hidden_panel_columns', ...
        'flight_sync', 'video_sync_with_avi', 'missing_plotconfig', 'missing_layout', ...
        'missing_projectsettings', 'flight1_only', 'invalid_data_path', ...
        'invalid_avi_path', 'corrupt_json', 'old_schema', 'extra_unknown_fields'};
    for pIdx = 1:numel(projectKinds)
        kind = projectKinds{pIdx};
        title = sprintf('I-PROJECT-RESTORE-%02d %s fixture', pIdx, kind);
        if any(strcmp(kind, {'invalid_data_path', 'invalid_avi_path', 'corrupt_json'}))
            acts = {PRF(kind, ['safe load failure: ' kind])};
        elseif strcmp(kind, 'layout_lower_board_off')
            acts = {BVR('reset board-off'), BV(2, 'lower board off'), PR(kind, ['restore: ' kind])};
        elseif strcmp(kind, 'layout_upper_board_off')
            acts = {BVR('reset board-off'), BV(1, 'upper board off'), PR(kind, ['restore: ' kind])};
        elseif strcmp(kind, 'hidden_panel_columns')
            acts = {BVR('reset board-off'), P(1, 'info', 'hide info'), P(1, 'dataView', 'hide plot data'), PR(kind, ['restore: ' kind])};
        else
            acts = {BVR('reset board-off'), PR(kind, ['restore: ' kind])};
        end
        cases(end + 1) = mk('I-PROJECT-RESTORE', title, 'project restore', ...
            ['fixture restores concrete state: ' kind], acts);
    end
    cases(end + 1) = mk('I-PROJECT-RESTORE','I-PROJECT-RESTORE-22 edit dialog project open path', ...
        'project restore through edit dialog', 'EditDialog stays visible and project path is restored', ...
        {BVR('reset board-off'), PRE('full', 'open fixture through edit dialog')});

    % J-PANEL-SYNC: cross-panel state propagation for main, edit, video, and flight-play controls.
    for jIdx = 1:10
        fIdx = 1 + mod(jIdx - 1, 2);
        cases(end + 1) = mk('J-PANEL-SYNC', sprintf('J-PANEL-SYNC-%02d flight play row sync F%d', jIdx, fIdx), ...
            'flight play sync', 'frame, slider and main time state stay aligned', ...
            {BVR('reset board-off'), FPT(fIdx, 'open flight play'), FPM(fIdx, 1 + mod(jIdx, 4), 'move data row'), FPR(fIdx, 'refresh play UI')});
    end
    for jIdx = 11:20
        fIdx = 1 + mod(jIdx - 1, 2);
        tabNames = {'Project', 'Files', 'Sync', 'Options', 'Plot Manager', 'Export'};
        tabName = tabNames{1 + mod(jIdx - 11, numel(tabNames))};
        cases(end + 1) = mk('J-PANEL-SYNC', sprintf('J-PANEL-SYNC-%02d edit dialog %s sync', jIdx, tabName), ...
            'edit dialog sync', 'dialog tab switch preserves dashboard state', ...
            {BVR('reset board-off'), OED('open edit dialog'), SET(tabName, ['switch to ' tabName]), ATC(fIdx, 1 + mod(jIdx, 8), 'main time change'), APD('apply pending')});
    end
    for jIdx = 21:30
        fIdx = 1 + mod(jIdx - 1, 2);
        targetFrame = 1 + mod(jIdx * 3, 20);
        cases(end + 1) = mk('J-PANEL-SYNC', sprintf('J-PANEL-SYNC-%02d video control sync F%d', jIdx, fIdx), ...
            'video control sync', 'video control frame and dashboard video state stay aligned', ...
            {BVR('reset board-off'), SVS(fIdx, 1, 0, 30, 50, 'enable video sync'), VCD(fIdx, 'open video control'), GTF(fIdx, targetFrame, 'go to frame'), VCD(fIdx, 'close video control')});
    end

    % K-PANEL-CAPTURE: mandatory external/control-panel capture coverage.
    captureSpecs = { ...
        'main', 1; 'editDialog', 1; 'videoControl', 1; 'videoViewer', 1; ...
        'flightPlay', 1; 'main', 2; 'editDialog', 2; 'videoControl', 2; ...
        'videoViewer', 2; 'flightPlay', 2; 'main', 1; 'editDialog', 1; ...
        'videoControl', 1; 'videoViewer', 1; 'flightPlay', 1; 'main', 2};
    for kIdx = 1:size(captureSpecs, 1)
        panelName = captureSpecs{kIdx, 1};
        fIdx = captureSpecs{kIdx, 2};
        cases(end + 1) = mk('K-PANEL-CAPTURE', sprintf('K-PANEL-CAPTURE-%02d %s F%d', kIdx, panelName, fIdx), ...
            'panel capture', 'required panel capture file exists and is non-empty', ...
            {BVR('reset board-off'), CAP(panelName, fIdx, ['capture ' panelName])});
    end

    % E04 is the ONLY case that needs actual AVI data loaded.
    for k = 1:numel(cases)
        if strncmp(cases(k).title, 'E04', 3)
            cases(k).requireAvi = true;
        elseif contains(cases(k).title, 'video control') || contains(cases(k).title, 'video_sync_with_avi')
            cases(k).requireAvi = true;
        end
    end
end
