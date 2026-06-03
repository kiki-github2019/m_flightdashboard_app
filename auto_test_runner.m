function auto_test_runner()
%AUTO_TEST_RUNNER  FlightDataDashboard 보드 off/on + 패널 토글 50 케이스 회귀.
%
%   결과 저장 경로 (자동 탐지, 첫 매칭 사용):
%       ~/MATLAB Drive/cowork_auto_test          (MATLAB Online / 데스크탑 Drive)
%       %USERPROFILE%/MATLAB Drive/cowork_auto_test
%       /MATLAB Drive/cowork_auto_test           (MATLAB Online 루트)
%       <pwd>/cowork_auto_test                   (최종 폴백)
%
%   생성 파일:
%       index.md                  전체 결과 요약
%       caseNN.md                 케이스별 보고서 (NN=01..50)
%       caseNN_stepMM.png         케이스 각 단계 캡처
%
%   사전 조건:
%       FlightDataDashboard.m, flight_data1.dat, flight_data1_fps35.avi,
%       flight_data2.dat, flight_data2_fps7.avi 가 현재 폴더에 있을 것.
%
%   사용:
%       >> auto_test_runner

    outDir = i_resolveOutputDir();
    if ~isfolder(outDir), mkdir(outDir); end
    fprintf('[auto_test_runner] output dir: %s\n', outDir);

    cases   = i_buildCaseMatrix();
    nCases  = numel(cases);
    results = repmat(struct('id',0,'group','','title','', ...
                            'status','','steps',0,'error',''), nCases, 1);

    for i = 1:nCases
        tc = cases(i);
        fprintf('\n[%02d/%02d] %s | %s\n', i, nCases, tc.group, tc.title);
        app = [];
        try
            app = i_setupFreshApp();
            r   = i_runCase(app, tc, i, outDir);
        catch ME
            r = struct('id', i, 'group', tc.group, 'title', tc.title, ...
                       'status', 'SETUP_FAIL', 'steps', 0, 'error', ME.message);
            fprintf('  SETUP_FAIL: %s\n', ME.message);
        end
        try, if ~isempty(app) && isvalid(app), delete(app); end, catch, end
        results(i) = r;
        i_writeCaseMd(outDir, i, tc, r);
    end
    i_writeIndexMd(outDir, results);

    nPass = sum(strcmp({results.status}, 'PASS'));
    nExc  = sum(strcmp({results.status}, 'EXCEPTION'));
    nSF   = sum(strcmp({results.status}, 'SETUP_FAIL'));
    fprintf('\nDone. %d cases. PASS=%d EXCEPTION=%d SETUP_FAIL=%d\n', ...
        nCases, nPass, nExc, nSF);
    fprintf('See: %s\n', fullfile(outDir, 'index.md'));
end

% =========================================================================
% Output dir resolution
% =========================================================================
function outDir = i_resolveOutputDir()
    candidates = {};
    if ~isempty(getenv('HOME'))
        candidates{end+1} = fullfile(getenv('HOME'), 'MATLAB Drive', 'cowork_auto_test'); %#ok<AGROW>
    end
    if ~isempty(getenv('USERPROFILE'))
        candidates{end+1} = fullfile(getenv('USERPROFILE'), 'MATLAB Drive', 'cowork_auto_test'); %#ok<AGROW>
    end
    candidates{end+1} = fullfile('/MATLAB Drive', 'cowork_auto_test');
    try
        candidates{end+1} = fullfile(userpath, '..', 'MATLAB Drive', 'cowork_auto_test'); %#ok<AGROW>
    catch
    end
    candidates{end+1} = fullfile(pwd, 'cowork_auto_test');

    outDir = '';
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
% Fresh app bootstrap (no file pickers)
% =========================================================================
function app = i_setupFreshApp()
    try
        prior = findall(groot, 'Type', 'figure', ...
            'Name', '비행 데이터 리뷰 대시보드 (Dual)');
        if ~isempty(prior), delete(prior); end
    catch
    end

    app = FlightDataDashboard();
    drawnow;

    dataFiles = {1, 'flight_data1.dat'; 2, 'flight_data2.dat'};
    for k = 1:size(dataFiles, 1)
        fIdx = dataFiles{k, 1};
        fpath = dataFiles{k, 2};
        if ~isfile(fpath), continue; end
        try
            app.parseFlightData(fIdx, fpath);
            app.setupDataUI(fIdx);
            app.calculateBounds(fIdx);
            app.initPlots(fIdx);
            app.updateDashboard(fIdx, 1);
        catch ME
            warning('setupFreshApp:data%d %s', fIdx, ME.message);
        end
    end

    aviFiles = {1, 'flight_data1_fps35.avi'; 2, 'flight_data2_fps7.avi'};
    for k = 1:size(aviFiles, 1)
        fIdx  = aviFiles{k, 1};
        fpath = aviFiles{k, 2};
        if ~isfile(fpath), continue; end
        try
            app.loadAviFileFromPath(fIdx, fpath, struct('promptOnSync', false));
        catch ME
            warning('setupFreshApp:avi%d %s', fIdx, ME.message);
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
    i_capture(app, outDir, caseIdx, 1);
    r.steps = 1;

    for j = 1:numel(tc.actions)
        act = tc.actions{j};
        try
            i_applyAction(app, act);
        catch ME
            r.status = 'EXCEPTION';
            r.error  = sprintf('step %d (%s): %s', j + 1, act.label, ME.message);
            fprintf('  EXCEPTION at step %d: %s\n', j + 1, ME.message);
        end
        drawnow;
        r.steps = r.steps + 1;
        i_capture(app, outDir, caseIdx, r.steps);
        if strcmp(r.status, 'EXCEPTION'), break; end
    end
