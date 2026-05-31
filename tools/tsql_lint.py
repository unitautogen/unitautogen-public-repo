#!/usr/bin/env python3
"""
tsql_lint.py - offline structural sanity checks for T-SQL scripts.

NOT a full parser. It catches mechanical mistakes that don't need a database to
detect - the ones that cause avoidable round-trips:
  - unbalanced BEGIN/END (counts CASE and BEGIN TRY/CATCH as openers)
  - unbalanced parentheses
  - unterminated '...' string or [...] bracket identifier or /* */ comment
  - a function call inside EXEC( ... )   (e.g. EXEC('..'+QUOTENAME(@x)) - illegal)
  - CREATE PROC/FUNCTION/VIEW/TRIGGER not first in its GO batch (Msg 111)

Comment / string / bracket aware.  Does NOT check semantics, types, column names,
or runtime behaviour - those still need a live SQL Server.  Exit 0 = clean, 1 = problems.

Usage:  python3 tsql_lint.py file1.sql [file2.sql ...]
"""
import sys, re


def mask(sql):
    """Copy of sql with comment/string/bracket contents blanked to spaces
    (newlines preserved); plus a list of (lineno, message) lexing errors."""
    out, errs = [], []
    i, n, line = 0, len(sql), 1
    while i < n:
        c = sql[i]
        nx = sql[i + 1] if i + 1 < n else ''
        if c == '\n':
            out.append('\n'); line += 1; i += 1; continue
        if c == '-' and nx == '-':                      # line comment
            while i < n and sql[i] != '\n':
                out.append(' '); i += 1
            continue
        if c == '/' and nx == '*':                      # block comment
            start = line; out.append('  '); i += 2
            while i < n and not (sql[i] == '*' and i + 1 < n and sql[i + 1] == '/'):
                out.append('\n' if sql[i] == '\n' else ' ')
                if sql[i] == '\n': line += 1
                i += 1
            if i < n:
                out.append('  '); i += 2
            else:
                errs.append((start, "unterminated /* block comment */"))
            continue
        if c == "'":                                    # string literal
            start = line; out.append(' '); i += 1; closed = False
            while i < n:
                if sql[i] == "'" and i + 1 < n and sql[i + 1] == "'":
                    out.append('  '); i += 2; continue
                if sql[i] == "'":
                    out.append(' '); i += 1; closed = True; break
                out.append('\n' if sql[i] == '\n' else ' ')
                if sql[i] == '\n': line += 1
                i += 1
            if not closed:
                errs.append((start, "unterminated '...' string literal"))
            continue
        if c == '[':                                    # bracket identifier
            start = line; out.append(' '); i += 1; closed = False
            while i < n:
                if sql[i] == ']':
                    out.append(' '); i += 1; closed = True; break
                out.append('\n' if sql[i] == '\n' else ' ')
                if sql[i] == '\n': line += 1
                i += 1
            if not closed:
                errs.append((start, "unterminated [...] identifier"))
            continue
        out.append(c); i += 1
    return ''.join(out), errs


def line_of(masked, pos):
    return masked.count('\n', 0, pos) + 1


def check(path):
    sql = open(path, encoding='utf-8-sig').read()
    masked, problems = mask(sql)

    # paren balance
    depth, bad = 0, None
    for idx, ch in enumerate(masked):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth < 0 and bad is None:
                bad = line_of(masked, idx)
    if bad is not None:
        problems.append((bad, "')' with no matching '('"))
    elif depth > 0:
        problems.append((line_of(masked, len(masked) - 1), f"{depth} unclosed '(' - missing ')'"))

    # BEGIN/END balance: an END closes a BEGIN, a CASE, or a TRY/CATCH (BEGIN TRY /
    # END TRY each match via BEGIN/END), so openers = BEGIN + CASE.
    # count BEGIN block-openers but NOT 'BEGIN TRAN[SACTION]' (closed by COMMIT/ROLLBACK, no END)
    begins = len(re.findall(r'\bBEGIN\b(?!\s+(?:DISTRIBUTED\s+)?TRAN)', masked, re.I))
    cases = len(re.findall(r'\bCASE\b', masked, re.I))
    ends = len(re.findall(r'\bEND\b', masked, re.I))
    if begins + cases != ends:
        problems.append((0, f"BEGIN/END imbalance: {begins} BEGIN + {cases} CASE "
                            f"= {begins + cases} openers vs {ends} END"))

    # function call inside EXEC( ... )
    for m in re.finditer(r'\bEXEC(?:UTE)?\s*\(', masked, re.I):
        j, d = m.end() - 1, 0
        while j < len(masked):
            if masked[j] == '(':
                d += 1
            elif masked[j] == ')':
                d -= 1
                if d == 0:
                    break
            j += 1
        inner = masked[m.end():j]
        fn = re.search(r'\b([A-Za-z_]\w*)\s*\(', inner)
        if fn:
            problems.append((line_of(masked, m.start()),
                f"function call '{fn.group(1)}(...)' inside EXEC(...) - illegal; "
                f"build the string into a variable, then EXEC sys.sp_executesql @v"))

    # CREATE PROC/FUNC/VIEW/TRIGGER must be first statement in its GO batch
    lines = masked.split('\n')
    batches, cur, cur_start = [], [], 1
    for ln_i, ln in enumerate(lines, 1):
        if re.match(r'^\s*GO\s*$', ln, re.I):
            batches.append((cur_start, '\n'.join(cur)))
            cur, cur_start = [], ln_i + 1
        else:
            cur.append(ln)
    batches.append((cur_start, '\n'.join(cur)))
    for start_line, b in batches:
        cm = re.search(r'\bCREATE\s+(?:OR\s+ALTER\s+)?(PROCEDURE|PROC|FUNCTION|VIEW|TRIGGER)\b', b, re.I)
        if not cm:
            continue
        before = b[:cm.start()]
        if re.search(r'\b(PRINT|SELECT|INSERT|UPDATE|DELETE|EXEC|EXECUTE|IF|WHILE|DECLARE|SET)\b',
                     before, re.I):
            problems.append((start_line + before.count('\n'),
                f"CREATE {cm.group(1).upper()} is not the first statement in its batch "
                f"(add a GO before it) - SQL Server Msg 111"))

    problems.sort(key=lambda p: p[0])
    return problems


def main(argv):
    any_bad = False
    for path in argv:
        probs = check(path)
        if probs:
            any_bad = True
            print(f"FAIL  {path}")
            for ln, msg in probs:
                print(f"   [{'line ' + str(ln) if ln else 'file'}] {msg}")
        else:
            print(f"ok    {path}")
    return 1 if any_bad else 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    sys.exit(main(sys.argv[1:]))
