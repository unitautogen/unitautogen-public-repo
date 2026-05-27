---
name: Bug report
about: Report a bug or unexpected behaviour in UnitAutogen
title: "[BUG] "
labels: bug
assignees: ''
---

## What happened

A clear description of the bug.

## Environment

- **UnitAutogen version:** (see the `VERSION` file)
- **SQL Server version:** (output of `SELECT @@VERSION`)
- **tSQLt version:** (output of `SELECT tSQLt.Info();`)
- **OS:** (Windows / Linux container / etc.)

## Procedure shape

Please describe the stored procedure you ran UnitAutogen against:

- Roughly how many lines?
- Does it use IF/CASE/EXISTS branching, set-based queries, CTEs, dynamic SQL, cursors, or a mix?
- Does it call other procedures, functions, or views?
- (Optional — and only if you can share it) the procedure definition, or a minimal reproduction.

## Steps to reproduce

1.
2.
3.

## Expected behaviour

What you expected to happen.

## Actual behaviour

What actually happened. Include any error messages, stack traces, or screenshots.

## Coverage report (if relevant)

Paste the output of `EXEC TestGen.RunCoverage @OutputMode='TEXT'` if the issue relates to coverage measurement.

## Additional context

Anything else that might help us diagnose — recent changes to the procedure, related procedures involved, etc.
