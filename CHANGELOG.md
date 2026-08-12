# Changelog

All notable changes to PathForge will be documented in this file.

## [Unreleased]

### Added
- Restart Manager lock-holder diagnostics report process names and PIDs before deletion attempts
- Version badge in the README
- Pre-repair SMART failure warning for CHKDSK /F and /R with an explicit override
- Quick volume health card backed by the NTFS corruption-count provider
- Save button for timestamped formatted console reports
- Reusable `PathForge.Core.psm1` module for deletion, repair-process, and storage-diagnostic operations

### Fixed
- Prompt before closing the application during an active repair and terminate the child process only after confirmation
- Bound the output console to 50,000 characters while preserving a visible trim marker
- Apply safe-path validation consistently to ADS scanning/removal and file-unblock operations
- Always remove the temporary empty directory after Robocopy failures
- Stream DISM, SFC, and CHKDSK output through one testable core runner instead of duplicated GUI handlers
- Package the GUI script and required core module together in the Scoop manifest

## [v3.1.0] - 2026-06-20

### Added
- Operation guard and Cancel button for long-running repair commands
- Per-monitor DPI awareness, accessible names/roles, and explicit tab order
- Recycle Bin-first deletion option and Dev Drive/ReFS capability awareness
- Detailed CHKDSK, DISM, and SFC progress and failure guidance
- Explorer context-menu integration and execution-policy-safe batch launcher
- Windows Update reset workflow, ACL CSV export, and Scoop manifest
- Pester test foundation covering path validation, deletion methods, logging, operation state, and volume detection

### Fixed
- Event-handler cleanup, deprecated API use, and security/correctness issues identified by the v3.1 audit

## [v3.0.0] - 2026-06-20

### Fixed
- Path input sanitization: reject dangerous characters (`;|&$()`) before passing to system commands
- Replace emoji/unicode in button and label text with ASCII equivalents for console compatibility
- Fix `$args` automatic variable shadowing in `Invoke-ChkdskFull`
- Add error logging to previously-silent catch blocks in ACL scanner, ADS scanner, and event log queries
- Fix README installation instructions (missing Option 2, incomplete download URL)
- Remove codex-branding block from main form builder
- Use `Start-Process` instead of `cmd /c` string interpolation for long-path and robocopy cleanup deletion
- Sync version strings across CLAUDE.md, CHANGELOG.md, and script header

## [v0.1.0] - 2026-01-01

- Initial release: 6-method escalating deletion, filesystem repair orchestration, NTFS permission management, drive diagnostics

## Roadmap archive — 2026-08-10 — ROADMAP.md

<details>
<summary>Original roadmap snapshot</summary>

