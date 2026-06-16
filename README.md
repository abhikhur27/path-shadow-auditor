# Path Shadow Auditor

Windows PowerShell utility that audits `PATH` ordering, flags duplicate or missing directories, and shows when common commands are being shadowed by earlier hits.

## Why it exists

`PATH` drift is a real Windows workflow problem:

- broken entries slow shell startup and confuse installs
- duplicate directories make cleanup harder
- command shadowing hides which `python`, `git`, or `node` you are actually invoking

This tool turns that into a reusable audit instead of a manual `where.exe` scavenger hunt.

## What it does

- Reads the selected `PATH` scope: `Process`, `User`, `Machine`, or `All`
- Splits and normalizes entries
- Flags missing directories and duplicate directories
- Resolves the first hit plus shadowed copies for requested commands
- Exports JSON and Markdown reports for cleanup follow-up

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\path-shadow-auditor.ps1
```

Audit specific commands:

```powershell
powershell -ExecutionPolicy Bypass -File .\path-shadow-auditor.ps1 `
  -Command python,node,git,pwsh `
  -MarkdownOut .\reports\audit.md `
  -JsonOut .\reports\audit.json
```

Audit commands from a file:

```powershell
powershell -ExecutionPolicy Bypass -File .\path-shadow-auditor.ps1 `
  -CommandFile .\targets.txt
```

## Output

- Console summary with first-hit command resolution
- `JSON` report for automation or scripting
- `Markdown` report for cleanup notes

## Portfolio fit

- Stack: PowerShell, Windows, CLI tooling
- Role: practical Windows environment audit utility
- Strongest demo: show duplicate `PATH` entries and command shadowing before a toolchain cleanup
