# Legacy — retired components

## `Get-ParsedPredicates.ps1` (retired in v0.13)

This is the original **PowerShell** predicate parser: it drove Microsoft's
ScriptDom from PowerShell to populate `TestGen.PredicateInbox`.

As of **v0.13** UnitAutogen uses a **single** parser everywhere — the C# SQLCLR
parser in [`../../clr/`](../../clr/), invoked from T-SQL as
`EXEC TestGen.ParseDatabasePredicates`. Maintaining two parsers that had to stay
behaviourally identical was a maintenance trap, so the PowerShell parser is no
longer part of any install or the published module.

It is kept here, **unmaintained**, only as:
- a historical reference for how the parser logic evolved, and
- a last-resort option for an environment that forbids `UNSAFE` SQLCLR entirely
  (in which case the C# parser cannot be registered). It still works against a
  live database, but it is not updated alongside the C# parser and may drift.

The C# parser was validated to produce identical output to this script across all
28 PredicateZoo gates before this one was retired (see CHANGES.md, v0.13).

Do not wire this back into the module or the installer.
