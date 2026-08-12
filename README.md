# PathForge

**Windows Filesystem Repair & Deletion Suite**

A professional PowerShell GUI toolkit for filesystem repair, stubborn file deletion, permission management, and drive diagnostics. Features a modern dark-themed interface with comprehensive educational panels explaining the underlying Windows concepts.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=flat&logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?style=flat&logo=windows&logoColor=white)
![Version](https://img.shields.io/badge/version-3.1.0-6969FF?style=flat)
![License](https://img.shields.io/badge/License-MIT-green.svg)

---

## Features

### 🗑️ File Operations
- **Six Deletion Methods** — Progressive escalation from PowerShell to WMI, including long path and 8.3 short name techniques
- **Lock-Holder Identification** — Uses Windows Restart Manager to report the process and PID holding a target open before deletion
- **Boot-Time Deletion** — Schedule stubborn files for removal on next restart via MoveFileEx API
- **Scheduled Queue Editor** — Review delete/move pairs and cancel selected next-boot operations without clearing unrelated entries
- **Link Inspector** — Identify junctions, symbolic links, hard-link sibling names, native reparse tags, and targets
- **Reparse Explorer** — Scan trees without descending into links, inspect results, and export a CSV report
- **Quarantine Zone** — Move files and folders into recoverable same-volume storage, restore them, or purge them after a configurable retention period
- **Take Ownership** — Seize control of protected system files with one click
- **Permission Reset** — Restore inheritance and remove explicit deny entries
- **Orphaned SID Cleanup** — Identify and remove permissions for deleted accounts
- **Alternate Data Streams** — Scan and remove hidden NTFS streams (Zone.Identifier, etc.)
- **File Unblocking** — Remove "downloaded from internet" flags recursively

### 🔧 Filesystem Repair
- **CHKDSK Integration** — Online scan, offline repair, bad sector recovery, and spotfix modes
- **SMART Repair Gate** — Warns and recommends a backup before CHKDSK /F or /R when the selected disk predicts failure
- **Quick Corruption Count** — Reads the volume's recorded NTFS corruption count without starting a full scan
- **DISM RestoreHealth** — Repair Windows component store corruption
- **SFC Scannow** — System file integrity verification and repair
- **Full Repair Sequence** — Automated DISM → SFC → CHKDSK in optimal order
- **NTFS Self-Healing** — Enable, disable, or check background repair status
- **Dirty Bit Management** — Query and clear volume dirty flags

### 📊 Diagnostics
- **Drive Health Report** — Physical disk info, volumes, and partition layout
- **MFT Layout Report** — Read native NTFS size, record, extent, and fragmentation data with a physical-placement graph and CSV export
- **USN Journal Browser** — Browse recent NTFS changes by reason flags, close summaries, and optional process evidence without changing the journal
- **SMART Monitoring** — Failure prediction with critical attribute warnings
- **Reliability Counters** — Read/write errors, temperature, wear leveling
- **Event Log Analysis** — Surface disk-related warnings (Event IDs 55, 50, 98, 129, 153, 157)
- **TRIM Status** — Verify SSD optimization is enabled

### 📚 Educational Panels
Every major feature includes an expandable info panel explaining:
- What the operation does and why it works
- Equivalent command-line syntax
- Important warnings and edge cases
- Technical background (ACLs, NTFS internals, Windows APIs)

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 / Server 2016+ |
| **PowerShell** | 5.1 or later (built into Windows) |
| **Privileges** | Administrator (auto-enforced) |
| **Dependencies** | None — uses native Windows components |

---

## Installation

### Option 1: Direct Download
```powershell
# Download and run
$pathForgeDir = Join-Path $env:TEMP "PathForge"
New-Item -Path $pathForgeDir -ItemType Directory -Force | Out-Null
$baseUrl = "https://raw.githubusercontent.com/SysAdminDoc/PathForge/main"
Invoke-WebRequest -Uri "$baseUrl/PathForge.ps1" -OutFile "$pathForgeDir\PathForge.ps1"
Invoke-WebRequest -Uri "$baseUrl/PathForge.Core.psm1" -OutFile "$pathForgeDir\PathForge.Core.psm1"
& "$pathForgeDir\PathForge.ps1"
```

### Option 2: Manual
1. Download `PathForge.ps1` and `PathForge.Core.psm1` from [Releases](https://github.com/SysAdminDoc/PathForge/releases), keeping them in the same folder
2. Right-click -> **Run with PowerShell**
3. Accept the UAC prompt

> **Note:** If you encounter execution policy restrictions:
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
> .\PathForge.ps1
> ```

---

## Usage

### Quick Start
1. Launch PathForge (requires Administrator)
2. Enter a file/folder path, click **Browse**, or drag it from Explorer onto the target field
3. Select an operation from the appropriate tab
4. Monitor progress in the console output panel

### Deletion Strategy
PathForge offers six deletion methods in order of escalation:

| Method | Best For |
|--------|----------|
| **PowerShell** | Standard files, first attempt |
| **.NET** | Files with special characters |
| **Long Path** | Paths exceeding 260 characters |
| **Short Name** | Unicode issues, malformed names |
| **Robocopy Mirror** | Folders with deep nesting or permissions |
| **WMI** | Last resort before boot-time deletion |

If all methods fail, use **Schedule Boot-Time Deletion** — the file will be removed before Windows fully loads.

Use **Pending Queue** to inspect the raw next-boot operation pairs. PathForge preserves Windows queue prefixes and unselected entries exactly, and refuses a cancellation if another process changed the queue after it was loaded.

Enable **Dry-run only** to inventory the target, preview a bounded sample, and see which deletion API would run at each escalation step without changing files, ownership, links, the Recycle Bin, or the reboot queue.

### Batch Deletion

Use **Batch Delete** to load either CSV or plain text. CSV supports `Path`, `Method`, and optional `DryRun` columns:

```csv
Path,Method,DryRun
C:\Temp\old.log,Standard,true
C:\Temp\locked-folder,Robocopy,false
C:\Temp\remove-at-boot.sys,BootTime,false
```

Text files use `path|method|dry-run`; method and dry-run are optional. Supported methods are `Auto`, `Standard`, `DotNet`, `LongPath`, `ShortName`, `Robocopy`, `WMI`, `RecycleBin`, `Quarantine`, `BootTime`, and `ReparsePoint`. PathForge previews every row and asks once before processing any mutating row.

### Quarantine Zone

Open **Quarantine Zone** from File Operations to move the current target into recovery storage, restore a selected item to its original path, permanently purge selected entries, or change the retention period (30 days by default). PathForge runs retention maintenance when the application opens; an invalid policy or manifest fails closed and is never auto-purged.

Each local or mapped volume uses its own hidden `PathForge.Quarantine` directory so folder quarantine is a same-volume move instead of a recursive copy. Every item has an atomic JSON recovery manifest. Purge walks the quarantined tree without following nested junctions or symbolic links, and restore refuses to overwrite an existing destination. Top-level reparse points remain under Link Inspector rather than quarantine.

### Link Safety

Use **Link Inspector** on a file or directory to distinguish ordinary objects, hard links, symbolic links, junctions, and volume mount points. For hard links, every sibling name is listed. **Safe Delete Link** re-inspects the object immediately before deletion and removes only the selected directory entry; it refuses ordinary files/directories and opaque reparse-point types. Dry-run mode previews this action without changing the link.

Use **Reparse Explorer** on a directory to list reparse type, native tag, path, and target. Its iterative scan never enqueues a discovered reparse-point directory, so target trees are not traversed. Results can be inspected individually or exported to CSV.

### MFT Layout

Open **MFT Layout** from Diagnostics to inspect the selected NTFS volume without modifying it. The report shows valid and allocated MFT size, estimated file-record count, cluster/record sizes, fragmentation boundaries, and every native extent. The graph plots logical MFT order against physical cluster placement and marks the reserved MFT zone; the extent table can be exported to CSV.

The report is NTFS-only and uses the application's required administrator access. If Windows provides volume metadata but refuses the extent query, PathForge keeps the size report visible and explains why the placement map is unavailable.

### USN Journal Browser

Open **USN Journal** from Diagnostics to read a bounded recent window of an NTFS change journal. Filter by native reason flags (create, delete, rename, data, security, reparse, stream, or basic-information changes), request final close summaries, cap retained records, and export the normalized results to CSV. PathForge only calls query/read controls; it never creates, resizes, or deletes a journal.

USN records do not contain a process ID or executable name. When **Correlate process evidence** is enabled—or a process-name filter is entered—PathForge makes a best-effort name/time correlation against existing Security event 4663 records. This is labeled as correlated evidence, not direct USN attribution, and is available only when Audit File System and a matching object SACL already produced those events. PathForge does not change audit policy or SACLs.

### Repair Sequence
For corrupted systems, run repairs in this order:

```
1. DISM /RestoreHealth  →  Repairs the component store
2. SFC /scannow         →  Repairs system files using the store
3. CHKDSK /F            →  Repairs filesystem structures
```

The **Full Repair Sequence** button automates this process.

Reusable deletion, repair, and diagnostic commands are also available for automation:

```powershell
Import-Module .\PathForge.Core.psm1
Get-Command -Module PathForge.Core
```

---

## Interface

### Tab Overview

| Tab | Purpose |
|-----|---------|
| **File Operations** | Deletion, ownership, permissions, ADS management |
| **Filesystem Repair** | CHKDSK, DISM, SFC, NTFS self-healing |
| **Diagnostics** | Drive health, SMART, event logs, TRIM |
| **Help** | Quick reference and methodology guide |

### Console Output
- **Success** — Green text
- **Error** — Red text
- **Warning** — Yellow/orange text
- **Progress** — Blue text with percentage updates
- **Info** — Standard output
- **Saveable Reports** — Export the formatted console to a timestamped text file

All operations log to: `%USERPROFILE%\Documents\PathForge_Logs\Session_*.log`

---

## Educational Content

PathForge includes detailed explanations accessible via **ℹ️ Show Details** buttons:

| Topic | Key Concepts |
|-------|--------------|
| **ACLs** | DACL vs SACL, inheritance flags (OI)(CI)(IO), permission types |
| **Alternate Data Streams** | Zone.Identifier, NTFS-only feature, security implications |
| **Ownership** | TrustedInstaller, SeTakeOwnershipPrivilege, why ownership matters |
| **Orphaned SIDs** | S-1-5-21-* patterns, causes, safe removal |
| **Boot-Time Deletion** | MoveFileEx API, PendingFileRenameOperations registry key |
| **Robocopy Mirror** | /MIR flag technique, why empty folder sync works |
| **CHKDSK** | /scan vs /F vs /R vs /spotfix, when each is appropriate |
| **SFC vs DISM** | Critical ordering, component store architecture |
| **SMART** | Attributes 05/C5/C6, failure prediction statistics |
| **Dirty Bit** | What triggers it, fsutil behavior, boot implications |
| **NTFS Self-Healing** | Background repair, Event IDs 55/98, when to disable |
| **Long Paths** | MAX_PATH 260 limit, \\\\?\\ prefix, registry enablement |
| **8.3 Short Names** | DOS compatibility, fsutil enumeration, deletion workaround |
| **Reparse Points** | Symlinks vs junctions, safe removal techniques |

---

## Technical Details

### APIs Used
- **DwmSetWindowAttribute** — Dark mode title bar (Windows 10 1809+)
- **MoveFileEx** — Boot-time deletion scheduling (MOVEFILE_DELAY_UNTIL_REBOOT)
- **FSCTL_GET_NTFS_VOLUME_DATA** — Read NTFS volume geometry, MFT size, record size, and reserved zone
- **FSCTL_GET_RETRIEVAL_POINTERS** — Enumerate the physical extents backing the MFT without changing the volume
- **FSCTL_QUERY_USN_JOURNAL / FSCTL_READ_USN_JOURNAL** — Query journal metadata and selectively read change records by reason flags
- **FSCTL_GET_REPARSE_POINT** — Native reparse tag and target inspection without following the link
- **FindFirstFileNameW / FindNextFileNameW** — Enumerate every hard-link name
- **DeleteFileW / RemoveDirectoryW** — Remove only a recognized link or hard-link name without recursive traversal
- **WMI/CIM** — Disk queries, SMART data, file operations

### Key Techniques
- Long path access via `\\?\` prefix bypasses MAX_PATH
- 8.3 short names accessed via `fsutil file setshortname` enumeration
- Robocopy `/MIR` with empty source efficiently removes nested structures
- NTFS ADS enumeration via `Get-Item -Stream *`
- Optional process evidence comes from existing Security event 4663 file-audit records and is explicitly reported as a correlation

### Error Handling
- All operations wrapped in try/catch with user-friendly messages
- Failed deletions automatically suggest next escalation method
- Network and permission errors provide specific remediation steps
- Active repairs can be cancelled safely, and closing the app during one prompts before terminating the child process
- Long-running output is bounded to keep the embedded console responsive

---

## Screenshots

*Coming soon — contributions welcome!*

---

## Troubleshooting

### "Access Denied" after Take Ownership
Some files are protected by Windows Resource Protection (WRP). These cannot be modified even with ownership. This is by design for system stability.

### CHKDSK requires restart
Offline repairs (`/F`, `/R`) on the system drive require exclusive access. Schedule for next boot and restart.

### SMART data unavailable
- USB-connected drives often don't support SMART passthrough
- Some NVMe drives require manufacturer tools
- Virtual disks don't have physical SMART attributes

### File returns after deletion
Check for:
- Application recreating the file (close the app first)
- Cloud sync restoring from server
- Malware persistence mechanisms

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines
- Maintain the existing code style (4-space indentation, verb-noun functions)
- Add educational content for new features
- Test on both Windows 10 and 11
- Update the Help tab if adding major functionality

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- Windows Internals documentation
- PowerShell community best practices
- NTFS technical documentation

---

## Disclaimer

**Use at your own risk.** Filesystem operations can result in data loss if used incorrectly. Always maintain backups before performing repairs or bulk deletions. The authors assume no liability for any damages resulting from the use of this software.

---

<p align="center">
  <b>PathForge</b> — Because some files just won't go quietly.
</p>