end

function i_applyAction(app, act)
    switch act.fn
        case 'togglePanel'
            app.togglePanel(act.args{:});
        case 'toggleBoardVisibility'
            app.toggleBoardVisibility(act.args{:});
        case 'boardOffAddPlotTab'
            app.boardOffAddPlotTab(act.args{:});
        case 'boardOffClearCurrentTab'
            app.boardOffClearCurrentTab(act.args{:});
        case 'boardOffPlotSelectedVariable'
            offIdx    = act.args{1};
            sourceIdx = 3 - offIdx;
            if ~isnan(act.row)
                app.Models(sourceIdx).selectedRow = act.row;
            end
            app.boardOffPlotSelectedVariable(offIdx);
        case 'plotSelectedVariable'
            fIdx = act.args{1};
            if ~isnan(act.row)
                app.Models(fIdx).selectedRow = act.row;
            end
            app.plotSelectedVariable(fIdx);
        case 'addPlotTab'
            app.addPlotTab(act.args{:});
        case 'applyTimeChange'
            app.applyTimeChange(act.args{:});
        case 'setVideoSync'
            app.setVideoSync(act.args{:});
        otherwise
            error('AutoTest:UnknownAction', 'Unknown action: %s', act.fn);
    end
end

% =========================================================================
% Capture helpers
% =========================================================================
function i_capture(app, outDir, caseIdx, stepIdx)
    file = fullfile(outDir, sprintf('case%02d_step%02d.png', caseIdx, stepIdx));
    try
        exportapp(app.UIFigure, file);
        return;
    catch
    end
    try
        f = getframe(app.UIFigure);
        imwrite(f.cdata, file);
        return;
    catch
    end
    try
        imwrite(zeros(10, 10, 3, 'uint8'), file);
    catch
    end
end

