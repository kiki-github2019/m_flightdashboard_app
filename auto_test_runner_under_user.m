function results = auto_test_runner_under_user(varargin)
% AUTO_TEST_RUNNER_UNDER_USER  사용자 입력(모달 dialog) 이 필요한 시나리오 전용 대화형 러너.
%
%   자동 러너(auto_test_runner)는 uigetfile/uiputfile/uiconfirm 등 모달 사용자
%   입력을 기다리는 액션을 차단한다 (AutoTest:UserInputActionBlocked).
%   이 러너는 그 시나리오들을 사람이 직접 조작하고 콘솔에서 판정을 입력하는
%   방식으로 실행·기록한다. 결과는 OutputDir 의 md 파일로 저장된다.
%
%   사용:
%     auto_test_runner_under_user                      % 전체 시나리오
%     auto_test_runner_under_user('Skip', {'U04'})     % 일부 skip
%     auto_test_runner_under_user('OutputDir', 'under_user_results')
%
%   판정 입력: y = PASS, n = FAIL, s = SKIP (사전조건 불충족 등)

p = inputParser;
p.addParameter('OutputDir', 'under_user_results', @(x) ischar(x) || isstring(x));
p.addParameter('Skip', {}, @iscell);
p.parse(varargin{:});
outDir = char(p.Results.OutputDir);
skipIds = p.Results.Skip;

if ~isfolder(outDir), mkdir(outDir); end

scenarios = i_buildScenarios();
results = struct('id', {}, 'title', {}, 'status', {}, 'note', {}, 'autoCheck', {});

fprintf('\n===== Under-User Interactive Test Runner =====\n');
fprintf('시나리오 %d개. 각 단계 안내에 따라 GUI 를 직접 조작한 뒤 판정을 입력하세요.\n', numel(scenarios));
fprintf('판정: y=PASS / n=FAIL / s=SKIP\n\n');

app = i_setupFreshAppLocal();
cleaner = onCleanup(@() i_safeDeleteApp(app));

for k = 1:numel(scenarios)
    sc = scenarios{k};
    r = struct('id', sc.id, 'title', sc.title, 'status', 'SKIP', 'note', '', 'autoCheck', '');
    if any(strcmpi(skipIds, sc.id))
        r.note = 'Skip 파라미터로 제외';
        results(end+1) = r; %#ok<AGROW>
        fprintf('[%s] %s — SKIP (파라미터)\n\n', sc.id, sc.title);
        continue;
    end

    fprintf('--------------------------------------------------\n');
    fprintf('[%s] %s\n', sc.id, sc.title);
    for s = 1:numel(sc.steps)
        fprintf('  %d) %s\n', s, sc.steps{s});
    end

    % 트리거 (모달을 띄우기 직전까지 자동 수행 — 모달 자체는 사람이 처리)
    if ~isempty(sc.trigger)
        try
            sc.trigger(app);
        catch ME
            fprintf('  !! 트리거 실패: %s\n', ME.message);
            r.status = 'FAIL';
            r.note = sprintf('trigger error: %s', ME.message);
            results(end+1) = r; %#ok<AGROW>
            continue;
        end
    end

    ans1 = '';
    while ~any(strcmpi(ans1, {'y', 'n', 's'}))
        ans1 = strtrim(input(sprintf('  [%s] 판정 (y/n/s): ', sc.id), 's'));
    end
    switch lower(ans1)
        case 'y', r.status = 'PASS';
        case 'n', r.status = 'FAIL';
        otherwise, r.status = 'SKIP';
    end
    if strcmp(r.status, 'FAIL')
        r.note = strtrim(input('  실패 메모 (선택): ', 's'));
    end

    % 사후 자동 확인 (가능한 시나리오만)
    if ~isempty(sc.autoCheck)
        try
            [okA, msgA] = sc.autoCheck(app);
            r.autoCheck = sprintf('%s: %s', char(string(okA)), msgA);
            if ~okA && strcmp(r.status, 'PASS')
                fprintf('  !! 자동 확인 불일치: %s (판정 PASS 였으나 상태 검증 실패)\n', msgA);
                r.status = 'FAIL';
                r.note = strtrim([r.note ' auto-check: ' msgA]);
            end
        catch ME
            r.autoCheck = sprintf('check error: %s', ME.message);
        end
    end

    results(end+1) = r; %#ok<AGROW>
    fprintf('  => %s\n\n', r.status);
end

i_writeResultsMd(outDir, results);
fprintf('===== 완료: PASS=%d FAIL=%d SKIP=%d =====\n', ...
    sum(strcmp({results.status}, 'PASS')), sum(strcmp({results.status}, 'FAIL')), ...
    sum(strcmp({results.status}, 'SKIP')));
end

% =========================================================================
function scenarios = i_buildScenarios()
scenarios = {};

scenarios{end+1} = struct( ...
    'id', 'U01', ...
    'title', 'SaveProjectAs — uiputfile 모달 저장', ...
    'steps', {{ ...
        'EditDialog 가 자동으로 열립니다.', ...
        '"다른 이름으로 저장" 버튼을 눌러 uiputfile 모달을 띄우세요.', ...
        '임의 파일명으로 저장 → "project 저장 완료" alert 확인 후 닫으세요.', ...
        '저장 파일이 실제로 생성되었으면 y.'}}, ...
    'trigger', @(app) app.testHook('openEditDialog'), ...
    'autoCheck', []);

