#!/usr/bin/env python3
"""Heuristic static linter for MATLAB (.m) sources.

Python 3 standard library only. Detects a handful of project conventions:
  - single-line try-comma (try ... catch ... end on one line)
  - loop variable named ``i`` (imaginary-unit shadow)
  - bare ``catch`` (no exception variable)
  - catch block with no logging (logCaught/warning/error/rethrow/fprintf)
  - magic-number density per function (heuristic threshold)

Usage:
    python tools/lint_matlab.py FlightDataDashboard.m auto_test_runner.m

Output (one finding per line):
    path:line: severity: message
Exit code: number of HIGH/MEDIUM findings (0 if none), capped at 250.
"""
import re
import sys

# ---- detection regexes -------------------------------------------------
RE_FOR_I = re.compile(r'^\s*for\s+i\s*=')
RE_TRY_INLINE = re.compile(r'\btry\b.*\bcatch\b')
RE_CATCH_BARE = re.compile(r'^\s*catch\s*$')
RE_CATCH_ANY = re.compile(r'^\s*catch\b')
RE_FUNC = re.compile(r'^\s*function\b')
RE_NUM = re.compile(r'(?<![\w.])\d+(?:\.\d+)?(?![\w.])')
LOG_TOKENS = ('logCaught', 'warning(', 'error(', 'rethrow', 'fprintf')
# literals that are not "magic" (indices, flags, common dims)
TRIVIAL_NUMS = {'0', '1', '2', '3', '0.0', '1.0', '100'}
MAGIC_THRESHOLD = 30   # numeric literals in one function body


def strip_comment(line):
    """Best-effort: drop trailing % comment (ignores % inside strings)."""
    in_str = False
    out = []
    i = 0
    while i < len(line):
        c = line[i]
        if c == "'" and not in_str:
            in_str = True
        elif c == "'" and in_str:
            in_str = False
        elif c == '%' and not in_str:
            break
        out.append(c)
        i += 1
    return ''.join(out)


def indent_of(line):
    return len(line) - len(line.lstrip())


def lint_file(path):
    findings = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            raw = fh.read().splitlines()
    except OSError as exc:
        return [(path, 0, 'HIGH', 'cannot read file: %s' % exc)]

    code = [strip_comment(ln) for ln in raw]

    # per-line checks
    for n, ln in enumerate(code, start=1):
        if RE_FOR_I.search(ln):
            findings.append((path, n, 'LOW', "loop variable 'i' shadows imaginary unit; rename"))
        if RE_TRY_INLINE.search(ln):
            findings.append((path, n, 'LOW', 'single-line try-comma; expand to multi-line try/catch'))
        if RE_CATCH_BARE.match(ln):
            findings.append((path, n, 'LOW', "bare 'catch' (no exception variable)"))

    # catch-without-logging (heuristic: indentation-bounded body)
    for n, ln in enumerate(code, start=1):
        if not RE_CATCH_ANY.match(ln):
            continue
        cind = indent_of(ln)
        body, j = [], n  # code is 0-based list; line n -> index n
        while j < len(code):
            bln = code[j]
            stripped = bln.strip()
            if stripped == '' :
                j += 1
                continue
            if stripped == 'end' and indent_of(bln) <= cind:
                break
            if RE_CATCH_ANY.match(bln) and indent_of(bln) == cind and j != n:
                break
            body.append(bln)
            j += 1
        joined = ' '.join(body)
        if body and not any(tok in joined for tok in LOG_TOKENS):
            findings.append((path, n, 'MEDIUM',
                             'catch block has no logging (logCaught/warning/error/rethrow)'))

    # magic-number density per function
    fstart, fname, count = None, None, 0
    def flush(fend):
        if fstart is not None and count > MAGIC_THRESHOLD:
            findings.append((path, fstart, 'LOW',
                             "function '%s' has %d numeric literals (magic-number density)"
                             % (fname or '?', count)))
    for n, ln in enumerate(code, start=1):
        if RE_FUNC.search(ln):
            flush(n - 1)
            fstart = n
            m = re.search(r'function\b(?:.*=)?\s*([A-Za-z_]\w*)', ln)
            fname = m.group(1) if m else '?'
            count = 0
        else:
            for tok in RE_NUM.findall(ln):
                if tok not in TRIVIAL_NUMS:
                    count += 1
    flush(len(code))

    findings.sort(key=lambda f: f[1])
    return findings


def main(argv):
    if len(argv) < 2:
        sys.stderr.write('usage: python lint_matlab.py FILE.m [FILE2.m ...]\n')
        return 2
    severe = 0
    for path in argv[1:]:
        for p, line, sev, msg in lint_file(path):
            print('%s:%d: %s: %s' % (p, line, sev, msg))
            if sev in ('HIGH', 'MEDIUM'):
                severe += 1
    return min(severe, 250)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