% =========================================================================
% Markdown writers
% =========================================================================
function i_writeCaseMd(outDir, idx, tc, r)
    fname = fullfile(outDir, sprintf('case%02d.md', idx));
    fid = fopen(fname, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    cu = onCleanup(@() fclose(fid)); %#ok<NASGU>

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
    fprintf(fid, '| 01 | baseline (data + AVI loaded) | ![](case%02d_step01.png) |\n', idx);
    for j = 1:numel(tc.actions)
        fprintf(fid, '| %02d | %s | ![](case%02d_step%02d.png) |\n', ...
            j + 1, tc.actions{j}.label, idx, j + 1);
    end

    if ~isempty(r.error)
        fprintf(fid, '\n## Exception\n```\n%s\n```\n', r.error);
    end
end

function i_writeIndexMd(outDir, results)
    fname = fullfile(outDir, 'index.md');
    fid = fopen(fname, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    cu = onCleanup(@() fclose(fid)); %#ok<NASGU>

    fprintf(fid, '# Cowork Auto Test — 결과 인덱스\n\n');
    fprintf(fid, '- 실행 시각: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    fprintf(fid, '- 총 케이스 수: %d\n', numel(results));
    fprintf(fid, '- PASS: %d\n', sum(strcmp({results.status}, 'PASS')));
    fprintf(fid, '- EXCEPTION: %d\n', sum(strcmp({results.status}, 'EXCEPTION')));
    fprintf(fid, '- SETUP_FAIL: %d\n\n', sum(strcmp({results.status}, 'SETUP_FAIL')));

    fprintf(fid, '## 그룹 요약\n\n');
    fprintf(fid, '| Group | Total | PASS | FAIL |\n|---|---|---|---|\n');
    groups = unique({results.group}, 'stable');
    for g = 1:numel(groups)
        sel = strcmp({results.group}, groups{g});
        pass = sum(strcmp({results(sel).status}, 'PASS'));
        total = sum(sel);
        fprintf(fid, '| %s | %d | %d | %d |\n', groups{g}, total, pass, total - pass);
    end

    fprintf(fid, '\n## 케이스 목록\n\n');
    fprintf(fid, '| # | Group | Title | Status | Steps |\n');
    fprintf(fid, '|---|---|---|---|---|\n');
    for i = 1:numel(results)
        r = results(i);
        fprintf(fid, '| %02d | %s | [%s](case%02d.md) | `%s` | %d |\n', ...
            r.id, r.group, r.title, r.id, r.status, r.steps);
    end
end

% =========================================================================
% 50-case matrix
% =========================================================================
function cases = i_buildCaseMatrix()
    P   = @(fIdx, name, lbl)   struct('fn','togglePanel',                'args',{{fIdx, name}},        'label',lbl, 'row',NaN);
    BV  = @(fIdx, lbl)         struct('fn','toggleBoardVisibility',      'args',{{fIdx}},              'label',lbl, 'row',NaN);
    BOA = @(offIdx, lbl)       struct('fn','boardOffAddPlotTab',         'args',{{offIdx}},            'label',lbl, 'row',NaN);
    BOC = @(offIdx, lbl)       struct('fn','boardOffClearCurrentTab',    'args',{{offIdx}},            'label',lbl, 'row',NaN);
    BOP = @(offIdx, row, lbl)  struct('fn','boardOffPlotSelectedVariable','args',{{offIdx}},           'label',lbl, 'row',row);
    PSV = @(fIdx, row, lbl)    struct('fn','plotSelectedVariable',       'args',{{fIdx}},              'label',lbl, 'row',row);
    APT = @(fIdx, lbl)         struct('fn','addPlotTab',                 'args',{{fIdx}},              'label',lbl, 'row',NaN);
    ATC = @(fIdx, idx, lbl)    struct('fn','applyTimeChange',            'args',{{fIdx, idx}},         'label',lbl, 'row',NaN);
    SVS = @(fIdx, fr, t, vf, df, lbl) struct('fn','setVideoSync',        'args',{{fIdx, fr, t, vf, df, true}}, 'label',lbl, 'row',NaN);

    mk = @(g, t, tgt, exp, acts) struct('group', g, 'title', t, ...
        'target', tgt, 'expected', exp, 'actions', {acts});

    cases = struct('group',{},'title',{},'target',{},'expected',{},'actions',{});

    %% Group A — 보드 off 없음 (5)
    cases(end+1) = mk('A','A01 기본 로드','','baseline 캡처', {});
    cases(end+1) = mk('A','A02 보드1 자세 off','','보드1 자세 숨김', ...
        {P(1,'attitude','보드1 자세 off')});
    cases(end+1) = mk('A','A03 보드1 지도/고도 off','','보드1 map 숨김', ...
        {P(1,'map','보드1 지도/고도 off')});
    cases(end+1) = mk('A','A04 보드1 비디오 off','','보드1 비디오 숨김', ...
        {P(1,'video','보드1 비디오 off')});
    cases(end+1) = mk('A','A05 보드1 자세+지도+비디오 모두 off','','3개 동시 숨김, H 패널 1x 흡수', ...
        {P(1,'attitude','자세 off'), P(1,'map','지도/고도 off'), P(1,'video','비디오 off')});

    %% Group B — 보드1 off 시나리오 (15)
    cases(end+1) = mk('B','B01 보드1 off→on','','왕복 정상', ...
        {BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B02 보드1 off + 보드2 자세 off → on','mid-off 영속성','보드2 자세 off 유지', ...
        {BV(1,'보드1 off'), P(2,'attitude','보드2 자세 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B03 보드1 off + 보드2 지도 off → on','mid-off 영속성','보드2 지도 off 유지', ...
        {BV(1,'보드1 off'), P(2,'map','보드2 지도/고도 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B04 보드1 off + 보드2 비디오 off → on','mid-off 영속성','보드2 비디오 off 유지', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B05 보드1 off + 비디오 off→on 토글 → 보드1 on','비정상#2 회귀','보드2 비디오 visible (재활성 유지)', ...
        {BV(1,'보드1 off'), P(2,'video','보드2 비디오 off'), P(2,'video','보드2 비디오 on'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B06 보드1 off + 보드2 자세+지도 off → on','','복합 mid-off 영속성', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B07 보드1 off + off-summary "+빈 탭 추가"','off-summary 버튼 가시성','새 탭 추가', ...
        {BV(1,'보드1 off'), BOA(1,'off-summary +빈 탭 추가')});
    cases(end+1) = mk('B','B08 보드1 off + off-summary "현재 탭 지우기"','','현재 탭 클리어', ...
        {BV(1,'보드1 off'), BOA(1,'+빈 탭 추가'), BOC(1,'현재 탭 지우기')});
    cases(end+1) = mk('B','B09 보드1 off + off-summary plot 추가','비정상#1 회귀','X축 데이터 전체 범위', ...
        {BV(1,'보드1 off'), BOP(1, 4, 'off-summary plot 추가 (row=4)')});
    cases(end+1) = mk('B','B10 B09 + 보드1 on','비정상#1 회귀','X축 ≥ 데이터 전체 유지', ...
        {BV(1,'보드1 off'), BOP(1, 4, 'off-summary plot 추가'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B11 보드2 비디오 off → 보드1 off → on','snapshot 영속성','보드2 비디오 off 유지', ...
        {P(2,'video','보드2 비디오 off'), BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B12 보드2 지도 off → 보드1 off → on','','보드2 지도 off 유지', ...
        {P(2,'map','보드2 지도 off'), BV(1,'보드1 off'), BV(1,'보드1 on')});
    cases(end+1) = mk('B','B13 보드1 off + 보드2 자세 off→on','','즉시 토글 반응', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'attitude','자세 on')});
    cases(end+1) = mk('B','B14 보드1 off + 보드2 3개 모두 off','source 1x flex','widths 폴백 작동', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), P(2,'video','비디오 off')});
    cases(end+1) = mk('B','B15 보드1 off + applyTimeChange 시뮬레이션','드래그 결과 동기','source 시간 + off-summary 마커 추종', ...
        {BV(1,'보드1 off'), ATC(2, 50, 'applyTimeChange(2,50)'), ATC(2, 200, 'applyTimeChange(2,200)')});

    %% Group C — 보드2 off (B 대칭) (15)
    cases(end+1) = mk('C','C01 보드2 off→on','','왕복 정상', ...
        {BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C02 보드2 off + 보드1 자세 off → on','mid-off 영속성','보드1 자세 off 유지', ...
        {BV(2,'보드2 off'), P(1,'attitude','보드1 자세 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C03 보드2 off + 보드1 지도 off → on','mid-off 영속성','보드1 지도 off 유지', ...
        {BV(2,'보드2 off'), P(1,'map','보드1 지도/고도 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C04 보드2 off + 보드1 비디오 off → on','mid-off 영속성','보드1 비디오 off 유지', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C05 보드2 off + 비디오 off→on 토글 → 보드2 on','비정상#2 회귀','보드1 비디오 visible', ...
        {BV(2,'보드2 off'), P(1,'video','보드1 비디오 off'), P(1,'video','보드1 비디오 on'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C06 보드2 off + 보드1 자세+지도 off → on','','복합 mid-off', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'map','지도 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C07 보드2 off + off-summary "+빈 탭 추가"','','새 탭 추가', ...
        {BV(2,'보드2 off'), BOA(2,'+빈 탭 추가')});
    cases(end+1) = mk('C','C08 보드2 off + off-summary "현재 탭 지우기"','','현재 탭 클리어', ...
        {BV(2,'보드2 off'), BOA(2,'+빈 탭 추가'), BOC(2,'현재 탭 지우기')});
    cases(end+1) = mk('C','C09 보드2 off + off-summary plot 추가','비정상#1 회귀','X축 데이터 전체 범위', ...
        {BV(2,'보드2 off'), BOP(2, 4, 'off-summary plot 추가 (row=4)')});
    cases(end+1) = mk('C','C10 C09 + 보드2 on','비정상#1 회귀','X축 유지', ...
        {BV(2,'보드2 off'), BOP(2, 4, 'off-summary plot 추가'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C11 보드1 비디오 off → 보드2 off → on','','보드1 비디오 off 유지', ...
        {P(1,'video','보드1 비디오 off'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C12 보드1 지도 off → 보드2 off → on','','보드1 지도 off 유지', ...
        {P(1,'map','보드1 지도 off'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('C','C13 보드2 off + 보드1 자세 off→on','','즉시 토글 반응', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'attitude','자세 on')});
    cases(end+1) = mk('C','C14 보드2 off + 보드1 3개 모두 off','source 1x flex','widths 폴백', ...
        {BV(2,'보드2 off'), P(1,'attitude','자세 off'), P(1,'map','지도 off'), P(1,'video','비디오 off')});
    cases(end+1) = mk('C','C15 보드2 off + applyTimeChange 시뮬레이션','드래그 결과 동기','source 시간 변화', ...
        {BV(2,'보드2 off'), ATC(1, 50, 'applyTimeChange(1,50)'), ATC(1, 200, 'applyTimeChange(1,200)')});

    %% Group D — 전이 / mutual exclusion (10)
    cases(end+1) = mk('D','D01 보드1 off/on → 보드2 off/on','','순차 토글', ...
        {BV(1,'보드1 off'), BV(1,'보드1 on'), BV(2,'보드2 off'), BV(2,'보드2 on')});
    cases(end+1) = mk('D','D02 보드1 off 중 보드2 off 호출','mutual exclusion','no-op (보드2 visible 유지)', ...
        {BV(1,'보드1 off'), BV(2,'보드2 off 시도 (무시되어야 함)')});
    cases(end+1) = mk('D','D03 보드1 off + 자세 off → on → 자세 on','','잔여 상태 회귀 없음', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), BV(1,'보드1 on'), P(2,'attitude','자세 on')});
    cases(end+1) = mk('D','D04 복합 전이','','전체 시퀀스 회귀', ...
        {BV(1,'보드1 off'), P(2,'video','비디오 off'), BV(1,'보드1 on'), BV(2,'보드2 off'), P(1,'video','보드1 비디오 on'), BV(2,'보드2 on')});
    cases(end+1) = mk('D','D05 빠른 보드1 off/on 5회','timer/drawnow 회귀','크래시 없음', ...
        {BV(1,'off1'), BV(1,'on1'), BV(1,'off2'), BV(1,'on2'), BV(1,'off3'), BV(1,'on3'), BV(1,'off4'), BV(1,'on4'), BV(1,'off5'), BV(1,'on5')});
    cases(end+1) = mk('D','D06 보드1 off 중 보드1 자세 off 시도','','보드1 hidden 이라 무영향', ...
        {BV(1,'보드1 off'), P(1,'attitude','보드1 자세 off (off 상태)')});
    cases(end+1) = mk('D','D07 보드1 off + source 3개 순차 off','단일 1x flex','widths 정확 수렴', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off'), P(2,'video','비디오 off')});
    cases(end+1) = mk('D','D08 보드1 off + source 2단계 hide','','2개 패널 hide 후 폭 흡수', ...
        {BV(1,'보드1 off'), P(2,'attitude','자세 off'), P(2,'map','지도 off')});
    cases(end+1) = mk('D','D09 보드2 off + 보드1 비디오 on→off→on','반대 보드 회귀','마지막 on 상태 유지', ...
        {BV(2,'보드2 off'), P(1,'video','비디오 off'), P(1,'video','비디오 on')});
    cases(end+1) = mk('D','D10 보드1 off 후 off-summary 버튼 가시성','4014bf9 회귀','+빈 탭 추가 / 현재 탭 지우기 보임', ...
        {BV(1,'보드1 off'), BOA(1,'+빈 탭 추가 (보여야 함)')});

    %% Group E — 별표 드래그 결과 (applyTimeChange 시뮬레이션) (5)
    cases(end+1) = mk('E','E01 일반 모드 보드1 시간 변화','별표 드래그 결과','marker/spinner/avi 동기', ...
        {ATC(1, 30, 'applyTimeChange(1,30)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end+1) = mk('E','E02 보드1 off + applyTimeChange','off-summary 동기','marker 추종', ...
        {BV(1,'보드1 off'), ATC(2, 30, 'applyTimeChange(2,30)'), ATC(2, 100, 'applyTimeChange(2,100)')});
    cases(end+1) = mk('E','E03 보드2 off + applyTimeChange','off-summary 동기 (반대)','marker 추종', ...
        {BV(2,'보드2 off'), ATC(1, 30, 'applyTimeChange(1,30)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end+1) = mk('E','E04 AVI 동기 + applyTimeChange','동기 후 frame 추종','video frame 변화', ...
        {SVS(1, 230, 36.56, 35, 50, 'setVideoSync(1,230,36.56,35,50)'), ATC(1, 100, 'applyTimeChange(1,100)')});
    cases(end+1) = mk('E','E05 보드1 비디오 off + applyTimeChange','비디오 hidden 회귀','크래시 없음', ...
        {P(1,'video','보드1 비디오 off'), ATC(1, 100, 'applyTimeChange(1,100)')});
end