scenarios{end+1} = struct( ...
    'id', 'U02', ...
    'title', 'OpenProject — uigetfile 모달 열기', ...
    'steps', {{ ...
        'EditDialog 의 "열기" 버튼을 눌러 uigetfile 모달을 띄우세요.', ...
        'U01 에서 저장한 .fdproj 를 선택해 로드하세요.', ...
        '취소(Cancel) 한 번 → 앱이 멈추지 않는지도 확인.', ...
        '로드 후 보드 상태가 정상 복원되면 y.'}}, ...
    'trigger', [], ...
    'autoCheck', []);

scenarios{end+1} = struct( ...
    'id', 'U03', ...
    'title', 'Sync Search — 수동 검색/T1/T2/적용', ...
    'steps', {{ ...
        '"현재 비행 정보" 테이블에서 숫자 항목 행을 좌클릭으로 선택하세요.', ...
        '우클릭 → "동기시간 찾기..." 로 검색 dialog 를 여세요.', ...
        '값 검색 → 후보 행 선택 → T1 지정. Flight 2 에서도 반복해 T2 지정.', ...
        '"동기 적용" 후 두 보드가 동기되면 y.'}}, ...
    'trigger', [], ...
    'autoCheck', @(app) i_checkFlightSync(app));

scenarios{end+1} = struct( ...
    'id', 'U04', ...
    'title', 'Autosave 복구 dialog (사전조건: autosave 잔존)', ...
    'steps', {{ ...
        '사전조건: 이전 비정상 종료로 autosave 스냅샷이 남아 있어야 합니다.', ...
        '없으면 s (SKIP) 를 입력하세요.', ...
        '앱 재시작 시 복구 confirm 이 뜨고, "복구"/"무시" 가 모두 정상 동작하면 y.'}}, ...
    'trigger', [], ...
    'autoCheck', []);

scenarios{end+1} = struct( ...
    'id', 'U05', ...
    'title', 'Dirty-close confirm — 마지막 시나리오 (앱 종료)', ...
    'steps', {{ ...
        '옵션/플롯 등 임의 변경으로 dirty 상태를 만드세요 (EditDialog 에서 옵션 수정 등).', ...
        '메인 창 X 버튼으로 닫기 → 저장 확인 confirm 이 떠야 합니다.', ...
        '"취소" 선택 시 앱 유지, 다시 닫기 → "저장 안 함" 선택 시 종료되면 y.', ...
        '(이 시나리오 후 앱은 종료된 상태여도 됩니다.)'}}, ...
    'trigger', [], ...
    'autoCheck', []);
end

% =========================================================================
function [ok, msg] = i_checkFlightSync(app)
ok = false;
msg = 'SyncState 확인 불가';
try
    st = app.testHook('getTestState');
    if isfield(st, 'SyncState') && isfield(st.SyncState, 'IsSynced') && logical(st.SyncState.IsSynced)
        ok = true;
        msg = 'SyncState.IsSynced=true';
    else
        msg = 'SyncState.IsSynced=false (동기 미적용)';
    end
catch ME
    msg = ME.message;
end
end

% =========================================================================
function app = i_setupFreshAppLocal()
% 자동 러너 i_setupFreshApp 와 동일한 file-picker 없는 부트스트랩 (AVI 불필요)
app = FlightDataDashboard();
drawnow;
dataFiles = {1, 'flight_data1.dat'; 2, 'flight_data2.dat'};
for k = 1:size(dataFiles, 1)
    fIdx  = dataFiles{k, 1};
    fpath = dataFiles{k, 2};
    if ~isfile(fpath)
        error('UnderUser:MissingDataFile', 'Missing required data file: %s', fpath);
    end
    app.testHook('parseFlightData', fIdx, fpath);
    app.testHook('setupDataUI', fIdx);
    app.testHook('calculateBounds', fIdx);
    app.testHook('initPlots', fIdx);
    app.testHook('updateDashboard', fIdx, 1);
end
drawnow;
end

% =========================================================================
function i_safeDeleteApp(app)
try
    if ~isempty(app) && isvalid(app)
        delete(app);
    end
catch
end
end

% =========================================================================
function i_writeResultsMd(outDir, results)
ts = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
fpath = fullfile(outDir, sprintf('under_user_results_%s.md', ts));
lines = {'# Under-User Interactive Test Results', '', ...
    sprintf('- 실행 시각: %s', datestr(now, 'yyyy-mm-dd HH:MM:SS')), ... %#ok<TNOW1,DATST>
    sprintf('- PASS: %d / FAIL: %d / SKIP: %d', ...
    sum(strcmp({results.status}, 'PASS')), sum(strcmp({results.status}, 'FAIL')), ...
    sum(strcmp({results.status}, 'SKIP'))), '', ...
    '| ID | Title | Status | AutoCheck | Note |', '|---|---|---|---|---|'};
for k = 1:numel(results)
    r = results(k);
    lines{end+1} = sprintf('| %s | %s | `%s` | %s | %s |', ...
        r.id, r.title, r.status, r.autoCheck, r.note); %#ok<AGROW>
end
fid = fopen(fpath, 'w', 'n', 'UTF-8');
if fid < 0
    warning('UnderUser:WriteFailed', 'Could not write %s', fpath);
    return;
end
cleaner = onCleanup(@() fclose(fid));
fwrite(fid, strjoin(lines, newline), 'char');
clear cleaner;
fprintf('결과 저장: %s\n', fpath);
end