```markdown
# PathForge Roadmap

Windows filesystem repair and stubborn-file deletion toolkit with educational panels. Roadmap layers in preview/dry-run workflows, deeper NTFS insight, and automation paths for sysadmins.

## Planned Features

### Deletion & Operations
- Dry-run mode for every deletion method — preview what would be removed and via which API
- Batch mode: feed a CSV/text list of paths, pick method per line
- Scheduled deletion queue viewer/editor (`PendingFileRenameOperations` read/write + cancel)
- Junction / symlink / hardlink inspector with safe-delete that never traverses into targets
- Quarantine zone (move before delete, auto-purge after N days)

### Filesystem Intelligence
- $MFT size + fragmentation report with graph
- USN Journal browser (read-only, filter by reason flags and process)
- Reparse point explorer (type, tag, target)
- ACL diff tool (compare two paths, export effective permissions)
- Sparse file + compressed attribute scanner with toggle actions

### Diagnostics
- SMART history timeline with Event Log correlation
- Storage Spaces health (pool / virtual disk / drive status)
- NTFS vs ReFS feature comparison panel with live capability detection
- SSD wear-level trend (sample reliability counters on a schedule)
- Disk latency live monitor (per-drive read/write ms graph)

### Repair
- One-click repair sequence runner with checkpoint + resume across reboots
- DISM source fallback config (ISO/WIM path, WSUS offline cab)
- Component store size + analyze (`DISM /AnalyzeComponentStore`) + cleanup
- CBS.log + DISM.log parser with color-coded summary

### Packaging & Automation
- CLI parity: every GUI action callable non-interactively
- Intune / SCCM remediation script templates exported from any action
- Authenticode-signed release, winget manifest, `Invoke-Expression` installer

## Competitive Research
- **Unlocker / IObit Unlocker** — stubborn file deletion, closed source, bundled with adware. Lesson: PathForge's transparent escalation ladder is the differentiator.
- **TreeSize / WizTree** — fast MFT scanners for disk usage. Lesson: add an MFT-driven size report tab so users don't leave the app.
- **Disk2vhd / CrystalDiskInfo** — SMART viewers. Lesson: embed CrystalDiskInfo-style SMART decoding; ship no external tool dependency.
- **PowerShell `Repair-Volume`** — built-in CHKDSK wrapper. Lesson: surface it alongside the `chkdsk.exe` path so users see both options.

## Nice-to-Haves
- Boot-time PE environment builder for offline CHKDSK/DISM on system drive
- PowerShell DSC configuration export for hardened/repaired state
- Plugin model for custom "find-and-fix" rules
- Localization (en, es, de, fr, pt-BR)
- Telemetry-free crash reporter that writes local zip bundle
- Dark / light / high-contrast theme toggle

## Open-Source Research (Round 2)

### Related OSS Projects
- https://github.com/ios12checker/Windows-Maintenance-Tool — All-in-one PS/Batch maintenance toolkit, offline-compatible.
- https://github.com/kocken/WindowsRepairScript — SFC + DISM + CHKDSK orchestrator.
- https://github.com/ITJoeSchmo/FixMissingMSI.PowerShell — Windows Installer cache recovery with RPR/LPR phases.
- https://github.com/ikkxeer/PSCacheCleaner — Disk optimization + temp/cache purge orchestrator.
- https://devblogs.microsoft.com/scripting/weekend-scripter-use-powershell-and-pinvoke-to-remove-stubborn-files/ — Boe Prox's canonical MoveFileEx pinvoke pattern for locked files.
- https://github.com/IgorMundstein/WinMemoryCleaner — Empties standby/working-set/system-cache via NtSetSystemInformation.
- https://github.com/PowerShell/PowerShell/discussions/20708 — Community thread on `scd` corruption-deletion tool proposal.
- https://github.com/MicrosoftDocs/windows-powershell-docs — Reference for built-in repair cmdlets (Repair-Volume, Update-FsrmFileScreen).

### Features to Borrow
- SFC + DISM + CHKDSK orchestrator view with tail-log stream in-pane (WindowsRepairScript).
- Installer-cache (MSI/MSP) repair module with RPR and LPR phases (FixMissingMSI.PowerShell).
- Pinvoke wrapper for MoveFileEx and NtSetInformationFile::Disposition (Boe Prox).
- Standby memory purge action — useful after big deletes to release file-backed pages (WinMemoryCleaner).
- ProductCode-based MSI uninstall escalation (msiexec /x → RPR scrub → registry cleanup) (FixMissingMSI).
- Offline mode: pre-cache DISM source (install.wim mount) for air-gapped repair (Windows-Maintenance-Tool).
- One-click "post-repair report" — HTML summary of what was fixed, what failed, next steps (winutil-style).
- Batch ACL reset across whole volumes with progress (icacls /reset /T /C /Q wrapper).

### Patterns & Architectures Worth Studying
- **Escalation-ladder pattern** for deletion (already in project): PS → WMI → short-name → MoveFileEx — add NtSetInformationFile::Disposition as tier 5 for files held by handle.
- **Handle enumeration before delete** — call `handle.exe` or NtQuerySystemInformation(SystemHandleInformation) to name the holding process, prompt user to kill.
- **Structured logging with JSONL output** (Windows-SysAdmin-ProSuite pattern) — every operation a record, easy to feed into Splunk/ELK.
- **DSC configuration export** of post-repair state (already roadmapped — good call; pair with `Invoke-DscResource -Method Test` for drift detection).
- **Transcript + secondary structured log** — `Start-Transcript` for humans plus JSONL for machines.

## Research-Driven Additions (Round 3)

- [ ] P1 -- Restart Manager API for lock-holder identification
  Why: Before attempting deletion, identify which process holds the file open. The Restart Manager API (RmStartSession/RmRegisterResources/RmGetList) is simpler and safer than NtQuerySystemInformation handle enumeration -- no deadlock risk, returns process name directly, works without external tools. No OSS PowerShell GUI tool currently does this.
  Evidence: pldmgg/misc-powershell Get-FileLockProcess (pure PS P/Invoke wrapper); LockHunter (commercial) proves UX value; CrowdStrike Restart Manager blog
  Touches: PathForge.ps1 (new Add-Type block for rstrtmgr.dll P/Invoke, new Get-FileLockProcess function, integrate into Invoke-ForceDelete before escalation, show locking process in console output)
  Acceptance: When a file is locked, console shows "Locked by: ProcessName (PID XXXX)" before attempting deletion methods
  Complexity: M

- [ ] P1 -- Form closing handler for active operation safety
  Why: If the user closes the window while CHKDSK/SFC/DISM is running, the form disposes but the external process continues as an orphan. No FormClosing handler exists to warn or kill the subprocess.
  Evidence: PathForge.ps1:3619 ($mainForm.Dispose() with no FormClosing check); $Script:ActiveProcess holds the reference but nothing checks it on close
  Touches: PathForge.ps1 (Build-MainForm -- add $form.Add_FormClosing handler that checks $Script:OperationRunning, prompts user, calls Stop-ActiveOperation if confirmed)
  Acceptance: Closing the window during an operation shows "An operation is running. Cancel it and close?" with Yes/No; Yes kills the subprocess then closes; No cancels the close
  Complexity: S

- [ ] P1 -- Output console RichTextBox line cap
  Why: Write-Console appends text with no upper bound. Extended CHKDSK /R output or repeated operations can grow the RichTextBox buffer past 64KB, where WinForms performance degrades significantly.
  Evidence: PathForge.ps1:756 (AppendText with no trim); WinForms RichTextBox known performance degradation past MaxLength thresholds
  Touches: PathForge.ps1 (Write-Console -- after AppendText, check TextLength and trim oldest lines when exceeding threshold, e.g., 50K chars)
  Acceptance: After trimming, console shows "[Output trimmed -- oldest entries removed]" marker; no memory growth during 2+ hour CHKDSK /R sessions
  Complexity: S

- [ ] P2 -- Pre-repair SMART health gate
  Why: Running CHKDSK /R on a drive with PredictFailure=TRUE or uncorrectable sectors can cause further data loss. No existing tool warns before repair; CrystalDiskInfo only shows status passively.
  Evidence: CrystalDiskInfo SMART decoding; community signal "don't run chkdsk on a dying drive"; PathForge already queries MSStorageDriver_FailurePredictStatus in Get-DriveHealth
  Touches: PathForge.ps1 (Invoke-ChkdskFix, Invoke-ChkdskFull -- before running, query PredictFailure for the selected drive; if TRUE, show warning MessageBox with "BACKUP FIRST" recommendation and Yes/No to proceed)
  Acceptance: Attempting CHKDSK /F or /R on a drive with PredictFailure=TRUE shows a warning dialog; user can override
  Complexity: S

- [ ] P2 -- Export console output to file
  Why: The console output contains formatted operation results useful for reporting, but there's no way to save it from the GUI. The session log captures raw events but not the formatted console text.
  Evidence: NirSoft tools pattern (CSV/HTML/XML export from any list view); sysadmins need shareable reports
  Touches: PathForge.ps1 (Build-MainForm output panel -- add "Save" button next to Clear/Cancel; handler saves $Script:OutputBox.Text to timestamped .txt in LogPath)
  Acceptance: "Save" button writes console text to PathForge_Logs/Console_YYYYMMDD_HHMMSS.txt and shows confirmation in status bar
  Complexity: S

- [ ] P2 -- Robocopy temp directory cleanup in error path
  Why: Remove-ItemRobocopy creates a temp directory ($emptyDir) at line 954 but if robocopy throws an exception, the catch block at line 968 doesn't remove it, leaking temp directories.
  Evidence: PathForge.ps1:954-968 (New-Item inside try, Remove-Item only on success path, catch has no cleanup)
  Touches: PathForge.ps1 (Remove-ItemRobocopy -- add finally block or move cleanup to ensure it runs regardless of exception)
  Acceptance: No PathForge_Empty_* directories remain in $env:TEMP after failed robocopy operations
  Complexity: S

- [ ] P2 -- CHANGELOG v3.1.0 entry
  Why: Script is at v3.1.0 with 10+ features shipped since v3.0.0 (DPI, accessibility, DISM coaching, Recycle Bin, ReFS awareness, context menu, WU reset, ACL export, Scoop manifest, tests, Cancel button) but CHANGELOG.md only documents up to v3.0.0.
  Evidence: CHANGELOG.md:5 (latest entry is v3.0.0); git log shows 10 feature commits since
  Touches: CHANGELOG.md
  Acceptance: CHANGELOG.md has a v3.1.0 section listing all features shipped since v3.0.0
  Complexity: S

- [ ] P2 -- MSFT_Volume.GetCorruptionCount() pre-CHKDSK check
  Why: The Storage WMI class MSFT_Volume exposes a GetCorruptionCount() method that returns the number of corruptions detected without running a full CHKDSK. This is a near-instant pre-check that can tell users whether a scan is even needed.
  Evidence: Microsoft Learn MSFT_Volume docs; root\Microsoft\Windows\Storage namespace; PathForge already queries Get-Volume for drive info
  Touches: PathForge.ps1 (Build-RepairPage -- add a "Quick Health Check" card that calls GetCorruptionCount on the selected drive and reports the count before any repair operation)
  Acceptance: New card in Repair tab shows corruption count per volume; non-zero count highlights in warning color
  Complexity: S

## Audit Findings

- [ ] P1 -- Path validation coverage for ADS and unblock functions
  Why: Invoke-ADSScanner, Remove-AllADS, Invoke-UnblockFile, Invoke-UnblockRecursive accept user paths without Test-SafePath. These don't use cmd.exe but defense-in-depth says validate everywhere.
  Where: PathForge.ps1 (Invoke-ADSScanner, Remove-AllADS, Invoke-UnblockFile, Invoke-UnblockRecursive)

- [ ] P2 -- Separate logic functions from GUI for testability
  Why: Core deletion, repair, and diagnostic logic is interleaved with WinForms GUI code, making it impossible to unit test without AST extraction hacks. Extracting into a module (PathForge.Core.psm1) would enable direct testing and CLI reuse.
  Where: PathForge.ps1 (all function definitions vs. Build-*Page functions)

- [ ] P2 -- Add version badge to README
  Why: README has PowerShell, Windows, and License badges but no version badge. Users can't see the current version at a glance.
  Where: README.md (badge row)

- [ ] P3 -- Add drag-and-drop path input
  Why: Users encounter locked files in Explorer and expect to drag them onto the app. Currently must browse or type the path.
  Where: PathForge.ps1 (path textbox AllowDrop + DragEnter/DragDrop handlers)
```

</details>
