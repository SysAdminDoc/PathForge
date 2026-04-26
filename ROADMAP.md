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
