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
%       'End'   (default 50)   : 종료 케이스 번호 (양 끝 포함)
%       'LoadAvi' (default 'lazy') : 'lazy' | 'always' | 'never'
%
%   사용:
%       >> auto_test_runner                      % 전체 50개, lazy AVI
%       >> auto_test_runner('Start',1,'End',10) % 1~10 만 실행 (OOM 회피)
%       >> auto_test_runner('LoadAvi','never')   % AVI 일체 미로드

    p = inputParser;
    p.addParameter('Start',   1,      @(x) isnumeric(x) && isscalar(x) && x >= 1);
    p.addParameter('End',     Inf,    @(x) isnumeric(x) && isscalar(x));
    p.addParameter('LoadAvi', 'lazy', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    opts = p.Results;
    loadAviMode = lower(char(opts.LoadAvi));
    if ~ismember(loadAviMode, {'lazy', 'always', 'never'})
        error('auto_test_runner:BadLoadAvi', 'LoadAvi must be lazy, always, or never.');
    end

    outDir = i_resolveOutputDir();
    if ~isfolder(outDir), mkdir(outDir); end
    fprintf('[auto_test_runner] output dir: %s\n', outDir);

    cases   = i_buildCaseMatrix();
    nCases  = numel(cases);
    iStart  = max(1, round(opts.Start));
    iEnd    = min(nCases, round(opts.End));

    results = repmat(struct('id', 0, 'group', '', 'title', '', ...
                            'status', 'SKIPPED', 'steps', 0, 'error', ''), nCases, 1);
    for i = 1:nCases
        results(i).id    = i;
        results(i).group = cases(i).group;
        results(i).title = cases(i).title;
    end

    for i = iStart:iEnd
        tc = cases(i);
        fprintf('\n[%02d/%02d] %s | %s\n', i, nCases, tc.group, tc.title);

        if tc.requireAvi && strcmp(loadAviMode, 'never')
            r = struct('id', i, 'group', tc.group, 'title', tc.title, ...
                       'status', 'SKIPPED', 'steps', 0, ...
                       'error', 'LoadAvi=never: AVI-required case skipped');
            results(i) = r;
            i_writeCaseMd(outDir, i, tc, r);
            fprintf('  SKIPPED: %s\n', r.error);
            continue;
        end

        i_aggressiveCleanup();   % kill any leftover figures/timers/dialogs

        app = [];
        try
            needAvi = strcmp(loadAviMode, 'always') || ...
                      (strcmp(loadAviMode, 'lazy') && tc.requireAvi);
            app = i_setupFreshApp(needAvi);
            r   = i_runCase(app, tc, i, outDir);
        catch ME
            r = struct('id', i, 'group', tc.group, 'title', tc.title, ...
                       'status', 'SETUP_FAIL', 'steps', 0, 'error', ME.message);
            fprintf('  SETUP_FAIL: %s\n', ME.message);
        end

        try
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        catch
        end
        i_aggressiveCleanup();
        pause(0.2);              % let MATLAB GC settle before next case

        results(i) = r;
        i_writeCaseMd(outDir, i, tc, r);
    end
    i_writeIndexMd(outDir, results);

    nPass = sum(strcmp({results.status}, 'PASS'));
    nFail = sum(strcmp({results.status}, 'FAIL'));
    nExc  = sum(strcmp({results.status}, 'EXCEPTION'));
    nCap  = sum(strcmp({results.status}, 'CAPTURE_FAIL'));
    nSF   = sum(strcmp({results.status}, 'SETUP_FAIL'));
    nSkip = sum(strcmp({results.status}, 'SKIPPED'));
    fprintf('\nDone. %d cases. PASS=%d FAIL=%d EXCEPTION=%d CAPTURE_FAIL=%d SETUP_FAIL=%d SKIPPED=%d\n', ...
        nCases, nPass, nFail, nExc, nCap, nSF, nSkip);
    fprintf('See: %s\n', fullfile(outDir, 'index.md'));
end

% =========================================================================
% Output dir resolution
% =========================================================================
function outDir = i_resolveOutputDir()
    candidates = {};
    if ~isempty(getenv('HOME'))
        candidates{end + 1} = fullfile(getenv('HOME'), 'MATLAB Drive', 'cowork_auto_test');
    end
    if ~isempty(getenv('USERPROFILE'))
        candidates{end + 1} = fullfile(getenv('USERPROFILE'), 'MATLAB Drive', 'cowork_auto_test');
    end
    candidates{end + 1} = fullfile('/MATLAB Drive', 'cowork_auto_test');
    try
        candidates{end + 1} = fullfile(userpath, '..', 'MATLAB Drive', 'cowork_auto_test');
    catch
    end
    candidates{end + 1} = fullfile(pwd, 'cowork_auto_test');

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
function i_aggressiveCleanup()
    % Close only FlightDataDashboard figures created by this runner.
    try
        figs = findall(groot, 'Type', 'figure');
        for k = 1:numel(figs)
            try
                nm = char(figs(k).Name);
                if strcmp(nm, '비행 데이터 리뷰 대시보드 (Dual)') || ...
                        strcmp(nm, '설정/프로젝트 편집기') || ...
                        startsWith(nm, 'AVI 제어 - Flight Data')
                    delete(figs(k));
                end
            catch
            end
        end
    catch
    end
end

% =========================================================================
% Fresh app bootstrap (no file pickers)
% =========================================================================
function app = i_setupFreshApp(needAvi)
    if nargin < 1, needAvi = false; end

    app = FlightDataDashboard();
    drawnow;

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
    drawnow;
end

% =========================================================================
% Per-case runner
% =========================================================================
function r = i_runCase(app, tc, caseIdx, outDir)
    r = struct('id', caseIdx, 'group', tc.group, 'title', tc.title, ...
               'status', 'PASS', 'steps', 0, 'error', '');

    drawnow;
    try
        i_capture(app, outDir, caseIdx, 1);
    catch ME
        r.status = 'CAPTURE_FAIL';
        r.error = sprintf('baseline capture: %s', ME.message);
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
        fprintf('  FAIL: %s\n', r.error);
        return;
    end

    for j = 1:numel(tc.actions)
        act = tc.actions{j};
        try
            beforeState = app.testHook('getTestState');
            i_applyAction(app, act, beforeState);
            exp = i_updateExpectedState(exp, act, beforeState);
        catch ME
            r.status = 'EXCEPTION';
            r.error  = sprintf('step %d (%s): %s', j + 1, act.label, ME.message);
            fprintf('  EXCEPTION at step %d: %s\n', j + 1, ME.message);
        end
        drawnow;
        r.steps = r.steps + 1;
        try
            i_capture(app, outDir, caseIdx, r.steps);
        catch ME
            r.status = 'CAPTURE_FAIL';
            r.error  = sprintf('step %d (%s): %s', j + 1, act.label, ME.message);
            fprintf('  CAPTURE_FAIL at step %d: %s\n', j + 1, ME.message);
        end
        if strcmp(r.status, 'EXCEPTION'), break; end
        if strcmp(r.status, 'CAPTURE_FAIL'), break; end

        st = app.testHook('getTestState');
        [ok, msg] = i_validateState(st, exp);
        if ~ok
            r.status = 'FAIL';
            r.error = sprintf('step %d (%s): %s', j + 1, act.label, msg);
            fprintf('  FAIL at step %d: %s\n', j + 1, msg);
            break;
        end
    end
end

function i_applyAction(app, act, beforeState)
    switch act.fn
        case 'togglePanel'
            fIdx = act.args{1};
            if beforeState.BoardOffState(fIdx)
                return;
            end
            app.testHook('pushPanelToggleButton', act.args{:});
        case 'toggleBoardVisibility'
            app.testHook('pushBoardToggleButton', act.args{:});
        case 'boardOffAddPlotTab'
            app.testHook('boardOffAddPlotTab', act.args{:});
        case 'boardOffClearCurrentTab'
            app.testHook('boardOffClearCurrentTab', act.args{:});
        case 'boardOffPlotSelectedVariable'
            offIdx    = act.args{1};
            sourceIdx = 3 - offIdx;
            if ~isnan(act.row)
                app.testHook('setSelectedRow', sourceIdx, act.row);
            end
            app.testHook('boardOffPlotSelectedVariable', offIdx);
        case 'applyTimeChange'
            app.testHook('applyTimeChange', act.args{:});
        case 'setVideoSync'
            app.testHook('setVideoSync', act.args{:});
        otherwise
            error('AutoTest:UnknownAction', 'Unknown action: %s', act.fn);
    end
end

function exp = i_expectedFromState(st)
    side = struct('attitude', true, 'map', true, 'video', true);
    exp = struct();
    exp.boardOff = logical(st.BoardOffState);
    exp.panel = repmat(side, 1, 2);
    exp.currentIndex = NaN(1, 2);
    exp.minPlotTabCount = zeros(1, 2);
    exp.minTotalPlotCount = zeros(1, 2);
    exp.expectSelectedTabClear = false(1, 2);
    exp.videoSynced = false(1, 2);
    for fIdx = 1:2
        exp.panel(fIdx) = st.boards(fIdx).PanelVisible;
        exp.currentIndex(fIdx) = st.boards(fIdx).currentIndex;
        exp.minPlotTabCount(fIdx) = st.boards(fIdx).plotTabCount;
        exp.minTotalPlotCount(fIdx) = st.boards(fIdx).totalPlotCount;
        exp.videoSynced(fIdx) = st.boards(fIdx).videoSync.IsSynced;
    end
end

function exp = i_updateExpectedState(exp, act, beforeState)
    switch act.fn
        case 'togglePanel'
            fIdx = act.args{1};
            if beforeState.BoardOffState(fIdx)
                return;
            end
            name = char(act.args{2});
            exp.panel(fIdx).(name) = ~exp.panel(fIdx).(name);
        case 'toggleBoardVisibility'
            fIdx = act.args{1};
            if exp.boardOff(fIdx)
                exp.boardOff(fIdx) = false;
            elseif ~any(exp.boardOff)
                exp.boardOff(fIdx) = true;
            end
        case 'boardOffAddPlotTab'
            sourceIdx = 3 - act.args{1};
            exp.minPlotTabCount(sourceIdx) = exp.minPlotTabCount(sourceIdx) + 1;
            exp.expectSelectedTabClear(sourceIdx) = false;
        case 'boardOffClearCurrentTab'
            sourceIdx = 3 - act.args{1};
            exp.expectSelectedTabClear(sourceIdx) = true;
        case 'boardOffPlotSelectedVariable'
            sourceIdx = 3 - act.args{1};
            exp.minTotalPlotCount(sourceIdx) = exp.minTotalPlotCount(sourceIdx) + 1;
            exp.expectSelectedTabClear(sourceIdx) = false;
        case 'applyTimeChange'
            exp.currentIndex(act.args{1}) = act.args{2};
        case 'setVideoSync'
            exp.videoSynced(act.args{1}) = true;
    end
end

function [ok, msg] = i_validateState(st, exp)
    issues = {};
    if sum(st.BoardOffState) > 1
        issues{end + 1} = 'both boards are off'; %#ok<AGROW>
    end

    activeOff = find(st.BoardOffState, 1);
    if isempty(activeOff)
        for fIdx = 1:2
            if ~st.boards(fIdx).panelVisible
                issues{end + 1} = sprintf('board %d panel hidden while no board-off active', fIdx); %#ok<AGROW>
            end
            if st.boards(fIdx).boardOffPanelVisible
                issues{end + 1} = sprintf('board %d summary visible while no board-off active', fIdx); %#ok<AGROW>
            end
            if st.boards(fIdx).infoColumnHidden || st.boards(fIdx).plotColumnHidden
                issues{end + 1} = sprintf('board %d info/plot column hidden after board-on restore', fIdx); %#ok<AGROW>
            end
        end
    else
        offIdx = activeOff;
        srcIdx = 3 - offIdx;
        if st.boards(offIdx).panelVisible
            issues{end + 1} = sprintf('off board %d original panel still visible', offIdx); %#ok<AGROW>
        end
        if ~st.boards(offIdx).boardOffPanelVisible
            issues{end + 1} = sprintf('off board %d summary panel not visible', offIdx); %#ok<AGROW>
        end
        if ~st.boards(srcIdx).panelVisible
            issues{end + 1} = sprintf('source board %d panel hidden', srcIdx); %#ok<AGROW>
        end
        if ~(st.boards(srcIdx).infoColumnHidden && st.boards(srcIdx).plotColumnHidden && st.boards(srcIdx).splitterColumnHidden)
            issues{end + 1} = sprintf('source board %d info/plot columns were not moved out', srcIdx); %#ok<AGROW>
        end
        if st.boards(srcIdx).dataLoaded && st.boards(offIdx).boardOff.tableRows ~= st.boards(srcIdx).dataTableRows
            issues{end + 1} = sprintf('summary table rows mismatch: off=%d source=%d', ...
                st.boards(offIdx).boardOff.tableRows, st.boards(srcIdx).dataTableRows); %#ok<AGROW>
        end
        if ~i_hasButtonText(st.boards(offIdx).boardOff.buttonTexts, '+ 빈 탭 추가') || ...
                ~i_hasButtonText(st.boards(offIdx).boardOff.buttonTexts, '현재 탭 지우기')
            issues{end + 1} = sprintf('off board %d summary plot buttons missing', offIdx); %#ok<AGROW>
        end
        if st.boards(offIdx).boardOff.markerCount > 0 && ...
                st.boards(offIdx).boardOff.interactiveMarkerCount ~= st.boards(offIdx).boardOff.markerCount
            issues{end + 1} = sprintf('off board %d summary marker is not draggable', offIdx); %#ok<AGROW>
        end
        if st.boards(offIdx).boardOff.lineCount > 0 && ...
                st.boards(offIdx).boardOff.interactiveLineCount ~= st.boards(offIdx).boardOff.lineCount
            issues{end + 1} = sprintf('off board %d summary xline is not draggable', offIdx); %#ok<AGROW>
        end
        if st.boards(offIdx).boardOff.markerCount > 0 && st.boards(srcIdx).dataLoaded && ...
                abs(st.boards(offIdx).boardOff.firstMarkerX - st.boards(srcIdx).currentTime) > 0.05
            issues{end + 1} = sprintf('summary marker time mismatch on off board %d', offIdx); %#ok<AGROW>
        end
    end

    for fIdx = 1:2
        if ~st.boards(fIdx).exists
            issues{end + 1} = sprintf('board %d state missing', fIdx); %#ok<AGROW>
            continue;
        end
        names = {'attitude', 'map', 'video'};
        for iName = 1:numel(names)
            nm = names{iName};
            if st.boards(fIdx).PanelVisible.(nm) ~= exp.panel(fIdx).(nm)
                issues{end + 1} = sprintf('board %d %s PanelVisible expected=%d actual=%d', ...
                    fIdx, nm, exp.panel(fIdx).(nm), st.boards(fIdx).PanelVisible.(nm)); %#ok<AGROW>
            end
            if ~st.BoardOffState(fIdx) && st.boards(fIdx).sideHandleVisible.(nm) ~= st.boards(fIdx).PanelVisible.(nm)
                issues{end + 1} = sprintf('board %d %s handle visibility mismatch', fIdx, nm); %#ok<AGROW>
            end
        end
        if st.boards(fIdx).dataLoaded
            if st.boards(fIdx).dataTableRows < 1
                issues{end + 1} = sprintf('board %d data table empty', fIdx); %#ok<AGROW>
            end
            if isfinite(st.boards(fIdx).currentTime) && isfinite(st.boards(fIdx).spinnerValue) && ...
                    abs(st.boards(fIdx).currentTime - st.boards(fIdx).spinnerValue) > 0.01
                issues{end + 1} = sprintf('board %d spinner/current time mismatch', fIdx); %#ok<AGROW>
            end
            if isfinite(exp.currentIndex(fIdx)) && st.boards(fIdx).currentIndex ~= exp.currentIndex(fIdx)
                issues{end + 1} = sprintf('board %d currentIndex expected=%d actual=%d', ...
                    fIdx, exp.currentIndex(fIdx), st.boards(fIdx).currentIndex); %#ok<AGROW>
            end
            if ~st.boards(fIdx).altMarkerInteractive || ~st.boards(fIdx).altLineInteractive
                issues{end + 1} = sprintf('board %d altitude marker/xline callback missing', fIdx); %#ok<AGROW>
            end
        end
        if st.boards(fIdx).plotTabCount < exp.minPlotTabCount(fIdx)
            issues{end + 1} = sprintf('board %d plot tab count below expected minimum', fIdx); %#ok<AGROW>
        end
        if st.boards(fIdx).totalPlotCount < exp.minTotalPlotCount(fIdx)
            issues{end + 1} = sprintf('board %d plot count below expected minimum', fIdx); %#ok<AGROW>
        end
        if exp.expectSelectedTabClear(fIdx) && st.boards(fIdx).selectedTabPlotCount ~= 0
            issues{end + 1} = sprintf('board %d selected tab not cleared', fIdx); %#ok<AGROW>
        end
        if exp.videoSynced(fIdx) && ~st.boards(fIdx).videoSync.IsSynced
            issues{end + 1} = sprintf('board %d video sync not enabled', fIdx); %#ok<AGROW>
        end
        if st.boards(fIdx).videoSync.IsSynced && st.boards(fIdx).videoSync.TotalFrames > 0 && ...
                st.boards(fIdx).dataLoaded && isfinite(st.boards(fIdx).currentTime)
            vss = st.boards(fIdx).videoSync;
            expectedFrame = round(vss.AnchorFrame + (st.boards(fIdx).currentTime - vss.AnchorTime) * vss.VideoFps);
            expectedFrame = max(1, min(expectedFrame, vss.TotalFrames));
            if abs(vss.CurrentFrame - expectedFrame) > 1
                issues{end + 1} = sprintf('board %d video frame mismatch expected=%d actual=%d', ...
                    fIdx, expectedFrame, vss.CurrentFrame); %#ok<AGROW>
            end
        end
    end

    if isempty(activeOff)
        if ~i_buttonStateOk(st.toggleButtons(1), 'off', 'on') || ~i_buttonStateOk(st.toggleButtons(2), 'off', 'on')
            issues{end + 1} = 'board toggle buttons not restored to off/on-enabled labels'; %#ok<AGROW>
        end
    else
        otherIdx = 3 - activeOff;
        if ~i_buttonStateOk(st.toggleButtons(activeOff), 'on', 'on') || ...
                ~i_buttonStateOk(st.toggleButtons(otherIdx), 'off', 'off')
            issues{end + 1} = 'board toggle mutual-exclusion button state mismatch'; %#ok<AGROW>
        end
    end

    ok = isempty(issues);
    if ok
        msg = '';
    else
        msg = strjoin(issues, '; ');
    end
end

function tf = i_hasButtonText(buttonTexts, needle)
    tf = false;
    for k = 1:numel(buttonTexts)
        if contains(buttonTexts{k}, needle)
            tf = true;
            return;
        end
    end
end

function tf = i_buttonStateOk(btn, labelNeedle, enableValue)
    tf = false;
    try
        tf = contains(btn.Text, labelNeedle) && strcmpi(btn.Enable, enableValue);
    catch
        tf = false;
    end
end

% =========================================================================
% Capture helpers
% =========================================================================
function i_capture(app, outDir, caseIdx, stepIdx)
    file = fullfile(outDir, sprintf('case%02d_step%02d.png', caseIdx, stepIdx));
    try
        exportapp(app.UIFigure, file);
        if isfile(file), return; end
    catch
    end
    try
        f = getframe(app.UIFigure);
        imwrite(f.cdata, file);
        if isfile(file), return; end
    catch
    end
    error('AutoTest:CaptureFailed', 'Failed to capture %s', file);
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
        fprintf(fid, '| 01 | baseline (data loaded) | ![](case%02d_step01.png) |\n', idx);
    else
        fprintf(fid, '| - | not executed | - |\n');
    end
    maxActionRows = min(numel(tc.actions), max(0, r.steps - 1));
    for j = 1:maxActionRows
        fprintf(fid, '| %02d | %s | ![](case%02d_step%02d.png) |\n', ...
            j + 1, tc.actions{j}.label, idx, j + 1);
    end

    if ~isempty(r.error)
        fprintf(fid, '\n## Failure Detail\n```\n%s\n```\n', r.error);
    end
    clear closeFid;
end

function i_writeIndexMd(outDir, results)
    fname = fullfile(outDir, 'index.md');
    fid = fopen(fname, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    closeFid = onCleanup(@() fclose(fid));

    fprintf(fid, '# Cowork Auto Test — 결과 인덱스\n\n');
    fprintf(fid, '- 실행 시각: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    fprintf(fid, '- 총 케이스 수: %d\n', numel(results));
    fprintf(fid, '- PASS: %d\n', sum(strcmp({results.status}, 'PASS')));
    fprintf(fid, '- FAIL: %d\n', sum(strcmp({results.status}, 'FAIL')));
    fprintf(fid, '- EXCEPTION: %d\n', sum(strcmp({results.status}, 'EXCEPTION')));
    fprintf(fid, '- CAPTURE_FAIL: %d\n', sum(strcmp({results.status}, 'CAPTURE_FAIL')));
    fprintf(fid, '- SETUP_FAIL: %d\n', sum(strcmp({results.status}, 'SETUP_FAIL')));
    fprintf(fid, '- SKIPPED: %d\n\n', sum(strcmp({results.status}, 'SKIPPED')));

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
    BOA = @(offIdx, lbl)       struct('fn','boardOffAddPlotTab',          'args',{{offIdx}},     'label',lbl, 'row',NaN);
    BOC = @(offIdx, lbl)       struct('fn','boardOffClearCurrentTab',     'args',{{offIdx}},     'label',lbl, 'row',NaN);
    BOP = @(offIdx, row, lbl)  struct('fn','boardOffPlotSelectedVariable','args',{{offIdx}},     'label',lbl, 'row',row);
    ATC = @(fIdx, idx, lbl)    struct('fn','applyTimeChange',             'args',{{fIdx, idx}},  'label',lbl, 'row',NaN);
    SVS = @(fIdx, fr, t, vf, df, lbl) struct('fn','setVideoSync', ...
                                              'args',{{fIdx, fr, t, vf, df, true}}, 'label',lbl, 'row',NaN);

    mk = @(g, t, tgt, exp, acts) struct('group', g, 'title', t, ...
        'target', tgt, 'expected', exp, 'actions', {acts}, 'requireAvi', false);

    cases = struct('group',{}, 'title',{}, 'target',{}, 'expected',{}, 'actions',{}, 'requireAvi',{});

    %% Group A — 보드 off 없음 (5)
    cases(end + 1) = mk('A','A01 기본 로드','','baseline 캡처', {});
    cases(end + 1) = mk('A','A02 보드1 자세 off','','보드1 자세 숨김', ...
        {P(1,'attitude','보드1 자세 off')});
    cases(end + 1) = mk('A','A03 보드1 지도/고도 off','','보드1 map 숨김', ...
        {P(1,'map','보드1 지도/고도 off')});
    cases(end + 1) = mk('A','A04 보드1 비디오 off','','보드1 비디오 숨김', ...
        {P(1,'video','보드1 비디오 off')});
    cases(end + 1) = mk('A','A05 보드1 자세+지도+비디오 모두 off','','3개 동시 숨김, H 1x 흡수', ...
        {P(1,'attitude','자세 off'), P(1,'map','지도/고도 off'), P(1,'video','비디오 off')});

    %% Group B — 보드1 off 시나리오 (15)
    cases(end + 1) = mk('B','B01 보드1 off→on','','왕복 정상', ...
        {BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B02 보드1 off + 보드2 자세 off → on','mid-off 영속성','보드2 자세 off 유지', ...
        {BV(1,'보드1 off'), P(2,'attitude','보드2 자세 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B03 보드1 off + 보드2 지도 off → on','mid-off 영속성','보드2 지도 off 유지', ...
        {BV(1,'보드1 off'), P(2,'map','보드2 지도/고도 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B04 보드1 off + 보드2 비디오 off → on','mid-off 영속성','보드2 비디오 off 유지', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B05 보드1 off + 비디오 off→on 토글 → 보드1 on','비정상#2 회귀','보드2 비디오 visible', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), P(2,'video','보드2 비디오 on'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B06 보드1 off + 보드2 자세+지도 off → on','','복합 mid-off 영속성', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), BV(1,'보드1 on')});
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
        {P(2,'map','보드2 지도 off'), BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end + 1) = mk('B','B13 보드1 off + 보드2 자세 off→on','','즉시 토글 반응', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'attitude','자세 on')});
    cases(end + 1) = mk('B','B14 보드1 off + 보드2 3개 모두 off','source 1x flex','widths 폴백 작동', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), P(2,'video','비디오 off')});
    cases(end + 1) = mk('B','B15 보드1 off + applyTimeChange','드래그 결과 동기','source 시간 + off-summary 추종', ...
        {BV(1,'보드1 off'), ATC(2, 50, 'applyTimeChange(2,50)'), ATC(2, 200, 'applyTimeChange(2,200)')});

    %% Group C — 보드2 off (B 대칭) (15)
    cases(end + 1) = mk('C','C01 보드2 off→on','','왕복 정상', ...
        {BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C02 보드2 off + 보드1 자세 off → on','mid-off 영속성','보드1 자세 off 유지', ...
        {BV(2,'보드2 off'), P(1,'attitude','보드1 자세 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C03 보드2 off + 보드1 지도 off → on','mid-off 영속성','보드1 지도 off 유지', ...
        {BV(2,'보드2 off'), P(1,'map','보드1 지도/고도 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C04 보드2 off + 보드1 비디오 off → on','mid-off 영속성','보드1 비디오 off 유지', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C05 보드2 off + 비디오 off→on 토글 → 보드2 on','비정상#2 회귀','보드1 비디오 visible', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), P(1,'video','보드1 비디오 on'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C06 보드2 off + 보드1 자세+지도 off → on','','복합 mid-off', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'map','지도 off'), BV(2,'보드2 on')});
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
        {P(1,'map','보드1 지도 off'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end + 1) = mk('C','C13 보드2 off + 보드1 자세 off→on','','즉시 토글 반응', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'attitude','자세 on')});
    cases(end + 1) = mk('C','C14 보드2 off + 보드1 3개 모두 off','source 1x flex','widths 폴백', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'map','지도 off'), P(1,'video','비디오 off')});
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
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), P(2,'video','비디오 off')});
    cases(end + 1) = mk('D','D08 보드1 off + source 2단계 hide','','폭 흡수', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off')});
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
        {SVS(1, 230, 36.56, 35, 50, 'setVideoSync(1,230,36.56,35,50)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end + 1) = mk('E','E05 보드1 비디오 off + applyTimeChange','비디오 hidden 회귀','크래시 없음', ...
        {P(1,'video','보드1 비디오 off'), ATC(1, 100, 'applyTimeChange(1,100)')});

    % E04 is the ONLY case that needs actual AVI data loaded.
    for k = 1:numel(cases)
        if strncmp(cases(k).title, 'E04', 3)
            cases(k).requireAvi = true;
        end
    end
end
