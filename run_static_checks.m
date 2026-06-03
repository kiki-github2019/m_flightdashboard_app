function reportPath = run_static_checks(targetFile)
%RUN_STATIC_CHECKS Static checks for FlightDataDashboard.m.
% Save this file in the same folder as FlightDataDashboard.m and run:
%   reportPath = run_static_checks
%
% The script prints progress to the MATLAB Command Window and writes a
% Markdown report under the "static check" folder.

    startedAt = datetime('now');
    rootDir = fileparts(mfilename('fullpath'));
    if nargin < 1 || isempty(targetFile)
        targetFile = fullfile(rootDir, 'FlightDataDashboard.m');
    else
        targetFile = char(targetFile);
        if ~isAbsolutePath(targetFile)
            targetFile = fullfile(rootDir, targetFile);
        end
    end

    fprintf('\n[static-check] Start: %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
    fprintf('[static-check] Target: %s\n', targetFile);

    outDir = fullfile(rootDir, 'static check');
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end
    reportPath = fullfile(outDir, ['static_check_' datestr(now, 'yyyymmdd_HHMMSS') '.md']);

    customRows = {};
    checkcodeRows = {};
    notes = {};

    fprintf('[static-check] 1/6 Checking target file...\n');
    if ~isfile(targetFile)
        customRows(end+1,:) = {'FAIL', 'FILE-001', 'Target file exists', ...
            sprintf('File not found: %s', targetFile), NaN}; %#ok<AGROW>
        writeReport();
        fprintf('[static-check] FAIL: Target file not found.\n');
        return;
    end

    fileInfo = dir(targetFile);
    codeText = fileread(targetFile);
    codeLines = regexp(codeText, '\r\n|\n|\r', 'split');
    if ~isempty(codeLines) && isempty(codeLines{end})
        codeLines(end) = [];
    end
    customRows(end+1,:) = {'PASS', 'FILE-001', 'Target file exists', ...
        sprintf('%d bytes, %d lines', fileInfo.bytes, numel(codeLines)), 1}; %#ok<AGROW>

    fprintf('[static-check] 2/6 Running MATLAB checkcode...\n');
    try
        cc = checkcode(targetFile, '-id');
        checkcodeRows = normalizeCheckcodeOutput(cc);
        customRows(end+1,:) = {'PASS', 'MLINT-001', 'checkcode executed', ...
            sprintf('%d message(s)', size(checkcodeRows, 1)), NaN}; %#ok<AGROW>
    catch ME
        checkcodeRows = {};
        customRows(end+1,:) = {'WARN', 'MLINT-001', 'checkcode executed', ...
            sprintf('checkcode failed: %s', ME.message), NaN}; %#ok<AGROW>
    end

    fprintf('[static-check] 3/6 Checking project/load/export wiring...\n');
    addFunctionExistsCheck('loadAviFileFromPath', 'AVI-001', ...
        'Path-based AVI loader exists');
    addBlockPatternCheck('autoLoadProjectFromFile', 'AUTOLOAD-001', ...
        'Project auto-load does not open file picker for AVI', ...
        'loadAviFile\s*\(', false);
    addBlockAllPatternCheck('autoLoadProjectFromFile', 'AUTOLOAD-002', ...
        'Project auto-load preserves project-restored AVI sync', ...
        {'loadAviFileFromPath\s*\(', '''preserveSync''\s*,\s*true'});
    addBlockPatternCheck('reopenReleasedAvis', 'EXPORT-001', ...
        'Export AVI reopen does not open file picker', ...
        'loadAviFile\s*\(', false);
    addBlockAllPatternCheck('reopenReleasedAvis', 'EXPORT-004', ...
        'Export AVI reopen preserves live dashboard sync', ...
        {'loadAviFileFromPath\s*\(', '''preserveSync''\s*,\s*true'});
    addBlockPatternCheck('requestFileChange', 'FILES-001', ...
        'AVI file replacement uses selected path without second picker', ...
        'case\s+''avi''[\s\S]*loadAviFile\s*\(', false);

    fprintf('[static-check] 4/6 Checking state consistency and close behavior...\n');
    addBlockAllPatternCheck('loadAviFileFromPath', 'AVI-002', ...
        'AVI load updates both runtime path fields', ...
        {'VideoFilePath\s*\{fIdx\}', 'Models\s*\(fIdx\)\.aviFilePath'});
    addBlockAllPatternCheck('loadAviFileFromPath', 'LOADAVI-001', ...
        'Path-based AVI loader can preserve sync snapshots', ...
        {'preserveSync', 'syncSnapshot', 'refreshSyncUi\s*\('});
    addBlockAllPatternCheck('UIFigureCloseRequest', 'CLOSE-001', ...
        'CloseRequest blocks close when save/apply is cancelled or fails', ...
        {'ProjectDirty', 'canClose\s*=\s*true', 'uiputfile\s*\(', ...
         'if\s+~okSave', 'canClose\s*=\s*false;\s*return', ...
         'writeOptionFileAtomic\s*\('});
    addExternalCallCheck('exportEverythingToFolder', 'UI-001', ...
        'Export helper is wired to a user action', 2);
    addPatternCheck('UI-002', 'Edit dialog uifigure is created', ...
        'EditDialog\s*=\s*uifigure\s*\(', true);
    addFunctionExistsCheck('toggleBoardVisibility', 'BOARD-001', ...
        'Main board off/on toggle helper exists');
    addFunctionExistsCheck('createBoardOffSummaryPanel', 'BOARD-002', ...
        'Board off summary panel factory exists');
    addBlockAllPatternCheck('buildHeaderBar', 'BOARD-003', ...
        'Header wires top/bottom board off buttons', ...
        {'상단 보드 off', '하단 보드 off', 'toggleBoardVisibility\s*\(1\)', 'toggleBoardVisibility\s*\(2\)'});
    addBlockAllPatternCheck('toggleBoardVisibility', 'BOARD-004', ...
        'Board toggle prevents both boards from being off at once', ...
        {'otherIdx\s*=\s*3\s*-\s*fIdx', 'BoardOffState\s*\(otherIdx\)', 'updateBoardToggleButtons\s*\('});
    addBlockAllPatternCheck('refreshBoardOffSummaryPanel', 'BOARD-005', ...
        'Board off summary syncs table data and plot markers efficiently', ...
        {'boardOffTable\.Data', 'getBoardOffPlotSignature\s*\(', 'rebuildBoardOffPlots\s*\(', 'syncBoardOffPlotMarkers\s*\('});
    addBlockAllPatternCheck('restoreBoardPanelState', 'BOARD-006', ...
        'Board on restore preserves prior panel visibility and widths', ...
        {'BoardPanelVisibleSnapshot', 'PanelVisible', 'ColumnWidth'});

    fprintf('[static-check] 5/6 Checking export verification and PlotConfig risks...\n');
    addBlockPatternCheck('buildExportFileList', 'EXPORT-002', ...
        'Export list does not silently drop missing project files', ...
        'isfile\s*\(\s*p\s*\)\s*&&', false);
    addBlockAllPatternCheck('buildExportFileList', 'EXPORT-005', ...
        'Export list reports missing project files explicitly', ...
        {'missing\s*=', 'addMissing', 'missing\s*\(end\+1\)'});
    addBlockAllPatternCheck('verifyExportedProject', 'EXPORT-003', ...
        'Export verification checks rewritten project paths and copied file pairs', ...
        {'collectProjectPathFields', 'allWithinFolder', 'collectPathPairs'});
    addBlockAllPatternCheck('rebuildPlotsFromConfig', 'PLOT-001', ...
        'PlotConfig rebuild avoids default-tab index drift', ...
        {'existingTabCount\s*=\s*numel', '\(existingTabCount\s*\+\s*1\)\s*:\s*numel\(tabs\)', ...
         'PlotTabs\s*=\s*\[\]'});
    addBlockAllPatternCheck('capturePlotConfigFromUi', 'PLOT-002', ...
        'PlotConfig capture preserves YColumn', ...
        {'existingPlots', 'yColumn', '''YColumn'''});
    addBlockAllPatternCheck('saveProjectFile', 'PLOT-003', ...
        'Project save captures live PlotConfig before persistence', ...
        {'capturePlotConfigFromUi\s*\(', 'collectCurrentProjectState\s*\('});
    addBlockAllPatternCheck('exportEverythingToFolder', 'PLOT-004', ...
        'Export captures live PlotConfig before project snapshot', ...
        {'capturePlotConfigFromUi\s*\(', 'collectCurrentProjectState\s*\('});
    addBlockPatternCheck('buildEditTabOptions', 'OPTIONS-001', ...
        'Options DisplayColumns table does not expose unsupported Visible column', ...
        '''Visible''', false);
    addBlockPatternCheck('refreshOptionsTab', 'OPTIONS-002', ...
        'Options refresh does not recreate unsupported Visible column', ...
        '''Visible''', false);
    addExternalCallCheck('saveProjectFile', 'PROJECT-001', ...
        'Project save helper is wired beyond its definition', 1);
    addExternalCallCheck('writeOptionFileAtomic', 'OPTION-001', ...
        'Option file writer is wired beyond its definition', 1);

    fprintf('[static-check] 6/6 Writing Markdown report...\n');
    notes{end+1} = sprintf('Generated from %s.', mfilename('fullpath')); %#ok<AGROW>
    notes{end+1} = 'Pattern checks are conservative static checks; inspect FAIL/WARN rows before changing production code.'; %#ok<AGROW>
    writeReport();

    failCount = countSeverity(customRows, 'FAIL');
    warnCount = countSeverity(customRows, 'WARN');
    passCount = countSeverity(customRows, 'PASS');
    elapsedSec = seconds(datetime('now') - startedAt);
    fprintf('[static-check] Done: PASS=%d, WARN=%d, FAIL=%d, checkcode=%d, elapsed=%.2fs\n', ...
        passCount, warnCount, failCount, size(checkcodeRows, 1), elapsedSec);
    fprintf('[static-check] Report saved: %s\n\n', reportPath);

    function addFunctionExistsCheck(funcName, id, title)
        [~, startLine] = getFunctionBlock(codeLines, funcName);
        if isnan(startLine)
            customRows(end+1,:) = {'FAIL', id, title, ...
                sprintf('Missing function: %s', funcName), NaN}; %#ok<AGROW>
        else
            customRows(end+1,:) = {'PASS', id, title, ...
                sprintf('Found function: %s', funcName), startLine}; %#ok<AGROW>
        end
    end

    function addPatternCheck(id, title, pattern, shouldExist)
        [tf, lineNo, evidence] = findPatternInLines(codeLines, pattern);
        if tf == shouldExist
            sev = 'PASS';
        elseif shouldExist
            sev = 'FAIL';
            evidence = ['Missing required pattern: ' pattern];
        else
            sev = 'FAIL';
        end
        customRows(end+1,:) = {sev, id, title, evidence, lineNo}; %#ok<AGROW>
    end

    function addBlockPatternCheck(funcName, id, title, pattern, shouldExist)
        [blockLines, startLine] = getFunctionBlock(codeLines, funcName);
        if isnan(startLine)
            customRows(end+1,:) = {'FAIL', id, title, ...
                sprintf('Function not found: %s', funcName), NaN}; %#ok<AGROW>
            return;
        end
        [tf, relLine, evidence] = findPatternInLines(blockLines, pattern);
        if tf == shouldExist
            sev = 'PASS';
            if isempty(evidence)
                evidence = sprintf('Pattern state OK in %s', funcName);
            end
        elseif shouldExist
            sev = 'FAIL';
            evidence = ['Missing required pattern: ' pattern];
        else
            sev = 'FAIL';
        end
        if isnan(relLine)
            lineNo = startLine;
        else
            lineNo = startLine + relLine - 1;
        end
        customRows(end+1,:) = {sev, id, title, evidence, lineNo}; %#ok<AGROW>
    end

    function addBlockAnyPatternCheck(funcName, id, title, patterns)
        [blockLines, startLine] = getFunctionBlock(codeLines, funcName);
        if isnan(startLine)
            customRows(end+1,:) = {'FAIL', id, title, ...
                sprintf('Function not found: %s', funcName), NaN}; %#ok<AGROW>
            return;
        end
        found = false;
        evidence = '';
        relLine = NaN;
        for k = 1:numel(patterns)
            [tf, tmpLine, tmpEvidence] = findPatternInLines(blockLines, patterns{k});
            if tf
                found = true;
                relLine = tmpLine;
                evidence = tmpEvidence;
                break;
            end
        end
        if found
            customRows(end+1,:) = {'PASS', id, title, evidence, startLine + relLine - 1}; %#ok<AGROW>
        else
            customRows(end+1,:) = {'FAIL', id, title, ...
                ['Missing any of: ' strjoin(patterns, ', ')], startLine}; %#ok<AGROW>
        end
    end

    function addBlockAllPatternCheck(funcName, id, title, patterns)
        [blockLines, startLine] = getFunctionBlock(codeLines, funcName);
        if isnan(startLine)
            customRows(end+1,:) = {'FAIL', id, title, ...
                sprintf('Function not found: %s', funcName), NaN}; %#ok<AGROW>
            return;
        end
        missing = {};
        evidence = {};
        firstLine = NaN;
        for k = 1:numel(patterns)
            [tf, relLine, tmpEvidence] = findPatternInLines(blockLines, patterns{k});
            if tf
                evidence{end+1} = tmpEvidence; %#ok<AGROW>
                if isnan(firstLine), firstLine = startLine + relLine - 1; end
            else
                missing{end+1} = patterns{k}; %#ok<AGROW>
            end
        end
        if isempty(missing)
            customRows(end+1,:) = {'PASS', id, title, strjoin(evidence, ' / '), firstLine}; %#ok<AGROW>
        else
            customRows(end+1,:) = {'FAIL', id, title, ...
                ['Missing: ' strjoin(missing, ', ')], startLine}; %#ok<AGROW>
        end
    end

    function addExternalCallCheck(funcName, id, title, allowedInternalCount)
        pattern = [funcName '\s*\('];
        matches = regexp(codeText, pattern, 'match');
        count = numel(matches);
        if count > allowedInternalCount
            customRows(end+1,:) = {'PASS', id, title, ...
                sprintf('Found %d occurrence(s)', count), NaN}; %#ok<AGROW>
        else
            customRows(end+1,:) = {'WARN', id, title, ...
                sprintf('Only %d occurrence(s); likely helper is not wired to UI/callbacks', count), NaN}; %#ok<AGROW>
        end
    end

    function writeReport()
        fid = fopenUtf8(reportPath);
        cleanup = onCleanup(@() fclose(fid));
        fprintf(fid, '# FlightDataDashboard Static Check\n\n');
        fprintf(fid, '- Generated: %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
        fprintf(fid, '- Target: `%s`\n', targetFile);
        fprintf(fid, '- File size: %d bytes\n', fileInfoOrZero(targetFile));
        fprintf(fid, '- Line count: %d\n\n', numel(codeLines));

        fprintf(fid, '## Summary\n\n');
        fprintf(fid, '| Severity | Count |\n');
        fprintf(fid, '|---|---:|\n');
        fprintf(fid, '| PASS | %d |\n', countSeverity(customRows, 'PASS'));
        fprintf(fid, '| WARN | %d |\n', countSeverity(customRows, 'WARN'));
        fprintf(fid, '| FAIL | %d |\n', countSeverity(customRows, 'FAIL'));
        fprintf(fid, '| checkcode messages | %d |\n\n', size(checkcodeRows, 1));

        fprintf(fid, '## Custom Checks\n\n');
        fprintf(fid, '| Status | ID | Check | Line | Evidence |\n');
        fprintf(fid, '|---|---|---|---:|---|\n');
        for r = 1:size(customRows, 1)
            fprintf(fid, '| %s | `%s` | %s | %s | %s |\n', ...
                escapeMd(customRows{r,1}), escapeMd(customRows{r,2}), ...
                escapeMd(customRows{r,3}), formatLine(customRows{r,5}), ...
                escapeMd(customRows{r,4}));
        end
        fprintf(fid, '\n');

        fprintf(fid, '## MATLAB checkcode\n\n');
        if isempty(checkcodeRows)
            fprintf(fid, 'No checkcode messages or checkcode was unavailable.\n\n');
        else
            fprintf(fid, '| Line | ID | Message |\n');
            fprintf(fid, '|---:|---|---|\n');
            for r = 1:size(checkcodeRows, 1)
                fprintf(fid, '| %s | `%s` | %s |\n', ...
                    formatLine(checkcodeRows{r,1}), escapeMd(checkcodeRows{r,2}), ...
                    escapeMd(checkcodeRows{r,3}));
            end
            fprintf(fid, '\n');
        end

        fprintf(fid, '## Notes\n\n');
        for r = 1:numel(notes)
            fprintf(fid, '- %s\n', escapeMd(notes{r}));
        end
        fprintf(fid, '\n');
    end
end

function tf = isAbsolutePath(p)
    tf = false;
    if isempty(p), return; end
    if numel(p) >= 2 && p(2) == ':'
        tf = true;
    elseif startsWith(p, filesep) || startsWith(p, '\\')
        tf = true;
    end
end

function fid = fopenUtf8(path)
    fid = -1;
    try
        fid = fopen(path, 'w', 'n', 'UTF-8');
    catch
    end
    if fid < 0
        fid = fopen(path, 'w');
    end
    if fid < 0
        error('run_static_checks:ReportOpenFailed', 'Cannot write report: %s', path);
    end
end

function rows = normalizeCheckcodeOutput(cc)
    rows = {};
    if isempty(cc), return; end
    if isstruct(cc)
        for k = 1:numel(cc)
            lineNo = getStructValue(cc(k), {'line', 'Line'}, NaN);
            msgId = getStructValue(cc(k), {'id', 'identifier', 'Identifier'}, '');
            msg = getStructValue(cc(k), {'message', 'Message'}, '');
            rows(end+1,:) = {lineNo, char(msgId), char(msg)}; %#ok<AGROW>
        end
    elseif iscell(cc)
        for k = 1:numel(cc)
            rows(end+1,:) = {NaN, '', char(cc{k})}; %#ok<AGROW>
        end
    elseif isstring(cc)
        for k = 1:numel(cc)
            rows(end+1,:) = {NaN, '', char(cc(k))}; %#ok<AGROW>
        end
    elseif ischar(cc)
        rows(end+1,:) = {NaN, '', cc}; %#ok<AGROW>
    end
end

function val = getStructValue(s, names, defaultVal)
    val = defaultVal;
    for i = 1:numel(names)
        if isfield(s, names{i})
            val = s.(names{i});
            return;
        end
    end
end

function [blockLines, startLine, endLine] = getFunctionBlock(lines, funcName)
    blockLines = {};
    startLine = NaN;
    endLine = NaN;
    for i = 1:numel(lines)
        if ~isempty(regexp(lines{i}, '^\s*function\s+', 'once')) && ...
                ~isempty(regexp(lines{i}, [regexptranslate('escape', funcName) '\s*\('], 'once'))
            startLine = i;
            break;
        end
    end
    if isnan(startLine), return; end
    endLine = numel(lines);
    for j = startLine + 1:numel(lines)
        if ~isempty(regexp(lines{j}, '^\s*function\s+', 'once'))
            endLine = j - 1;
            break;
        end
    end
    blockLines = lines(startLine:endLine);
end

function [tf, lineNo, evidence] = findPatternInLines(lines, pattern)
    tf = false;
    lineNo = NaN;
    evidence = '';
    for i = 1:numel(lines)
        if ~isempty(regexp(lines{i}, pattern, 'once'))
            tf = true;
            lineNo = i;
            evidence = strtrim(lines{i});
            return;
        end
    end
    joined = strjoin(lines, sprintf('\n'));
    if ~isempty(regexp(joined, pattern, 'once'))
        tf = true;
        lineNo = NaN;
        evidence = ['Matched multi-line pattern: ' pattern];
    end
end

function n = countSeverity(rows, severity)
    n = 0;
    if isempty(rows), return; end
    for i = 1:size(rows, 1)
        if strcmp(rows{i,1}, severity)
            n = n + 1;
        end
    end
end

function s = formatLine(v)
    if isempty(v) || (isnumeric(v) && isnan(v))
        s = '';
    elseif isnumeric(v)
        s = sprintf('%g', v);
    else
        s = char(v);
    end
end

function s = escapeMd(v)
    if isempty(v)
        s = '';
        return;
    end
    if isnumeric(v)
        s = formatLine(v);
    else
        s = char(v);
    end
    s = strrep(s, '\', '\\');
    s = strrep(s, '|', '\|');
    s = strrep(s, sprintf('\n'), '<br>');
    s = strrep(s, sprintf('\r'), '');
end

function bytes = fileInfoOrZero(path)
    d = dir(path);
    if isempty(d)
        bytes = 0;
    else
        bytes = d(1).bytes;
    end
end
